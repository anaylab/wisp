# Phase 07: Download concierge

You're implementing phase 07 of the Wisp Chrome extension roadmap in `/Users/m3pro/Downloads/clicky`.
First read `CLAUDE.md`, `docs/chrome-extension/README.md` and `docs/chrome-extension/contracts.md`.
Phase 01 is merged. Branch `feature/chrome-ext-07-downloads` from `feature/chrome-extension`, and open
a PR back into it. This needs the `downloads` capability.

## Goal

When a download finishes, Wisp can offer to file it: rename it to something meaningful, move it into
a folder by rule, and/or add it to the brain. The user decides once per download from a small notch
card, or once per rule. Nothing moves without a yes.

## Extension

- `events/downloads.js`: `download.created` / `download.completed` / `download.failed` with id,
  final filename (absolute path), MIME type, size, the source page URL and referrer, and whether it's
  dangerous. `handlers/downloads.js`: `getDownloads({limit})` and `showDownload({downloadId})`.
- The extension never renames or moves files. Wisp does that on disk, since it owns the decision and
  the filesystem.

## Wisp

1. `ChromeExtension/DownloadFilingRules.swift` (pure):
   - rules in `~/.wisp/download-rules.json`: match by extension/MIME/source host/filename words →
     destination folder + rename template (`{date}`, `{site}`, `{title}`);
   - suggested name: from the source page title for PDFs and images, otherwise the cleaned filename;
   - collision-safe naming (` 2`, ` 3`);
   - refusal for dangerous downloads and for paths outside the user's home.
2. `ChromeExtension/DownloadConcierge.swift`: subscribes to `download.completed`. If a rule matches
   and the user has marked it "always", it applies it and reports in the notch with an Undo that moves
   the file back, kept in memory for 10 minutes. Otherwise it shows a compact notch card,
   "Paper.pdf from arxiv.org → ~/Documents/Papers/… · Add to brain", with File / Just brain / Ignore.
   It respects quiet mode (no card, just a badge) and is off by default (switch in the Chrome Tabs card).
3. Agent tools (`.browser`): `chrome_list_downloads` (read) and `file_download` (rename/move, asks).
4. Brain: "Add to brain" enqueues the file with `BrainIngestQueue.enqueue(fileURL:)`, for supported
   types only.
5. Suites: `Tests/ChromeExtDownloads/` for rule matching, templates, collisions and refusals.

## Manual checks

Download a PDF from arxiv and an image. File one, add one to the brain, and undo a filing. A `.dmg`
gets no rename suggestion beyond the cleaned name.
