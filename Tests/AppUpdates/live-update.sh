#!/bin/bash
#
# A real update, end to end, without a Developer ID certificate or anything public: a tiny app built
# from the real WispUpdater.swift and the real Sparkle goes from build 1 to build 2 through a signed
# feed on localhost, using a throwaway key. It proves the feed format, signature checks, silent
# download, the quiet reminder and install-on-quit.
#
# It doesn't touch Wisp, its permissions or your Keychain, and shows no window. It can't prove what
# only signed builds can: notarization, Gatekeeper, and permissions surviving an update.
#
#   ./Tests/AppUpdates/live-update.sh
#
# Needs Sparkle's download from an Xcode build of this project (Cmd+B once).
#
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO_ROOT="$(pwd)"

SPARKLE_ROOT=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/leanring-buddy-*/SourcePackages/artifacts/sparkle/Sparkle 2>/dev/null | head -1 || true)
[ -n "$SPARKLE_ROOT" ] || { echo "Sparkle not found: build once in Xcode first"; exit 1; }
SPARKLE_FRAMEWORK_PARENT=$(ls -d "$SPARKLE_ROOT"/Sparkle.xcframework/macos-*)
SDK="$(xcrun --show-sdk-path --sdk macosx)"

WORK="$(mktemp -d)"
readonly BUNDLE_ID="com.gluepixel.wisp.update-test"
SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    pkill -f "$WORK/installed/WispUpdateTest.app" 2>/dev/null || true
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/Caches/Sparkle_generate_appcast"
    rm -rf "$WORK"
}
trap cleanup EXIT

# ── A throwaway key, never in the Keychain ───────────────────────────────────
openssl genpkey -algorithm ed25519 -outform DER -out "$WORK/key.der" 2>/dev/null
tail -c 32 "$WORK/key.der" | base64 >"$WORK/private-key.txt"
openssl pkey -inform DER -in "$WORK/key.der" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 >"$WORK/public-key.txt"

# ── The app: real WispUpdater and real rules, with two test-only edits ───────
# http for localhost (the real rule insists on https), and the controller reachable so a check can be
# triggered now rather than in a day.
mkdir -p "$WORK/src"
sed 's/feedURL.scheme == "https"/feedURL.scheme == "http"/' leanring-buddy/Updates/WispUpdatePolicy.swift >"$WORK/src/WispUpdatePolicy.swift"
sed 's/private var updaterController/var updaterController/' leanring-buddy/Updates/WispUpdater.swift >"$WORK/src/WispUpdater.swift"
cat >"$WORK/src/main.swift" <<'SWIFT'
import AppKit
import Sparkle

enum WispDemoMode { static let isOn = false }
final class QuietModeMonitor { @MainActor static let shared = QuietModeMonitor(); let isQuiet = true }

func log(_ text: String) {
    let line = text + "\n"
    let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ProcessInfo.processInfo.environment["WISP_TEST_LOG"] ?? "/dev/null"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    }
}

final class TestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        log("launched build \(build)")
        if build != "1" { NSApp.terminate(nil); return }

        let updater = WispUpdater.shared
        updater.startIfAvailable()
        log("availability \(updater.availability)")
        updater.updaterController?.updater.checkForUpdatesInBackground()

        // Sparkle downloads silently. A later scheduled check on a held update is what surfaces it.
        Task { @MainActor in
            var hasAskedForReminder = false
            for second in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                let staged = FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/Library/Caches/\(Bundle.main.bundleIdentifier!)/org.sparkle-project.Sparkle/Installation")
                if let pending = updater.pendingUpdateVersion {
                    log("pending update \(pending)")
                    log("quitting so it installs")
                    NSApp.terminate(nil)
                    return
                }
                if staged, updater.canCheckForUpdates, !hasAskedForReminder, second > 3 {
                    log("downloaded silently; checking again")
                    hasAskedForReminder = true
                    updater.updaterController?.updater.checkForUpdatesInBackground()
                }
            }
            log("timed out")
            NSApp.terminate(nil)
        }
    }
}

let application = NSApplication.shared
let delegate = TestDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
SWIFT

swiftc -target arm64-apple-macos26.0 -sdk "$SDK" -swift-version 5 -default-isolation MainActor \
  -F "$SPARKLE_FRAMEWORK_PARENT" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$WORK/WispUpdateTest" \
  "$WORK/src/main.swift" "$WORK/src/WispUpdater.swift" "$WORK/src/WispUpdatePolicy.swift" 2>"$WORK/compile.log" \
  || { cat "$WORK/compile.log"; exit 1; }

PORT=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')

make_app() {
    local version="$1" build="$2" destination="$3"
    local app="$destination/WispUpdateTest.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
    cp "$WORK/WispUpdateTest" "$app/Contents/MacOS/WispUpdateTest"
    ditto "$SPARKLE_FRAMEWORK_PARENT/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
    cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>WispUpdateTest</string>
<key>CFBundleExecutable</key><string>WispUpdateTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>LSEnvironment</key><dict><key>WISP_TEST_LOG</key><string>$WORK/log.txt</string></dict>
$(sed -n '/<key>SUFeedURL/,/<key>NSMicrophoneUsageDescription/p' leanring-buddy/Info.plist | sed '$d' \
    | sed "s|https://github.com/anaylab/wisp/releases/latest/download/appcast.xml|http://127.0.0.1:$PORT/appcast.xml|" \
    | sed "s|\$(WISP_SPARKLE_PUBLIC_ED_KEY)|$(cat "$WORK/public-key.txt")|")
</dict></plist>
PLIST
    codesign --force --deep --sign - "$app" 2>/dev/null
}

make_app 0.1 1 "$WORK/installed"
mkdir -p "$WORK/next" "$WORK/feed"
make_app 0.2 2 "$WORK/next"
ditto -c -k --keepParent "$WORK/next/WispUpdateTest.app" "$WORK/feed/WispUpdateTest-0.2-2.zip"
echo "Test **notes** for 0.2." >"$WORK/feed/WispUpdateTest-0.2-2.md"

# ── The feed, generated the way release.sh generates it ──────────────────────
"$SPARKLE_ROOT/bin/generate_appcast" \
  --ed-key-file "$WORK/private-key.txt" \
  --download-url-prefix "http://127.0.0.1:$PORT/" \
  --embed-release-notes --link "https://example.com/" --maximum-deltas 0 \
  "$WORK/feed" >"$WORK/generate.log" 2>&1 || { cat "$WORK/generate.log"; exit 1; }

echo "── feed ──"
grep -E "sparkle:(version|shortVersionString|signature)|edSignature|<enclosure|Test|<!-- " "$WORK/feed/appcast.xml" | sed 's/^ */   /' | cut -c1-160

# The same read-back release.sh's verify_update_feed does.
feed_signature=$(xmllint --xpath 'string(//item[1]/enclosure/@*[local-name()="edSignature"])' "$WORK/feed/appcast.xml")
[ -n "$feed_signature" ] || { echo "FAIL: no signature on the update"; exit 1; }
[ "$(xmllint --xpath 'string(//item[1]/*[local-name()="version"])' "$WORK/feed/appcast.xml")" = "2" ] || { echo "FAIL: feed version"; exit 1; }
"$SPARKLE_ROOT/bin/sign_update" --ed-key-file "$WORK/private-key.txt" --verify "$WORK/feed/WispUpdateTest-0.2-2.zip" "$feed_signature" >/dev/null \
  || { echo "FAIL: zip signature"; exit 1; }
"$SPARKLE_ROOT/bin/sign_update" --ed-key-file "$WORK/private-key.txt" --verify "$WORK/feed/appcast.xml" >/dev/null \
  || { echo "FAIL: the feed itself isn't signed"; exit 1; }
echo "── signatures verify ──"

# ── Run it ───────────────────────────────────────────────────────────────────
(cd "$WORK/feed" && exec python3 -I -m http.server "$PORT" --bind 127.0.0.1 >"$WORK/server.log" 2>&1) &
SERVER_PID=$!
sleep 1
cp -R "$WORK/installed" "$WORK/pristine"

# Starts build 1 from clean and reports the build installed once it has finished. 45s is longer than
# the app's own 30s limit, so a refused update has also had its chance to install on quit.
run_build_one() {
    rm -rf "$WORK/installed" "$HOME/Library/Caches/$BUNDLE_ID"
    cp -R "$WORK/pristine" "$WORK/installed"
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    : >"$WORK/log.txt"
    : >"$WORK/server.log"
    open -n "$WORK/installed/WispUpdateTest.app" --args "$WORK/log.txt"

    installed_build=""
    for _ in $(seq 1 45); do
        sleep 1
        installed_build=$(defaults read "$WORK/installed/WispUpdateTest.app/Contents/Info" CFBundleVersion 2>/dev/null || true)
        [ "$installed_build" = "2" ] && break
    done
    pkill -f "$WORK/installed/WispUpdateTest.app" 2>/dev/null || true
    sleep 1
}

failures=0

run_build_one
echo "── a good update ──"
sed 's/^/   /' "$WORK/log.txt"
grep -E '"GET' "$WORK/server.log" | sed -E 's/.*"(GET [^"]*)" ([0-9]+).*/   \1 → \2/'
if [ "$installed_build" = "2" ]; then
    echo "PASS: build 1 updated itself to build 2"
else
    echo "FAIL: still build ${installed_build:-unknown}"
    failures=$((failures + 1))
fi

# The zip swapped for another one, under the signed feed: someone who can replace a release asset but
# doesn't hold the key.
good_zip="$WORK/good.zip"
cp "$WORK/feed/WispUpdateTest-0.2-2.zip" "$good_zip"
original_size=$(stat -f %z "$good_zip")
head -c "$original_size" /dev/urandom >"$WORK/feed/WispUpdateTest-0.2-2.zip"
run_build_one
cp "$good_zip" "$WORK/feed/WispUpdateTest-0.2-2.zip"
if [ "$installed_build" = "1" ]; then
    echo "PASS: a swapped zip was refused"
else
    echo "FAIL: a swapped zip installed"
    failures=$((failures + 1))
fi

# The feed edited after signing, and then with no signature at all.
cp "$WORK/feed/appcast.xml" "$WORK/good-appcast.xml"
sed -i '' 's|<sparkle:shortVersionString>0.2<|<sparkle:shortVersionString>0.9<|' "$WORK/feed/appcast.xml"
run_build_one
if [ "$installed_build" = "1" ]; then
    echo "PASS: an edited feed was refused"
else
    echo "FAIL: an edited feed was accepted"
    failures=$((failures + 1))
fi

python3 -I - "$WORK/good-appcast.xml" "$WORK/feed/appcast.xml" <<'PY_STRIP'
import re, sys
text = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(re.sub(r"<!-- sparkle-signatures:.*?-->", "", text, flags=re.S))
PY_STRIP
run_build_one
if [ "$installed_build" = "1" ]; then
    echo "PASS: an unsigned feed was refused"
else
    echo "FAIL: an unsigned feed was accepted"
    failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] || exit 1
echo "AppUpdates live: all checks passed"
