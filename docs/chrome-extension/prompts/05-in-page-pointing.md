# Phase 05: In-page pointing and walkthroughs that follow the page

You're implementing phase 05 of the Wisp Chrome extension roadmap in `/Users/m3pro/Downloads/clicky`.
First read `CLAUDE.md`, `docs/chrome-extension/README.md` and `docs/chrome-extension/contracts.md`.
Phase 03 (DOM controller) is merged. Branch `feature/chrome-ext-05-in-page-pointing` from
`feature/chrome-extension`, and open a PR back into it.

## Goal

When the thing Wisp points at is in a Chrome page, draw the marker **inside the page**, anchored to
the element, so it survives scrolling, resizing and zoom. The screen overlay's annotations are pinned
to screen positions and get dropped on scroll. Guided walkthrough steps in Chrome complete on the
real click event instead of the global mouse-down matcher.

## Extension

- `content/highlight.js`: draws in a closed shadow root at the top of the page, with no page CSS
  leaking in or out. It supports:
  - ring (pulse), box, highlight band and numbered step badge;
  - an optional short label;
  - the user's marker colour, passed in, from `CursorAppearanceStore`.

  It follows the element with `ResizeObserver` + scroll listeners + `requestAnimationFrame`
  throttling, and scrolls the element into view once if it's off-screen. Esc or a click on the label
  dismisses it (`page.highlightDismissed`). Respect `prefers-reduced-motion` (no pulse).
- `handlers/pointing.js`: `highlightElements({tabId, items:[{elementId, kind, label, stepNumber}]})`,
  `clearHighlights`, `watchClicks({tabId, elementIds})` → `page.elementClicked {elementId}`,
  `stopWatchingClicks`. Element ids are phase 03's `e` ids.
- Tests: badge numbering, reduced-motion, click matching within a target's subtree.

## Wisp

1. Pointing route: when the target of fast pointing (`runFastPointingTurn`) or a model `[POINT:]` /
   `[BOX:]` resolves to something in the frontmost Chrome tab, and the DOM controller can find a
   matching element (`findElements` with the label), draw it in-page instead of on the overlay.
   Otherwise keep the overlay. Put the decision (`ChromeInPagePointingPolicy`) in a pure file.
2. Guided walkthrough (`GuidedWalkthroughController.swift`: `GuidedWalkthroughSession` and the
   `CompanionManager` extension): for steps in Chrome, find each step's target
   with `findElements`, highlight it as a numbered step, and complete the step on `page.elementClicked`.
   "Do it for me" clicks through `clickElement` and keeps the irreversible-action refusal. A
   navigation (`nav.completed`) re-finds the next step on the new page.
3. Esc / `clearScreenAnnotations` also calls `clearHighlights`.
4. Suites: `Tests/ChromeExtInPagePointing/` for the policy and the step-to-element matching.

## Manual checks

- "Where is the settings button" on GitHub draws a ring in-page. Scrolling keeps it on the button.
- A 3-step walkthrough across two GitHub pages completes on real clicks.
- On a non-Chrome app, pointing is unchanged.

## Out of scope

Text-fragment citations (11).
