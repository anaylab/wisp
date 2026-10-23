// Runs content/highlight.js in a `vm` against fake-dom.mjs's document, with
// the few extra browser pieces the highlighter uses: createElement,
// attachShadow, inline style setters, element and window listeners,
// matchMedia, requestAnimationFrame, ResizeObserver and
// chrome.runtime.sendMessage.
//
// The layout is still given, not computed (each element's `rect`), and the
// animation frame runs at once, so a test reads mark positions straight away.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

import { FakeElement } from "./fake-dom.mjs";

const HIGHLIGHTER_SOURCE = readFileSync(
  fileURLToPath(new URL("../content/highlight.js", import.meta.url)),
  "utf8"
);

// Gives a fake element the style object, class name, text and listeners the
// highlighter writes to.
function makeDrawable(element) {
  const inlineStyle = element.style;
  if (typeof inlineStyle.setProperty !== "function") {
    inlineStyle.setProperty = (propertyName, propertyValue) => {
      inlineStyle[propertyName] = propertyValue;
    };
  }
  element.className = element.className ?? "";
  element.eventListeners = element.eventListeners ?? {};
  element.addEventListener = (eventName, listener) => {
    (element.eventListeners[eventName] ??= []).push(listener);
  };
  element.attachShadow = ({ mode }) => {
    const shadowRoot = makeDrawable(new FakeElement("#shadow-root"));
    shadowRoot.mode = mode;
    shadowRoot.ownerDocument = element.ownerDocument;
    element.attachedShadowRoot = shadowRoot;
    // Closed: `element.shadowRoot` stays null, as in Chrome.
    return shadowRoot;
  };
  // The fake element's `title` is read-only; the highlighter sets one.
  Object.defineProperty(element, "title", { value: "", writable: true, configurable: true });
  Object.defineProperty(element, "textContent", {
    get: () => element.ownText,
    set: (newText) => {
      element.ownText = String(newText);
    },
    configurable: true,
  });
  return element;
}

export function loadHighlighter(fakeDocument, {
  reducedMotion = false,
  innerWidth = 1200,
  agentElementsByID = null,
} = {}) {
  const sentMessages = [];
  const windowListeners = {};
  const observedElements = [];
  const scrolledIntoView = [];

  fakeDocument.createElement = (tagName) => {
    const element = makeDrawable(new FakeElement(tagName));
    element.ownerDocument = fakeDocument;
    return element;
  };

  // Every existing element can be measured and scrolled to.
  for (const element of fakeDocument.querySelectorAll("*")) {
    element.scrollIntoView = (options) => scrolledIntoView.push([element, options]);
  }

  class FakeResizeObserver {
    constructor(callback) {
      this.callback = callback;
    }
    observe(element) {
      observedElements.push(element);
    }
    unobserve(element) {
      const elementIndex = observedElements.indexOf(element);
      if (elementIndex >= 0) observedElements.splice(elementIndex, 1);
    }
  }

  const context = vm.createContext({
    document: fakeDocument,
    innerHeight: fakeDocument.viewportHeight,
    innerWidth,
    matchMedia: (query) => ({ matches: query.includes("prefers-reduced-motion") && reducedMotion }),
    requestAnimationFrame: (callback) => callback(),
    ResizeObserver: FakeResizeObserver,
    addEventListener: (eventName, listener) => {
      (windowListeners[eventName] ??= []).push(listener);
    },
    chrome: {
      runtime: {
        sendMessage(message) {
          sentMessages.push(JSON.parse(JSON.stringify(message)));
        },
      },
    },
    Object,
    Set,
    Map,
    String,
    Number,
    Math,
    Array,
  });
  context.window = context;
  if (agentElementsByID) {
    context.__wispAgent = { version: 1, state: { elementsByID: agentElementsByID } };
  }
  vm.runInContext(HIGHLIGHTER_SOURCE, context);

  return {
    context,
    highlighter: context.__wispHighlighter,
    sentMessages,
    windowListeners,
    observedElements,
    scrolledIntoView,
    // The shadow root the highlighter drew into, or null.
    shadowRoot() {
      return context.__wispHighlighter.state.shadowRoot;
    },
    // Runs the file again in the same world, as a second injection would.
    reinject() {
      vm.runInContext(HIGHLIGHTER_SOURCE, context);
    },
    // Plays an event reaching the window's capture listeners.
    dispatchToWindow(eventName, event) {
      for (const listener of windowListeners[eventName] ?? []) listener(event);
    },
  };
}

// Every element in a fake subtree, depth first.
export function descendantsOf(rootElement) {
  return rootElement ? rootElement.querySelectorAll("*") : [];
}
