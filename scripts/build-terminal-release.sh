#!/bin/bash
#
# Builds Wisp.zip + Wisp.zip.sha256 for the terminal installer (site/install.sh).
# No Apple Developer account needed: the app is signed with a self-signed certificate
# ("Wisp Release", made once by scripts/make-signing-identity.sh) so that macOS permissions
# (microphone, screen recording, accessibility) survive updates.
#
#   scripts/build-terminal-release.sh                 build into ./build/terminal-release
#   scripts/build-terminal-release.sh --publish v0.1  also create the GitHub Release v0.1
#
# Also builds Wisp.dmg (drag-to-Applications window; uses create-dmg if installed, else hdiutil).
# The dmg is self-signed, not notarized: opened from a browser download, macOS asks the user to approve it
# once (right-click > Open, or System Settings > Privacy & Security > Open Anyway).
#
# Options:
#   --version X.Y    marketing version (default: read from the project)
#   --identity NAME  signing identity (default: "Wisp Release")
#   --publish TAG    upload to a GitHub Release named TAG (asks first)
#
# Publishing requires a clean working tree on main that is pushed, so the release matches the code.
# Never run xcodebuild by hand for day-to-day work (it resets permissions); this script is the one
# deliberate exception, and it builds into its own folder, not the copy you run.

set -euo pipefail

REPOSITORY="anaylab/wisp"
SCHEME="leanring-buddy"          # the legacy spelling is intentional
PROJECT="leanring-buddy.xcodeproj"
IDENTITY="Wisp Release"
OUT_DIR="build/terminal-release"
marketing_version=""
publish_tag=""

while [ $# -gt 0 ]; do
    case "$1" in
        --version) shift; marketing_version="${1:?--version needs a value}" ;;
        --identity) shift; IDENTITY="${1:?--identity needs a value}" ;;
        --publish) shift; publish_tag="${1:?--publish needs a tag, e.g. v0.1}" ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

cd "$(dirname "$0")/.."

if ! security find-identity -v -p codesigning | grep -q "\"${IDENTITY}\""; then
    echo "No code-signing identity named \"${IDENTITY}\" in your keychain." >&2
    echo "Run scripts/make-signing-identity.sh once, or pass --identity." >&2
    exit 1
fi

if [ -n "$publish_tag" ]; then
    branch="$(git rev-parse --abbrev-ref HEAD)"
    [ "$branch" = "main" ] || { echo "Publish from main (you are on $branch)." >&2; exit 1; }
    [ -z "$(git status --porcelain)" ] || { echo "Working tree isn't clean; commit or stash first." >&2; exit 1; }
    git fetch -q origin main
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main isn't in sync with origin/main." >&2; exit 1; }
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
archive_path="${OUT_DIR}/Wisp.xcarchive"

version_arguments=()
if [ -n "$marketing_version" ]; then
    version_arguments+=("MARKETING_VERSION=${marketing_version}")
fi

echo "==> Archiving (Release)"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$archive_path" \
    -derivedDataPath "${OUT_DIR}/DerivedData" \
    ${version_arguments[@]+"${version_arguments[@]}"} \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="" \
    OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
    > "${OUT_DIR}/archive.log" 2>&1 || { grep -E "error:" "${OUT_DIR}/archive.log" | sort -u | head; echo "Archive failed; full log: ${OUT_DIR}/archive.log" >&2; exit 1; }

app_path="$(pwd)/${archive_path}/Products/Applications/Wisp.app"
[ -d "$app_path" ] || { echo "The archive has no Wisp.app at $app_path" >&2; exit 1; }

echo "==> Checking the signature"
codesign --verify --deep --strict "$app_path"
bundle_id="$(defaults read "${app_path}/Contents/Info" CFBundleIdentifier)"
[ "$bundle_id" = "com.gluepixel.wisp" ] || { echo "Unexpected bundle id: $bundle_id" >&2; exit 1; }
version="$(defaults read "${app_path}/Contents/Info" CFBundleShortVersionString)"
codesign -dr - "$app_path" 2>&1 | grep designated || true

echo "==> Zipping Wisp ${version}"
zip_path="$(pwd)/${OUT_DIR}/Wisp.zip"
( cd "${archive_path}/Products/Applications" && ditto -c -k --keepParent Wisp.app "$zip_path" )
( cd "$OUT_DIR" && shasum -a 256 Wisp.zip > Wisp.zip.sha256 && cat Wisp.zip.sha256 )

echo "==> Building Wisp.dmg"
dmg_path="$(pwd)/${OUT_DIR}/Wisp.dmg"
dmg_source="${OUT_DIR}/dmg-source"
mkdir -p "$dmg_source"
ditto "$app_path" "${dmg_source}/Wisp.app"
if command -v create-dmg >/dev/null 2>&1; then
    # Window and icon positions match dmg-background.png (660x400), as in scripts/release.sh.
    create-dmg --volname "Wisp" --window-pos 200 120 --window-size 660 400 --icon-size 100 \
        --icon "Wisp.app" 160 195 --hide-extension "Wisp.app" --app-drop-link 500 195 \
        --background "dmg-background.png" "$dmg_path" "$dmg_source" >/dev/null
else
    echo "(create-dmg not installed; making a plain dmg. brew install create-dmg for the styled window.)"
    ln -s /Applications "${dmg_source}/Applications"
    hdiutil create -quiet -volname "Wisp" -srcfolder "$dmg_source" -ov -format UDZO "$dmg_path"
fi
codesign --sign "$IDENTITY" "$dmg_path"
rm -rf "$dmg_source"
( cd "$OUT_DIR" && shasum -a 256 Wisp.dmg > Wisp.dmg.sha256 && cat Wisp.dmg.sha256 )

echo
echo "Built ${OUT_DIR}/Wisp.zip ($(du -h "${OUT_DIR}/Wisp.zip" | cut -f1)), version ${version}."

if [ -n "$publish_tag" ]; then
    printf 'Create GitHub Release %s on %s with the zip, dmg and checksums? [y/N] ' "$publish_tag" "$REPOSITORY"
    read -r answer
    case "$answer" in y|Y|yes) ;; *) echo "Not published."; exit 0 ;; esac
    gh release create "$publish_tag" \
        --repo "$REPOSITORY" \
        --title "Wisp ${version}" \
        --notes "Install: \`curl -fsSL https://anaylab.github.io/wisp/install.sh | bash\`" \
        "${OUT_DIR}/Wisp.zip" "${OUT_DIR}/Wisp.zip.sha256" "${OUT_DIR}/Wisp.dmg" "${OUT_DIR}/Wisp.dmg.sha256"
fi
