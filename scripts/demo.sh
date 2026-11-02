#!/bin/bash
#
# Run Wisp on sample data, for screenshots and demos. Your own buddies, chats, brain
# and history are never read or changed: demo mode keeps everything in
# ~/Library/Application Support/Wisp Demo/, and nothing runs on its own.
#
#   ./scripts/demo.sh            quit Wisp and reopen it in demo mode
#   ./scripts/demo.sh --reset    the same, starting again from fresh sample data
#   ./scripts/demo.sh --off      quit the demo and reopen Wisp normally
#
set -euo pipefail

APP_PATH="/Applications/Wisp.app"
DEMO_FOLDER="$HOME/Library/Application Support/Wisp Demo"
DEMO_DEFAULTS_SUITE="com.gluepixel.wisp.demo"

should_reset=false
should_turn_off=false
for argument in "$@"; do
    case "$argument" in
        --reset) should_reset=true ;;
        --off) should_turn_off=true ;;
        *) echo "unknown option: $argument"; exit 2 ;;
    esac
done

quit_wisp() {
    osascript -e 'tell application id "com.gluepixel.wisp" to quit' >/dev/null 2>&1 || true
    # Give it a moment to save and exit, since only one copy may run.
    for _ in $(seq 1 20); do
        pgrep -x Wisp >/dev/null || return 0
        sleep 0.5
    done
    echo "error: Wisp didn't quit; quit it from the menu bar and run this again."
    exit 1
}

quit_wisp

if $should_turn_off; then
    open -a "$APP_PATH"
    echo "  Wisp is back on your own data"
    exit 0
fi

if $should_reset; then
    rm -rf "$DEMO_FOLDER"
    defaults delete "$DEMO_DEFAULTS_SUITE" >/dev/null 2>&1 || true
    echo "  cleared the demo data"
fi

open -a "$APP_PATH" --args -WispDemoMode YES
echo "  Wisp is running in demo mode (sample data). ./scripts/demo.sh --off to go back."
