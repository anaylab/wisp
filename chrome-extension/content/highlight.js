// Wisp Tabs — Wisp's marks drawn inside the page (phase 05).
//
// Injected with chrome.scripting.executeScript({files: ["content/highlight.js"]})
// when Wisp points at something in a Chrome tab. The screen overlay's marks are
// pinned to screen positions, so Wisp drops them the moment the page scrolls;
// a mark drawn here is anchored to the element itself and follows it through
// scrolling, resizing, zoom and layout changes.
//
// What it draws, all inside one closed shadow root so no page CSS leaks in and
// none of Wisp's leaks out:
//   ring       a pulsing outline around the element ("here it is")
//   box        a steady outline
//   highlight  a translucent band over the element
//   step       a box with a numbered badge (a guided walkthrough step)
// each with an optional short label, in the marker colour the user chose in
// Wisp (passed in; Wisp owns the colour).
//
// It also watches for the real click on a walkthrough step's element and tells
// Wisp (`page.elementClicked`), and lets the user dismiss the marks with Esc or
// a click on a label (`page.highlightDismissed`). Messages go to the service
// worker with chrome.runtime.sendMessage; events/pointing.js turns them into
// events, adding the tab and frame.
//
// Elements are named by the DOM controller's ids (`e7`): looked up in
// `window.__wispAgent`'s registry (content/dom-agent.js, same isolated world),
// which reaches into shadow roots, else by the `data-wisp-id` it stamped.
//
// It never reads page text and never acts on the page: it only measures the
// elements it was told about and draws over them, and `[data-wisp-ignore]`
// regions are never marked. A classic script, not a module, like dom-agent.js;
// state lives on `window.__wispHighlighter`, so a second injection is a no-op.

(function installWispHighlighter() {
  "use strict";

  const HIGHLIGHTER_VERSION = 1;
  const existingHighlighter = window.__wispHighlighter;
  if (existingHighlighter && existingHighlighter.version === HIGHLIGHTER_VERSION) {
    return;
  }

  const MESSAGE_TYPE = "wisp.pointing";
  const SUPPORTED_KINDS = new Set(["ring", "box", "highlight", "step"]);
  const MAXIMUM_LABEL_CHARACTERS = 60;
  const MAXIMUM_MARK_COUNT = 12;
  const ELEMENT_ID_PATTERN = /^e\d{1,9}$/;
  // Breathing room between the element and the outline drawn around it.
  const OUTLINE_PADDING_PIXELS = 4;
  // Used only if Wisp sent no colour (or one that isn't a plain colour).
  const FALLBACK_MARK_COLOR = "rgb(51, 128, 255)";
  // A colour Wisp sends: rgb(r, g, b) or #rrggbb. Anything else (a url(),
  // an expression) is refused, since it lands in a style attribute.
  const PLAIN_COLOR_PATTERN = /^(?:rgb\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*\)|#[0-9a-fA-F]{6})$/;

  const highlighterState = {
    // The page element that hosts the shadow root, or null when nothing is drawn.
    hostElement: null,
    shadowRoot: null,
    // [{ elementId, element, kind, label, badgeNumber, markElement, labelElement }]
    marks: [],
    resizeObserver: null,
    isFramePending: false,
    // Element ids whose real clicks Wisp is waiting for.
    watchedElementIDs: [],
    // A walkthrough step isn't dismissed by Esc: the page may use Esc to
    // close its own dialog, and Esc in Wisp doesn't end a walkthrough either.
    dismissesOnEscape: true,
    areDocumentListenersInstalled: false,
  };

  // MARK: - Pure rules (exposed for the tests as `internals`)

  // The number each item's badge shows, or null for no badge. A walkthrough
  // step carries its own number (step 3 of a plan stays "3" even when it is
  // the only mark); a step without one is numbered by its place among the
  // badged items, from 1.
  function badgeNumbersFor(items) {
    let nextSequentialNumber = 1;
    return items.map((item) => {
      const hasOwnNumber = Number.isInteger(item.stepNumber) && item.stepNumber >= 1 && item.stepNumber <= 99;
      if (item.kind !== "step" && !hasOwnNumber) return null;
      const badgeNumber = hasOwnNumber ? item.stepNumber : nextSequentialNumber;
      nextSequentialNumber = badgeNumber + 1;
      return badgeNumber;
    });
  }

  function cleanLabel(label) {
    const collapsed = String(label ?? "").replace(/\s+/g, " ").trim();
    return collapsed.length > MAXIMUM_LABEL_CHARACTERS
      ? collapsed.slice(0, MAXIMUM_LABEL_CHARACTERS - 1) + "…"
      : collapsed;
  }

  function sanitizedColor(color) {
    return typeof color === "string" && PLAIN_COLOR_PATTERN.test(color.trim()) ? color.trim() : FALLBACK_MARK_COLOR;
  }

  // The watched element a click landed on, or null. A click on a child (the
  // icon inside a button, the text inside a link) counts for the element that
  // contains it: `eventPath` is the click's composed path, innermost first, so
  // it also crosses shadow roots.
  function watchedElementIDForClick(eventPath, watchedElementsByID) {
    for (const node of eventPath) {
      for (const [elementId, watchedElement] of watchedElementsByID) {
        if (node === watchedElement) return elementId;
      }
    }
    return null;
  }

  // Where to draw a mark for an element's client rect (viewport pixels, the
  // host is position:fixed). Outlines sit a little outside the element; a
  // highlight band covers it exactly.
  function markFrameFor(elementRect, kind) {
    const padding = kind === "highlight" ? 0 : OUTLINE_PADDING_PIXELS;
    return {
      left: elementRect.left - padding,
      top: elementRect.top - padding,
      width: elementRect.width + padding * 2,
      height: elementRect.height + padding * 2,
    };
  }

  function isOffScreen(elementRect, viewportWidth, viewportHeight) {
    return elementRect.bottom <= 0 || elementRect.top >= viewportHeight ||
      elementRect.right <= 0 || elementRect.left >= viewportWidth;
  }

  // MARK: - Page lookups

  function prefersReducedMotion() {
    try {
      return Boolean(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);
    } catch (error) {
      return false;
    }
  }

  function isInsideIgnoredRegion(element) {
    for (let current = element; current; current = current.parentElement) {
      if (current.hasAttribute && current.hasAttribute("data-wisp-ignore")) return true;
    }
    return false;
  }

  function findElementByID(elementId) {
    if (typeof elementId !== "string" || !ELEMENT_ID_PATTERN.test(elementId)) return null;
    const registered = window.__wispAgent?.state?.elementsByID?.[elementId];
    if (registered && registered.isConnected) return registered;
    const descendants = document.querySelectorAll("*");
    for (let index = 0; index < descendants.length; index++) {
      const candidate = descendants[index];
      if (candidate.getAttribute && candidate.getAttribute("data-wisp-id") === elementId) return candidate;
    }
    return null;
  }

  function sendToWisp(eventName, data) {
    try {
      chrome.runtime.sendMessage({ type: MESSAGE_TYPE, event: eventName, data });
    } catch (error) {
      // The extension was reloaded under this page; nobody is listening.
    }
  }

  // MARK: - Drawing

  const SHADOW_STYLES = `
    :host { all: initial; }
    .wisp-layer { position: fixed; inset: 0; pointer-events: none; }
    .wisp-mark { position: fixed; box-sizing: border-box; pointer-events: none; border-radius: 8px; }
    .wisp-mark.ring { border: 3px solid var(--wisp-mark-color); }
    .wisp-mark.ring.pulse { animation: wisp-pulse 1.4s ease-in-out infinite; }
    .wisp-mark.box, .wisp-mark.step { border: 2.5px solid var(--wisp-mark-color); }
    .wisp-mark.highlight { background: var(--wisp-mark-color); opacity: 0.22; border-radius: 4px; }
    .wisp-badge {
      position: absolute; left: -11px; top: -11px; min-width: 22px; height: 22px; padding: 0 5px;
      box-sizing: border-box; border-radius: 11px; background: var(--wisp-mark-color); color: white;
      font: 700 12px/22px -apple-system, BlinkMacSystemFont, sans-serif; text-align: center;
      box-shadow: 0 1px 4px rgba(0, 0, 0, 0.3);
    }
    .wisp-label {
      position: fixed; pointer-events: auto; cursor: pointer; max-width: 260px;
      padding: 3px 9px; border-radius: 10px; background: rgba(20, 20, 22, 0.88); color: white;
      font: 500 12px/18px -apple-system, BlinkMacSystemFont, sans-serif;
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
      box-shadow: 0 2px 8px rgba(0, 0, 0, 0.25);
    }
    @keyframes wisp-pulse {
      0%, 100% { transform: scale(1); opacity: 1; }
      50% { transform: scale(1.06); opacity: 0.55; }
    }
  `;

  function ensureHost(markColor) {
    if (!highlighterState.hostElement || !highlighterState.hostElement.isConnected) {
      const hostElement = document.createElement("wisp-highlights");
      // Wisp's own marks are never something Wisp lists, reads or marks.
      hostElement.setAttribute("data-wisp-ignore", "");
      hostElement.setAttribute("aria-hidden", "true");
      hostElement.style.cssText =
        "all: initial; position: fixed; inset: 0; pointer-events: none; z-index: 2147483647;";
      // Closed: the page's scripts can't reach in and restyle or read it.
      const shadowRoot = hostElement.attachShadow({ mode: "closed" });
      const styleElement = document.createElement("style");
      styleElement.textContent = SHADOW_STYLES;
      shadowRoot.append(styleElement);
      const layerElement = document.createElement("div");
      layerElement.className = "wisp-layer";
      shadowRoot.append(layerElement);
      document.documentElement.append(hostElement);
      highlighterState.hostElement = hostElement;
      highlighterState.shadowRoot = shadowRoot;
      highlighterState.layerElement = layerElement;
    }
    highlighterState.hostElement.style.setProperty("--wisp-mark-color", markColor);
    return highlighterState.layerElement;
  }

  function removeAllMarks() {
    for (const mark of highlighterState.marks) {
      if (highlighterState.resizeObserver) highlighterState.resizeObserver.unobserve(mark.element);
    }
    highlighterState.marks = [];
    if (highlighterState.hostElement) highlighterState.hostElement.remove();
    highlighterState.hostElement = null;
    highlighterState.shadowRoot = null;
    highlighterState.layerElement = null;
  }

  function positionMarks() {
    highlighterState.isFramePending = false;
    for (const mark of highlighterState.marks) {
      const isGone = !mark.element.isConnected;
      const elementRect = isGone ? null : mark.element.getBoundingClientRect();
      const isHidden = isGone || elementRect.width <= 0 || elementRect.height <= 0;
      mark.markElement.style.display = isHidden ? "none" : "block";
      if (mark.labelElement) mark.labelElement.style.display = isHidden ? "none" : "block";
      if (isHidden) continue;
      const markFrame = markFrameFor(elementRect, mark.kind);
      mark.markElement.style.left = markFrame.left + "px";
      mark.markElement.style.top = markFrame.top + "px";
      mark.markElement.style.width = markFrame.width + "px";
      mark.markElement.style.height = markFrame.height + "px";
      if (mark.labelElement) {
        // Under the mark, or above it when the mark sits at the bottom edge.
        const labelTop = markFrame.top + markFrame.height + 6 + 24 > innerHeight
          ? markFrame.top - 6 - 24
          : markFrame.top + markFrame.height + 6;
        mark.labelElement.style.left = Math.max(4, markFrame.left) + "px";
        mark.labelElement.style.top = Math.max(4, labelTop) + "px";
      }
    }
  }

  // Scrolling and resizing fire far more often than frames are drawn; one
  // reposition per frame is enough.
  function schedulePositioning() {
    if (highlighterState.isFramePending) return;
    highlighterState.isFramePending = true;
    requestAnimationFrame(positionMarks);
  }

  function dismissMarks(reason, elementId) {
    if (highlighterState.marks.length === 0) return;
    const dismissedElementIDs = highlighterState.marks.map((mark) => mark.elementId);
    removeAllMarks();
    const data = { reason, elementIds: dismissedElementIDs };
    if (elementId) data.elementId = elementId;
    sendToWisp("page.highlightDismissed", data);
  }

  function handleKeyDown(event) {
    if (event.key !== "Escape" || !highlighterState.dismissesOnEscape) return;
    if (highlighterState.marks.length > 0) dismissMarks("escape", null);
  }

  // Only clicks a person made count (`isTrusted`). Wisp's own "do it for me"
  // click is synthetic, and the page's scripts can't fake a step done.
  function handleClick(event) {
    if (!event.isTrusted || highlighterState.watchedElementIDs.length === 0) return;
    const watchedElementsByID = [];
    for (const elementId of highlighterState.watchedElementIDs) {
      const element = findElementByID(elementId);
      if (element) watchedElementsByID.push([elementId, element]);
    }
    const eventPath = typeof event.composedPath === "function" ? event.composedPath() : pathFromTarget(event.target);
    const clickedElementID = watchedElementIDForClick(eventPath, watchedElementsByID);
    if (clickedElementID) sendToWisp("page.elementClicked", { elementId: clickedElementID });
  }

  function pathFromTarget(target) {
    const path = [];
    for (let current = target; current; current = current.parentElement ?? current.host ?? null) path.push(current);
    return path;
  }

  function installDocumentListeners() {
    if (highlighterState.areDocumentListenersInstalled) return;
    highlighterState.areDocumentListenersInstalled = true;
    // Capture phase, so a page that stops propagation can't hide a click or
    // an Esc from Wisp. Nothing here prevents anything: the page sees both.
    window.addEventListener("click", handleClick, true);
    window.addEventListener("keydown", handleKeyDown, true);
    // `scroll` doesn't bubble, but capture sees inner scrollers too.
    window.addEventListener("scroll", schedulePositioning, { capture: true, passive: true });
    window.addEventListener("resize", schedulePositioning, { passive: true });
  }

  // MARK: - Entry points

  function show({ items = [], color, dismissOnEscape = true } = {}) {
    removeAllMarks();
    highlighterState.dismissesOnEscape = dismissOnEscape !== false;
    const requestedItems = Array.isArray(items) ? items.slice(0, MAXIMUM_MARK_COUNT) : [];
    const badgeNumbers = badgeNumbersFor(requestedItems);
    const shownElementIDs = [];
    const missingElementIDs = [];
    const isReducedMotion = prefersReducedMotion();

    requestedItems.forEach((item, itemIndex) => {
      const element = findElementByID(item.elementId);
      if (!element || isInsideIgnoredRegion(element)) {
        missingElementIDs.push(String(item.elementId ?? ""));
        return;
      }
      const kind = SUPPORTED_KINDS.has(item.kind) ? item.kind : "ring";
      const layerElement = ensureHost(sanitizedColor(color));

      const markElement = document.createElement("div");
      markElement.className = "wisp-mark " + kind + (kind === "ring" && !isReducedMotion ? " pulse" : "");
      if (badgeNumbers[itemIndex] !== null) {
        const badgeElement = document.createElement("div");
        badgeElement.className = "wisp-badge";
        badgeElement.textContent = String(badgeNumbers[itemIndex]);
        markElement.append(badgeElement);
      }
      layerElement.append(markElement);

      let labelElement = null;
      const label = cleanLabel(item.label);
      if (label) {
        labelElement = document.createElement("div");
        labelElement.className = "wisp-label";
        // textContent, never HTML: a label can carry words from the page.
        labelElement.textContent = label;
        labelElement.title = "Click to dismiss";
        labelElement.addEventListener("click", (event) => {
          event.stopPropagation();
          dismissMarks("label", item.elementId);
        });
        layerElement.append(labelElement);
      }

      highlighterState.marks.push({
        elementId: item.elementId, element, kind, label, badgeNumber: badgeNumbers[itemIndex], markElement, labelElement,
      });
      shownElementIDs.push(item.elementId);
    });

    if (highlighterState.marks.length > 0) {
      installDocumentListeners();
      if (typeof ResizeObserver === "function") {
        if (!highlighterState.resizeObserver) highlighterState.resizeObserver = new ResizeObserver(schedulePositioning);
        for (const mark of highlighterState.marks) highlighterState.resizeObserver.observe(mark.element);
      }
      // Bring the first mark into view once, if it is off-screen. Never again
      // after that: the user is free to scroll away from it.
      const firstElementRect = highlighterState.marks[0].element.getBoundingClientRect();
      if (isOffScreen(firstElementRect, innerWidth, innerHeight)) {
        highlighterState.marks[0].element.scrollIntoView({
          block: "center", inline: "nearest", behavior: isReducedMotion ? "auto" : "smooth",
        });
      }
      positionMarks();
    }

    return {
      status: "OK",
      shown: shownElementIDs,
      missing: missingElementIDs,
      reducedMotion: isReducedMotion,
      badges: highlighterState.marks.map((mark) => mark.badgeNumber),
    };
  }

  function clear() {
    const hadMarks = highlighterState.marks.length > 0;
    removeAllMarks();
    return { status: "OK", cleared: hadMarks };
  }

  function watchClicks({ ids = [] } = {}) {
    const requestedIDs = Array.isArray(ids) ? ids.filter((elementId) => typeof elementId === "string") : [];
    const watching = [];
    const missing = [];
    for (const elementId of requestedIDs) {
      const element = findElementByID(elementId);
      if (element && !isInsideIgnoredRegion(element)) watching.push(elementId);
      else missing.push(elementId);
    }
    highlighterState.watchedElementIDs = watching;
    if (watching.length > 0) installDocumentListeners();
    return { status: "OK", watching, missing };
  }

  function stopWatchingClicks() {
    highlighterState.watchedElementIDs = [];
    return { status: "OK" };
  }

  window.__wispHighlighter = {
    version: HIGHLIGHTER_VERSION,
    state: highlighterState,
    show,
    clear,
    watchClicks,
    stopWatchingClicks,
    internals: { badgeNumbersFor, watchedElementIDForClick, markFrameFor, isOffScreen, sanitizedColor, cleanLabel },
  };
})();
