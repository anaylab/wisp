# Phase 11: Research mode with on-page citations

You're implementing phase 11 of the Wisp Chrome extension roadmap in `/Users/m3pro/Downloads/clicky`.
First read `CLAUDE.md`, `docs/chrome-extension/README.md` and `docs/chrome-extension/contracts.md`.
Phases 02 and 03 are merged. Branch `feature/chrome-ext-11-research` from `feature/chrome-extension`,
and open a PR back into it.

## Goal

"Research the best budget mechanical keyboards" / "research how mRNA vaccines work for my bio essay":

1. Wisp searches (in its own tab group), picks 5–8 sources, opens them inactive in the Wisp group, and
   reads each with `getPageText`.
2. It writes an answer with numbered claims, each tied to a source and an exact supporting quote
   (≤25 words, verbatim from the extracted text, checked by string match, and dropped if it doesn't
   match).
3. Optionally it saves a Brain page (`topics/` + `sources/` pages through `BrainEditPlanner`,
   provenance `.external`, so it can only append/create).
4. Clicking a citation focuses that tab and highlights the quote with a text fragment
   (`#:~:text=`), falling back to `highlightTextFragments`, which uses the phase 05 highlight style if
   merged, else a plain `<mark>`.
5. It closes the tabs it opened when the user says "done", or after 30 minutes idle. It asks first if
   the user has interacted with them.

## Design notes

- Run it as a background task (`BackgroundTaskLauncher`, "Research · <topic>"), so it shows in History
  and doesn't block talking.
- Local model: cap at 5 sources and summarise each page separately first (map), then combine (reduce).
  Keep each call within the local budget. Cloud model: up to 8 sources, one combine call. Both go
  through `ModelAccessGate` at background priority.
- Search results come from the DOM controller on the user's default search engine page. Don't add a
  search API.
- Page text is untrusted (contracts §6). A page that says "ignore previous instructions" must not change
  the plan. Add a case to `Tests/HostileProviderAttack` or a new hostile-page fixture suite.

## Wisp

- `ChromeExtension/ResearchSession.swift` (orchestration) and `ResearchCitationVerifier.swift` (pure:
  quote ↔ text matching with whitespace/quote normalisation, claim/source numbering, the text-fragment
  URL builder).
- The answer surface: the notch shows a short answer + "Open report". The report is a Chat page entry
  with clickable citations (`WispWindowRouter`).
- Agent tool: `research_topic` (`.browser`, starts the background task, returns when done). A plain
  phrase route "research …" goes through `BrowserCommandRouter`, conservatively.
- Extension: `handlers/research.js` with `highlightTextFragments({tabId, quotes})`.
- Suites: `Tests/ChromeExtResearch/` for the verifier, the fragment URLs, source dedupe (same host +
  path), and map/reduce prompt budgets.

## Manual checks

One local-model and one cloud-model research run. The citations open the right tab at the right
passage, and a fabricated quote is dropped (test with a stub).
