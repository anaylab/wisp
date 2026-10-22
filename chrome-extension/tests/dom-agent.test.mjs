// content/dom-agent.js against the fake DOM: the snapshot format and ids Wisp's
// planners depend on, the dialog-first order, the sensitive-field refusals,
// select by visible text, and settle detection.

import { test } from "node:test";
import assert from "node:assert/strict";

import { FakeDocument, el, loadAgent, loadDomAgent, makeSelect } from "./fake-dom.mjs";

function pageWithSearchForm() {
  const fakeDocument = new FakeDocument({ title: "Search", url: "https://search.example/" });
  const searchField = el("input", { attributes: { type: "search", "aria-label": "Search" } });
  const submitButton = el("button", { text: "Go" });
  const aboutLink = el("a", { attributes: { href: "https://search.example/about" }, text: "About us" });
  fakeDocument.body.append(
    el("main", {}, el("h1", { text: "Find things" }), searchField, submitButton, el("p", { text: "Welcome to search." })),
    aboutLink
  );
  return { fakeDocument, searchField, submitButton, aboutLink };
}

test("a snapshot lists elements with e ids, roles, labels and the AppleScript fields", () => {
  const { fakeDocument, submitButton } = pageWithSearchForm();
  const agent = loadAgent(fakeDocument);

  const snapshot = agent.snapshot({ maximumTextCharacters: 1500, elementLimit: 25 });

  assert.equal(snapshot.status, "OK");
  assert.equal(snapshot.url, "https://search.example/");
  assert.equal(snapshot.title, "Search");
  assert.deepEqual(snapshot.headings, ["Find things"]);
  assert.deepEqual(
    snapshot.elements.map(({ id, role, label }) => ({ id, role, label })),
    [
      { id: "e0", role: "textbox:search", label: "Search" },
      { id: "e1", role: "button", label: "Go" },
      { id: "e2", role: "link", label: "About us" },
    ]
  );
  assert.equal(snapshot.elements[2].href, "https://search.example/about");
  assert.equal(submitButton.getAttribute("data-wisp-id"), "e1");
  assert.equal(snapshot.text, "Find things Go Welcome to search.");
  assert.equal(snapshot.scroll, "the whole page fits on screen");
  assert.equal(snapshot.dialog, "");
});

test("ids stay stable across snapshots, and a new element gets a fresh id", () => {
  const { fakeDocument, submitButton, aboutLink } = pageWithSearchForm();
  const agent = loadAgent(fakeDocument);

  agent.snapshot({});
  const extraButton = el("button", { text: "Clear" });
  fakeDocument.body.children[0].append(extraButton);
  const secondSnapshot = agent.snapshot({});

  const idsByLabel = Object.fromEntries(secondSnapshot.elements.map((element) => [element.label, element.id]));
  assert.equal(idsByLabel["Go"], "e1");
  assert.equal(idsByLabel["About us"], "e2");
  assert.equal(idsByLabel["Clear"], "e3");
  assert.equal(submitButton.getAttribute("data-wisp-id"), "e1");

  // A removed element's id is never handed to another element.
  aboutLink.remove();
  const thirdSnapshot = agent.snapshot({});
  assert.ok(!thirdSnapshot.elements.some((element) => element.id === "e2"));
});

test("re-injecting the agent keeps its registry, so ids survive", () => {
  const { fakeDocument } = pageWithSearchForm();
  const context = loadDomAgent(fakeDocument);
  const firstAgent = context.__wispAgent;
  firstAgent.snapshot({});

  // A second executeScript({files}) into the same document is a no-op.
  const sameContextAgain = loadDomAgent(fakeDocument);
  assert.notEqual(sameContextAgain.__wispAgent, firstAgent, "a separate context is a separate document");
  assert.equal(context.__wispAgent, firstAgent);
});

test("an open dialog's elements come first, then what is in view, then below", () => {
  const fakeDocument = new FakeDocument({ viewportHeight: 800, scrollHeight: 3000 });
  const belowButton = el("button", { text: "Far below", rect: { left: 10, top: 1500, width: 80, height: 20 } });
  const inViewButton = el("button", { text: "In view", rect: { left: 10, top: 100, width: 80, height: 20 } });
  const dialogButton = el("button", { text: "Accept", rect: { left: 300, top: 400, width: 80, height: 20 } });
  const dialog = el("div", { attributes: { role: "dialog", "aria-label": "Cookies" }, rect: { left: 200, top: 300, width: 400, height: 200 } },
    el("p", { text: "We use cookies." }), dialogButton);
  fakeDocument.body.append(belowButton, inViewButton, dialog);
  const agent = loadAgent(fakeDocument);

  const snapshot = agent.snapshot({});

  assert.deepEqual(snapshot.elements.map((element) => element.label), ["Accept", "In view", "Far below"]);
  assert.equal(snapshot.dialog, "Cookies");
  assert.equal(snapshot.text, "We use cookies. Accept", "the dialog is the text region while it is open");
  assert.match(snapshot.scroll, /^scrolled 0% down the page$/);
});

test("hidden, unlabelled and ignored elements are left out; the budget is respected", () => {
  const fakeDocument = new FakeDocument();
  fakeDocument.body.append(
    el("button", { text: "Hidden", style: { display: "none" } }),
    el("button", { text: "Zero size", rect: { left: 0, top: 0, width: 0, height: 0 } }),
    el("div", { attributes: { role: "button" } }),
    el("div", { attributes: { "data-wisp-ignore": "" } }, el("button", { text: "Private" })),
    el("button", { text: "One" }),
    el("button", { text: "Two" }),
    el("button", { text: "Three" })
  );
  const agent = loadAgent(fakeDocument);

  assert.deepEqual(agent.snapshot({ elementLimit: 2 }).elements.map((element) => element.label), ["One", "Two"]);
});

test("a password field is listed as sensitive, never read, and typing into it is refused", () => {
  const fakeDocument = new FakeDocument();
  const passwordField = el("input", { attributes: { type: "password", name: "pw", "aria-label": "Password" } });
  passwordField.storedValue = "hunter2";
  const codeField = el("input", { attributes: { autocomplete: "one-time-code", "aria-label": "Code" } });
  fakeDocument.body.append(passwordField, codeField);
  const agent = loadAgent(fakeDocument);

  const snapshot = agent.snapshot({});
  const listedPassword = snapshot.elements.find((element) => element.label === "Password");
  assert.equal(listedPassword.sensitive, true);
  assert.equal(listedPassword.value, undefined);
  assert.equal(listedPassword.role, "textbox:password");
  assert.equal(snapshot.elements.find((element) => element.label === "Code").sensitive, true);

  assert.deepEqual(agent.typeText({ id: listedPassword.id, text: "guess", pressEnter: true }), { status: "SENSITIVE" });
  assert.equal(passwordField.value, "hunter2");
  assert.deepEqual(passwordField.dispatchedEvents, []);
});

test("typing uses the native setter and dispatches input and change; Enter submits the form", () => {
  const fakeDocument = new FakeDocument();
  const submittedForms = [];
  const form = { requestSubmit: () => submittedForms.push("submitted") };
  const nameField = el("input", { attributes: { "aria-label": "Name" }, form });
  fakeDocument.body.append(nameField);
  const agent = loadAgent(fakeDocument);
  const [listedField] = agent.snapshot({}).elements;

  assert.deepEqual(agent.typeText({ id: listedField.id, text: "Ada", pressEnter: true }), { status: "OK" });

  assert.equal(nameField.value, "Ada");
  assert.deepEqual(nameField.dispatchedEvents, ["input", "change", "keydown", "keypress", "keyup"]);
  assert.deepEqual(submittedForms, ["submitted"]);
  assert.equal(agent.snapshot({}).elements[0].value, "Ada");
});

test("a click fires the full pointer sequence; disabled and missing elements say so", () => {
  const fakeDocument = new FakeDocument();
  const button = el("button", { text: "Open menu" });
  const disabledButton = el("button", { text: "Later", disabled: true });
  fakeDocument.body.append(button, disabledButton);
  const agent = loadAgent(fakeDocument);
  const elements = agent.snapshot({}).elements;

  assert.deepEqual(agent.click({ id: elements[0].id }), { status: "OK" });
  assert.deepEqual(button.dispatchedEvents, ["pointerover", "mouseover", "pointerdown", "mousedown", "pointerup", "mouseup", "click"]);
  assert.equal(elements[1].state, "disabled");
  assert.deepEqual(agent.click({ id: elements[1].id }), { status: "DISABLED" });
  assert.deepEqual(agent.click({ id: "e99" }), { status: "MISSING" });
});

test("select chooses an option by visible text and reports what it couldn't do", () => {
  const fakeDocument = new FakeDocument();
  const countrySelect = makeSelect({ "aria-label": "Country" }, ["Choose…", "United Kingdom", "United States"]);
  const notASelect = el("button", { text: "Menu" });
  fakeDocument.body.append(countrySelect, notASelect);
  const agent = loadAgent(fakeDocument);
  const [listedSelect, listedButton] = agent.snapshot({}).elements;
  assert.equal(listedSelect.role, "select");
  assert.equal(listedSelect.value, "Choose…");

  assert.deepEqual(agent.selectOption({ id: listedSelect.id, optionLabel: "states" }), { status: "OK" });
  assert.equal(countrySelect.value, "united-states");
  assert.deepEqual(countrySelect.dispatchedEvents, ["input", "change"]);
  assert.equal(agent.snapshot({}).elements[0].value, "United States");

  assert.deepEqual(agent.selectOption({ id: listedSelect.id, optionLabel: "France" }), { status: "NOOPTION" });
  assert.deepEqual(agent.selectOption({ id: listedButton.id, optionLabel: "x" }), { status: "NOTSELECT" });
});

test("only listed keys can be pressed, and they go to the focused element", () => {
  const fakeDocument = new FakeDocument();
  const field = el("input", { attributes: { "aria-label": "Query" } });
  fakeDocument.body.append(field);
  field.focus();
  const agent = loadAgent(fakeDocument);

  assert.deepEqual(agent.pressKey({ key: "Escape" }), { status: "OK" });
  assert.deepEqual(field.dispatchedEvents, ["keydown", "keyup"]);
  assert.deepEqual(agent.pressKey({ key: "alert(1)" }), { status: "UNSUPPORTED_KEY" });
});

test("elements in shadow roots and same-origin frames are found and acted on", () => {
  const fakeDocument = new FakeDocument();
  const host = el("div");
  const shadowRootStandIn = el("shadow-root-fragment");
  const shadowButton = el("button", { text: "Shadow action" });
  shadowRootStandIn.append(shadowButton);
  shadowRootStandIn.ownerDocument = fakeDocument;
  host.shadowRoot = shadowRootStandIn;
  shadowRootStandIn.shadowHost = host;
  const frameDocument = new FakeDocument({ url: "https://fixture.example/frame" });
  frameDocument.body.append(el("button", { text: "Frame action" }));
  fakeDocument.body.append(host, el("iframe", { contentDocument: frameDocument }), el("button", { text: "Top action" }));
  const agent = loadAgent(fakeDocument);

  const snapshot = agent.snapshot({});
  assert.deepEqual(snapshot.elements.map((element) => element.label), ["Top action", "Shadow action", "Frame action"]);
  const shadowID = snapshot.elements[1].id;
  assert.deepEqual(agent.click({ id: shadowID }), { status: "OK" });
  assert.equal(shadowButton.clickCount, 1);
});

test("settle detection: not quiet right after a change, quiet once the DOM has been still", () => {
  const fakeDocument = new FakeDocument();
  const clock = { now: 5_000 };
  const agent = loadAgent(fakeDocument, { clock });

  // The first probe installs the observer and counts as "just changed".
  assert.equal(agent.quietness({ quietMilliseconds: 400 }).isQuiet, false);
  clock.now += 450;
  assert.equal(agent.quietness({ quietMilliseconds: 400 }).isQuiet, true);

  fakeDocument.body.append(el("div", { text: "loaded more" }));
  assert.equal(agent.quietness({ quietMilliseconds: 400 }).isQuiet, false);
  clock.now += 200;
  assert.equal(agent.quietness({ quietMilliseconds: 400 }).isQuiet, false);
  clock.now += 250;
  assert.equal(agent.quietness({ quietMilliseconds: 400 }).isQuiet, true);

  fakeDocument.readyState = "loading";
  clock.now += 1000;
  assert.equal(agent.quietness({ quietMilliseconds: 400 }).isQuiet, false, "a loading page is never quiet");
});

test("screen geometry is given only for a visible tab", () => {
  const fakeDocument = new FakeDocument({ viewportHeight: 700 });
  fakeDocument.body.append(el("button", { text: "Here", rect: { left: 100, top: 200, width: 40, height: 20 } }));
  const agent = loadAgent(fakeDocument, { innerWidth: 1000 });
  const [button] = agent.snapshot({}).elements;

  assert.deepEqual(agent.elementScreenGeometry({ id: button.id }), {
    status: "OK", centerX: 120, centerY: 210, viewportWidth: 1000, viewportHeight: 700,
  });
  fakeDocument.visibilityState = "hidden";
  assert.deepEqual(agent.elementScreenGeometry({ id: button.id }), { status: "MISSING" });
});

test("the snapshot still matches the shared fixture the Swift decoder is tested against", async () => {
  const { readFileSync } = await import("node:fs");
  const { buildSnapshotFixturePage } = await import("./snapshot-fixture-page.mjs");
  const { mergeFrameSnapshots } = await import("../handlers/dom-controller.js");
  const expectedSnapshot = JSON.parse(readFileSync(new URL("../../Tests/ChromeExtDOMController/snapshot-fixture.json", import.meta.url), "utf8"));

  const { status, ...agentSnapshot } = loadAgent(buildSnapshotFixturePage()).snapshot({ maximumTextCharacters: 1500, elementLimit: 25 });
  agentSnapshot.elements = mergeFrameSnapshots(agentSnapshot, [], 25);

  assert.equal(status, "OK");
  assert.deepEqual(agentSnapshot, expectedSnapshot);
});
