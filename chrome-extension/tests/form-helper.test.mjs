// The form helper (phase 12): content/form-helper.js against the fake DOM (with
// the real DOM agent under it), and handlers/form-helper.js against the fake
// Chrome. Most of this is about what it must never do: read a value, touch a
// password, payment, id, one-time-code or security-question field, list a
// hidden trap field, press Enter, click or submit.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

import { createFakeChrome } from "./fake-chrome.mjs";
import { FakeDocument, el, loadDomAgent, makeSelect, runSerializedFunction } from "./fake-dom.mjs";
import {
  FORM_HELPER_FILE,
  createFormHelperHandlers,
  samePage,
  validatedFillValues,
} from "../handlers/form-helper.js";
import { DOM_AGENT_FILE } from "../handlers/dom-controller.js";

const FORM_HELPER_SOURCE = readFileSync(
  fileURLToPath(new URL("../content/form-helper.js", import.meta.url)),
  "utf8"
);

function loadFormHelper(fakeDocument) {
  const context = loadDomAgent(fakeDocument);
  vm.runInContext(FORM_HELPER_SOURCE, context);
  return context;
}

// Results cloned into this realm, as executeScript hands them over.
function helperOf(context) {
  return new Proxy({}, {
    get(target, methodName) {
      return (...methodArguments) =>
        JSON.parse(JSON.stringify(context.__wispFormHelper[methodName](...methodArguments)));
    },
  });
}

function labelled(labelText, inputOptions, tagName = "input") {
  const field = el(tagName, inputOptions);
  const label = el("label", { text: labelText });
  field.labels = [label];
  return { label, field };
}

function signUpPage() {
  const fakeDocument = new FakeDocument({ title: "Sign up", url: "https://club.example/join" });
  const form = el("form", {});
  const fields = {};
  const add = (key, labelText, inputOptions, tagName) => {
    const { label, field } = labelled(labelText, inputOptions, tagName);
    field.form = form;
    fields[key] = field;
    form.append(label, field);
  };
  form.append(el("h2", { text: "Your details" }));
  add("first", "First name", { attributes: { name: "first_name", autocomplete: "given-name" }, required: true });
  add("email", "Email", { attributes: { type: "email", name: "email" } });
  add("bio", "Tell us about yourself", { attributes: { name: "bio" } }, "textarea");
  add("password", "Password", { attributes: { type: "password", name: "password" } });
  add("trapEmail", "Email (or your password)", { attributes: { name: "contact" } });
  add("card", "Card number", { attributes: { name: "cardNumber" } });
  add("pet", "What was the name of your first pet?", { attributes: { name: "answer" } });
  const country = makeSelect({ name: "country" }, ["Choose", "Canada", "United States"], 0);
  country.options[0].value = "";
  country.storedValue = "";
  const countryLabel = el("label", { text: "Country" });
  country.labels = [countryLabel];
  country.form = form;
  fields.country = country;
  form.append(countryLabel, country);
  const transparent = el("input", { attributes: { name: "copy", "aria-label": "Email again" }, style: { opacity: "0" } });
  const offscreen = el("input", { attributes: { name: "phone2", "aria-label": "Phone again" }, rect: { left: -9999, top: 10, width: 100, height: 20 } });
  const hidden = el("input", { attributes: { type: "hidden", name: "token" } });
  const ignored = el("div", { attributes: { "data-wisp-ignore": "" } }, el("input", { attributes: { "aria-label": "Nickname" } }));
  const submit = el("button", { attributes: { type: "submit" }, text: "Create account" });
  for (const trap of [transparent, offscreen, hidden]) trap.form = form;
  form.append(transparent, offscreen, hidden, ignored, submit);
  fields.transparent = transparent;
  fields.offscreen = offscreen;
  fields.submit = submit;
  fakeDocument.body.append(el("h1", { text: "Join" }), form);
  return { fakeDocument, form, fields };
}

test("describeForm lists the form's fields with e ids, labels and kinds, never values", () => {
  const { fakeDocument, fields } = signUpPage();
  fields.email.storedValue = "someone@else.example";
  const helper = helperOf(loadFormHelper(fakeDocument));

  const description = helper.describeForm({});

  assert.equal(description.status, "OK");
  assert.equal(description.formLabel, "Your details");
  assert.match(description.formId, /^e\d+$/);
  const byLabel = Object.fromEntries(description.fields.map((field) => [field.label, field]));
  assert.deepEqual(Object.keys(byLabel), [
    "First name", "Email", "Tell us about yourself", "Password", "Email (or your password)",
    "Card number", "What was the name of your first pet?", "Country",
  ]);
  assert.equal(byLabel["First name"].autocomplete, "given-name");
  assert.equal(byLabel["First name"].required, true);
  assert.equal(byLabel["First name"].type, "text");
  assert.equal(byLabel["Tell us about yourself"].type, "textarea");
  assert.equal(byLabel["Email"].hasValue, true);
  assert.equal(byLabel["First name"].hasValue, false);
  assert.deepEqual(byLabel["Country"].options.map((option) => option.text), ["Choose", "Canada", "United States"]);
  assert.equal(byLabel["Country"].hasValue, false);
  // Ids are the DOM agent's: stamped on the element, in its registry.
  assert.equal(fields.first.getAttribute("data-wisp-id"), byLabel["First name"].id);
  // No value anywhere in what goes back to Wisp.
  assert.ok(!JSON.stringify(description).includes("someone@else.example"));
});

test("refused fields say why and nothing else: no options, not even whether they're filled", () => {
  const { fakeDocument, fields } = signUpPage();
  fields.password.storedValue = "hunter2";
  const helper = helperOf(loadFormHelper(fakeDocument));
  const byLabel = Object.fromEntries(helper.describeForm({}).fields.map((field) => [field.label, field]));

  assert.equal(byLabel["Password"].refused, "password");
  assert.equal(byLabel["Email (or your password)"].refused, "password");
  assert.equal(byLabel["Card number"].refused, "payment");
  assert.equal(byLabel["What was the name of your first pet?"].refused, "securityQuestion");
  for (const label of ["Password", "Email (or your password)", "Card number"]) {
    assert.equal("hasValue" in byLabel[label], false, label);
    assert.equal("options" in byLabel[label], false, label);
  }
  assert.ok(!JSON.stringify(byLabel).includes("hunter2"));
});

test("hidden, transparent, off-screen, ignored fields and buttons are never listed", () => {
  const { fakeDocument } = signUpPage();
  const helper = helperOf(loadFormHelper(fakeDocument));
  const labels = helper.describeForm({}).fields.map((field) => field.label);
  for (const trapLabel of ["Email again", "Phone again", "token", "Nickname", "Create account"]) {
    assert.ok(!labels.includes(trapLabel), trapLabel);
  }
});

test("the refusal list, including adversarial labels", () => {
  const fakeDocument = new FakeDocument();
  const context = loadFormHelper(fakeDocument);
  const reasonFor = (label, attributes = {}) =>
    context.__wispFormHelper.refusalReasonFor(el("input", { attributes }), label);

  const refused = [
    ["Email (or your password)", "password"],
    ["Confirm password", "password"],
    ["Passphrase", "password"],
    ["PIN", "password"],
    ["Card number", "payment"],
    ["Name on card", "payment"],
    ["Cardholder name", "payment"],
    ["CVV", "payment"],
    ["Security code", "payment"],
    ["Expiry date", "payment"],
    ["IBAN", "payment"],
    ["Routing number", "payment"],
    ["Social Security number", "governmentID"],
    ["SSN (last 4)", "governmentID"],
    ["Passport number", "governmentID"],
    ["Driver's license number", "governmentID"],
    ["National ID", "governmentID"],
    ["Tax ID", "governmentID"],
    ["Verification code", "oneTimeCode"],
    ["One-time code", "oneTimeCode"],
    ["2FA code", "oneTimeCode"],
    ["Security question", "securityQuestion"],
    ["Mother's maiden name", "securityQuestion"],
    ["Name of your first pet", "securityQuestion"],
  ];
  for (const [label, reason] of refused) assert.equal(reasonFor(label), reason, label);

  // The label can be harmless while the name, id, placeholder or autocomplete isn't.
  assert.equal(reasonFor("Your name", { name: "user_password" }), "password");
  assert.equal(reasonFor("Number", { name: "cardNumber" }), "payment");
  assert.equal(reasonFor("Code", { autocomplete: "one-time-code" }), "oneTimeCode");
  assert.equal(reasonFor("Name", { autocomplete: "cc-name" }), "payment");
  assert.equal(reasonFor("Email", { autocomplete: "username current-password" }), "password");
  assert.equal(reasonFor("Field", { type: "password" }), "password");

  // Ordinary fields stay fillable.
  for (const label of ["First name", "Email address", "Phone", "School", "Street address", "City", "Postal code", "Company", "Bio"]) {
    assert.equal(reasonFor(label), null, label);
  }
});

test("fillFields types allowed values with the agent's setter and never presses Enter, clicks or submits", () => {
  const { fakeDocument, form, fields } = signUpPage();
  let submitCount = 0;
  form.requestSubmit = () => { submitCount += 1; };
  form.submit = () => { submitCount += 1; };
  const helper = helperOf(loadFormHelper(fakeDocument));
  const byLabel = Object.fromEntries(helper.describeForm({}).fields.map((field) => [field.label, field.id]));

  const result = helper.fillFields({
    values: [
      { elementId: byLabel["First name"], value: "Ada\nLovelace" },
      { elementId: byLabel["Tell us about yourself"], value: "Line one\nLine two" },
      { elementId: byLabel["Country"], value: "canada" },
    ],
  });

  assert.equal(result.filledCount, 3);
  assert.equal(fields.first.value, "Ada Lovelace", "a single-line field never takes a line break");
  assert.equal(fields.bio.value, "Line one\nLine two");
  assert.equal(fields.country.value, "canada");
  for (const field of [fields.first, fields.bio, fields.country]) {
    assert.ok(field.dispatchedEvents.includes("input"));
    assert.ok(field.dispatchedEvents.includes("change"));
    assert.ok(!field.dispatchedEvents.some((eventName) => /^key/.test(eventName)), "no key events");
  }
  assert.equal(fields.submit.clickCount, 0);
  assert.equal(submitCount, 0);
});

test("fillFields refuses secret fields even when Wisp asks for them by id", () => {
  const { fakeDocument, fields } = signUpPage();
  const context = loadFormHelper(fakeDocument);
  const helper = helperOf(context);
  const byLabel = Object.fromEntries(helper.describeForm({}).fields.map((field) => [field.label, field.id]));

  const result = helper.fillFields({
    values: [
      { elementId: byLabel["Password"], value: "hunter2" },
      { elementId: byLabel["Email (or your password)"], value: "ada@example.com" },
      { elementId: byLabel["Card number"], value: "4242424242424242" },
      { elementId: byLabel["What was the name of your first pet?"], value: "Rex" },
    ],
  });
  assert.deepEqual(result.results.map((entry) => entry.status), ["refused", "refused", "refused", "refused"]);
  assert.equal(result.filledCount, 0);
  for (const field of [fields.password, fields.trapEmail, fields.card, fields.pet]) assert.equal(field.value, "");

  // A trap field given an id by an earlier snapshot is still invisible, so not a field to fill.
  context.__wispAgent.state.elementsByID.e99 = fields.transparent;
  fields.transparent.setAttribute("data-wisp-id", "e99");
  const transparentResult = helper.fillFields({ values: [{ elementId: "e99", value: "ada@example.com" }] });
  assert.deepEqual(transparentResult.results, [{ elementId: "e99", status: "hidden" }]);
  assert.equal(fields.transparent.value, "");
});

test("fillFields leaves what the user typed, picks select options exactly, and rejects bad entries", () => {
  const { fakeDocument, fields } = signUpPage();
  const helper = helperOf(loadFormHelper(fakeDocument));
  const byLabel = Object.fromEntries(helper.describeForm({}).fields.map((field) => [field.label, field.id]));
  fields.email.storedValue = "typed@by.user";

  const result = helper.fillFields({
    values: [
      { elementId: byLabel["Email"], value: "ada@example.com" },
      { elementId: byLabel["Country"], value: "can" },
      { elementId: "e999", value: "x" },
      { elementId: byLabel["First name"], value: "" },
    ],
  });
  assert.deepEqual(result.results.map((entry) => entry.status), ["alreadyFilled", "noOption", "missing", "badValue"]);
  assert.equal(fields.email.value, "typed@by.user");
  assert.equal(fields.country.value, "");
});

// MARK: - The handler

function makeChromeWithPage({ fakeDocument, tab }) {
  let context = null;
  const injectedFiles = [];
  const executeScript = ({ target, files, func, args }) => {
    assert.deepEqual(target.frameIds, [0], "the form helper only works in the top frame");
    if (files) {
      injectedFiles.push(...files);
      context = loadFormHelper(fakeDocument);
      return [{ frameId: 0, result: null }];
    }
    const pageContext = context ?? Object.assign(vm.createContext({}), {});
    if (!context) pageContext.window = pageContext;
    return [{ frameId: 0, result: JSON.parse(JSON.stringify(runSerializedFunction(pageContext, func, args) ?? null)) }];
  };
  const fakeChrome = createFakeChrome({
    windows: [{ id: 1, type: "normal", focused: true, incognito: false }],
    tabs: [tab],
    executeScript,
  });
  return { fakeChrome, injectedFiles };
}

test("describeForm injects the DOM agent and the form helper, then lists the front tab's form", async () => {
  const { fakeDocument } = signUpPage();
  const { fakeChrome, injectedFiles } = makeChromeWithPage({
    fakeDocument,
    tab: { id: 7, windowId: 1, active: true, url: "https://club.example/join", title: "Sign up", status: "complete" },
  });
  const handlers = createFormHelperHandlers({ chromeAPI: () => fakeChrome });

  const description = await handlers.describeForm({});
  assert.deepEqual(injectedFiles, [DOM_AGENT_FILE, FORM_HELPER_FILE]);
  assert.equal(description.tabId, 7);
  assert.equal(description.url, "https://club.example/join");
  assert.equal(description.fields.length, 8);
});

test("fillFormFields refuses a tab that moved to another page, and fills the same page", async () => {
  const { fakeDocument, fields } = signUpPage();
  const tab = { id: 7, windowId: 1, active: true, url: "https://club.example/join", title: "Sign up", status: "complete" };
  const { fakeChrome } = makeChromeWithPage({ fakeDocument, tab });
  const handlers = createFormHelperHandlers({ chromeAPI: () => fakeChrome });
  const description = await handlers.describeForm({ tabId: 7 });
  const firstNameID = description.fields.find((field) => field.label === "First name").id;

  await assert.rejects(
    handlers.fillFormFields({ tabId: 7, expectedUrl: "https://other.example/join", values: [{ elementId: firstNameID, value: "Ada" }] }),
    /moved to another page/
  );
  assert.equal(fields.first.value, "");

  const filled = await handlers.fillFormFields({
    tabId: 7,
    expectedUrl: "https://club.example/join?step=1#top",
    values: [{ elementId: firstNameID, value: "Ada" }, { elementId: "f12e3", value: "x" }],
  });
  assert.equal(filled.filledCount, 1);
  assert.equal(fields.first.value, "Ada");
  assert.deepEqual(filled.results.at(-1), { elementId: "f12e3", status: "badRequest" });
});

test("protected pages, incognito tabs and missing permission are refused", async () => {
  const { fakeDocument } = signUpPage();
  for (const [tab, pattern] of [
    [{ id: 7, windowId: 1, active: true, url: "chrome://settings/" }, /ordinary web pages/],
    [{ id: 7, windowId: 1, active: true, url: "file:///Users/me/form.html" }, /ordinary web pages/],
    [{ id: 7, windowId: 1, active: true, url: "https://club.example/", incognito: true }, /incognito/],
  ]) {
    const { fakeChrome } = makeChromeWithPage({ fakeDocument, tab });
    const handlers = createFormHelperHandlers({ chromeAPI: () => fakeChrome });
    await assert.rejects(handlers.describeForm({ tabId: 7 }), pattern);
  }
  const { fakeChrome } = makeChromeWithPage({
    fakeDocument,
    tab: { id: 7, windowId: 1, active: true, url: "https://club.example/" },
  });
  delete fakeChrome.scripting;
  const handlers = createFormHelperHandlers({ chromeAPI: () => fakeChrome });
  await assert.rejects(handlers.describeForm({ tabId: 7 }), /missing capability pages\.read/);
});

test("request shape: ids, duplicates, blanks and same-page checks", () => {
  const { accepted, rejected } = validatedFillValues([
    { elementId: "e1", value: "Ada" },
    { elementId: "e1", value: "again" },
    { elementId: "f3e2", value: "frame" },
    { elementId: "e2", value: "   " },
    { elementId: "e3", value: 42 },
    { elementId: "e4", value: "x".repeat(2001) },
  ]);
  assert.deepEqual(accepted, [{ elementId: "e1", value: "Ada" }]);
  assert.equal(rejected.length, 5);
  assert.ok(samePage("https://a.example/form?x=1", "https://a.example/form#y"));
  assert.ok(!samePage("https://a.example/form", "https://a.example/other"));
  assert.ok(!samePage("https://a.example/form", "https://b.example/form"));
  assert.ok(!samePage("not a url", "https://a.example/"));
});
