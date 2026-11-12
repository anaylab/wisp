# Scripts

## `update.sh` — Build, install and relaunch in one command

Asks Xcode to build (never `xcodebuild`, which resets permissions), installs the result into
`/Applications` with `install.sh`, quits the running copy and relaunches that one.

```bash
./scripts/update.sh              # build + install + relaunch
./scripts/update.sh --no-build   # install what you already built
./scripts/update.sh --clean      # also offer to delete stale builds (agent worktrees etc.)
```

## `install.sh` — Put your dev build in /Applications

Copies the `Wisp.app` you last built in Xcode (Cmd+B) into `/Applications`, keeping its
permission grants. It deliberately doesn't build: see the comment at the top of the script.

```bash
./scripts/install.sh
```

## `release.sh` — Ship a new version of Wisp

Builds a Developer ID–signed, notarized DMG and update, and publishes them as a GitHub Release on
[anaylab/wisp](https://github.com/anaylab/wisp/releases):
archive → export → notarize the app → DMG → notarize the DMG → signed update + feed → draft → publish.

Installed copies update themselves from the feed, `appcast.xml`, attached to the latest release. New
people download `https://github.com/anaylab/wisp/releases/latest/download/Wisp.dmg`. Publishing
reaches every installed copy within a day and **can't be recalled**, so the fix for a bad release is a
newer one.

### Usage

```bash
# See what would happen, without building or publishing anything
./scripts/release.sh --dry-run

# Release for real: auto-bumps version and build from the latest GitHub Release
./scripts/release.sh

# Build everything but stop at a draft: nobody can see it or update to it
./scripts/release.sh --draft

# Write the release notes yourself. They appear in the update window.
./scripts/release.sh --notes my-notes.md
```

The script reads the latest release (e.g. `Wisp v0.5 (build 6)`) and bumps to `v0.6`, build 7. The
first release is `v0.1`, build 1. Everything below 1.0 reads as "beta" in the app. Without `--notes`,
GitHub writes the notes from merged PRs since the last release.

### Choosing the numbers yourself

```bash
# Pick the version; the build number still goes up by one
./scripts/release.sh 1.0

# Pick both
./scripts/release.sh 1.0 10
```

The build number decides who gets offered what, so it must only ever go up.

### Guardrails

- **Preflight checks**: before anything runs, it checks for `create-dmg`, a signed-in `gh`,
  a "Developer ID Application" identity for team `W2H2SA2F98`, a working notarytool keychain
  profile, the update signing key (and that it matches `sparkle-public-key.txt`),
  `dmg-background.png`, a clean working tree, and that `HEAD` is pushed to GitHub.
  Everything missing is listed at once, with the command that fixes it.
- **Duplicate detection**: if the tag already exists on GitHub, the script exits and
  suggests what to do.
- **Two confirmations**: one before building (version, build, previous release, commit) and one
  before publishing. Say no to the second and the release stays a draft.
- **Reads its own work back**: the exported app's version, key and Sparkle helper signatures,
  Apple's verdict on each notarization, the feed's version, address and signatures, and finally the
  feed as installed copies will fetch it.
- **Dry run**: `--dry-run` runs the same checks (reporting instead of stopping) and prints
  every command it would run, without the prompts.

### Steps

1. Checks the prerequisites above
2. Picks the next version + build from the latest GitHub Release
3. Archives the Release configuration with `xcodebuild archive` into `build/` (with its own
   DerivedData, arm64 only), passing the public update key
4. Exports a Developer ID–signed `Wisp.app` and verifies its signature, bundle id, version, update
   key and Sparkle's helpers
5. Notarizes the app and staples the ticket, because an update arrives without the DMG
6. Creates `build/dmg/Wisp.dmg` with `create-dmg` and the drag-to-Applications
   `dmg-background.png`, signs it, notarizes it, staples it and checks it with `spctl`
7. Zips the app as `build/update/Wisp-<version>-<build>.zip` and has Sparkle's `generate_appcast`
   sign it and write the signed `build/update/appcast.xml`, with the notes embedded
8. Creates a draft GitHub Release (`vX.Y`, titled `Wisp vX.Y (build N)`) with the three files
9. After the second confirmation, publishes it as the latest release, which creates the tag on the
   built commit and puts the feed live

Build logs go to `build/logs/`; on failure the script prints the end of the relevant log.

### Does releasing reset my permissions?

The rule "don't run `xcodebuild` from the terminal" is about your **dev copy**. A release
archive doesn't touch it: everything builds inside `build/`, not Xcode's DerivedData or
`/Applications/Wisp.app`, and building doesn't touch the TCC database. Your installed copy
keeps its Accessibility, Screen Recording, Microphone and Speech grants.

**Opening the release build on the same Mac does affect them.** TCC ties each grant to the
app's signing requirement. Your dev copy is signed "Apple Development", while the release is
signed "Developer ID Application", with the same bundle id (`com.gluepixel.wisp`). If you run
the release copy, macOS asks for permissions again, and granting them moves the entries to
the Developer ID signature. After that, reinstall your dev copy with `./scripts/install.sh`
and expect to grant permissions once more. A second user account avoids all of this.

Your dev copy never updates itself: only this script gives a build the update key.

### Before the first release

1. **Paid Apple Developer Program membership.** Developer ID needs it; a free Personal Team can't.
2. **Xcode**, signed in with the Apple Developer account for team `W2H2SA2F98` (if your paid
   team has a different ID, change `SIGNING_TEAM_ID` at the top of `release.sh`)
3. **Developer ID Application certificate**: Xcode → Settings → Accounts → Manage
   Certificates → **+** → Developer ID Application. (Only the Account Holder can create one.)
4. **Homebrew tools**:
   ```bash
   brew install create-dmg gh
   ```
5. **GitHub CLI auth** (with push access to `anaylab/wisp`):
   ```bash
   gh auth login
   ```
6. **Apple notarization credentials**, stored in the Keychain:
   ```bash
   xcrun notarytool store-credentials "AC_PASSWORD" \
       --apple-id YOUR_APPLE_ID \
       --team-id W2H2SA2F98
   ```
   You'll be prompted for an app-specific password (generate one at
   [account.apple.com](https://account.apple.com)). To use a different profile name, set
   `WISP_NOTARY_PROFILE=<name>` when running the script.
7. **The update signing key**, generated once. Build once in Xcode so Sparkle's tools download, then:
   ```bash
   SPARKLE_BIN=$(ls -d ~/Library/Developer/Xcode/DerivedData/leanring-buddy-*/SourcePackages/artifacts/sparkle/Sparkle/bin | head -1)
   "$SPARKLE_BIN/generate_keys" --account com.gluepixel.wisp
   ```
   This stores the private key in your login Keychain and prints the public key. Put the public key
   in `scripts/sparkle-public-key.txt` and commit it; it isn't secret. **Never commit the private key.**

   Back up the private key, because every installed copy trusts only this key and losing it means
   nobody can be updated again. Export it to a file, move that into a password manager, then delete it:
   ```bash
   "$SPARKLE_BIN/generate_keys" --account com.gluepixel.wisp -x wisp-update-key-backup.txt
   ```
   On a new Mac, bring it back with `generate_keys --account com.gluepixel.wisp -f <file>`.
