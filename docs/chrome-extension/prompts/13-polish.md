# Phase 13: Polish (other Chromium browsers, settings, docs)

You're implementing the last phase of the Wisp Chrome extension roadmap in
`/Users/m3pro/Downloads/clicky`. First read `CLAUDE.md`, `docs/chrome-extension/README.md` and
`docs/chrome-extension/contracts.md`. Every earlier phase that's going to land is merged. Branch
`feature/chrome-ext-13-polish` from `feature/chrome-extension`, and open a PR back into it.

## Goal

1. **Other Chromium browsers.** Arc, Brave, Edge, Vivaldi and Chrome Beta/Canary load the same unpacked
   extension with the same ID (the manifest `key`). Make Wisp:
   - name the connected browser correctly (`hello.browserName`, plus the frontmost app's bundle id);
   - pick the extension path when *that* browser is frontmost (`BrowserControllerSelector`);
   - make "this tab" mean the focused window of the connected browser;
   - support one connection per browser, if more than one is running. That's a bridge change: keep
     `activeConnection` per browser name, and route requests to the frontmost one, or Chrome when
     ambiguous.

   Test what you can locally, and list what you couldn't.
2. **Settings.** The Chrome Tabs card becomes a tidy **Browser** card: connection per browser,
   capabilities with grant buttons, the feature switches added by phases 04/07/09/10, tab sessions,
   and a "What Wisp can do in your browser" disclosure listing the commands. Follow the window style
   rules (one button treatment, copy that earns its place).
3. **Docs.**
   - Rewrite `chrome-extension/README.md` (install, permissions, everything you can say, privacy).
   - Consolidate the Chrome paragraphs in `CLAUDE.md` into one coherent architecture section and check
     every Key Files row against the files on disk (line counts too).
   - Update `docs/chrome-extension/README.md` to say what shipped and what didn't.
4. **Audit.** Go through contracts §6 for every handler and content script and fix what doesn't hold.
   Run every `Tests/ChromeExt*/run.sh`, `node --test chrome-extension/tests/`,
   `Tests/AgentRuntimeIntegration` and `Tests/HostileProviderAttack`, and paste the results into the PR.
5. Bump the extension version to `2.0.0`.

## Out of scope

New features. If you find a gap, list it in the PR.
