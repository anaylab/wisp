#!/bin/bash
#
# Wisp installer for macOS.
#
#   curl -fsSL https://anaylab.github.io/wisp/install.sh | bash
#
# What it does, in order, and nothing else:
#   1. checks this Mac (Apple silicon, macOS 26 or later)
#   2. downloads Wisp.zip and its checksum from the latest GitHub Release of anaylab/wisp
#   3. verifies the checksum and the app's code signature
#   4. quits a running Wisp, then puts Wisp.app in /Applications (replacing an older copy)
#   5. offers to set up the local model (Ollama) if it isn't there
#   6. opens Wisp
#
# It never uses sudo, never edits your shell files, and never touches anything outside
# /Applications/Wisp.app (and, only if you say yes, Ollama and one model). Read it before you run it.
#
# Options:
#   --yes            say yes to the optional steps instead of asking
#   --no-ollama      skip the local-model step
#   --version TAG    install a specific release, e.g. --version v0.1
#   --uninstall      remove Wisp.app (your data stays, and the script tells you where)
#   --help           show this text
#
# Why this isn't a notarized download: notarization needs Apple's paid developer program. Files fetched
# with curl aren't marked "downloaded from the internet", so macOS doesn't block them, and the checksum
# plus the open source code are what you're trusting. A notarized build may come later.

set -eu

REPOSITORY="anaylab/wisp"
APP_NAME="Wisp"
EXPECTED_BUNDLE_ID="com.gluepixel.wisp"
DEFAULT_MODEL="qwen2.5vl:3b"

# These can be overridden for testing; normal use never sets them.
RELEASE_BASE="${WISP_RELEASE_BASE:-https://github.com/${REPOSITORY}/releases/latest/download}"
INSTALL_DIR="${WISP_INSTALL_DIR:-/Applications}"

assume_yes=false
skip_ollama=false
skip_launch="${WISP_SKIP_LAUNCH:-}"
uninstall=false
requested_version=""

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

show_help() {
    sed -n '3,30p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y) assume_yes=true ;;
        --no-ollama) skip_ollama=true ;;
        --version) shift; requested_version="${1:-}"; [ -n "$requested_version" ] || fail "--version needs a release tag, e.g. v0.1" ;;
        --uninstall) uninstall=true ;;
        --help|-h) show_help ;;
        *) fail "unknown option: $1 (try --help)" ;;
    esac
    shift
done

if [ -n "$requested_version" ]; then
    RELEASE_BASE="https://github.com/${REPOSITORY}/releases/download/${requested_version}"
fi

# Questions read from the terminal, not from the script, because the script itself arrives on stdin.
ask_yes_no() {
    local question="$1"
    if $assume_yes; then return 0; fi
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        local answer=""
        printf '%s [Y/n] ' "$question" > /dev/tty
        read -r answer < /dev/tty || answer=""
        case "$answer" in n|N|no|NO|No) return 1 ;; *) return 0 ;; esac
    fi
    return 1   # no terminal to ask on: don't do optional things silently
}

app_is_running() { pgrep -x "$APP_NAME" >/dev/null 2>&1; }

quit_running_app() {
    if app_is_running; then
        say "Wisp is running; asking it to quit..."
        osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            app_is_running || return 0
            sleep 1
        done
        fail "Wisp is still running. Quit it from the menu bar, then run this again."
    fi
}

# ── Uninstall ─────────────────────────────────────────────────────────────────────────────

if $uninstall; then
    step "Removing Wisp"
    quit_running_app
    if [ -d "${INSTALL_DIR}/${APP_NAME}.app" ]; then
        rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
        say "Removed ${INSTALL_DIR}/${APP_NAME}.app"
    else
        say "Nothing to remove: ${INSTALL_DIR}/${APP_NAME}.app isn't there."
    fi
    say ""
    say "Your data was left alone. To delete it too:"
    say "  ~/Library/Application Support/Wisp     buddies, history, files"
    say "  ~/.wisp                                memory, brain, skills, settings"
    say "Permissions (microphone, screen recording, accessibility) can be removed in System Settings → Privacy & Security."
    exit 0
fi

# ── 1. This Mac ───────────────────────────────────────────────────────────────────────────

step "Checking this Mac"
[ "$(uname -s)" = "Darwin" ] || fail "Wisp is a Mac app; this isn't macOS."
[ "$(id -u)" != "0" ] || fail "Don't run this as root or with sudo."
if [ -z "${WISP_SKIP_OS_CHECK:-}" ]; then
    [ "$(uname -m)" = "arm64" ] || fail "Wisp needs an Apple-silicon Mac (M1 or later). This one is $(uname -m)."
    macos_major="$(sw_vers -productVersion | cut -d. -f1)"
    [ "$macos_major" -ge 26 ] 2>/dev/null || fail "Wisp needs macOS 26 or later. This Mac has $(sw_vers -productVersion)."
fi
command -v curl >/dev/null 2>&1 || fail "curl is missing."
command -v ditto >/dev/null 2>&1 || fail "ditto is missing."
say "OK: macOS $(sw_vers -productVersion), $(uname -m)."

# ── 2. Download ───────────────────────────────────────────────────────────────────────────

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/wisp-install.XXXXXX")"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

step "Downloading Wisp"
say "From: ${RELEASE_BASE}"
curl -fL --progress-bar -o "${work_dir}/Wisp.zip" "${RELEASE_BASE}/Wisp.zip" \
    || fail "couldn't download Wisp.zip. Check your connection, and that a release exists: https://github.com/${REPOSITORY}/releases"
curl -fsSL -o "${work_dir}/Wisp.zip.sha256" "${RELEASE_BASE}/Wisp.zip.sha256" \
    || fail "couldn't download the checksum file (Wisp.zip.sha256). Not installing something I can't verify."

# ── 3. Verify ─────────────────────────────────────────────────────────────────────────────

step "Verifying the download"
expected_hash="$(awk '{print $1}' "${work_dir}/Wisp.zip.sha256" | head -1)"
actual_hash="$(shasum -a 256 "${work_dir}/Wisp.zip" | awk '{print $1}')"
if [ -z "$expected_hash" ] || [ "$expected_hash" != "$actual_hash" ]; then
    fail "the checksum doesn't match, so nothing was installed.
  expected: ${expected_hash:-(missing)}
  got:      ${actual_hash}"
fi
say "Checksum OK (${actual_hash})."

mkdir -p "${work_dir}/extracted"
ditto -x -k "${work_dir}/Wisp.zip" "${work_dir}/extracted" || fail "couldn't unpack Wisp.zip."
new_app="${work_dir}/extracted/${APP_NAME}.app"
[ -d "$new_app" ] || fail "the download doesn't contain ${APP_NAME}.app."

bundle_id="$(defaults read "${new_app}/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
[ "$bundle_id" = "$EXPECTED_BUNDLE_ID" ] || fail "the app has bundle id '${bundle_id}', expected '${EXPECTED_BUNDLE_ID}'. Not installing."

codesign --verify --deep --strict "$new_app" 2>/dev/null \
    || fail "the app's code signature is broken, so nothing was installed."
version="$(defaults read "${new_app}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
say "Signature OK. This is Wisp ${version}."

# ── 4. Install ────────────────────────────────────────────────────────────────────────────

step "Installing to ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR" 2>/dev/null || true
[ -w "$INSTALL_DIR" ] || fail "can't write to ${INSTALL_DIR}. Ask an administrator, or set WISP_INSTALL_DIR to a folder you own (for example ~/Applications)."
quit_running_app

destination="${INSTALL_DIR}/${APP_NAME}.app"
previous_copy=""
if [ -d "$destination" ]; then
    previous_copy="${work_dir}/previous-${APP_NAME}.app"
    mv "$destination" "$previous_copy"
fi
if ! ditto "$new_app" "$destination"; then
    rm -rf "$destination"
    [ -n "$previous_copy" ] && mv "$previous_copy" "$destination"
    fail "couldn't copy the app into ${INSTALL_DIR}. Your earlier copy, if you had one, is back in place."
fi
xattr -dr com.apple.quarantine "$destination" 2>/dev/null || true
say "Installed ${destination}"

# ── 5. Local model (optional) ─────────────────────────────────────────────────────────────

if ! $skip_ollama && [ -z "${WISP_SKIP_OLLAMA:-}" ]; then
    step "Local model"
    say "Wisp's default model runs on your Mac through Ollama (about 3 GB). You can instead pick Apple's"
    say "on-device model or your own cloud key later in Settings → Model."
    if command -v ollama >/dev/null 2>&1; then
        say "Ollama is installed."
    elif command -v brew >/dev/null 2>&1 && ask_yes_no "Install Ollama with Homebrew?"; then
        brew install ollama || say "Ollama didn't install. Get it from https://ollama.com/download"
    elif ! command -v ollama >/dev/null 2>&1; then
        say "Get Ollama from https://ollama.com/download, then run:  ollama pull ${DEFAULT_MODEL}"
    fi
    if command -v ollama >/dev/null 2>&1; then
        if ollama list 2>/dev/null | grep -q "${DEFAULT_MODEL}"; then
            say "The model ${DEFAULT_MODEL} is already there."
        elif ask_yes_no "Download the model ${DEFAULT_MODEL} now (about 3 GB)?"; then
            ollama pull "${DEFAULT_MODEL}" || say "Couldn't pull it. Start Ollama (open the app, or 'brew services start ollama'), then run:  ollama pull ${DEFAULT_MODEL}"
        else
            say "Skipped. Later:  ollama pull ${DEFAULT_MODEL}"
        fi
    fi
fi

# ── 6. Done ───────────────────────────────────────────────────────────────────────────────

step "Done"
say "Wisp lives in the menu bar and the notch (there's no Dock icon)."
say "Hold Control + Option and talk. The first time, Wisp opens on Today with a checklist of the"
say "permissions it needs (microphone, speech, screen recording, accessibility). Grant them there."
say ""
say "Update later by running this command again. Remove it with:  curl -fsSL https://anaylab.github.io/wisp/install.sh | bash -s -- --uninstall"
if [ -z "$skip_launch" ]; then
    open "$destination" || say "Open it yourself from ${INSTALL_DIR}."
fi
