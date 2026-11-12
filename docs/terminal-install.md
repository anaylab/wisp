# Terminal install

```bash
curl -fsSL https://anaylab.github.io/wisp/install.sh | bash
```

Needs an Apple-silicon Mac on macOS 26 or later. No sudo, no Apple ID. Re-run the same command to update.
Options (pass after `bash -s --`): `--yes`, `--no-ollama`, `--version v0.1`, `--uninstall`, `--help`.

## Drag-and-drop dmg

The same build also produces `Wisp.dmg` (with `Wisp.dmg.sha256`), attached to the release. Open it and drag Wisp
to Applications. Because it isn't notarized, a dmg downloaded in a browser is blocked once: right-click Wisp in
Applications and choose Open, or approve it in System Settings > Privacy & Security > Open Anyway. The curl
command avoids that prompt, so keep it as the main path until the app is notarized.

## What it does

`site/install.sh` checks the Mac, downloads `Wisp.zip` and `Wisp.zip.sha256` from the latest GitHub Release,
verifies the checksum, the bundle id (`com.gluepixel.wisp`) and the code signature, quits a running Wisp, replaces
`/Applications/Wisp.app` (the old copy is put back if the copy fails), optionally installs Ollama and the
`qwen2.5vl:3b` model (asks first; skipped with no terminal unless `--yes`), and opens the app.
Uninstall removes only the app and says where your data lives (`~/Library/Application Support/Wisp`, `~/.wisp`).

## Why this works without Apple's paid program

- Files fetched with `curl` aren't tagged "downloaded from the internet", so Gatekeeper doesn't block or warn.
  The installer also strips that tag if it is present.
- Trust comes from the SHA-256 check, the open source code, and the script being short enough to read.
  The checksum is served from the same place as the zip, so it protects against corruption and a bad mirror,
  not against someone who controls the release itself.

## Tradeoffs (be honest about these)

- **Not notarized.** A browser download of this zip would be blocked by Gatekeeper; only the curl path is smooth.
  That is why there is no download button yet.
- **Permissions across updates.** The app is signed with a self-signed certificate, "Wisp Release", so its
  designated requirement stays the same between builds and macOS keeps the microphone / screen recording /
  accessibility grants. If that key is ever lost or replaced, everyone re-grants once. Back it up.
- **Updates** are manual (re-run the command) until the Sparkle work in PR #64 lands.

## Cutting a release

1. Once: `scripts/make-signing-identity.sh` (changes your keychain and asks for your login password).
2. From a clean, pushed `main`: `scripts/build-terminal-release.sh --publish v0.1`. It archives Release, signs
   with "Wisp Release", verifies, zips with `ditto`, writes the checksum, and creates the GitHub Release after
   asking.
3. Check on a second Mac (or a fresh user account): run the install command, grant permissions, talk to it.
4. Then switch the site and README wording to the install command (see `docs/product-hunt.md`).

The installer itself is published by copying `site/install.sh` to the `gh-pages` branch like the rest of `site/`.
