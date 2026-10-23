// content/highlight.js in a fake page: marks, badge numbering, reduced
// motion, following the element, dismissal and click matching.

import { test } from "node:test";
import assert from "node:assert/strict";

import { FakeDocument, el } from "./fake-dom.mjs";
import { descendantsOf, loadHighlighter } from "./fake-highlight-page.mjs";

// A page with a settings button (holding an icon and a text span), a link,
// a region Wisp must ignore, and a button far below the fold.
function makePage() {
  const fakeDocument = new FakeDocument({ viewportHeight: 800 });
  const settingsIcon = el("svg", { rect: { left: 104, top: 52, width: 16, height: 16 } });
  const settingsText = el("span", { text: "Settings", rect: { left: 122, top: 50, width: 60, height: 20 } });
  const settingsButton = el("button", { attributes: { "data-wisp-id": "e1" }, rect: { left: 100, top: 48, width: 90, height: 24 } },
    settingsIcon, settingsText);
  const docsLink = el("a", { attributes: { href: "/docs", "data-wisp-id": "e2" }, text: "Docs", rect: { left: 220, top: 50, width: 40, height: 20 } });
  const ignoredButton = el("button", { attributes: { "data-wisp-id": "e3" }, text: "Secret" });
  const ignoredRegion = el("div", { attributes: { "data-wisp-ignore": "" } }, ignoredButton);
  const footerButton = el("button", { attributes: { "data-wisp-id": "e4" }, text: "Footer", rect: { left: 40, top: 2400, width: 80, height: 24 } });
  const unrelatedParagraph = el("p", { text: "Unrelated", rect: { left: 10, top: 300, width: 300, height: 20 } });
  fakeDocument.body.append(settingsButton, docsLink, ignoredRegion, footerButton, unrelatedParagraph);
  return { fakeDocument, settingsButton, settingsIcon, settingsText, docsLink, footerButton, unrelatedParagraph };
}

function marksIn(page) {
  return descendantsOf(page.shadowRoot()).filter((element) => String(element.className).startsWith("wisp-mark"));
}

test("badges number walkthrough steps by their own number, else in order", () => {
  const { fakeDocument } = makePage();
  const { highlighter } = loadHighlighter(fakeDocument);
  const badgeNumbersFor = (items) => [...highlighter.internals.badgeNumbersFor(items)];

  assert.deepEqual(badgeNumbersFor([{ kind: "step", stepNumber: 3 }]), [3]);
  assert.deepEqual(badgeNumbersFor([{ kind: "step" }, { kind: "step" }, { kind: "ring" }]), [1, 2, null]);
  // A step that names its number moves the sequence on from there.
  assert.deepEqual(badgeNumbersFor([{ kind: "step", stepNumber: 4 }, { kind: "step" }]), [4, 5]);
  // A ring with a step number still gets the badge; bad numbers don't count.
  assert.deepEqual(badgeNumbersFor([{ kind: "ring", stepNumber: 2 }, { kind: "step", stepNumber: 0 }]), [2, 3]);
  assert.deepEqual(badgeNumbersFor([{ kind: "box", stepNumber: 150 }]), [null]);
});

test("show draws each kind in a closed shadow root, with its badge and label", () => {
  const page = makePage();
  const loaded = loadHighlighter(page.fakeDocument);
  const shownResult = loaded.highlighter.show({
    color: "rgb(255, 69, 58)",
    items: [
      { elementId: "e1", kind: "step", stepNumber: 2, label: "Open settings" },
      { elementId: "e2", kind: "highlight" },
      { elementId: "e3", kind: "ring" },
      { elementId: "e99", kind: "ring" },
    ],
  });
  assert.deepEqual([...shownResult.shown], ["e1", "e2"]);
  // Ignored regions are never marked, and unknown ids are reported.
  assert.deepEqual([...shownResult.missing], ["e3", "e99"]);
  assert.deepEqual([...shownResult.badges], [2, null]);

  const hostElement = loaded.highlighter.state.hostElement;
  assert.equal(hostElement.parentElement, page.fakeDocument.documentElement);
  assert.ok(hostElement.hasAttribute("data-wisp-ignore"));
  assert.equal(hostElement.attachedShadowRoot.mode, "closed");
  assert.equal(hostElement.style["--wisp-mark-color"], "rgb(255, 69, 58)");

  const marks = marksIn(loaded);
  assert.deepEqual(marks.map((mark) => mark.className), ["wisp-mark step", "wisp-mark highlight"]);
  const badge = descendantsOf(marks[0]).find((element) => element.className === "wisp-badge");
  assert.equal(badge.textContent, "2");
  // Outlines sit 4px outside the element; the band covers it exactly.
  assert.equal(marks[0].style.left, "96px");
  assert.equal(marks[0].style.width, "98px");
  assert.equal(marks[1].style.left, "220px");
  const label = descendantsOf(loaded.shadowRoot()).find((element) => element.className === "wisp-label");
  assert.equal(label.textContent, "Open settings");
});

test("a colour that isn't a plain rgb() or #hex is replaced", () => {
  const page = makePage();
  const loaded = loadHighlighter(page.fakeDocument);
  loaded.highlighter.show({ color: "url(https://evil.example/x.png)", items: [{ elementId: "e1", kind: "ring" }] });
  assert.equal(loaded.highlighter.state.hostElement.style["--wisp-mark-color"], "rgb(51, 128, 255)");
  assert.equal(loaded.highlighter.internals.sanitizedColor("#34C759"), "#34C759");
});

test("the ring pulses, unless the user prefers reduced motion", () => {
  const animatedPage = loadHighlighter(makePage().fakeDocument);
  const animatedResult = animatedPage.highlighter.show({ items: [{ elementId: "e1", kind: "ring" }] });
  assert.equal(animatedResult.reducedMotion, false);
  assert.equal(marksIn(animatedPage)[0].className, "wisp-mark ring pulse");

  const stillPage = loadHighlighter(makePage().fakeDocument, { reducedMotion: true });
  const stillResult = stillPage.highlighter.show({ items: [{ elementId: "e1", kind: "ring" }] });
  assert.equal(stillResult.reducedMotion, true);
  assert.equal(marksIn(stillPage)[0].className, "wisp-mark ring");
});

test("an off-screen element is scrolled into view once, without smooth motion when reduced", () => {
  const page = makePage();
  const loaded = loadHighlighter(page.fakeDocument, { reducedMotion: true });
  loaded.highlighter.show({ items: [{ elementId: "e4", kind: "ring" }] });
  assert.equal(loaded.scrolledIntoView.length, 1);
  assert.equal(loaded.scrolledIntoView[0][0], page.footerButton);
  assert.equal(loaded.scrolledIntoView[0][1].behavior, "auto");

  // Scrolling later only moves the mark; the page is never scrolled again.
  page.footerButton.rect = { left: 40, top: 400, width: 80, height: 24 };
  loaded.dispatchToWindow("scroll", {});
  assert.equal(loaded.scrolledIntoView.length, 1);
  assert.equal(marksIn(loaded)[0].style.top, "396px");

  // An element already on screen is never scrolled to.
  const onScreen = loadHighlighter(makePage().fakeDocument);
  onScreen.highlighter.show({ items: [{ elementId: "e1", kind: "ring" }] });
  assert.equal(onScreen.scrolledIntoView.length, 0);
});

test("marks follow the element and hide while it is gone", () => {
  const page = makePage();
  const loaded = loadHighlighter(page.fakeDocument);
  loaded.highlighter.show({ items: [{ elementId: "e2", kind: "box", label: "Docs" }] });
  assert.deepEqual(loaded.observedElements, [page.docsLink]);

  page.docsLink.rect = { left: 220, top: -150, width: 40, height: 20 };
  loaded.dispatchToWindow("scroll", {});
  assert.equal(marksIn(loaded)[0].style.top, "-154px");

  page.docsLink.remove();
  loaded.dispatchToWindow("resize", {});
  assert.equal(marksIn(loaded)[0].style.display, "none");
});

test("ids resolve through the DOM agent's registry first", () => {
  const page = makePage();
  const shadowOnlyButton = el("button", { text: "Inside shadow", rect: { left: 5, top: 5, width: 50, height: 20 } });
  const host = el("div");
  page.fakeDocument.body.append(host);
  shadowOnlyButton.shadowHost = host;
  const loaded = loadHighlighter(page.fakeDocument, { agentElementsByID: { e7: shadowOnlyButton } });
  const shownResult = loaded.highlighter.show({ items: [{ elementId: "e7", kind: "ring" }] });
  assert.deepEqual([...shownResult.shown], ["e7"]);
});

test("Esc and a click on a label dismiss the marks and tell Wisp", () => {
  const page = makePage();
  const loaded = loadHighlighter(page.fakeDocument);
  loaded.highlighter.show({ items: [{ elementId: "e1", kind: "ring", label: "Settings" }, { elementId: "e2", kind: "ring" }] });
  loaded.dispatchToWindow("keydown", { key: "a" });
  assert.equal(loaded.sentMessages.length, 0);
  loaded.dispatchToWindow("keydown", { key: "Escape" });
  assert.equal(loaded.highlighter.state.hostElement, null);
  assert.deepEqual(loaded.sentMessages, [{
    type: "wisp.pointing",
    event: "page.highlightDismissed",
    data: { reason: "escape", elementIds: ["e1", "e2"] },
  }]);
  // A second Esc has nothing to dismiss.
  loaded.dispatchToWindow("keydown", { key: "Escape" });
  assert.equal(loaded.sentMessages.length, 1);

  loaded.highlighter.show({ items: [{ elementId: "e1", kind: "ring", label: "Settings" }] });
  const label = descendantsOf(loaded.shadowRoot()).find((element) => element.className === "wisp-label");
  label.eventListeners.click[0]({ stopPropagation() {} });
  assert.deepEqual(loaded.sentMessages.at(-1).data, { reason: "label", elementIds: ["e1"], elementId: "e1" });
});

test("a real click anywhere inside a watched element counts for it", () => {
  const page = makePage();
  const loaded = loadHighlighter(page.fakeDocument);
  const watchResult = loaded.highlighter.watchClicks({ ids: ["e1", "e3", "e42"] });
  assert.deepEqual([...watchResult.watching], ["e1"]);
  assert.deepEqual([...watchResult.missing], ["e3", "e42"]);

  const clickOn = (target, isTrusted = true) => ({
    isTrusted,
    target,
    composedPath() {
      const path = [];
      for (let current = target; current; current = current.parentElement) path.push(current);
      return path;
    },
  });

  // The icon inside the button is part of the button.
  loaded.dispatchToWindow("click", clickOn(page.settingsIcon));
  assert.deepEqual(loaded.sentMessages, [{ type: "wisp.pointing", event: "page.elementClicked", data: { elementId: "e1" } }]);

  // Elsewhere on the page, or a synthetic click (Wisp's own, or the page's), doesn't.
  loaded.dispatchToWindow("click", clickOn(page.unrelatedParagraph));
  loaded.dispatchToWindow("click", clickOn(page.settingsText, false));
  loaded.dispatchToWindow("click", clickOn(page.docsLink));
  assert.equal(loaded.sentMessages.length, 1);

  loaded.highlighter.stopWatchingClicks();
  loaded.dispatchToWindow("click", clickOn(page.settingsButton));
  assert.equal(loaded.sentMessages.length, 1);
});

test("click matching walks the composed path, so shadow-DOM clicks count", () => {
  const { fakeDocument } = makePage();
  const { highlighter } = loadHighlighter(fakeDocument);
  const watchedHost = { name: "host" };
  const innerNode = { name: "inner" };
  const shadowRootNode = { name: "shadow" };
  const watchedElementsByID = [["e5", watchedHost]];
  assert.equal(highlighter.internals.watchedElementIDForClick([innerNode, shadowRootNode, watchedHost], watchedElementsByID), "e5");
  assert.equal(highlighter.internals.watchedElementIDForClick([innerNode, shadowRootNode], watchedElementsByID), null);
});

test("injecting twice keeps the first highlighter and its marks", () => {
  const page = makePage();
  const loaded = loadHighlighter(page.fakeDocument);
  loaded.highlighter.show({ items: [{ elementId: "e1", kind: "ring" }] });
  const firstHighlighter = loaded.context.__wispHighlighter;
  loaded.reinject();
  assert.equal(loaded.context.__wispHighlighter, firstHighlighter);
  assert.equal(loaded.highlighter.clear().cleared, true);
  assert.equal(loaded.highlighter.clear().cleared, false);
});

test("a walkthrough step can ask not to be dismissed by Esc", () => {
  const page = makePage();
  const loaded = loadHighlighter(page.fakeDocument);
  loaded.highlighter.show({ dismissOnEscape: false, items: [{ elementId: "e1", kind: "step", stepNumber: 1, label: "Settings" }] });
  loaded.dispatchToWindow("keydown", { key: "Escape" });
  assert.equal(loaded.highlighter.state.marks.length, 1);
  assert.equal(loaded.sentMessages.length, 0);

  // The next ordinary mark is dismissable again.
  loaded.highlighter.show({ items: [{ elementId: "e2", kind: "ring" }] });
  loaded.dispatchToWindow("keydown", { key: "Escape" });
  assert.equal(loaded.highlighter.state.marks.length, 0);
});

test("a badge at the viewport's edge moves inside the mark instead of being cut off", () => {
  const { highlighter } = loadHighlighter(makePage().fakeDocument);
  const badgeOffsetFor = (markFrame) => ({ ...highlighter.internals.badgeOffsetFor(markFrame) });
  assert.deepEqual(badgeOffsetFor({ left: 200, top: 300 }), { left: -11, top: -11 });
  assert.deepEqual(badgeOffsetFor({ left: -4, top: 300 }), { left: 6, top: -11 });
  assert.deepEqual(badgeOffsetFor({ left: 200, top: 3 }), { left: -11, top: -1 });
});
