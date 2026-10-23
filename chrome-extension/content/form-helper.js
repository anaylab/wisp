// Wisp Tabs — the in-page half of the form helper (phase 12).
//
// Injected after content/dom-agent.js (handlers/form-helper.js injects both),
// into the top frame only. It lists a form's fields so Wisp can propose values
// from what it knows about the user, and, after the user allowed those values
// on Wisp's card, types them in with the DOM agent's React-safe setter.
//
// This is the most safety-sensitive script the extension has, so it refuses on
// its own, whatever Wisp asks (contracts.md §6 and the phase 12 brief):
//  * It never reads a field's value. `describeForm` says only whether a field
//    already has something in it.
//  * Passwords, payment fields, government ids, one-time codes and security
//    questions are listed as refused (so Wisp can say "won't fill") with no
//    options and nothing about their contents, and `fillFields` never types
//    into them — judged by type, autocomplete and every piece of text that
//    describes the field, so "Email (or your password)" is a password field.
//  * It never submits, never clicks, never presses Enter: text goes in through
//    the agent's `typeText` with `pressEnter: false`, and a select is set by
//    exact option, nothing else is touched.
//  * Anything inside `[data-wisp-ignore]` is neither listed nor filled.
//
// The refusal patterns are mirrored in Wisp's `FormFillRefusal`
// (FormFillPlanner.swift); Wisp refuses again before it ever asks the user.
//
// Ids are the DOM agent's `e7` ids, from the agent's own registry, so a field
// keeps the id a snapshot gave it and in-page pointing can mark it.
//
// A classic script, not a module: executeScript({files}) runs files as scripts.

(function installWispFormHelper() {
  "use strict";

  const FORM_HELPER_VERSION = 1;
  if (window.__wispFormHelper && window.__wispFormHelper.version === FORM_HELPER_VERSION) {
    return;
  }

  // Fields listed per form. A sign-up or application form is a few dozen at
  // most; anything past this is a page-sized "form" Wisp shouldn't fill anyway.
  const MAXIMUM_LISTED_FIELDS = 60;
  const MAXIMUM_LABEL_CHARACTERS = 120;
  const MAXIMUM_LISTED_OPTIONS = 60;
  const MAXIMUM_OPTION_CHARACTERS = 80;
  const MAXIMUM_FILLED_VALUE_CHARACTERS = 2000;

  // Input types that take typed text Wisp may know. Checkboxes, radios, files,
  // dates, colours and ranges are left to the user.
  const FILLABLE_INPUT_TYPES = new Set(["text", "email", "tel", "url", "search", "number", ""]);

  // Never listed at all: not something a person fills.
  const UNLISTED_INPUT_TYPES = new Set(["hidden", "submit", "button", "reset", "image", "file"]);

  // MARK: - Refusals

  // Each reason with the words that mean it, matched against the field's
  // label, name, id, placeholder, aria-label, title and autocomplete together.
  // Biased toward refusing: a field wrongly refused is one the user types
  // themselves; a field wrongly filled could leak something that matters.
  const REFUSAL_PATTERNS = [
    ["password", /pass(?:word|wd|phrase|code)|\bpwd\b|\bpin\b|\bpin ?(?:code|number)\b|\bsecret\b/],
    ["payment", /card ?(?:number|no\b|holder|verification)|cardholder|name on (?:the )?card|credit ?card|debit ?card|\bcc ?(?:num|number|no)\b|\bcvc\b|\bcvv2?\b|\bcsc\b|security ?code|expir(?:y|ation|es)|\bexp ?(?:date|month|year)\b|\biban\b|\bswift\b|\bbic\b|routing ?(?:number|no)|account ?(?:number|no\b)|sort ?code|\bbank\b/],
    ["governmentID", /\bssn\b|social ?security|social ?insurance|national ?insurance|passport|driv(?:er|ing)'?s? ?licen[cs]e|licen[cs]e ?(?:number|no\b)|\btax ?(?:id|number)\b|\btin\b|\bitin\b|\bein\b|national ?id|government ?id|\bid ?(?:number|no\b)|identity ?(?:number|card)|aadhaar|\bnric\b|\bcpf\b/],
    ["oneTimeCode", /one[- ]?time|\botp\b|verification ?code|confirmation ?code|\b2fa\b|two[- ]?(?:factor|step)|authenticat|auth ?code|code (?:we )?sent|sms ?code/],
    ["securityQuestion", /security ?(?:question|answer)|secret ?(?:question|answer)|maiden ?name|first ?pet|pet'?s ?name|childhood|grew up|first ?(?:car|school|teacher|job)|favou?rite ?(?:teacher|book|movie|food|color|colour|sports)|memorable ?(?:word|place|date|name)|born in (?:what|which) city/],
  ];

  function cleanText(text) {
    return String(text || "").replace(/\s+/g, " ").trim();
  }

  function attributeOf(element, attributeName) {
    return element.getAttribute ? element.getAttribute(attributeName) : null;
  }

  function lowercaseAttribute(element, attributeName) {
    return (attributeOf(element, attributeName) || "").toLowerCase();
  }

  function isInsideIgnoredRegion(element) {
    for (let current = element; current; current = current.parentElement) {
      if (current.hasAttribute && current.hasAttribute("data-wisp-ignore")) return true;
    }
    return false;
  }

  // The reason a field is never read or filled, or null.
  function refusalReasonFor(element, label) {
    const fieldType = String(element.type || "").toLowerCase();
    if (fieldType === "password") return "password";
    const autocomplete = lowercaseAttribute(element, "autocomplete");
    const autocompleteTokens = autocomplete.split(/\s+/).filter(Boolean);
    for (const token of autocompleteTokens) {
      if (token.indexOf("cc-") === 0) return "payment";
      if (token === "current-password" || token === "new-password" || token.indexOf("password") >= 0) return "password";
      if (token === "one-time-code") return "oneTimeCode";
      if (token === "webauthn") return "password";
      if (token === "transaction-amount" || token === "transaction-currency") return "payment";
    }
    const describingText = [
      label,
      element.name,
      element.id,
      element.placeholder,
      attributeOf(element, "aria-label"),
      attributeOf(element, "aria-description"),
      element.title,
      autocomplete,
    ].map((part) => cleanText(part)).join(" ")
      // Splits camelCase and snake_case names into words ("cardNumber" →
      // "card number") before lowercasing, which would hide the boundary.
      .replace(/([a-z])([A-Z])/g, "$1 $2")
      .toLowerCase()
      .replace(/[_\-.[\]]+/g, " ");
    for (const [reason, pattern] of REFUSAL_PATTERNS) {
      if (pattern.test(describingText)) return reason;
    }
    return null;
  }

  // MARK: - Reading fields

  // Only fields a person can see. A field that is invisible, transparent or
  // parked off the page is how a hostile page collects autofilled details the
  // user never meant to give it, so those are never listed or filled.
  function isVisible(element) {
    if (attributeOf(element, "aria-hidden") === "true") return false;
    const rect = element.getBoundingClientRect();
    if (rect.width < 2 || rect.height < 2) return false;
    if (rect.right <= 0 || rect.bottom + (window.scrollY || 0) <= 0) return false;
    const style = getComputedStyle(element);
    return style.visibility !== "hidden" && style.display !== "none" && style.opacity !== "0";
  }

  // What a person reads as the field's name: an explicit aria label, the
  // `<label>` (for= or wrapping), then placeholder, title, name. Never the
  // field's own value.
  function labelOf(element) {
    const ariaLabel = cleanText(attributeOf(element, "aria-label"));
    if (ariaLabel) return ariaLabel;
    const labelledBy = attributeOf(element, "aria-labelledby");
    if (labelledBy) {
      const joined = labelledBy.split(" ").map((labelID) => {
        const labelElement = element.ownerDocument.getElementById(labelID);
        return labelElement ? labelElement.innerText : "";
      }).join(" ");
      if (cleanText(joined)) return cleanText(joined);
    }
    if (element.labels && element.labels.length) {
      const fromLabel = cleanText(element.labels[0].innerText);
      if (fromLabel) return fromLabel;
    }
    for (let ancestor = element.parentElement; ancestor; ancestor = ancestor.parentElement) {
      if (ancestor.tagName === "LABEL") {
        const fromWrappingLabel = cleanText(ancestor.innerText);
        if (fromWrappingLabel) return fromWrappingLabel;
        break;
      }
    }
    return cleanText(element.placeholder || element.title || element.name || "");
  }

  function fieldKindOf(element) {
    if (element.tagName === "TEXTAREA") return "textarea";
    if (element.tagName === "SELECT") return "select";
    if (element.tagName !== "INPUT") return null;
    const inputType = String(element.type || "").toLowerCase();
    if (UNLISTED_INPUT_TYPES.has(inputType)) return null;
    if (inputType === "password") return "password";
    if (FILLABLE_INPUT_TYPES.has(inputType)) return inputType || "text";
    // Checkbox, radio, date, colour, range…: listed so the user hears about
    // them, never filled.
    return "other:" + inputType;
  }

  function isFieldElement(element) {
    return (element.tagName === "INPUT" || element.tagName === "TEXTAREA" || element.tagName === "SELECT") &&
      fieldKindOf(element) !== null;
  }

  function hasValue(element) {
    if (element.tagName === "SELECT") {
      // A select always has some option chosen; it "has a value" only when
      // that isn't the empty placeholder option.
      return Boolean(element.value);
    }
    const inputType = String(element.type || "").toLowerCase();
    if (inputType === "checkbox" || inputType === "radio") return Boolean(element.checked);
    return String(element.value ?? "").length > 0;
  }

  function agent() {
    const domAgent = window.__wispAgent;
    if (!domAgent || !domAgent.state) throw new Error("the page agent isn't installed");
    return domAgent;
  }

  // The DOM agent's id for this element, handing out a new one from the same
  // counter when it has none yet, exactly as a snapshot would.
  function elementIDFor(element) {
    const agentState = agent().state;
    let elementID = attributeOf(element, "data-wisp-id");
    if (!elementID || agentState.elementsByID[elementID] !== element) {
      elementID = "e" + agentState.nextElementNumber++;
      element.setAttribute("data-wisp-id", elementID);
    }
    agentState.elementsByID[elementID] = element;
    return elementID;
  }

  function findElement(elementID) {
    const agentState = agent().state;
    const registered = agentState.elementsByID[elementID];
    if (registered && registered.isConnected) return registered;
    const everyElement = document.querySelectorAll("*");
    for (let index = 0; index < everyElement.length; index++) {
      if (attributeOf(everyElement[index], "data-wisp-id") === elementID) return everyElement[index];
    }
    return null;
  }

  function visibleFieldsUnder(root) {
    const fields = [];
    root.querySelectorAll("*").forEach((element) => {
      if (!isFieldElement(element)) return;
      if (isInsideIgnoredRegion(element)) return;
      if (!isVisible(element)) return;
      fields.push(element);
    });
    return fields;
  }

  function enclosingForm(element) {
    if (element.form) return element.form;
    for (let ancestor = element.parentElement; ancestor; ancestor = ancestor.parentElement) {
      if (ancestor.tagName === "FORM") return ancestor;
    }
    return null;
  }

  // Which fields "this form" means: the form Wisp was pointed at (an element
  // id of the form or anything inside it); else the form holding the focused
  // field; else the form with the most fields; else, for pages that build
  // forms without a <form> element, every field on the page.
  function chooseFormFields(formElementId) {
    const everyField = visibleFieldsUnder(document);
    if (formElementId) {
      const pointedElement = findElement(formElementId);
      if (!pointedElement) return { status: "MISSING" };
      const pointedForm = pointedElement.tagName === "FORM" ? pointedElement : enclosingForm(pointedElement);
      if (!pointedForm) return { status: "NOT_A_FORM" };
      return { status: "OK", form: pointedForm, fields: everyField.filter((field) => pointedForm.contains(field)) };
    }
    const focusedForm = document.activeElement ? enclosingForm(document.activeElement) : null;
    if (focusedForm) {
      return { status: "OK", form: focusedForm, fields: everyField.filter((field) => focusedForm.contains(field)) };
    }
    const fieldsByForm = new Map();
    everyField.forEach((field) => {
      const form = enclosingForm(field);
      if (!form) return;
      if (!fieldsByForm.has(form)) fieldsByForm.set(form, []);
      fieldsByForm.get(form).push(field);
    });
    let biggestForm = null;
    fieldsByForm.forEach((fields, form) => {
      if (!biggestForm || fields.length > fieldsByForm.get(biggestForm).length) biggestForm = form;
    });
    if (biggestForm) return { status: "OK", form: biggestForm, fields: fieldsByForm.get(biggestForm) };
    return { status: "OK", form: null, fields: everyField };
  }

  function formLabelOf(form) {
    if (!form) return "";
    const ariaLabel = cleanText(attributeOf(form, "aria-label"));
    if (ariaLabel) return ariaLabel.slice(0, MAXIMUM_LABEL_CHARACTERS);
    let heading = null;
    form.querySelectorAll("*").forEach((element) => {
      if (!heading && /^(H[1-4]|LEGEND)$/.test(element.tagName)) heading = element;
    });
    return heading ? cleanText(heading.innerText).slice(0, MAXIMUM_LABEL_CHARACTERS) : "";
  }

  function describeField(element) {
    const label = labelOf(element);
    const kind = fieldKindOf(element);
    const refusal = refusalReasonFor(element, label);
    const described = {
      id: elementIDFor(element),
      label: label.slice(0, MAXIMUM_LABEL_CHARACTERS),
      type: kind,
      autocomplete: lowercaseAttribute(element, "autocomplete").slice(0, 80),
      name: cleanText(element.name).slice(0, 80),
      required: Boolean(element.required || attributeOf(element, "aria-required") === "true"),
      disabled: Boolean(element.disabled || element.readOnly || attributeOf(element, "aria-disabled") === "true"),
    };
    const placeholder = cleanText(element.placeholder);
    if (placeholder && placeholder !== described.label) described.placeholder = placeholder.slice(0, MAXIMUM_LABEL_CHARACTERS);
    if (refusal) {
      // A refused field says why and nothing else: no options, and not even
      // whether something is typed in it.
      described.refused = refusal;
      return described;
    }
    described.hasValue = hasValue(element);
    if (element.tagName === "SELECT" && element.options) {
      const options = [];
      for (let optionIndex = 0; optionIndex < element.options.length && options.length < MAXIMUM_LISTED_OPTIONS; optionIndex++) {
        const option = element.options[optionIndex];
        options.push({
          text: cleanText(option.text).slice(0, MAXIMUM_OPTION_CHARACTERS),
          value: String(option.value ?? "").slice(0, MAXIMUM_OPTION_CHARACTERS),
        });
      }
      described.options = options;
      if (element.options.length > MAXIMUM_LISTED_OPTIONS) described.optionsTruncated = true;
    }
    return described;
  }

  function describeForm({ formElementId } = {}) {
    const chosen = chooseFormFields(formElementId);
    if (chosen.status !== "OK") return { status: chosen.status };
    const listedFields = chosen.fields.slice(0, MAXIMUM_LISTED_FIELDS);
    return {
      status: "OK",
      url: location.href,
      title: document.title,
      formId: chosen.form ? elementIDFor(chosen.form) : null,
      formLabel: formLabelOf(chosen.form),
      fields: listedFields.map(describeField),
      truncated: chosen.fields.length > MAXIMUM_LISTED_FIELDS,
    };
  }

  // MARK: - Filling

  // An option chosen by exact visible text or exact value, ignoring case and
  // spacing — never "contains", so "CA" can't pick "Canada".
  function exactOption(selectElement, wantedValue) {
    const wanted = cleanText(wantedValue).toLowerCase();
    if (!wanted) return null;
    for (let optionIndex = 0; optionIndex < selectElement.options.length; optionIndex++) {
      const option = selectElement.options[optionIndex];
      if (cleanText(option.text).toLowerCase() === wanted || cleanText(option.value).toLowerCase() === wanted) return option;
    }
    return null;
  }

  // The DOM agent's setter technique (native prototype setter, then input and
  // change), for a select chosen by exact option.
  function setSelectValue(selectElement, optionValue) {
    const valueDescriptor = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value");
    if (valueDescriptor && valueDescriptor.set) valueDescriptor.set.call(selectElement, optionValue);
    else selectElement.value = optionValue;
    selectElement.dispatchEvent(new Event("input", { bubbles: true }));
    selectElement.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function fillOneField({ elementId, value }, onlyIntoEmptyFields) {
    if (typeof elementId !== "string" || !/^e\d{1,9}$/.test(elementId)) return "missing";
    if (typeof value !== "string" || value.length === 0 || value.length > MAXIMUM_FILLED_VALUE_CHARACTERS) return "badValue";
    const element = findElement(elementId);
    if (!element || !isFieldElement(element)) return "missing";
    if (isInsideIgnoredRegion(element)) return "refused";
    // Same rule as listing: a field the user can't see is never filled.
    if (!isVisible(element)) return "hidden";
    if (refusalReasonFor(element, labelOf(element))) return "refused";
    const kind = fieldKindOf(element);
    if (kind === "password") return "refused";
    if (!kind || kind.indexOf("other:") === 0) return "notFillable";
    if (element.disabled || element.readOnly || attributeOf(element, "aria-disabled") === "true") return "disabled";
    // Something the user typed after Wisp looked is theirs.
    if (onlyIntoEmptyFields && hasValue(element)) return "alreadyFilled";

    if (kind === "select") {
      const option = exactOption(element, value);
      if (!option) return "noOption";
      setSelectValue(element, option.value);
      return "filled";
    }
    // Single-line fields never take a line break: one could submit some forms.
    const textToType = kind === "textarea" ? value : value.replace(/[\r\n]+/g, " ");
    const typed = agent().typeText({ id: elementId, text: textToType, pressEnter: false });
    if (typed.status === "SENSITIVE") return "refused";
    return typed.status === "OK" ? "filled" : "missing";
  }

  function fillFields({ values, onlyIntoEmptyFields = true } = {}) {
    if (!Array.isArray(values)) return { status: "BAD_REQUEST" };
    const results = values.slice(0, MAXIMUM_LISTED_FIELDS).map((entry) => ({
      elementId: String(entry && entry.elementId || ""),
      status: fillOneField(entry || {}, onlyIntoEmptyFields !== false),
    }));
    return {
      status: "OK",
      results,
      filledCount: results.filter((result) => result.status === "filled").length,
    };
  }

  window.__wispFormHelper = {
    version: FORM_HELPER_VERSION,
    describeForm,
    fillFields,
    refusalReasonFor,
  };
})();
