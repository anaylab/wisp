#!/bin/bash
set -euo pipefail

# Add Homebrew to PATH so create-dmg and gh are available in non-interactive shells
export PATH="/opt/homebrew/bin:$PATH"

# =============================================================================
# release.sh — Builds, notarizes and publishes a Wisp release
#
# What it does (in order):
#   1. Picks the next version + build from the latest GitHub Release
#   2. Checks every prerequisite up front (create-dmg, gh, Developer ID
#      identity, notarytool profile, the DMG background, a pushed HEAD)
#   3. Archives the app with xcodebuild into build/ (its own DerivedData)
#   4. Exports a Developer ID–signed Wisp.app
#   5. Wraps it in a drag-to-Applications DMG (create-dmg + dmg-background.png)
#   6. Signs, notarizes and staples the DMG
#   7. Creates a GitHub Release on anaylab/wisp with the DMG and generated notes
#
# There are no auto-updates: Wisp doesn't use Sparkle, so there is no appcast.
# Users get new versions by downloading the DMG from GitHub Releases.
#
# Usage:
#   ./scripts/release.sh                 Auto-bumps: 1.5 → 1.6, build 6 → 7
#   ./scripts/release.sh 2.0             Sets marketing version to 2.0, auto-bumps build
#   ./scripts/release.sh 2.0 10          Sets both marketing version and build number
#   ./scripts/release.sh --dry-run [...] Runs the checks and prints every step
#                                        without building, notarizing or publishing
#
# Prerequisites (one-time setup) — see scripts/README.md:
#   - Xcode, and a "Developer ID Application" certificate for team W2H2SA2F98
#   - `brew install create-dmg gh` and `gh auth login`
#   - `xcrun notarytool store-credentials "AC_PASSWORD" ...`
#     (or another profile name, passed as WISP_NOTARY_PROFILE)
#
# TCC note — does releasing reset your dev copy's permissions? No, but testing
# the release copy does:
#   - The archive builds into build/DerivedData and exports into build/export.
#     It never writes to Xcode's DerivedData or /Applications/Wisp.app, and
#     building doesn't touch the TCC database, so the Accessibility / Screen
#     Recording / Microphone / Speech grants of your installed copy survive.
#   - TCC keys a grant on the app's designated requirement. The copy that
#     scripts/install.sh installs is signed "Apple Development" and its
#     requirement names that certificate; the release is signed "Developer ID
#     Application", a different requirement for the same bundle id
#     (com.gluepixel.wisp). If you open the release DMG's copy on this Mac,
#     macOS asks for permissions again and granting them re-points the entries
#     at the Developer ID signature, so your dev copy stops matching. After
#     testing a release locally, reinstall the dev copy with scripts/install.sh
#     (and expect to grant permissions once more).
# =============================================================================

# ── Configuration ────────────────────────────────────────────────────────────

SCHEME="leanring-buddy"
APP_NAME="Wisp"
BUNDLE_IDENTIFIER="com.gluepixel.wisp"
DEVELOPMENT_TEAM_ID="W2H2SA2F98"
GITHUB_REPO="anaylab/wisp"
NOTARY_KEYCHAIN_PROFILE="${WISP_NOTARY_PROFILE:-AC_PASSWORD}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="${PROJECT_DIR}/leanring-buddy.xcodeproj"
BUILD_DIR="${PROJECT_DIR}/build"
DERIVED_DATA_DIR="${BUILD_DIR}/DerivedData"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
EXPORT_OPTIONS_PLIST="${BUILD_DIR}/ExportOptions.plist"
DMG_OUTPUT_DIR="${BUILD_DIR}/dmg"
LOG_DIR="${BUILD_DIR}/logs"
DMG_BACKGROUND="${PROJECT_DIR}/dmg-background.png"

# ── Arguments ────────────────────────────────────────────────────────────────

IS_DRY_RUN=false
POSITIONAL_ARGUMENTS=()
for argument in "$@"; do
    case "$argument" in
        --dry-run) IS_DRY_RUN=true ;;
        -h|--help)
            sed -n '/^# Usage:/,/^# Prerequisites/p' "$0" | sed '$d; s/^# \{0,1\}//'
            exit 0
            ;;
        -*)
            echo "❌ Unknown option: ${argument} (try --help)"
            exit 1
            ;;
        *) POSITIONAL_ARGUMENTS+=("$argument") ;;
    esac
done

if [ "${#POSITIONAL_ARGUMENTS[@]}" -gt 2 ]; then
    echo "❌ Too many arguments. Usage: ./scripts/release.sh [--dry-run] [version] [build]"
    exit 1
fi

REQUESTED_MARKETING_VERSION="${POSITIONAL_ARGUMENTS[0]:-}"
REQUESTED_BUILD_NUMBER="${POSITIONAL_ARGUMENTS[1]:-}"

if [ -n "$REQUESTED_MARKETING_VERSION" ] && [[ ! "$REQUESTED_MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "❌ Version must look like 1.2 or 1.2.3 (got '${REQUESTED_MARKETING_VERSION}')"
    exit 1
fi
if [ -n "$REQUESTED_BUILD_NUMBER" ] && [[ ! "$REQUESTED_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "❌ Build number must be a whole number (got '${REQUESTED_BUILD_NUMBER}')"
    exit 1
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

# Runs a command, or in --dry-run prints it (shell-quoted, so it can be pasted).
run_step_command() {
    if $IS_DRY_RUN; then
        printf '   would run:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# Runs a long, noisy command with its output going to a log file, and shows
# the end of that log if it fails — piping to `tail` alone hides the error.
run_logged_step_command() {
    local log_file_path="$1"
    shift
    if $IS_DRY_RUN; then
        run_step_command "$@"
        echo "              (output → ${log_file_path})"
        return
    fi
    if ! "$@" > "$log_file_path" 2>&1; then
        echo "❌ Failed. Last lines of ${log_file_path}:"
        tail -25 "$log_file_path" | sed 's/^/   /'
        exit 1
    fi
}

# ── Preflight: fail early, before anything slow runs ─────────────────────────
# Every missing prerequisite is reported at once, so one run tells you the
# whole setup that's left. In --dry-run they're reported but don't stop it.

echo "🔎 Checking prerequisites..."
MISSING_PREREQUISITES=()

if ! command -v xcodebuild >/dev/null 2>&1; then
    MISSING_PREREQUISITES+=("xcodebuild not found — install Xcode and run: sudo xcode-select -s /Applications/Xcode.app")
fi

if ! command -v create-dmg >/dev/null 2>&1; then
    MISSING_PREREQUISITES+=("create-dmg not found — install it with: brew install create-dmg")
fi

IS_GITHUB_CLI_READY=false
if ! command -v gh >/dev/null 2>&1; then
    MISSING_PREREQUISITES+=("gh (GitHub CLI) not found — install it with: brew install gh")
elif ! gh auth status >/dev/null 2>&1; then
    MISSING_PREREQUISITES+=("gh is not signed in — run: gh auth login")
else
    IS_GITHUB_CLI_READY=true
fi

# Xcode's export picks the certificate itself; this just makes sure there is
# one to pick, rather than failing ten minutes in at the export step.
DEVELOPER_ID_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | grep "(${DEVELOPMENT_TEAM_ID})" | head -1 \
    | sed -E 's/^[^"]*"(.*)"$/\1/' || true)
if [ -z "$DEVELOPER_ID_IDENTITY" ]; then
    MISSING_PREREQUISITES+=("No \"Developer ID Application\" signing identity for team ${DEVELOPMENT_TEAM_ID} in your keychain — create one in Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application")
fi

# `notarytool history` is the cheapest call that actually authenticates with
# the stored profile, so a typo'd name or expired app-specific password shows
# up now instead of after the build.
if ! xcrun notarytool history --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    MISSING_PREREQUISITES+=("notarytool keychain profile \"${NOTARY_KEYCHAIN_PROFILE}\" is missing or can't sign in — run: xcrun notarytool store-credentials \"${NOTARY_KEYCHAIN_PROFILE}\" --apple-id YOUR_APPLE_ID --team-id ${DEVELOPMENT_TEAM_ID}")
fi

if [ ! -f "$DMG_BACKGROUND" ]; then
    MISSING_PREREQUISITES+=("DMG background not found at ${DMG_BACKGROUND}")
fi

# The release tag is created on the exact commit being built, so that commit
# has to exist on GitHub, and nothing uncommitted may sneak into the build.
RELEASE_COMMIT_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD)
if [ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]; then
    MISSING_PREREQUISITES+=("The working tree has uncommitted changes — commit or stash them so the release matches its tag")
fi
if $IS_GITHUB_CLI_READY && ! gh api "repos/${GITHUB_REPO}/commits/${RELEASE_COMMIT_SHA}" >/dev/null 2>&1; then
    MISSING_PREREQUISITES+=("HEAD (${RELEASE_COMMIT_SHA:0:7}) isn't on github.com/${GITHUB_REPO} yet — push it first")
fi

if [ "${#MISSING_PREREQUISITES[@]}" -gt 0 ]; then
    echo ""
    if $IS_DRY_RUN; then
        echo "⚠️  A real release would stop here. Missing:"
    else
        echo "❌ Can't release yet. Missing:"
    fi
    for missing_prerequisite in "${MISSING_PREREQUISITES[@]}"; do
        echo "   • ${missing_prerequisite}"
    done
    echo ""
    $IS_DRY_RUN || exit 1
else
    echo "   ✅ All prerequisites found (signing as: ${DEVELOPER_ID_IDENTITY})"
fi

# ── Pick the version from the latest GitHub Release ─────────────────────────
# Release titles are "Wisp v1.5 (build 6)", so the build number is read back
# from the latest title. If it can't be read, the number of releases so far is
# used instead, which matches for releases made by this script.

echo "🔍 Checking latest release on GitHub..."

LATEST_TAG=""
LATEST_TITLE=""
if $IS_GITHUB_CLI_READY; then
    LATEST_TAG=$(gh release view --repo "${GITHUB_REPO}" --json tagName --jq '.tagName' 2>/dev/null || echo "")
    LATEST_TITLE=$(gh release view --repo "${GITHUB_REPO}" --json name --jq '.name' 2>/dev/null || echo "")
fi

if [ -n "$LATEST_TAG" ]; then
    LATEST_VERSION="${LATEST_TAG#v}"
    if [[ "$LATEST_TITLE" =~ \(build\ ([0-9]+)\) ]]; then
        LATEST_BUILD="${BASH_REMATCH[1]}"
    else
        LATEST_BUILD=$(gh release list --repo "${GITHUB_REPO}" --limit 1000 --json tagName --jq 'length' 2>/dev/null || echo "0")
    fi
    echo "   Latest release: ${LATEST_TAG} (build ${LATEST_BUILD})"
else
    LATEST_VERSION=""
    LATEST_BUILD=0
    if $IS_GITHUB_CLI_READY; then
        echo "   No previous releases found — this will be the first"
    else
        echo "   (gh unavailable — assuming no previous releases)"
    fi
fi

# Next marketing version: bump the minor, carrying into the major at 10
# (1.5 → 1.6, 1.9 → 2.0, 1.4.2 → 1.5). The first release is 1.0, matching
# MARKETING_VERSION in the Xcode project.
if [ -n "$REQUESTED_MARKETING_VERSION" ]; then
    MARKETING_VERSION="$REQUESTED_MARKETING_VERSION"
elif [ -z "$LATEST_VERSION" ]; then
    MARKETING_VERSION="1.0"
elif [[ "$LATEST_VERSION" =~ ^([0-9]+)\.([0-9]+) ]]; then
    MAJOR_VERSION="${BASH_REMATCH[1]}"
    NEXT_MINOR_VERSION=$((10#${BASH_REMATCH[2]} + 1))
    if [ "$NEXT_MINOR_VERSION" -ge 10 ]; then
        MAJOR_VERSION=$((MAJOR_VERSION + 1))
        NEXT_MINOR_VERSION=0
    fi
    MARKETING_VERSION="${MAJOR_VERSION}.${NEXT_MINOR_VERSION}"
else
    echo "❌ Can't work out the next version from the latest tag '${LATEST_TAG}'."
    echo "   Pass one explicitly: ./scripts/release.sh 1.2"
    exit 1
fi

BUILD_NUMBER="${REQUESTED_BUILD_NUMBER:-$((LATEST_BUILD + 1))}"
TAG="v${MARKETING_VERSION}"
RELEASE_TITLE="${APP_NAME} ${TAG} (build ${BUILD_NUMBER})"
DMG_FILENAME="${APP_NAME}.dmg"
DMG_PATH="${DMG_OUTPUT_DIR}/${DMG_FILENAME}"

# ── Safety checks ────────────────────────────────────────────────────────────

# Check if this tag already exists on GitHub to prevent accidental duplicates
if $IS_GITHUB_CLI_READY && gh release view "${TAG}" --repo "${GITHUB_REPO}" &>/dev/null; then
    echo ""
    echo "❌ Release ${TAG} already exists on GitHub!"
    echo "   https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
    echo ""
    echo "   To release a new version, either:"
    echo "     • Run without arguments to auto-bump: ./scripts/release.sh"
    echo "     • Specify a higher version: ./scripts/release.sh <version>"
    echo "     • Delete the existing release first: gh release delete ${TAG} --repo ${GITHUB_REPO} --cleanup-tag --yes"
    exit 1
fi

echo ""
if $IS_DRY_RUN; then
    echo "🧪 DRY RUN — nothing will be built, notarized or published"
fi
echo "🚀 Releasing ${APP_NAME} v${MARKETING_VERSION} (build ${BUILD_NUMBER})"
echo "   Previous: ${LATEST_TAG:-none}"
echo "   Commit:   ${RELEASE_COMMIT_SHA:0:7} — $(git -C "$PROJECT_DIR" log -1 --format=%s)"
echo ""

# Confirm with the user before proceeding
if ! $IS_DRY_RUN; then
    read -p "   Proceed? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "   Aborted."
        exit 0
    fi
    echo ""
fi

# ── Step 1: Clean build directory ────────────────────────────────────────────
# build/ is gitignored and holds only this script's output.

echo "🧹 Cleaning build directory..."
run_step_command rm -rf "${BUILD_DIR}"
run_step_command mkdir -p "${BUILD_DIR}" "${EXPORT_DIR}" "${DMG_OUTPUT_DIR}" "${LOG_DIR}"

# ── Step 2: Archive ──────────────────────────────────────────────────────────
# -derivedDataPath keeps every intermediate inside build/, away from the
# DerivedData that Xcode and scripts/install.sh use for your dev copy. See the
# TCC note at the top for what this does and doesn't affect.

echo "📦 Archiving (Release configuration)..."
run_logged_step_command "${LOG_DIR}/archive.log" \
    xcodebuild archive \
    -project "${PROJECT_FILE}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${ARCHIVE_PATH}" \
    -derivedDataPath "${DERIVED_DATA_DIR}" \
    MARKETING_VERSION="${MARKETING_VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}"
echo "✅ Archive created"

# ── Step 3: Export a Developer ID–signed app ─────────────────────────────────
# `destination: export` signs the app with Developer ID for distribution
# outside the App Store. It does not notarize — that happens to the DMG in
# step 5, and notarizing the DMG covers the app inside it.

echo "📝 Writing export options..."
if $IS_DRY_RUN; then
    echo "   would write: ${EXPORT_OPTIONS_PLIST} (method developer-id, team ${DEVELOPMENT_TEAM_ID})"
else
    cat > "${EXPORT_OPTIONS_PLIST}" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>${DEVELOPMENT_TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST
fi

echo "📤 Exporting signed app..."
run_logged_step_command "${LOG_DIR}/export.log" \
    xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}"

EXPORTED_APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"
echo "🔍 Verifying the app's signature..."
run_step_command codesign --verify --deep --strict "${EXPORTED_APP_PATH}"
if ! $IS_DRY_RUN; then
    EXPORTED_BUNDLE_IDENTIFIER=$(defaults read "${EXPORTED_APP_PATH}/Contents/Info" CFBundleIdentifier)
    if [ "$EXPORTED_BUNDLE_IDENTIFIER" != "$BUNDLE_IDENTIFIER" ]; then
        echo "❌ Exported app has bundle id ${EXPORTED_BUNDLE_IDENTIFIER}, expected ${BUNDLE_IDENTIFIER}"
        exit 1
    fi
    if ! codesign -dv "${EXPORTED_APP_PATH}" 2>&1 | grep -q "Authority=Developer ID Application"; then
        echo "❌ Exported app isn't signed with Developer ID:"
        codesign -dv "${EXPORTED_APP_PATH}" 2>&1 | grep Authority | sed 's/^/   /'
        exit 1
    fi
fi
echo "✅ Export complete (Developer ID signed)"

# ── Step 4: Create DMG ──────────────────────────────────────────────────────
# Window and icon positions match dmg-background.png (660×400): the app on the
# left, the Applications drop link on the right.

echo "💿 Creating DMG..."
run_logged_step_command "${LOG_DIR}/create-dmg.log" \
    create-dmg \
    --volname "${APP_NAME}" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 100 \
    --icon "${APP_NAME}.app" 160 195 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 500 195 \
    --background "${DMG_BACKGROUND}" \
    "${DMG_PATH}" \
    "${EXPORTED_APP_PATH}"

# Sign the DMG itself too, so Gatekeeper can check who made the container
# as well as the app inside it.
run_step_command codesign --sign "${DEVELOPER_ID_IDENTITY:-Developer ID Application}" --timestamp "${DMG_PATH}"
echo "✅ DMG created: ${DMG_PATH}"

# ── Step 5: Notarize + staple the DMG ────────────────────────────────────────
# Apple scans the DMG and everything in it. Stapling attaches the ticket to
# the DMG so Gatekeeper can verify it without a network round trip.

echo "🔏 Notarizing DMG with Apple (this may take a few minutes)..."
run_step_command xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" \
    --wait

echo "📎 Stapling notarization ticket to DMG..."
run_step_command xcrun stapler staple "${DMG_PATH}"
run_step_command xcrun stapler validate "${DMG_PATH}"
run_step_command spctl --assess --type open --context context:primary-signature --verbose "${DMG_PATH}"
echo "✅ DMG notarized and stapled"

# ── Step 6: Create GitHub Release ────────────────────────────────────────────
# The tag is created on the commit that was built. Notes are generated by
# GitHub from the merged PRs since the previous release.

echo "🏷️  Creating GitHub Release ${TAG}..."
run_step_command gh release create "${TAG}" "${DMG_PATH}" \
    --repo "${GITHUB_REPO}" \
    --target "${RELEASE_COMMIT_SHA}" \
    --title "${RELEASE_TITLE}" \
    --generate-notes \
    --latest

echo ""
echo "═══════════════════════════════════════════════════════════════"
if $IS_DRY_RUN; then
    echo "🧪 Dry run complete — v${MARKETING_VERSION} (build ${BUILD_NUMBER}) was not released."
else
    echo "✅ Release v${MARKETING_VERSION} (build ${BUILD_NUMBER}) complete!"
fi
echo ""
echo "   DMG:      ${DMG_PATH}"
echo "   Release:  https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
echo ""
echo "   Download URL (always latest):"
echo "   https://github.com/${GITHUB_REPO}/releases/latest/download/${DMG_FILENAME}"
echo ""
echo "   Testing the release copy on this Mac? Afterwards, put your dev copy"
echo "   back with ./scripts/install.sh (see the TCC note in this script)."
echo "═══════════════════════════════════════════════════════════════"
