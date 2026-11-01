#!/bin/bash
#
# One command to get the latest Wisp running: build in Xcode, install to /Applications, relaunch.
#
#   ./scripts/update.sh            build (through Xcode), install, relaunch
#   ./scripts/update.sh --no-build install the app you already built, relaunch
#   ./scripts/update.sh --clean    also list stale Wisp builds and delete them after you say yes
#
# The build goes through Xcode's own AppleScript interface, never `xcodebuild`: a terminal build
# re-signs the bundle and resets Accessibility / Screen Recording / Microphone grants.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$REPO_ROOT/leanring-buddy.xcodeproj"
DERIVED_DATA_ROOT="$HOME/Library/Developer/Xcode/DerivedData"

should_build=true
should_clean=false
for argument in "$@"; do
    case "$argument" in
        --no-build) should_build=false ;;
        --clean) should_clean=true ;;
        *) echo "unknown option: $argument"; exit 2 ;;
    esac
done

recorded_workspace_of() {
    /usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$1/info.plist" 2>/dev/null || true
}

if $should_build; then
    echo "  building in Xcode (this can take a few minutes)"
    # Xcode must have this checkout open, or the build would be of some other project.
    open -a Xcode "$PROJECT_PATH"
    sleep 3
    build_status=$(osascript <<APPLESCRIPT
tell application "Xcode"
    set targetDocument to missing value
    -- Xcode can take a while to load the project after being asked to open it.
    repeat 60 times
        repeat with candidateDocument in workspace documents
            if (path of candidateDocument) is "$PROJECT_PATH" then set targetDocument to candidateDocument
        end repeat
        if targetDocument is not missing value then exit repeat
        delay 1
    end repeat
    if targetDocument is missing value then return "not-open"
    set buildResult to build targetDocument
    repeat until completed of buildResult
        delay 2
    end repeat
    return status of buildResult as text
end tell
APPLESCRIPT
    )
    echo "  build status: $build_status"
    if [[ "$build_status" == "not-open" ]]; then
        echo "error: Xcode did not open this project within a minute. Open $PROJECT_PATH in Xcode"
        echo "       (look for a dialog waiting on you), then re-run. Use --no-build to skip the build."
        exit 1
    fi
    if [[ "$build_status" != "succeeded" ]]; then
        echo "error: the build did not succeed; nothing was installed. Open Xcode to see why."
        exit 1
    fi
fi

"$REPO_ROOT/scripts/install.sh"

echo "  relaunching"
sleep 1
open -a /Applications/Wisp.app

if $should_clean; then
    echo ""
    echo "stale Wisp builds (anything not built from this checkout):"
    stale_folders=()
    for derived_data_folder in "$DERIVED_DATA_ROOT"/leanring-buddy-*/; do
        derived_data_folder="${derived_data_folder%/}"
        [[ -d "$derived_data_folder" ]] || continue
        if [[ "$(recorded_workspace_of "$derived_data_folder")" != "$PROJECT_PATH" ]]; then
            stale_folders+=("$derived_data_folder")
            printf "  %s  %s\n" "$(du -sh "$derived_data_folder" | cut -f1)" "$(recorded_workspace_of "$derived_data_folder")"
        fi
    done
    if [[ ${#stale_folders[@]} -eq 0 ]]; then
        echo "  none"
        exit 0
    fi
    read -r -p "delete these ${#stale_folders[@]} folders? [y/N] " answer
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        rm -rf "${stale_folders[@]}"
        echo "  deleted"
    else
        echo "  left alone"
    fi
fi
