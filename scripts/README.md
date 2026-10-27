# Scripts

## `install.sh` — Put your dev build in /Applications

Copies the `Wisp.app` you last built in Xcode (Cmd+B) into `/Applications`, keeping its
permission grants. It deliberately doesn't build: see the comment at the top of the script.

```bash
./scripts/install.sh
```

## `release.sh` — Ship a new version of Wisp

Builds a Developer ID–signed, notarized DMG and publishes it as a GitHub Release on
[anaylab/wisp](https://github.com/anaylab/wisp/releases):
archive → export → DMG → notarize + staple → GitHub Release.

Wisp has no auto-updater, so there's no appcast: people download new versions from the
Releases page (`https://github.com/anaylab/wisp/releases/latest/download/Wisp.dmg`).

### Usage

```bash
# See what would happen, without building or publishing anything
./scripts/release.sh --dry-run

# Release for real: auto-bumps version and build from the latest GitHub Release
./scripts/release.sh
```

The script reads the latest release (e.g. `Wisp v1.5 (build 6)`) and bumps to `v1.6`,
build 7. The first release is `v1.0`, build 1. You'll see a confirmation prompt before
anything slow or public happens.

### Choosing the numbers yourself

```bash
# Pick the version; the build number still goes up by one
./scripts/release.sh 2.0

# Pick both
./scripts/release.sh 2.0 10
```

### Guardrails

- **Preflight checks**: before anything runs, it checks for `create-dmg`, a signed-in `gh`,
  a "Developer ID Application" identity for team `W2H2SA2F98`, a working notarytool keychain
  profile, `dmg-background.png`, a clean working tree, and that `HEAD` is pushed to GitHub.
  Everything missing is listed at once, with the command that fixes it.
- **Duplicate detection**: if the tag already exists on GitHub, the script exits and
  suggests what to do.
- **Confirmation prompt**: shows the version, build, previous release and commit. Press `y`
  to continue.
- **Dry run**: `--dry-run` runs the same checks (reporting instead of stopping) and prints
  every command it would run, without the prompt.

### Steps

1. Checks the prerequisites above
2. Picks the next version + build from the latest GitHub Release
3. Archives the Release configuration with `xcodebuild archive` into `build/` (with its own
   DerivedData)
4. Exports a Developer ID–signed `Wisp.app` and verifies the signature and bundle id
5. Creates `build/dmg/Wisp.dmg` with `create-dmg` and the drag-to-Applications
   `dmg-background.png`, then signs the DMG
6. Notarizes the DMG with Apple, staples the ticket, and checks it with `spctl`
7. Creates a GitHub Release (`vX.Y`, titled `Wisp vX.Y (build N)`) on the built commit, with
   the DMG attached and notes generated from merged PRs

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
and expect to grant permissions once more.

### Before the first release

1. **Xcode**, signed in with the Apple Developer account for team `W2H2SA2F98`
2. **Developer ID Application certificate**: Xcode → Settings → Accounts → Manage
   Certificates → **+** → Developer ID Application. (Only the Account Holder can create one.)
3. **Homebrew tools**:
   ```bash
   brew install create-dmg gh
   ```
4. **GitHub CLI auth** (with push access to `anaylab/wisp`):
   ```bash
   gh auth login
   ```
5. **Apple notarization credentials**, stored in the Keychain:
   ```bash
   xcrun notarytool store-credentials "AC_PASSWORD" \
       --apple-id YOUR_APPLE_ID \
       --team-id W2H2SA2F98
   ```
   You'll be prompted for an app-specific password (generate one at
   [account.apple.com](https://account.apple.com)). To use a different profile name, set
   `WISP_NOTARY_PROFILE=<name>` when running the script.
