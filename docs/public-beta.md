# Public beta

What's needed to put Wisp in strangers' hands, with automatic updates. Written 2026-11-04 on
`feature/public-beta-updates`; delete it once the first release is out and the gaps are dealt with.

## How updates work

- Installed copies ask `https://github.com/anaylab/wisp/releases/latest/download/appcast.xml` once a
  day. The feed is an asset of the latest GitHub Release, so a release and its feed go live together.
- An update downloads silently and installs the next time Wisp quits. If Wisp is still running at a
  later check, the menu bar gets "Update to Wisp 0.2…" and one notification.
- The zip and the feed are both signed with an EdDSA key that exists only in your Keychain. The app
  refuses anything else, on top of Apple's Developer ID signature and notarization.
- Only `scripts/release.sh` puts the public key in the app, so a copy built in Xcode never updates and
  your dev copy can't replace itself and lose its permissions.
- There's one feed and no separate beta channel, because there's one audience. Versions below 1.0
  read as "beta" in Settings. When a stable 1.0 needs testing ahead of everyone, Sparkle's channels add
  this: `generate_appcast --channel beta` plus `allowedChannels(for:)` in `WispUpdater`.

## What only you can do

1. **Join the paid Apple Developer Program, if you aren't already ($99/year).** Team `W2H2SA2F98`
   ("Anay Parwal") looks like a free Personal Team: its provisioning profile lasts 7 days, where a paid
   team's lasts a year. Developer ID and notarization need the paid program. Without them macOS
   blocks the download for everyone. If you do pay, ignore this.
2. **Create the Developer ID certificate:** Xcode → Settings → Accounts → Manage Certificates → + →
   Developer ID Application. This Mac only has "Apple Development" today. If the paid membership gets a
   new team ID, change `SIGNING_TEAM_ID` in `scripts/release.sh`.
3. **Store notarization credentials:** `xcrun notarytool store-credentials "AC_PASSWORD" --apple-id YOU --team-id W2H2SA2F98`
   with an app-specific password from account.apple.com.
4. **Install the tools:** `brew install create-dmg`.
5. **Generate the update signing key**, once, ever (`scripts/README.md` has the commands). Put the public
   half in `scripts/sparkle-public-key.txt` and commit it. **Back up the private half somewhere safe,
   such as a password manager.** If it's lost, no installed copy can ever be updated again; people
   would have to download by hand.
6. **Merge this branch and push it**, since a release must be built from a commit on GitHub.
7. **Cut the first release:** `./scripts/release.sh --dry-run`, then `./scripts/release.sh`. It starts at
   0.1 and asks twice, once before building and once before publishing.
8. **Cut a second release soon after, and watch 0.1 update to it on a clean Mac or user account.** This
   is the one test nothing else can stand in for (below). Do it before announcing.
9. **After the first release, change the words that say there's no download:** `README.md` (the Get
   section and the "Why isn't there a download button?" answer), `docs/assets/readme/get-*.png`, and
   `site/index.html` (the Get section and the same answer). The download link is
   `https://github.com/anaylab/wisp/releases/latest/download/Wisp.dmg`.

## What has and hasn't been tested

Tested, on this Mac:

- The app builds through Xcode, and a dev build has an empty key, so it never contacts the feed.
- `./Tests/AppUpdates/live-update.sh`: a small app built from the real `WispUpdater.swift` and real Sparkle
  went from build 1 to build 2 through a signed feed on localhost, with Wisp's own `SU*` settings: silent
  download, the quiet reminder, install on quit. A swapped zip, an edited feed and an unsigned feed
  were each refused.
- `release.sh --dry-run` runs every check and prints every step.

Not tested, because it needs a Developer ID certificate or a real release:

- The real `xcodebuild archive` and export, notarization, stapling, the DMG, and uploading.
- **Wisp itself updating from one signed build to the next.**
- **Permissions surviving an update.** They should, since macOS ties them to the bundle id and signing
  certificate and neither changes, but nothing has shown it yet.
- A stranger's first run on a clean Mac. The gaps below come from reading the code, not watching it.

Testing a release copy on your own Mac moves your permission grants to the Developer ID signature, so
your dev copy will need them again (see `scripts/README.md`). A second user account avoids that.

## Gaps for a stranger

Found by reading the first-run path. None are fixed here, since they're separate from updates.

**Would stop someone in the first five minutes:**

- **Nothing installs or even mentions the model.** Default is local Ollama, which a stranger won't have.
  Today's only hint is "The local model isn't running: start Ollama with `ollama serve`", with a Copy
  command button, which fails for someone without Ollama. There's no download link and no pointer to
  Apple's on-device model or a cloud provider.
- **Ollama running without the model** (`qwen2.5vl:3b`, 3.2 GB) isn't detected at all. The health check only
  asks whether Ollama answers. A turn then gets a raw 404 from Ollama, and the spoken line is "Something
  went wrong answering that".
- **The first-run setup never appears.** `FirstRunSetupFlow` isn't used by any view, and nothing reads
  `isFirstRunSetupRequested`, so Settings' "Run setup again" button does nothing. `AGENTS.md` describes
  it as working. What a stranger really gets is Today with the permissions checklist.

**Would confuse or annoy:**

- **Opening Wisp from the disk image or Downloads** isn't caught. Permissions then attach to a throwaway
  location and updates can't install. Settings says to move it, but nothing else does. A "Move to
  Applications?" prompt at launch would fix it.
- **Wisp adds itself as a login item on first launch without asking**, with no setting to change it, and
  tries again on every launch if it isn't enabled, which may undo someone turning it off in System Settings.
- **The default agent folder is `~/Downloads/clicky`** (`CodeProjectDirectory` in `Info.plist`), your own
  path, which won't exist elsewhere.
- **The Chrome extension isn't in the download.** Tab organizing needs `chrome-extension/` from the repo.
- **Testers have no way to report back from inside the app.** There's no analytics by design, so GitHub's
  bug report form is the only channel, and nothing links to it. A "Send Feedback…" menu item would help.
