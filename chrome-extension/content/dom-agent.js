// Wisp Tabs — the in-page half of the DOM controller (phase 03).
//
// Injected with chrome.scripting.executeScript({files: ["content/dom-agent.js"]})
// into the page (and, for cross-origin frames, into each frame on its own). It
// reads the page as text and acts on elements by id, so Wisp's browser agent
// works without AppleScript and without a screenshot.
//
// This is a port of the JavaScript `AppleScriptBrowserController` injects, and
// it must stay behaviourally identical to it: the same element selection, the
// same `e7` ids stamped as `data-wisp-id`, the same dialog → in view → below
// ordering, the same labels, roles and state flags, the same React-safe value
// setter and real pointer-event sequence. Wisp's planners, plan validator and
// prompts are written against that format.
//
// Two differences, both on purpose:
//  * Candidates are found with a predicate over `querySelectorAll('*')` rather
//    than one long CSS selector. Same elements, same order, but the tests can
//    drive it against a small fake DOM without a CSS engine.
//  * It refuses a little more (contracts.md §6): `one-time-code` fields and
//    anything inside `[data-wisp-ignore]` are never listed, read or typed into.
//
// Content scripts run in an isolated world that lasts as long as the document,
// so the state (the id registry, the mutation clock) lives on
// `window.__wispAgent` and a second injection into the same document reuses it.
// It never throws back at the caller: every entry point returns a plain object
// with a `status` the extension (and Wisp) can read.
//
// A classic script, not a module: executeScript({files}) runs files as scripts.

(function installWispAgent() {
  "use strict";

  const AGENT_VERSION = 1;
  const existingAgent = window.__wispAgent;
  if (existingAgent && existingAgent.version === AGENT_VERSION) {
    return;
  }

  // Keys the agent may press. A fixed list, mirroring
  // `AppleScriptBrowserController.supportedKeyNames`.
  const KEY_CODES = {
    Enter: 13, Escape: 27, Tab: 9, Backspace: 8, Delete: 46, Space: 32,
    ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39,
    PageUp: 33, PageDown: 34, Home: 36, End: 35,
  };

  // How long the DOM must go without structural change to count as quiet.
  // Wisp passes its own number; this is the fallback.
  const DEFAULT_QUIET_MILLISECONDS = 400;

  const agentState = {
    // id → element. Reaches elements inside shadow roots and same-origin
    // frames, where a document-level attribute query cannot.
    elementsByID: existingAgent?.state?.elementsByID ?? {},
    nextElementNumber: existingAgent?.state?.nextElementNumber ?? 0,
    lastMutationAt: Date.now(),
    mutationObserver: null,
  };

  // MARK: - Reading elements

  function cleanText(text) {
    return (text || "").replace(/\s+/g, " ").trim();
  }

  function attributeOf(element, attributeName) {
    return element.getAttribute ? element.getAttribute(attributeName) : null;
  }

  function lowercaseAttribute(element, attributeName) {
    return (attributeOf(element, attributeName) || "").toLowerCase();
  }

  function isVisible(element) {
    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return false;
    const style = getComputedStyle(element);
    return style.visibility !== "hidden" && style.display !== "none" && style.opacity !== "0";
  }

  function isInView(element) {
    const rect = element.getBoundingClientRect();
    return rect.bottom > 0 && rect.top < innerHeight && rect.right > 0 && rect.left < innerWidth;
  }

  function isNearView(element) {
    const rect = element.getBoundingClientRect();
    return rect.bottom > -innerHeight && rect.top < innerHeight * 3;
  }

  const INTERACTIVE_ROLES = new Set([
    "button", "link", "tab", "menuitem", "menuitemcheckbox", "option", "checkbox", "radio",
    "switch", "combobox", "textbox", "searchbox", "slider",
  ]);

  // The predicate form of the AppleScript snapshot's selector:
  // a[href], button, input:not([type=hidden]), select, textarea, summary,
  // [role=…], [contenteditable=""], [contenteditable=true], [onclick]
  function isInteractiveCandidate(element) {
    const tagName = element.tagName;
    if (tagName === "A" && element.hasAttribute("href")) return true;
    if (tagName === "BUTTON" || tagName === "SELECT" || tagName === "TEXTAREA" || tagName === "SUMMARY") return true;
    if (tagName === "INPUT" && lowercaseAttribute(element, "type") !== "hidden") return true;
    if (INTERACTIVE_ROLES.has(attributeOf(element, "role"))) return true;
    const contentEditable = attributeOf(element, "contenteditable");
    if (contentEditable === "" || contentEditable === "true") return true;
    return element.hasAttribute("onclick");
  }

  function isDialog(element) {
    if (element.tagName === "DIALOG" && element.hasAttribute("open")) return true;
    const roleName = attributeOf(element, "role");
    if (roleName === "dialog" || roleName === "alertdialog") return true;
    return attributeOf(element, "aria-modal") === "true";
  }

  function isInsideIgnoredRegion(element) {
    for (let current = element; current; current = current.parentElement) {
      if (current.hasAttribute && current.hasAttribute("data-wisp-ignore")) return true;
    }
    return false;
  }

  // Password and payment fields: listed so the agent knows to ask the user,
  // never read, never typed into. Same rule as `wispSensitive`, plus
  // one-time codes.
  function isSensitiveField(element) {
    const fieldType = (element.type || "").toLowerCase();
    if (fieldType === "password") return true;
    // Autocomplete is a list of tokens ("billing cc-number", "section-a
    // current-password"), so each token is checked, not just the first.
    const autocompleteTokens = lowercaseAttribute(element, "autocomplete").split(/\s+/).filter(Boolean);
    for (const token of autocompleteTokens) {
      if (token.indexOf("cc-") === 0 || token.indexOf("password") >= 0 || token === "one-time-code") return true;
    }
    const describingText = (
      (element.name || "") + " " + (element.id || "") + " " + (element.placeholder || "") + " " +
      (attributeOf(element, "aria-label") || "")
    ).toLowerCase();
    return /card.?num|cardnumber|cvc|cvv|security.?code|expir/.test(describingText);
  }

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
    const innerText = cleanText(element.innerText);
    if (innerText) return innerText;
    const image = firstDescendant(element, (candidate) => candidate.tagName === "IMG" && candidate.hasAttribute("alt"));
    if (image && cleanText(image.alt)) return cleanText(image.alt);
    const buttonValue = (element.tagName === "INPUT" && /^(submit|button|reset)$/i.test(element.type)) ? element.value : "";
    return cleanText(element.placeholder || element.title || element.alt || buttonValue || element.name || "");
  }

  function roleOf(element) {
    const explicitRole = attributeOf(element, "role");
    if (explicitRole) return explicitRole;
    const tagName = element.tagName;
    if (tagName === "A") return "link";
    if (tagName === "BUTTON" || tagName === "SUMMARY") return "button";
    if (tagName === "SELECT") return "select";
    if (tagName === "TEXTAREA" || element.isContentEditable) return "textbox";
    if (tagName === "INPUT") {
      const inputType = (element.type || "text").toLowerCase();
      if (/^(submit|button|reset|image)$/.test(inputType)) return "button";
      if (/^(text|email|search|url|tel|number|password)$/.test(inputType)) {
        return inputType === "text" ? "textbox" : "textbox:" + inputType;
      }
      return inputType;
    }
    return "control";
  }

  function stateOf(element) {
    const flags = [];
    if (element.disabled || attributeOf(element, "aria-disabled") === "true") flags.push("disabled");
    if (element.checked || attributeOf(element, "aria-checked") === "true") flags.push("checked");
    const expanded = attributeOf(element, "aria-expanded");
    if (expanded) flags.push(expanded === "true" ? "expanded" : "collapsed");
    const ariaCurrent = attributeOf(element, "aria-current");
    if (attributeOf(element, "aria-selected") === "true" || (ariaCurrent && ariaCurrent !== "false")) flags.push("selected");
    if (element.required) flags.push("required");
    if (document.activeElement === element) flags.push("focused");
    return flags.join(",");
  }

  function firstDescendant(root, predicate) {
    if (!root.querySelectorAll) return null;
    const descendants = root.querySelectorAll("*");
    for (let index = 0; index < descendants.length; index++) {
      if (predicate(descendants[index])) return descendants[index];
    }
    return null;
  }

  // Candidates in the order the AppleScript walk produces them: a root's own
  // matches in document order, then each shadow root and same-origin frame
  // under it, four levels deep at most.
  function collectCandidates(root, depth, found) {
    if (depth > 4) return;
    const descendants = root.querySelectorAll("*");
    descendants.forEach((element) => {
      if (isInteractiveCandidate(element)) found.push(element);
    });
    descendants.forEach((element) => {
      if (element.shadowRoot) collectCandidates(element.shadowRoot, depth + 1, found);
      if (element.tagName === "IFRAME") {
        try {
          const frameDocument = element.contentDocument;
          if (frameDocument && frameDocument.body) collectCandidates(frameDocument, depth + 1, found);
        } catch (crossOriginError) {
          // A cross-origin frame gets its own injection (allFrames).
        }
      }
    });
  }

  function findElement(elementID) {
    const registered = agentState.elementsByID[elementID];
    if (registered && registered.isConnected) return registered;
    return firstDescendant(document, (candidate) => attributeOf(candidate, "data-wisp-id") === elementID);
  }

  function openDialog() {
    const dialogs = [];
    document.querySelectorAll("*").forEach((element) => {
      if (isDialog(element) && isVisible(element)) dialogs.push(element);
    });
    return dialogs.length ? dialogs[dialogs.length - 1] : null;
  }

  // MARK: - Snapshot

  function snapshot({ maximumTextCharacters = 1500, elementLimit = 25 } = {}) {
    for (const elementID of Object.keys(agentState.elementsByID)) {
      if (!agentState.elementsByID[elementID].isConnected) delete agentState.elementsByID[elementID];
    }

    const candidates = [];
    collectCandidates(document, 0, candidates);
    const dialog = openDialog();

    const ranked = [];
    const seen = new Set();
    candidates.forEach((element, documentIndex) => {
      if (seen.has(element)) return;
      seen.add(element);
      if (!isVisible(element)) return;
      if (isInsideIgnoredRegion(element)) return;
      const isInDialog = Boolean(dialog && dialog.contains(element));
      if (!isInDialog && !isNearView(element)) return;
      const priority = isInDialog ? 0 : (isInView(element) ? 1 : 2);
      ranked.push({ element, priority, documentIndex });
    });
    ranked.sort((first, second) => first.priority - second.priority || first.documentIndex - second.documentIndex);

    const elements = [];
    for (let rankIndex = 0; rankIndex < ranked.length && elements.length < elementLimit; rankIndex++) {
      const { element, priority } = ranked[rankIndex];
      const label = labelOf(element).slice(0, 90);
      const role = roleOf(element);
      if (!label && role.indexOf("textbox") < 0 && role !== "select" && role !== "combobox") continue;

      // Stable ids: an element keeps the id an earlier snapshot gave it.
      let elementID = attributeOf(element, "data-wisp-id");
      if (!elementID || agentState.elementsByID[elementID] !== element) {
        elementID = "e" + agentState.nextElementNumber++;
        element.setAttribute("data-wisp-id", elementID);
      }
      agentState.elementsByID[elementID] = element;

      const described = { id: elementID, role, label: label || "(unlabelled)", priority };
      const state = stateOf(element);
      if (state) described.state = state;
      if (isSensitiveField(element)) described.sensitive = true;
      if (element.tagName === "A" && element.href) described.href = element.href.slice(0, 160);
      if (!described.sensitive && element.value && element.tagName !== "BUTTON" && typeof element.value === "string") {
        described.value = element.value.slice(0, 60);
      }
      if (element.tagName === "SELECT" && element.selectedOptions && element.selectedOptions[0]) {
        described.value = cleanText(element.selectedOptions[0].text).slice(0, 60);
      }
      elements.push(described);
    }

    const headings = [];
    document.querySelectorAll("*").forEach((element) => {
      if (headings.length >= 6) return;
      if (!/^H[123]$/.test(element.tagName) || !isVisible(element)) return;
      const headingText = cleanText(element.innerText);
      if (headingText) headings.push(headingText.slice(0, 90));
    });

    const mainRegion = dialog ||
      firstDescendant(document, (element) => element.tagName === "MAIN" || element.tagName === "ARTICLE" || attributeOf(element, "role") === "main") ||
      document.body;
    const text = ((mainRegion && mainRegion.innerText) || "").replace(/\n{3,}/g, "\n\n").trim().slice(0, maximumTextCharacters);

    const scrollableHeight = Math.max(document.documentElement.scrollHeight - innerHeight, 0);
    const scrollDescription = scrollableHeight <= 4
      ? "the whole page fits on screen"
      : "scrolled " + Math.round(100 * scrollY / scrollableHeight) + "% down the page";

    let dialogLabel = "";
    if (dialog) {
      const dialogHeading = firstDescendant(dialog, (element) => /^H[123]$/.test(element.tagName));
      dialogLabel = cleanText(attributeOf(dialog, "aria-label") || (dialogHeading || {}).innerText || "untitled").slice(0, 80);
    }

    return {
      status: "OK",
      url: location.href,
      title: document.title,
      headings,
      elements,
      text,
      scroll: scrollDescription,
      dialog: dialogLabel,
    };
  }

  // MARK: - Acting

  function pointerEventOptions(element, buttons) {
    const rect = element.getBoundingClientRect();
    return {
      bubbles: true, cancelable: true, composed: true,
      clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2,
      view: window, button: 0, buttons, pointerType: "mouse", isPrimary: true,
    };
  }

  function dispatch(element, EventConstructor, eventName, options) {
    try {
      element.dispatchEvent(new EventConstructor(eventName, options));
    } catch (dispatchError) {
      // An event type the page's realm lacks; the rest of the sequence still runs.
    }
  }

  // A bare element.click() fires only `click`, and many menus and custom
  // dropdowns listen for pointerdown/mousedown instead. So the whole sequence
  // a real press produces is dispatched at the element's centre first.
  function click({ id }) {
    const element = findElement(id);
    if (!element) return { status: "MISSING" };
    if (element.disabled || attributeOf(element, "aria-disabled") === "true") return { status: "DISABLED" };
    if (isInsideIgnoredRegion(element)) return { status: "IGNORED" };
    element.scrollIntoView({ block: "center", inline: "center" });
    const options = pointerEventOptions(element, 1);
    dispatch(element, PointerEvent, "pointerover", options);
    dispatch(element, MouseEvent, "mouseover", options);
    dispatch(element, PointerEvent, "pointerdown", options);
    dispatch(element, MouseEvent, "mousedown", options);
    if (element.focus) element.focus();
    options.buttons = 0;
    dispatch(element, PointerEvent, "pointerup", options);
    dispatch(element, MouseEvent, "mouseup", options);
    element.click();
    return { status: "OK" };
  }

  // Dispatches a key the way a real one arrives; Enter submits the enclosing
  // form when no handler claimed the key.
  function sendKey(element, keyName, submitsForm) {
    const keyCode = KEY_CODES[keyName] || 0;
    const options = {
      key: keyName === "Space" ? " " : keyName, code: keyName, keyCode, which: keyCode,
      bubbles: true, cancelable: true, composed: true,
    };
    const wasNotCancelled = element.dispatchEvent(new KeyboardEvent("keydown", options));
    if (keyName === "Enter") element.dispatchEvent(new KeyboardEvent("keypress", options));
    element.dispatchEvent(new KeyboardEvent("keyup", options));
    if (submitsForm && wasNotCancelled && element.form) {
      if (element.form.requestSubmit) element.form.requestSubmit();
      else element.form.submit();
    }
  }

  // Setting .value directly is invisible to React, which tracks the value
  // through the prototype's setter. Calling the native setter and then
  // dispatching `input` is the change React, Vue and most others see.
  // Rich-text editors are contenteditable and take text through insertText.
  function typeText({ id, text, pressEnter }) {
    const element = findElement(id);
    if (!element) return { status: "MISSING" };
    if (isSensitiveField(element) || isInsideIgnoredRegion(element)) return { status: "SENSITIVE" };
    const textToType = String(text ?? "");
    element.scrollIntoView({ block: "center" });
    if (element.focus) element.focus();
    if (element.isContentEditable) {
      document.execCommand("selectAll", false, null);
      document.execCommand("insertText", false, textToType);
    } else {
      const prototype = element.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const valueDescriptor = Object.getOwnPropertyDescriptor(prototype, "value");
      if (valueDescriptor && valueDescriptor.set) valueDescriptor.set.call(element, textToType);
      else element.value = textToType;
      try {
        element.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, data: textToType, inputType: "insertText" }));
      } catch (inputEventError) {
        element.dispatchEvent(new Event("input", { bubbles: true }));
      }
      element.dispatchEvent(new Event("change", { bubbles: true }));
    }
    if (pressEnter) sendKey(element, "Enter", true);
    return { status: "OK" };
  }

  function hover({ id }) {
    const element = findElement(id);
    if (!element) return { status: "MISSING" };
    element.scrollIntoView({ block: "center" });
    const rect = element.getBoundingClientRect();
    const options = {
      bubbles: true, cancelable: true, composed: true,
      clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2, view: window, pointerType: "mouse",
    };
    ["pointerover", "pointerenter", "mouseover", "mouseenter", "pointermove", "mousemove"].forEach((eventName) => {
      dispatch(element, eventName.indexOf("pointer") === 0 ? PointerEvent : MouseEvent, eventName, options);
    });
    return { status: "OK" };
  }

  function pressKey({ key }) {
    if (!Object.prototype.hasOwnProperty.call(KEY_CODES, key)) return { status: "UNSUPPORTED_KEY" };
    let focusedElement = document.activeElement || document.body;
    while (focusedElement && focusedElement.shadowRoot && focusedElement.shadowRoot.activeElement) {
      focusedElement = focusedElement.shadowRoot.activeElement;
    }
    sendKey(focusedElement, key, key === "Enter");
    return { status: "OK" };
  }

  function scrollPage({ direction }) {
    if (direction === "down") window.scrollBy(0, innerHeight * 0.85);
    else if (direction === "up") window.scrollBy(0, -innerHeight * 0.85);
    else if (direction === "top") window.scrollTo(0, 0);
    else if (direction === "bottom") window.scrollTo(0, document.body.scrollHeight);
    else return { status: "UNSUPPORTED_DIRECTION" };
    return { status: "OK" };
  }

  // Matches on visible text, which is what a person names, then fires change
  // so frameworks bound to the select notice.
  function selectOption({ id, optionLabel }) {
    const element = findElement(id);
    if (!element) return { status: "MISSING" };
    if (!element.options) return { status: "NOTSELECT" };
    if (isSensitiveField(element) || isInsideIgnoredRegion(element)) return { status: "SENSITIVE" };
    const wantedText = String(optionLabel ?? "").toLowerCase();
    let matchingOption = null;
    for (let optionIndex = 0; optionIndex < element.options.length; optionIndex++) {
      const option = element.options[optionIndex];
      if (option.text.toLowerCase().indexOf(wantedText) >= 0 || option.value.toLowerCase() === wantedText) {
        matchingOption = option;
        break;
      }
    }
    if (!matchingOption) return { status: "NOOPTION" };
    const valueDescriptor = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value");
    if (valueDescriptor && valueDescriptor.set) valueDescriptor.set.call(element, matchingOption.value);
    else element.value = matchingOption.value;
    element.dispatchEvent(new Event("input", { bubbles: true }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
    return { status: "OK" };
  }

  // MARK: - Settling and placing

  // Observes child-list and text changes only: attribute churn (hover styles,
  // animated classes) is constant and says nothing about whether the content
  // the agent waits for has arrived. Installed once per document.
  function quietness({ quietMilliseconds = DEFAULT_QUIET_MILLISECONDS } = {}) {
    if (!agentState.mutationObserver) {
      agentState.lastMutationAt = Date.now();
      agentState.mutationObserver = new MutationObserver(() => {
        agentState.lastMutationAt = Date.now();
      });
      agentState.mutationObserver.observe(document.documentElement, { subtree: true, childList: true, characterData: true });
    }
    const millisecondsSinceLastMutation = Date.now() - agentState.lastMutationAt;
    return {
      status: "OK",
      readyState: document.readyState,
      millisecondsSinceLastMutation,
      isQuiet: document.readyState === "complete" && millisecondsSinceLastMutation >= quietMilliseconds,
    };
  }

  // The element's centre in viewport pixels, plus what the extension needs to
  // turn that into a screen point: the browser chrome around the viewport.
  // Nil-equivalent (`MISSING`) when the tab is in the background: the element
  // isn't on screen at all then.
  function elementScreenGeometry({ id }) {
    const element = findElement(id);
    if (!element || document.visibilityState !== "visible") return { status: "MISSING" };
    element.scrollIntoView({ block: "center" });
    const rect = element.getBoundingClientRect();
    return {
      status: "OK",
      centerX: rect.left + rect.width / 2,
      centerY: rect.top + rect.height / 2,
      viewportWidth: innerWidth,
      viewportHeight: innerHeight,
    };
  }

  window.__wispAgent = {
    version: AGENT_VERSION,
    state: agentState,
    snapshot,
    click,
    typeText,
    hover,
    pressKey,
    scrollPage,
    selectOption,
    quietness,
    elementScreenGeometry,
  };
})();
