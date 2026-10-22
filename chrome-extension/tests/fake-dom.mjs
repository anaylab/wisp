// A tiny fake DOM, just enough to run content/dom-agent.js under `node --test`.
//
// The agent only walks the page with `querySelectorAll('*')` and reads plain
// element properties, so this fake needs no CSS engine. Layout is given, not
// computed: each element carries a `rect` and a `style`, and `innerText` is the
// element's own text plus its children's, joined by spaces.
//
// `loadDomAgent(document)` runs the real content script file inside a `vm`
// context whose globals (window, document, events, timers' clock) are fakes,
// and returns that context so a test can call `window.__wispAgent` or play
// executeScript by running a serialised function in it.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const DOM_AGENT_SOURCE = readFileSync(
  fileURLToPath(new URL("../content/dom-agent.js", import.meta.url)),
  "utf8"
);

export class FakeElement {
  constructor(tagName, { attributes = {}, text = "", rect, style, ...properties } = {}) {
    this.tagName = tagName.toUpperCase();
    this.attributes = new Map(Object.entries(attributes));
    this.ownText = text;
    this.children = [];
    this.parentElement = null;
    this.ownerDocument = null;
    this.rect = rect ?? { left: 10, top: 10, width: 100, height: 20 };
    this.style = { visibility: "visible", display: "block", opacity: "1", ...(style ?? {}) };
    this.dispatchedEvents = [];
    this.shadowRoot = null;
    this.contentDocument = null;
    this.labels = null;
    this.form = null;
    this.storedValue = "";
    this.isContentEditable = false;
    this.disabled = false;
    this.checked = false;
    this.required = false;
    this.clickCount = 0;
    Object.assign(this, properties);
  }

  // Inputs keep their value behind a prototype setter, like the real DOM, so
  // the agent's "native setter" path is what changes it.
  get value() {
    return this.storedValue;
  }

  set value(newValue) {
    this.storedValue = String(newValue);
  }

  get type() {
    return (this.attributes.get("type") ?? (this.tagName === "INPUT" ? "text" : "")).toLowerCase();
  }

  get id() {
    return this.attributes.get("id") ?? "";
  }

  get name() {
    return this.attributes.get("name") ?? "";
  }

  get placeholder() {
    return this.attributes.get("placeholder") ?? "";
  }

  get title() {
    return this.attributes.get("title") ?? "";
  }

  get alt() {
    return this.attributes.get("alt") ?? "";
  }

  get href() {
    return this.attributes.get("href") ?? "";
  }

  get isConnected() {
    // A shadow root's contents are connected through its host.
    let current = this;
    while (current.parentElement || current.shadowHost) current = current.parentElement ?? current.shadowHost;
    return Boolean(current.isDocumentRoot && current.ownerDocument?.documentElement === current);
  }

  get innerText() {
    if (this.style.display === "none") return "";
    return [this.ownText, ...this.children.map((child) => child.innerText)].filter(Boolean).join(" ");
  }

  getAttribute(attributeName) {
    return this.attributes.has(attributeName) ? this.attributes.get(attributeName) : null;
  }

  setAttribute(attributeName, attributeValue) {
    // Attribute changes are not mutations the agent watches (childList and
    // characterData only), so stamping ids never looks like page activity.
    this.attributes.set(attributeName, String(attributeValue));
  }

  hasAttribute(attributeName) {
    return this.attributes.has(attributeName);
  }

  append(...childElements) {
    for (const childElement of childElements) {
      childElement.parentElement = this;
      adoptInto(childElement, this.ownerDocument);
      this.children.push(childElement);
    }
    this.ownerDocument?.recordMutation();
    return this;
  }

  remove() {
    if (!this.parentElement) return;
    const siblings = this.parentElement.children;
    siblings.splice(siblings.indexOf(this), 1);
    const formerDocument = this.ownerDocument;
    this.parentElement = null;
    formerDocument?.recordMutation();
  }

  contains(otherElement) {
    for (let current = otherElement; current; current = current.parentElement) {
      if (current === this) return true;
    }
    return false;
  }

  querySelectorAll(selector) {
    if (selector !== "*") throw new Error(`the fake DOM only supports querySelectorAll('*'), got ${selector}`);
    const descendants = [];
    const visit = (element) => {
      for (const child of element.children) {
        descendants.push(child);
        visit(child);
      }
    };
    visit(this);
    return descendants;
  }

  getBoundingClientRect() {
    const { left, top, width, height } = this.rect;
    return { left, top, width, height, right: left + width, bottom: top + height };
  }

  scrollIntoView() {}

  focus() {
    if (this.ownerDocument) this.ownerDocument.activeElement = this;
  }

  click() {
    this.clickCount += 1;
    this.dispatchedEvents.push("click");
  }

  dispatchEvent(event) {
    this.dispatchedEvents.push(event.type);
    return !event.defaultPrevented;
  }
}

function adoptInto(element, ownerDocument) {
  element.ownerDocument = ownerDocument;
  for (const child of element.children) adoptInto(child, ownerDocument);
}

export class FakeDocument {
  constructor({ title = "Fixture", url = "https://fixture.example/", viewportHeight = 800, scrollHeight = 800 } = {}) {
    this.title = title;
    this.url = url;
    this.readyState = "complete";
    this.visibilityState = "visible";
    this.viewportHeight = viewportHeight;
    this.mutationObservers = [];
    this.documentElement = new FakeElement("html");
    this.documentElement.isDocumentRoot = true;
    this.documentElement.ownerDocument = this;
    Object.defineProperty(this.documentElement, "scrollHeight", { get: () => scrollHeight });
    this.body = new FakeElement("body");
    this.documentElement.append(this.body);
    this.activeElement = this.body;
    this.executedCommands = [];
  }

  querySelectorAll(selector) {
    return [this.documentElement, ...this.documentElement.querySelectorAll(selector)];
  }

  getElementById(elementID) {
    return this.querySelectorAll("*").find((element) => element.id === elementID) ?? null;
  }

  execCommand(commandName, showUI, commandValue) {
    this.executedCommands.push([commandName, commandValue]);
    if (commandName === "insertText" && this.activeElement) this.activeElement.ownText = commandValue;
    return true;
  }

  recordMutation() {
    for (const observer of this.mutationObservers) observer.callback([]);
  }
}

// One fake event class per constructor the agent uses. `type` is what the
// fake elements record.
class FakeEvent {
  constructor(type, options = {}) {
    this.type = type;
    Object.assign(this, options);
    this.defaultPrevented = false;
  }
}

// Runs content/dom-agent.js against `fakeDocument`. `clock.now` is the time the
// agent sees; tests move it to make the page "quiet".
export function loadDomAgent(fakeDocument, { clock = { now: 1_000_000 }, innerWidth = 1200 } = {}) {
  class FakeMutationObserver {
    constructor(callback) {
      this.callback = callback;
    }
    observe() {
      fakeDocument.mutationObservers.push(this);
    }
    disconnect() {}
  }
  const fakeDate = { now: () => clock.now };
  const fakeWindow = {
    scrollCalls: [],
    scrollBy(x, y) {
      this.scrollCalls.push(["scrollBy", x, y]);
    },
    scrollTo(x, y) {
      this.scrollCalls.push(["scrollTo", x, y]);
    },
  };
  const context = vm.createContext({
    document: fakeDocument,
    location: { href: fakeDocument.url },
    innerHeight: fakeDocument.viewportHeight,
    innerWidth,
    scrollY: 0,
    getComputedStyle: (element) => element.style,
    Date: fakeDate,
    MutationObserver: FakeMutationObserver,
    PointerEvent: FakeEvent,
    MouseEvent: FakeEvent,
    KeyboardEvent: FakeEvent,
    InputEvent: FakeEvent,
    Event: FakeEvent,
    HTMLInputElement: FakeElement,
    HTMLTextAreaElement: FakeElement,
    HTMLSelectElement: FakeElement,
    Object,
    Set,
    Map,
    String,
    Math,
  });
  context.window = context;
  context.scrollBy = fakeWindow.scrollBy.bind(fakeWindow);
  context.scrollTo = fakeWindow.scrollTo.bind(fakeWindow);
  context.scrollCalls = fakeWindow.scrollCalls;
  vm.runInContext(DOM_AGENT_SOURCE, context);
  return context;
}

// Plays chrome.scripting.executeScript's `func` form: the function is
// serialised and run in the page's world with JSON-cloned arguments.
export function runSerializedFunction(context, serializableFunction, functionArguments) {
  const argumentsJSON = JSON.stringify(functionArguments ?? []);
  return vm.runInContext(`(${serializableFunction.toString()}).apply(null, ${argumentsJSON})`, context);
}

// Builds an element tree in one expression:
// el("div", {attributes: {role: "dialog"}}, el("button", {text: "OK"}))
export function el(tagName, options = {}, ...childElements) {
  const element = new FakeElement(tagName, options);
  element.append(...childElements);
  return element;
}

export function makeSelect(attributes, optionTexts, selectedIndex = 0) {
  const options = optionTexts.map((optionText) => ({ text: optionText, value: optionText.toLowerCase().replace(/\s+/g, "-") }));
  const select = new FakeElement("select", { attributes });
  select.options = options;
  select.storedValue = options[selectedIndex]?.value ?? "";
  Object.defineProperty(select, "selectedOptions", {
    get: () => options.filter((option) => option.value === select.storedValue),
  });
  return select;
}

// The agent's methods with their results cloned into this realm, as
// executeScript would hand them to the extension (plain JSON values).
export function loadAgent(fakeDocument, options) {
  const context = loadDomAgent(fakeDocument, options);
  return new Proxy({}, {
    get(target, methodName) {
      return (...methodArguments) => JSON.parse(JSON.stringify(context.__wispAgent[methodName](...methodArguments)));
    },
  });
}
