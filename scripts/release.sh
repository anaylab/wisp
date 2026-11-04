#!/bin/bash
#
# release.sh — build, notarize and publish a Wisp release.
#
#   ./scripts/release.sh                 bump automatically: 0.5 → 0.6, build 6 → 7
#   ./scripts/release.sh 1.0             set the version, bump the build
#   ./scripts/release.sh 1.0 10          set both
#   ./scripts/release.sh --notes FILE    use FILE (Markdown) as the release notes
#   ./scripts/release.sh --draft         stop at a draft GitHub Release: nobody is
#                                        offered it until you publish it yourself
#   ./scripts/release.sh --dry-run [...] run the checks and print every step
#                                        without building, notarizing or publishing
#
# Order of work:
#   1. choose the version and build number from the latest GitHub Release
#   2. check every prerequisite up front
#   3. archive the app into build/ (its own DerivedData), with the update key in it
#   4. export a Developer ID–signed Wisp.app
#   5. notarize and staple the app
#   6. wrap it in a drag-to-Applications DMG, sign, notarize and staple that
#   7. zip the app as the update, and write and sign the update feed (appcast.xml)
#   8. create a draft GitHub Release with the DMG, the zip and the feed attached
#   9. after one more confirmation, publish it
#
# Automatic updates: installed copies read
#   https://github.com/anaylab/wisp/releases/latest/download/appcast.xml
# so the feed is an asset of the latest release. Publishing the draft is the one
# moment a release and its feed both go live, and until then nobody is offered it.
#
# One-time setup is described in scripts/README.md: Xcode with a "Developer ID
# Application" certificate for the team below, `brew install create-dmg gh`,
# `gh auth login`, a notarytool keychain profile (named AC_PASSWORD unless
# WISP_NOTARY_PROFILE says otherwise), and an update signing key in your Keychain
# whose public half is in scripts/sparkle-public-key.txt.
#
# Does releasing reset the permissions of your dev copy? No, but trying the
# release copy does. The archive goes to build/DerivedData and build/export, never
# to Xcode's DerivedData or /Applications/Wisp.app, and building doesn't touch the
# TCC database. TCC does key each grant to the app's designated requirement,
# though. scripts/install.sh installs a copy signed "Apple Development"; the
# release is signed "Developer ID Application", a different requirement for the
# same bundle id (com.gluepixel.wisp). Opening the release copy on this Mac makes
# macOS ask again, and granting re-points the entries at the Developer ID
# signature, so the dev copy stops matching. After testing a release locally,
# reinstall the dev copy with scripts/install.sh and grant permissions once more.

set -euo pipefail

# Non-interactive shells often lack Homebrew on PATH, and create-dmg and gh live there.
export PATH="/opt/homebrew/bin:$PATH"

# ── Settings ─────────────────────────────────────────────────────────────────

readonly XCODE_SCHEME="leanring-buddy"
readonly APP_NAME="Wisp"
readonly EXPECTED_BUNDLE_ID="com.gluepixel.wisp"
readonly SIGNING_TEAM_ID="W2H2SA2F98"
readonly GITHUB_REPOSITORY="anaylab/wisp"
readonly NOTARY_PROFILE="${WISP_NOTARY_PROFILE:-AC_PASSWORD}"
readonly WEBSITE_URL="https://anaylab.github.io/wisp/"
# The Keychain entry of the update signing key. Named for Wisp rather than left at Sparkle's shared
# default, so another Sparkle app on this Mac can't be confused with it.
readonly UPDATE_KEY_ACCOUNT="com.gluepixel.wisp"

readonly REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly XCODE_PROJECT="${REPO_ROOT}/leanring-buddy.xcodeproj"
readonly OUT_DIR="${REPO_ROOT}/build"
readonly DERIVED_DATA="${OUT_DIR}/DerivedData"
readonly ARCHIVE_FILE="${OUT_DIR}/${APP_NAME}.xcarchive"
readonly EXPORT_FOLDER="${OUT_DIR}/export"
readonly EXPORT_OPTIONS_FILE="${OUT_DIR}/ExportOptions.plist"
readonly DMG_FOLDER="${OUT_DIR}/dmg"
readonly LOG_FOLDER="${OUT_DIR}/logs"
readonly DMG_BACKGROUND_IMAGE="${REPO_ROOT}/dmg-background.png"
readonly DMG_NAME="${APP_NAME}.dmg"
readonly DMG_FILE="${DMG_FOLDER}/${DMG_NAME}"
readonly EXPORTED_APP="${EXPORT_FOLDER}/${APP_NAME}.app"
readonly NOTARIZATION_ZIP="${OUT_DIR}/${APP_NAME}-for-notarization.zip"
readonly UPDATE_FOLDER="${OUT_DIR}/update"
readonly UPDATE_FEED_FILE="${UPDATE_FOLDER}/appcast.xml"
readonly UPDATE_PUBLIC_KEY_FILE="${REPO_ROOT}/scripts/sparkle-public-key.txt"
# Where the archive's own package checkout leaves Sparkle's tools, at the exact version it builds with.
readonly BUILT_SPARKLE_TOOLS="${DERIVED_DATA}/SourcePackages/artifacts/sparkle/Sparkle/bin"

dry_run=false
stop_at_draft=false
requested_version=""
requested_build=""
requested_notes_file=""

# Filled in as the script learns them.
missing_prerequisites=()
github_ready=false
signing_identity=""
latest_tag=""
latest_title=""
latest_version=""
latest_build=0
new_version=""
new_build=""
release_tag=""
release_title=""
release_commit=""
update_public_key=""
update_zip_file=""
release_notes_file=""

# ── Small helpers ────────────────────────────────────────────────────────────

fail() {
    echo "❌ $*" >&2
    exit 1
}

# Runs a command; with --dry-run, prints it in a copy-pasteable form instead.
do_or_print() {
    if $dry_run; then
        printf '   would run:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# Runs a noisy command with its output in a log file. A failure shows the end of
# that log, which piping straight into `tail` would have hidden.
do_or_print_logged() {
    local log_file="$1"
    shift

    if $dry_run; then
        do_or_print "$@"
        echo "              (output → ${log_file})"
        return
    fi

    if ! "$@" >"$log_file" 2>&1; then
        echo "❌ Failed. Last lines of ${log_file}:"
        tail -25 "$log_file" | sed 's/^/   /'
        exit 1
    fi
}

# ── Arguments ────────────────────────────────────────────────────────────────

parse_arguments() {
    local positional=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run)
                dry_run=true
                ;;
            --draft)
                stop_at_draft=true
                ;;
            --notes)
                [ "$#" -ge 2 ] || fail "--notes needs a file"
                requested_notes_file="$2"
                [ -f "$requested_notes_file" ] || fail "Release notes file not found: ${requested_notes_file}"
                shift
                ;;
            -h|--help)
                sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
                exit 0
                ;;
            -*)
                fail "Unknown option: ${1} (try --help)"
                ;;
            *)
                positional+=("$1")
                ;;
        esac
        shift
    done

    [ "${#positional[@]}" -le 2 ] \
        || fail "Too many arguments. Usage: ./scripts/release.sh [--dry-run] [--draft] [--notes FILE] [version] [build]"

    requested_version="${positional[0]:-}"
    requested_build="${positional[1]:-}"

    if [ -n "$requested_version" ] && [[ ! "$requested_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        fail "Version must look like 1.2 or 1.2.3 (got '${requested_version}')"
    fi
    if [ -n "$requested_build" ] && [[ ! "$requested_build" =~ ^[0-9]+$ ]]; then
        fail "Build number must be a whole number (got '${requested_build}')"
    fi
}

# ── Prerequisites ────────────────────────────────────────────────────────────
# Everything that is missing is gathered and reported together, so a single run
# shows the whole remaining setup. Under --dry-run they are reported and the run
# carries on.

note_missing() {
    missing_prerequisites+=("$1")
}

check_prerequisites() {
    echo "🔎 Checking prerequisites..."

    command -v xcodebuild >/dev/null 2>&1 \
        || note_missing "xcodebuild not found — install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"

    command -v create-dmg >/dev/null 2>&1 \
        || note_missing "create-dmg not found — install it with: brew install create-dmg"

    if ! command -v gh >/dev/null 2>&1; then
        note_missing "gh (GitHub CLI) not found — install it with: brew install gh"
    elif ! gh auth status >/dev/null 2>&1; then
        note_missing "gh is not signed in — run: gh auth login"
    else
        github_ready=true
    fi

    # Xcode's export chooses the certificate itself. Looking for one here only
    # avoids learning it is absent ten minutes into the export.
    signing_identity=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | grep "(${SIGNING_TEAM_ID})" | head -1 \
        | sed -E 's/^[^"]*"(.*)"$/\1/' || true)
    [ -n "$signing_identity" ] \
        || note_missing "No \"Developer ID Application\" identity for team ${SIGNING_TEAM_ID} in your keychain — add one in Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application"

    # `notarytool history` is the cheapest call that really authenticates with
    # the stored profile, so a misspelled profile or an expired app-specific
    # password surfaces now rather than after the build.
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || note_missing "notarytool keychain profile \"${NOTARY_PROFILE}\" is missing or can't sign in — run: xcrun notarytool store-credentials \"${NOTARY_PROFILE}\" --apple-id YOUR_APPLE_ID --team-id ${SIGNING_TEAM_ID}"

    check_update_signing_key

    [ -f "$DMG_BACKGROUND_IMAGE" ] \
        || note_missing "DMG background not found at ${DMG_BACKGROUND_IMAGE}"

    # The tag lands on the exact commit that gets built, so that commit must be
    # on GitHub and nothing uncommitted may leak into the build.
    release_commit=$(git -C "$REPO_ROOT" rev-parse HEAD)
    [ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] \
        || note_missing "The working tree has uncommitted changes — commit or stash them so the release matches its tag"
    if $github_ready && ! gh api "repos/${GITHUB_REPOSITORY}/commits/${release_commit}" >/dev/null 2>&1; then
        note_missing "HEAD (${release_commit:0:7}) isn't on github.com/${GITHUB_REPOSITORY} yet — push it first"
    fi

    if [ "${#missing_prerequisites[@]}" -eq 0 ]; then
        echo "   ✅ All prerequisites found (signing as: ${signing_identity})"
        return
    fi

    echo ""
    if $dry_run; then
        echo "⚠️  A real release would stop here. Missing:"
    else
        echo "❌ Can't release yet. Missing:"
    fi
    local item
    for item in "${missing_prerequisites[@]}"; do
        echo "   • ${item}"
    done
    echo ""
    $dry_run || exit 1
}

# The app carries the public key and the feed is signed with the private one. A release built from a
# mismatched pair would leave every copy unable to accept any later update, with no way to fix it from
# here, so this is checked before anything is built.
check_update_signing_key() {
    update_public_key=$(tr -d '[:space:]' <"$UPDATE_PUBLIC_KEY_FILE" 2>/dev/null || true)

    local sparkle_tools
    sparkle_tools=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/leanring-buddy-*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1 || true)
    if [ -z "$sparkle_tools" ]; then
        note_missing "Sparkle's tools not found — build once in Xcode (Cmd+B) so it downloads them"
        return
    fi

    local keychain_public_key
    keychain_public_key=$("${sparkle_tools}/generate_keys" --account "$UPDATE_KEY_ACCOUNT" -p 2>/dev/null || true)
    # With no key, generate_keys prints its error on stdout, so only a real key's shape counts.
    if [[ ! "$keychain_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        note_missing "No update signing key in your Keychain — run: \"${sparkle_tools}/generate_keys\" --account ${UPDATE_KEY_ACCOUNT}   then put the public key it prints in scripts/sparkle-public-key.txt, commit that, and back up the private key (see scripts/README.md)"
    elif [ -z "$update_public_key" ]; then
        note_missing "scripts/sparkle-public-key.txt is empty — put this public key in it and commit: ${keychain_public_key}"
    elif [ "$keychain_public_key" != "$update_public_key" ]; then
        note_missing "scripts/sparkle-public-key.txt doesn't match the key in your Keychain (${keychain_public_key}). Shipping this would break updates for everyone on Wisp"
    fi
}

# ── Version ──────────────────────────────────────────────────────────────────
# Release titles read "Wisp v1.5 (build 6)", so the previous build number comes
# from the latest title. If that can't be parsed, the count of releases is the
# fallback, which is right for releases this script made.

read_latest_release() {
    echo "🔍 Checking latest release on GitHub..."

    if $github_ready; then
        latest_tag=$(gh release view --repo "$GITHUB_REPOSITORY" --json tagName --jq '.tagName' 2>/dev/null || echo "")
        latest_title=$(gh release view --repo "$GITHUB_REPOSITORY" --json name --jq '.name' 2>/dev/null || echo "")
    fi

    if [ -z "$latest_tag" ]; then
        if $github_ready; then
            echo "   No previous releases found — this will be the first"
        else
            echo "   (gh unavailable — assuming no previous releases)"
        fi
        return
    fi

    latest_version="${latest_tag#v}"
    if [[ "$latest_title" =~ \(build\ ([0-9]+)\) ]]; then
        latest_build="${BASH_REMATCH[1]}"
    else
        latest_build=$(gh release list --repo "$GITHUB_REPOSITORY" --limit 1000 --json tagName --jq 'length' 2>/dev/null || echo "0")
    fi
    echo "   Latest release: ${latest_tag} (build ${latest_build})"
}

# Bumps the minor number and rolls into the next major at 10: 0.5 → 0.6,
# 0.9 → 1.0, 1.4.2 → 1.5. The very first release is 0.1: anything before 1.0 reads
# as the public beta inside the app (WispUpdatePolicy.versionDescription).
choose_version() {
    if [ -n "$requested_version" ]; then
        new_version="$requested_version"
    elif [ -z "$latest_version" ]; then
        new_version="0.1"
    elif [[ "$latest_version" =~ ^([0-9]+)\.([0-9]+) ]]; then
        local major="${BASH_REMATCH[1]}"
        local minor=$((10#${BASH_REMATCH[2]} + 1))
        if [ "$minor" -ge 10 ]; then
            major=$((major + 1))
            minor=0
        fi
        new_version="${major}.${minor}"
    else
        fail "Can't work out the next version from the latest tag '${latest_tag}'. Pass one explicitly: ./scripts/release.sh 1.2"
    fi

    new_build="${requested_build:-$((latest_build + 1))}"
    release_tag="v${new_version}"
    release_title="${APP_NAME} ${release_tag} (build ${new_build})"
}

refuse_duplicate_release() {
    $github_ready || return 0
    gh release view "$release_tag" --repo "$GITHUB_REPOSITORY" &>/dev/null || return 0

    echo ""
    echo "❌ Release ${release_tag} already exists on GitHub!"
    echo "   https://github.com/${GITHUB_REPOSITORY}/releases/tag/${release_tag}"
    echo ""
    echo "   Either:"
    echo "     • run with no arguments to bump automatically: ./scripts/release.sh"
    echo "     • give a higher version: ./scripts/release.sh <version>"
    echo "     • delete the existing one: gh release delete ${release_tag} --repo ${GITHUB_REPOSITORY} --cleanup-tag --yes"
    exit 1
}

confirm_with_user() {
    echo ""
    $dry_run && echo "🧪 DRY RUN — nothing will be built, notarized or published"
    echo "🚀 Releasing ${APP_NAME} v${new_version} (build ${new_build})"
    echo "   Previous: ${latest_tag:-none}"
    echo "   Commit:   ${release_commit:0:7} — $(git -C "$REPO_ROOT" log -1 --format=%s)"
    $stop_at_draft && echo "   Stops at: a draft release, not published"
    echo ""

    $dry_run && return 0

    local answer
    read -p "   Proceed? (y/N) " -n 1 -r answer
    echo ""
    if [[ ! $answer =~ ^[Yy]$ ]]; then
        echo "   Aborted."
        exit 0
    fi
    echo ""
}

# ── Build stages ─────────────────────────────────────────────────────────────

prepare_build_folder() {
    # build/ is gitignored and holds nothing but this script's output.
    echo "🧹 Cleaning build directory..."
    do_or_print rm -rf "$OUT_DIR"
    do_or_print mkdir -p "$OUT_DIR" "$EXPORT_FOLDER" "$DMG_FOLDER" "$LOG_FOLDER" "$UPDATE_FOLDER"
}

archive_app() {
    # -derivedDataPath keeps every intermediate inside build/, apart from the
    # DerivedData that Xcode and scripts/install.sh use for the dev copy.
    # WISP_SPARKLE_PUBLIC_ED_KEY reaches SUPublicEDKey in Info.plist only here, which is what makes
    # this copy, and no copy built in Xcode, able to update itself (see WispUpdatePolicy).
    # ARCHS: Wisp needs Apple silicon, and the feed then declares that for Sparkle by itself.
    echo "📦 Archiving (Release configuration)..."
    do_or_print_logged "${LOG_FOLDER}/archive.log" \
        xcodebuild archive \
        -project "$XCODE_PROJECT" \
        -scheme "$XCODE_SCHEME" \
        -configuration Release \
        -destination "generic/platform=macOS" \
        ARCHS=arm64 \
        -archivePath "$ARCHIVE_FILE" \
        -derivedDataPath "$DERIVED_DATA" \
        -allowProvisioningUpdates \
        MARKETING_VERSION="$new_version" \
        CURRENT_PROJECT_VERSION="$new_build" \
        WISP_SPARKLE_PUBLIC_ED_KEY="$update_public_key"
    echo "✅ Archive created"
}

write_export_options() {
    echo "📝 Writing export options..."

    if $dry_run; then
        echo "   would write: ${EXPORT_OPTIONS_FILE} (method developer-id, team ${SIGNING_TEAM_ID})"
        return
    fi

    cat >"$EXPORT_OPTIONS_FILE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>${SIGNING_TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST
}

export_signed_app() {
    # Exporting with Developer ID signs the app for distribution outside the
    # App Store. Notarization is done on the DMG afterwards, which covers the
    # app inside it.
    write_export_options

    echo "📤 Exporting signed app..."
    do_or_print_logged "${LOG_FOLDER}/export.log" \
        xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_FILE" \
        -exportPath "$EXPORT_FOLDER" \
        -exportOptionsPlist "$EXPORT_OPTIONS_FILE" \
        -allowProvisioningUpdates

    echo "🔍 Verifying the app's signature..."
    do_or_print codesign --verify --deep --strict "$EXPORTED_APP"

    if ! $dry_run; then
        local bundle_id
        bundle_id=$(defaults read "${EXPORTED_APP}/Contents/Info" CFBundleIdentifier)
        if [ "$bundle_id" != "$EXPECTED_BUNDLE_ID" ]; then
            fail "Exported app has bundle id ${bundle_id}, expected ${EXPECTED_BUNDLE_ID}"
        fi

        if ! codesign -dv "$EXPORTED_APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
            echo "❌ Exported app isn't signed with Developer ID:"
            codesign -dv "$EXPORTED_APP" 2>&1 | grep Authority | sed 's/^/   /'
            exit 1
        fi

        verify_exported_app_can_update
    fi
    echo "✅ Export complete (Developer ID signed)"
}

# What installed copies will need from this build for the next release to reach them.
verify_exported_app_can_update() {
    local info_plist="${EXPORTED_APP}/Contents/Info"

    [ "$(defaults read "$info_plist" SUPublicEDKey)" = "$update_public_key" ] \
        || fail "Exported app has the wrong SUPublicEDKey: it could never accept an update"
    [ "$(defaults read "$info_plist" CFBundleShortVersionString)" = "$new_version" ] \
        || fail "Exported app's version isn't ${new_version}"
    [ "$(defaults read "$info_plist" CFBundleVersion)" = "$new_build" ] \
        || fail "Exported app's build isn't ${new_build}"

    # Sparkle's helpers run on their own, so each has to carry the same signature as the app.
    local sparkle_framework="${EXPORTED_APP}/Contents/Frameworks/Sparkle.framework"
    [ -d "$sparkle_framework" ] || fail "Sparkle.framework is missing from the exported app"
    local sparkle_helper
    for sparkle_helper in \
        "${sparkle_framework}/Versions/B/Autoupdate" \
        "${sparkle_framework}/Versions/B/Updater.app" \
        "${sparkle_framework}/Versions/B/XPCServices/Installer.xpc"; do
        codesign -dv "$sparkle_helper" 2>&1 | grep -q "Authority=Developer ID Application" \
            || fail "${sparkle_helper} isn't signed with Developer ID"
    done
}

# Submits one file to Apple and waits. notarytool can exit 0 for a rejected submission, so its answer
# is read rather than trusted; a rejection prints the command that says why.
notarize_file() {
    local file_to_notarize="$1"
    local log_file="$2"

    if $dry_run; then
        do_or_print xcrun notarytool submit "$file_to_notarize" --keychain-profile "$NOTARY_PROFILE" --wait
        return
    fi

    xcrun notarytool submit "$file_to_notarize" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$log_file"
    if ! grep -q "status: Accepted" "$log_file"; then
        local submission_id
        submission_id=$(grep -m1 "^  id:" "$log_file" | awk '{print $2}')
        fail "Apple rejected ${file_to_notarize}. To see why: xcrun notarytool log ${submission_id} --keychain-profile ${NOTARY_PROFILE}"
    fi
}

notarize_app() {
    # The DMG's ticket doesn't cover an update, which arrives as a zip of the app alone. So the app
    # gets its own ticket, stapled to it, and the DMG and the update are both made from that copy.
    echo "🔏 Notarizing the app with Apple (this may take a few minutes)..."
    do_or_print ditto -c -k --keepParent "$EXPORTED_APP" "$NOTARIZATION_ZIP"
    notarize_file "$NOTARIZATION_ZIP" "${LOG_FOLDER}/notarize-app.log"

    echo "📎 Stapling notarization ticket to the app..."
    do_or_print xcrun stapler staple "$EXPORTED_APP"
    do_or_print xcrun stapler validate "$EXPORTED_APP"
    do_or_print spctl --assess --type execute --verbose "$EXPORTED_APP"
    do_or_print rm -f "$NOTARIZATION_ZIP"
    echo "✅ App notarized and stapled"
}

build_dmg() {
    # The window and icon coordinates match dmg-background.png (660×400): the
    # app on the left, the Applications link on the right.
    echo "💿 Creating DMG..."
    do_or_print_logged "${LOG_FOLDER}/create-dmg.log" \
        create-dmg \
        --volname "$APP_NAME" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 100 \
        --icon "${APP_NAME}.app" 160 195 \
        --hide-extension "${APP_NAME}.app" \
        --app-drop-link 500 195 \
        --background "$DMG_BACKGROUND_IMAGE" \
        "$DMG_FILE" \
        "$EXPORTED_APP"

    # Signing the container lets Gatekeeper see who made it, not only the app inside.
    do_or_print codesign --sign "${signing_identity:-Developer ID Application}" --timestamp "$DMG_FILE"
    echo "✅ DMG created: ${DMG_FILE}"
}

notarize_dmg() {
    # Stapling attaches the ticket to the DMG so Gatekeeper can verify it without
    # a network round trip.
    echo "🔏 Notarizing DMG with Apple (this may take a few minutes)..."
    notarize_file "$DMG_FILE" "${LOG_FOLDER}/notarize-dmg.log"

    echo "📎 Stapling notarization ticket to DMG..."
    do_or_print xcrun stapler staple "$DMG_FILE"
    do_or_print xcrun stapler validate "$DMG_FILE"
    do_or_print spctl --assess --type open --context context:primary-signature --verbose "$DMG_FILE"
    echo "✅ DMG notarized and stapled"
}

write_release_notes() {
    release_notes_file="${update_zip_file%.zip}.md"

    if $dry_run; then
        echo "   would write release notes: ${release_notes_file}"
    elif [ -n "$requested_notes_file" ]; then
        cp "$requested_notes_file" "$release_notes_file"
    elif [ -z "$latest_tag" ]; then
        # GitHub's generated notes for a first release would list every PR the repo has ever had,
        # and they are shown in the update window.
        echo "The first public beta of Wisp." >"$release_notes_file"
    else
        gh api "repos/${GITHUB_REPOSITORY}/releases/generate-notes" \
            -f tag_name="$release_tag" \
            -f target_commitish="$release_commit" \
            -f previous_tag_name="$latest_tag" \
            --jq '.body' >"$release_notes_file"
    fi
}

build_update() {
    # A zip keeps Sparkle.framework's symlinks only when made with ditto. Sparkle's generate_appcast
    # reads the app inside, signs the zip and the feed with the Keychain key, and embeds the notes in
    # the feed, so the update window shows them without loading a web page.
    echo "📦 Building the update and its feed..."
    update_zip_file="${UPDATE_FOLDER}/${APP_NAME}-${new_version}-${new_build}.zip"
    do_or_print ditto -c -k --keepParent "$EXPORTED_APP" "$update_zip_file"
    write_release_notes

    do_or_print_logged "${LOG_FOLDER}/generate-appcast.log" \
        "${BUILT_SPARKLE_TOOLS}/generate_appcast" \
        --account "$UPDATE_KEY_ACCOUNT" \
        --download-url-prefix "https://github.com/${GITHUB_REPOSITORY}/releases/download/${release_tag}/" \
        --embed-release-notes \
        --link "$WEBSITE_URL" \
        --maximum-deltas 0 \
        "$UPDATE_FOLDER"

    $dry_run || verify_update_feed
    echo "✅ Update ready: ${update_zip_file}"
}

# Reads back what installed copies will read: the right version and address, and a signature that really
# is over this zip by the key the app trusts.
verify_update_feed() {
    local feed_version feed_short_version feed_url feed_signature
    feed_version=$(xmllint --xpath 'string(//item[1]/*[local-name()="version"])' "$UPDATE_FEED_FILE")
    feed_short_version=$(xmllint --xpath 'string(//item[1]/*[local-name()="shortVersionString"])' "$UPDATE_FEED_FILE")
    feed_url=$(xmllint --xpath 'string(//item[1]/enclosure/@url)' "$UPDATE_FEED_FILE")
    feed_signature=$(xmllint --xpath 'string(//item[1]/enclosure/@*[local-name()="edSignature"])' "$UPDATE_FEED_FILE")

    [ "$feed_version" = "$new_build" ] || fail "The feed says build ${feed_version}, expected ${new_build}"
    [ "$feed_short_version" = "$new_version" ] || fail "The feed says version ${feed_short_version}, expected ${new_version}"
    [ "$feed_url" = "https://github.com/${GITHUB_REPOSITORY}/releases/download/${release_tag}/$(basename "$update_zip_file")" ] \
        || fail "The feed points at the wrong download: ${feed_url}"
    [ -n "$feed_signature" ] || fail "The update in the feed has no signature"
    "${BUILT_SPARKLE_TOOLS}/sign_update" --account "$UPDATE_KEY_ACCOUNT" --verify "$update_zip_file" "$feed_signature" >/dev/null \
        || fail "The feed's signature doesn't verify against the zip"
    "${BUILT_SPARKLE_TOOLS}/sign_update" --account "$UPDATE_KEY_ACCOUNT" --verify "$UPDATE_FEED_FILE" >/dev/null \
        || fail "The feed itself isn't signed, and installed copies require that"
}

upload_draft_release() {
    # The draft holds the files, but isn't public and doesn't count as "latest", so nobody is
    # offered it yet. The tag is only created on the built commit when the draft is published.
    echo "🏷️  Creating draft GitHub Release ${release_tag}..."
    do_or_print gh release create "$release_tag" "$DMG_FILE" "$update_zip_file" "$UPDATE_FEED_FILE" \
        --repo "$GITHUB_REPOSITORY" \
        --target "$release_commit" \
        --title "$release_title" \
        --notes-file "$release_notes_file" \
        --draft
}

publish_release() {
    if $stop_at_draft; then
        echo "📝 Left as a draft. To go live: gh release edit ${release_tag} --repo ${GITHUB_REPOSITORY} --draft=false --latest"
        return
    fi

    if ! $dry_run; then
        echo ""
        echo "   Publishing makes ${release_tag} the download for new people, and every installed"
        echo "   copy of Wisp will pick it up within a day. It can't be recalled from those copies."
        local answer
        read -p "   Publish now? (y/N) " -n 1 -r answer
        echo ""
        if [[ ! $answer =~ ^[Yy]$ ]]; then
            stop_at_draft=true
            echo "📝 Left as a draft. To go live: gh release edit ${release_tag} --repo ${GITHUB_REPOSITORY} --draft=false --latest"
            return
        fi
    fi

    echo "🚀 Publishing ${release_tag}..."
    do_or_print gh release edit "$release_tag" --repo "$GITHUB_REPOSITORY" --draft=false --latest
    verify_published_feed
}

# What installed copies will actually fetch.
verify_published_feed() {
    local feed_address="https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/appcast.xml"
    if $dry_run; then
        echo "   would check the feed serves build ${new_build}: ${feed_address}"
        return
    fi
    curl -fsSL "$feed_address" | grep -q "<sparkle:version>${new_build}</sparkle:version>" \
        || echo "⚠️  ${feed_address} isn't serving build ${new_build} yet. Check it before announcing."
}

print_summary() {
    local rule="═══════════════════════════════════════════════════════════════"
    echo ""
    echo "$rule"
    if $dry_run; then
        echo "🧪 Dry run complete — v${new_version} (build ${new_build}) was not released."
    elif $stop_at_draft; then
        echo "📝 v${new_version} (build ${new_build}) is a draft: nobody can see it or update to it yet."
    else
        echo "✅ Release v${new_version} (build ${new_build}) complete!"
    fi
    echo ""
    echo "   DMG:      ${DMG_FILE}"
    echo "   Update:   ${update_zip_file}"
    echo "   Release:  https://github.com/${GITHUB_REPOSITORY}/releases/tag/${release_tag}"
    echo ""
    echo "   Link that always serves the newest build:"
    echo "   https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/${DMG_NAME}"
    echo ""
    echo "   If you try the release copy on this Mac, put your dev copy back afterwards"
    echo "   with ./scripts/install.sh (see the note about TCC at the top of this script)."
    echo "$rule"
}

# ── Run ──────────────────────────────────────────────────────────────────────

main() {
    parse_arguments "$@"
    check_prerequisites
    read_latest_release
    choose_version
    refuse_duplicate_release
    confirm_with_user

    prepare_build_folder
    archive_app
    export_signed_app
    notarize_app
    build_dmg
    notarize_dmg
    build_update
    upload_draft_release
    publish_release
    print_summary
}

main "$@"
