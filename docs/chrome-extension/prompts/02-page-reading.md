# Phase 02: Page reading (no screenshot)

You're implementing phase 02 of the Wisp Chrome extension roadmap in `/Users/m3pro/Downloads/clicky`.
First read `CLAUDE.md`, `docs/chrome-extension/README.md` and `docs/chrome-extension/contracts.md`.
Phase 01 is merged. Branch `feature/chrome-ext-02-page-reading` from `feature/chrome-extension`, and
open a PR back into it.

## Goal

"Summarize this tab", "what's the price on this page" and "add this page to my brain" should read the
page's **text** through the extension instead of encoding a screenshot (~4s of vision encoding, see
CLAUDE.md "Vision encoding dominates latency"). That makes these turns faster and more accurate, and
it works on tabs that aren't visible.

## Extension

- `content/read-page.js`, injected on demand with `chrome.scripting.executeScript`. It returns:
  - a Readability-style main text: drop nav/aside/footer/script/style/hidden elements, prefer
    `<main>`/`<article>`, keep headings as `#` lines, list items as `- `, table cells joined with ` | `;
  - the title, canonical URL, `lang`;
  - `meta[name=description]`, the published date if one is marked up;
  - word count.

  Write it from scratch, with no vendored library. It obeys contracts §6 (secrets, `data-wisp-ignore`).
- `handlers/page-reading.js`:
  - `getPageText({tabId?, maximumCharacters?})`, defaulting to the active tab of the focused window;
  - `getSelection({tabId?})`, the selected text plus ~300 chars of surrounding context;
  - `getPageOutline({tabId?})`, the headings with their levels.

  Refuse forbidden URLs (contracts §6) with a clear error. If `pages.read` is missing, return the error
  `missing capability pages.read`.
- Tests: the extraction runs against fixture HTML in `tests/fixtures/*.html`, using jsdom-free DOM
  parsing. If you can't parse fixtures without a dependency, use `node:test` with `linkedom` as a
  devDependency in `chrome-extension/package.json`, and never ship it in the extension. Cover: an
  article page, a docs page with a sidebar, a page with a password field, and a page whose text exceeds
  the cap.

## Wisp

1. `ChromeExtension/ChromePageReader.swift`: a typed `readPage(tabID:)` / `readSelection` /
   `readOutline` over the bridge, plus the pure `ChromePageTextPrompt` that fences the text as page DATA
   and trims it to a model budget. That budget is smaller for the local model, ~6k chars, than for
   cloud, ~20k. Put the constants beside the existing per-model budgets.
2. Turn path: when a turn is screen-referring *and* the frontmost app is Chrome *and* `pages.read` is
   granted *and* the request is about the page's content rather than its look (a pure classifier:
   "summarize / what does this say / price / explain this article" yes, "what color / where is the
   button / layout" no), attach the page text block instead of the screenshot. Add it to the per-turn
   context block that's stripped from history, like the `a`/`t` ids. Biased toward keeping the
   screenshot when unsure. Put the classifier in a pure file with its own tests.
3. Agent tools (`.browser` scope, buddy Browser group, `.reading(.localMachine)`):
   `chrome_read_tab` (tab by id, title or URL fragment, default the active tab) and
   `chrome_read_selection`.
4. Brain: `BrainCommandTargetResolver` prefers the extension's text for "add this page to my brain"
   and enqueues it with `BrainIngestQueue.enqueue(text:title:)`, keeping the URL as the source. It
   falls back to today's AppleScript/URL path.
5. Suites: `Tests/ChromeExtPageReading/` for the prompt fencing/trimming, the content-vs-look
   classifier, and the tab-reference resolver.

## Manual checks

- On a long article, "summarize this page": no screenshot is attached (check the perf log / History
  step) and the answer is correct.
- "What color is the header": the screenshot is still used.
- Without `pages.read`: the screenshot path works as before, and `chrome_read_tab` explains how to allow it.
- "Add this page to my brain" creates a source page with clean text.

## Out of scope

DOM actions (phase 03), the context menu (06), watchers (08).
