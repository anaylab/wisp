# Phase 03: DOM controller (replace AppleScript-injected JS when the extension is there)

You're implementing phase 03 of the Wisp Chrome extension roadmap in `/Users/m3pro/Downloads/clicky`.
First read `CLAUDE.md`, `docs/chrome-extension/README.md` and `docs/chrome-extension/contracts.md`.
Phase 01 is merged. Branch `feature/chrome-ext-03-dom-controller` from `feature/chrome-extension`, and
open a PR back into it. This is the largest phase, so plan before coding.

## Goal

A second implementation of the existing `BrowserController` protocol (`BrowserController.swift`)
backed by the extension: `ExtensionBrowserController`. With it, the whole browser agent (tier 0
planner, tier 1 plans, tier 2 step loop and the cloud `BrowserAgentLoop`) runs without AppleScript.
It can work in background tabs and keeps its work in a visible **Wisp** tab group.
`AppleScriptBrowserController` stays as the fallback, for Safari and for when `pages.read` is missing.

## Study first

`BrowserController.swift`, `AppleScriptBrowserController.swift` (the snapshot JS, `data-wisp-id`
stamping, shadow roots and iframes, the dialog-first ordering, React-safe setters, the password/payment
refusal, the dedicated-tab session), `BrowserAgent.run`, `BrowserAgentLoop`, `BrowserStepLoop`, and
how `AgentToolRegistry.browserController` is used. Element ids (`e7`) and the snapshot's text format
must stay identical, because the planners, validator and prompts depend on them.

## Extension

- `content/dom-agent.js`: port the snapshot / find / click / type / hover / key / scroll / select /
  settle logic from the AppleScript JS, keeping behaviour and the id scheme. Use real pointer events
  and React-safe value setters, and refuse password/payment fields in the script itself. Inject it with
  `executeScript({files})` and keep state on `window.__wispAgent`, so a re-injection is idempotent.
  Same-origin iframes and shadow roots are walked as today. Cross-origin frames are injected with
  `allFrames: true`, with ids prefixed by frame.
- `handlers/dom-controller.js`: the methods in contracts §2 for phase 03. `openTab` /
  `getOrCreateWispGroup` put Wisp's task tab into a collapsed-when-idle group titled "Wisp" (purple),
  in the focused window. `captureVisibleTab` is only for the protocol's screenshot fallback, and it can
  only capture the visible tab, so say so in its error.
- `events/navigation.js`: `nav.committed` / `nav.completed` from `webNavigation` for main frames only.
- Tests with the fake chrome and fixture DOM: id stability across snapshots, the dialog-first order,
  refusal of a password field, select by visible text, settle detection.

## Wisp

1. `ChromeExtension/ExtensionBrowserController.swift`: conforms to `BrowserController`. Many protocol
   methods are synchronous `throws`. Check how they're called. If you need an async variant, add it to
   the protocol with a default implementation for the AppleScript controller rather than blocking the
   main actor. Document the choice.
2. The dedicated-tab session maps to a real tab id, so there's no Safari window+index guesswork. A
   closed tab still means stop (`BrowserControllerError.dedicatedTabClosed`), detected from
   `tab.removed`.
3. Selection: a `BrowserControllerSelector` (pure decision + thin glue) picks the extension when it's
   connected, has `pages.read`, and the target browser is Chrome. Otherwise it picks AppleScript. Wire
   it where `browserController` is created, so `browser_task`, the direct browser route and
   `read_page` / `click_element` all go through it. Log which one served each task.
4. `BrowserCursorGuide` still gets screen points. Get them from the element's client rect plus the
   window's screen position (`chrome.windows.get`), and keep the existing conversion.
5. Suites: `Tests/ChromeExtDOMController/` for the selector and the snapshot decoding. Run
   `Tests/AgentRuntimeIntegration` and `Tests/HostileProviderAttack`. Both must pass, with no new
   known defects.

## Manual checks

- "Open youtube and search for lofi" runs in a tab inside the Wisp group, while the user stays on
  their own tab.
- A tier-2 task on a React form (e.g. a GitHub issue draft, no submit) types correctly.
- "Buy" / "send" buttons still raise the confirmation card with auto-approve on.
- Removing `pages.read` mid-session makes the next task use AppleScript, with no crash.
- Safari tasks are unchanged.

## Out of scope

Drawing in the page (05), forms from the brain (12), the `debugger` permission (never).
