// Wisp Tabs — highlights a research citation's quote in the page (phase 11).
//
// Research mode cites each claim with a short quote copied from a source's
// text. Clicking the citation in Wisp brings that tab forward and asks this
// script to mark the quote, so the user lands on the exact passage.
//
// Injected on demand by handlers/research.js with
// `chrome.scripting.executeScript({files: ["content/quote-highlight.js"]})`, as
// a classic script in the extension's isolated world. It only defines
// `globalThis.wispQuoteHighlighter`; the handler then calls it with a second
// `executeScript({func})`, the same pattern as content/read-page.js.
//
// Finding a quote: the page's visible text nodes are joined and compared with
// the quote with all whitespace removed, lowercased, and with curly quotes and
// dashes folded to plain ones. Whitespace is dropped entirely (not just
// collapsed) because the quote came from read-page.js's extraction, which puts
// line breaks between blocks, and the DOM has none there — "end of one
// paragraph" + "start of the next" must still match. Each kept character
// remembers its text node and offset, so a match maps straight back to a DOM
// Range.
//
// Drawing: translucent bands over the range's client rects, in the same look as
// content/highlight.js's `highlight` mark (phase 05), inside one closed shadow
// root so no page CSS leaks in. The bands follow scrolling and resizing. The
// first quote found is scrolled into view. Esc removes the marks.
//
// It never acts on the page and never reads form controls or
// `[data-wisp-ignore]` regions (contracts.md §6): those are skipped when the
// text is gathered, so a quote can't be "found" in a password field.

(() => {
  "use strict";

  const QUOTE_HIGHLIGHTER_VERSION = 1;
  const existingHighlighter = globalThis.wispQuoteHighlighter;
  if (existingHighlighter && existingHighlighter.version === QUOTE_HIGHLIGHTER_VERSION) {
    return;
  }

  const MAXIMUM_QUOTE_COUNT = 8;
  const MAXIMUM_QUOTE_CHARACTERS = 400;
  // A quote shorter than this (once whitespace is gone) would match all over
  // the page; Wisp's quotes are whole phrases.
  const MINIMUM_NORMALIZED_QUOTE_CHARACTERS = 8;
  const FALLBACK_MARK_COLOR = "rgb(51, 128, 255)";
  const PLAIN_COLOR_PATTERN = /^(?:rgb\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*\)|#[0-9a-fA-F]{6})$/;
  const SKIPPED_TAG_NAMES = new Set([
    "SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "CANVAS", "IFRAME",
    "INPUT", "TEXTAREA", "SELECT", "OPTION", "BUTTON", "WISP-HIGHLIGHTS", "WISP-QUOTES",
  ]);

  const highlighterState = {
    hostElement: null,
    layerElement: null,
    // [{ range, bandElements: [] }]
    marks: [],
    isFramePending: false,
    areWindowListenersInstalled: false,
  };

  // MARK: - Pure rules (exposed for the tests as `internals`)

  // Folds one character the way Wisp's Swift verifier does
  // (ResearchCitationVerifier), so "it’s" on the page matches "it's" in the
  // quote. Returns "" for whitespace, which is dropped.
  function foldedCharacter(character) {
    if (/\s/.test(character) || character === " ") return "";
    switch (character) {
      case "‘": case "’": case "‚": case "‛": case "′": case "`":
        return "'";
      case "“": case "”": case "„": case "‟": case "″":
        return '"';
      case "‐": case "‑": case "‒": case "–": case "—": case "―": case "−":
        return "-";
      case "…":
        return "...";
      default:
        return character.toLowerCase();
    }
  }

  function normalizedForMatching(text) {
    let normalizedText = "";
    for (const character of String(text ?? "")) normalizedText += foldedCharacter(character);
    return normalizedText;
  }

  // Quotes Wisp may ask for: strings, trimmed, capped, at most eight.
  function cleanedQuotes(quotes) {
    if (!Array.isArray(quotes)) return [];
    return quotes
      .filter((quote) => typeof quote === "string")
      .slice(0, MAXIMUM_QUOTE_COUNT)
      .map((quote) => quote.trim().slice(0, MAXIMUM_QUOTE_CHARACTERS));
  }

  function sanitizedColor(color) {
    return typeof color === "string" && PLAIN_COLOR_PATTERN.test(color.trim()) ? color.trim() : FALLBACK_MARK_COLOR;
  }

  // MARK: - Gathering the page's text

  function isSkippedElement(element) {
    if (!element || !element.tagName) return false;
    if (SKIPPED_TAG_NAMES.has(String(element.tagName).toUpperCase())) return true;
    if (typeof element.hasAttribute === "function") {
      if (element.hasAttribute("data-wisp-ignore")) return true;
      if (element.hasAttribute("hidden")) return true;
      if (element.getAttribute("contenteditable") === "true") return true;
      if (element.getAttribute("aria-hidden") === "true") return true;
    }
    return false;
  }

  // Every readable text node in order, walking the element tree by hand (no
  // TreeWalker, so the same code runs against the tests' parsed fixtures).
  function readableTextNodes(rootNode) {
    const textNodes = [];
    const pendingNodes = [rootNode];
    while (pendingNodes.length > 0) {
      const node = pendingNodes.pop();
      if (!node) continue;
      if (node.nodeType === 3) {
        if (node.nodeValue && node.nodeValue.length > 0) textNodes.push(node);
        continue;
      }
      if (node.nodeType !== 1 && node.nodeType !== 9 && node.nodeType !== 11) continue;
      if (node.nodeType === 1 && isSkippedElement(node)) continue;
      const childNodes = node.childNodes ? Array.from(node.childNodes) : [];
      for (let childIndex = childNodes.length - 1; childIndex >= 0; childIndex -= 1) {
        pendingNodes.push(childNodes[childIndex]);
      }
    }
    return textNodes;
  }

  // The page's text with whitespace removed and characters folded, plus, for
  // each kept character, where it came from. One page character can fold into
  // several ("…" → "..."), so each of those points at the same source spot.
  function indexedPageText(document) {
    const rootNode = document.body ?? document.documentElement ?? document;
    let normalizedText = "";
    const sourcePositions = [];
    for (const textNode of readableTextNodes(rootNode)) {
      const nodeText = textNode.nodeValue;
      for (let offset = 0; offset < nodeText.length; offset += 1) {
        const folded = foldedCharacter(nodeText[offset]);
        for (const foldedPiece of folded) {
          normalizedText += foldedPiece;
          sourcePositions.push({ textNode, offset });
        }
      }
    }
    return { normalizedText, sourcePositions };
  }

  // For each quote: the text node and offsets its first match starts and ends
  // at, or null when it isn't on the page.
  function findQuoteLocations(document, quotes) {
    const { normalizedText, sourcePositions } = indexedPageText(document);
    return cleanedQuotes(quotes).map((quote) => {
      const normalizedQuote = normalizedForMatching(quote);
      if (normalizedQuote.length < MINIMUM_NORMALIZED_QUOTE_CHARACTERS) return null;
      const matchStart = normalizedText.indexOf(normalizedQuote);
      if (matchStart < 0) return null;
      const startPosition = sourcePositions[matchStart];
      const endPosition = sourcePositions[matchStart + normalizedQuote.length - 1];
      return {
        startNode: startPosition.textNode,
        startOffset: startPosition.offset,
        endNode: endPosition.textNode,
        endOffset: endPosition.offset + 1,
      };
    });
  }

  // MARK: - Drawing

  const SHADOW_STYLES = `
    :host { all: initial; }
    .wisp-layer { position: fixed; inset: 0; pointer-events: none; }
    .wisp-quote-band {
      position: fixed; box-sizing: border-box; pointer-events: none;
      background: var(--wisp-mark-color); opacity: 0.28; border-radius: 3px;
    }
  `;

  function ensureHost(document, markColor) {
    if (!highlighterState.hostElement || !highlighterState.hostElement.isConnected) {
      const hostElement = document.createElement("wisp-quotes");
      hostElement.setAttribute("data-wisp-ignore", "");
      hostElement.setAttribute("aria-hidden", "true");
      hostElement.style.cssText =
        "all: initial; position: fixed; inset: 0; pointer-events: none; z-index: 2147483647;";
      const shadowRoot = hostElement.attachShadow({ mode: "closed" });
      const styleElement = document.createElement("style");
      styleElement.textContent = SHADOW_STYLES;
      shadowRoot.append(styleElement);
      const layerElement = document.createElement("div");
      layerElement.className = "wisp-layer";
      shadowRoot.append(layerElement);
      document.documentElement.append(hostElement);
      highlighterState.hostElement = hostElement;
      highlighterState.layerElement = layerElement;
    }
    highlighterState.hostElement.style.setProperty("--wisp-mark-color", markColor);
    return highlighterState.layerElement;
  }

  function positionBands() {
    highlighterState.isFramePending = false;
    for (const mark of highlighterState.marks) {
      const clientRects = typeof mark.range.getClientRects === "function"
        ? Array.from(mark.range.getClientRects()).filter((rect) => rect.width > 0 && rect.height > 0)
        : [];
      while (mark.bandElements.length < clientRects.length) {
        const bandElement = highlighterState.layerElement.ownerDocument.createElement("div");
        bandElement.className = "wisp-quote-band";
        highlighterState.layerElement.append(bandElement);
        mark.bandElements.push(bandElement);
      }
      mark.bandElements.forEach((bandElement, bandIndex) => {
        const rect = clientRects[bandIndex];
        bandElement.style.display = rect ? "block" : "none";
        if (!rect) return;
        bandElement.style.left = rect.left - 1 + "px";
        bandElement.style.top = rect.top - 1 + "px";
        bandElement.style.width = rect.width + 2 + "px";
        bandElement.style.height = rect.height + 2 + "px";
      });
    }
  }

  function schedulePositioning() {
    if (highlighterState.isFramePending) return;
    highlighterState.isFramePending = true;
    const requestFrame = globalThis.requestAnimationFrame ?? ((callback) => setTimeout(callback, 16));
    requestFrame(positionBands);
  }

  function installWindowListeners() {
    if (highlighterState.areWindowListenersInstalled || typeof globalThis.addEventListener !== "function") return;
    highlighterState.areWindowListenersInstalled = true;
    // Capture phase, so scrolling inside any scrollable element moves the bands.
    globalThis.addEventListener("scroll", schedulePositioning, { capture: true, passive: true });
    globalThis.addEventListener("resize", schedulePositioning, { passive: true });
    globalThis.addEventListener("keydown", (keyEvent) => {
      if (keyEvent.key === "Escape" && highlighterState.marks.length > 0) clearQuotes();
    }, { capture: true });
  }

  function clearQuotes() {
    highlighterState.marks = [];
    if (highlighterState.hostElement) highlighterState.hostElement.remove();
    highlighterState.hostElement = null;
    highlighterState.layerElement = null;
    return { cleared: true };
  }

  function scrollRangeIntoView(location) {
    const anchorElement = location.startNode.parentElement ?? location.startNode.parentNode;
    if (anchorElement && typeof anchorElement.scrollIntoView === "function") {
      const prefersReducedMotion = typeof globalThis.matchMedia === "function" &&
        globalThis.matchMedia("(prefers-reduced-motion: reduce)").matches;
      anchorElement.scrollIntoView({ block: "center", behavior: prefersReducedMotion ? "auto" : "smooth" });
    }
  }

  // Marks every quote found, replacing earlier marks. Returns the indexes (into
  // the quotes Wisp sent) that were found and that weren't.
  function showQuotes({ quotes, color, scrollToFirst = true } = {}) {
    const document = globalThis.document;
    clearQuotes();
    const locations = findQuoteLocations(document, quotes);
    const foundIndexes = [];
    const missingIndexes = [];
    locations.forEach((location, quoteIndex) => {
      (location ? foundIndexes : missingIndexes).push(quoteIndex);
    });
    const foundLocations = locations.filter(Boolean);
    if (foundLocations.length === 0) return { found: foundIndexes, missing: missingIndexes };

    ensureHost(document, sanitizedColor(color));
    for (const location of foundLocations) {
      if (typeof document.createRange !== "function") break;
      const range = document.createRange();
      range.setStart(location.startNode, location.startOffset);
      range.setEnd(location.endNode, location.endOffset);
      highlighterState.marks.push({ range, bandElements: [] });
    }
    installWindowListeners();
    if (scrollToFirst !== false) scrollRangeIntoView(foundLocations[0]);
    schedulePositioning();
    return { found: foundIndexes, missing: missingIndexes };
  }

  globalThis.wispQuoteHighlighter = {
    version: QUOTE_HIGHLIGHTER_VERSION,
    showQuotes,
    clearQuotes,
    findQuoteLocations,
    internals: { foldedCharacter, normalizedForMatching, cleanedQuotes, sanitizedColor, MAXIMUM_QUOTE_COUNT },
  };
})();
