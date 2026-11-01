#!/bin/bash
#
# Installs the built Wisp.app into /Applications.
#
# Build in Xcode first (Cmd+B). This only copies the result, deliberately:
# running xcodebuild from a terminal re-signs the bundle and resets its TCC
# grants, which means re-granting Accessibility, Screen Recording, Microphone
# and Speech by hand every time. Copying an already-signed bundle keeps them,
# because TCC keys on the designated requirement — bundle id plus signing
# certificate — and neither changes when the app moves.
#
set -euo pipefail

APP_NAME="Wisp.app"
DESTINATION="/Applications/$APP_NAME"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$REPO_ROOT/leanring-buddy.xcodeproj"

# Several DerivedData folders can hold a Wisp.app (agent worktrees each get their own), so pick
# the one whose recorded workspace is THIS checkout rather than just the newest file. update.sh
# passes the exact bundle through WISP_SOURCE_APP.
DERIVED_DATA_APP="${WISP_SOURCE_APP:-}"
if [[ -z "$DERIVED_DATA_APP" ]]; then
    for derived_data_folder in $(ls -td ~/Library/Developer/Xcode/DerivedData/leanring-buddy-*/ 2>/dev/null); do
        recorded_workspace=$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$derived_data_folder/info.plist" 2>/dev/null || true)
        candidate=$(ls -td "$derived_data_folder"Build/Products/*/"$APP_NAME" 2>/dev/null | head -1 || true)
        if [[ "$recorded_workspace" == "$PROJECT_PATH" && -n "$candidate" ]]; then
            DERIVED_DATA_APP="$candidate"
            break
        fi
    done
fi

if [[ -z "$DERIVED_DATA_APP" || ! -d "$DERIVED_DATA_APP" ]]; then
    echo "error: no built $APP_NAME found."
    echo "       Open leanring-buddy.xcodeproj and build once (Cmd+B), then re-run this."
    exit 1
fi

echo "  source: $DERIVED_DATA_APP"

# Quit the running copy first. Overwriting a bundle while its executable is
# mapped gives you a half-replaced app that launches into undefined behaviour.
if pgrep -f "$APP_NAME/Contents/MacOS/Wisp" >/dev/null 2>&1; then
    echo "  quitting the running copy"
    osascript -e 'quit app "Wisp"' >/dev/null 2>&1 || true
    sleep 1
    pkill -f "$APP_NAME/Contents/MacOS/Wisp" 2>/dev/null || true
    sleep 1
fi

echo "  installing to $DESTINATION"
rm -rf "$DESTINATION"
cp -R "$DERIVED_DATA_APP" "$DESTINATION"

# Re-register with LaunchServices so Spotlight and Launchpad see it immediately
# rather than whenever they next happen to rescan.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DESTINATION" 2>/dev/null || true

echo ""
echo "  signature:"
codesign -dv "$DESTINATION" 2>&1 | grep -E "Identifier|Authority=Apple Dev" | sed 's/^/    /'

echo ""
echo "installed. open it with:  open -a Wisp"
