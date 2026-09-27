#!/usr/bin/env bash
# Open the macOS project in Xcode and trigger Build & Run.
#
# Mac side rarely needs Xcode debug (NSLog from `ESP32Bridge` goes to stderr,
# which the test-e2e harness redirects to /tmp/nb-stderr.log). But this is here
# for when you want breakpoints / variable inspection.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$ROOT/macos/NotifBridge-macOS.xcodeproj"

if [[ "${1:-}" == "stop" ]]; then
    /usr/bin/osascript <<'EOF'
tell application "System Events"
    if exists process "Xcode" then
        tell process "Xcode" to keystroke "." using {command down}
    end if
end tell
EOF
    exit 0
fi

[[ -d "$PROJ" ]] || { echo "Run macos/ xcodegen first."; exit 1; }

open -a Xcode "$PROJ"
sleep 6
/usr/bin/osascript <<'EOF'
tell application "Xcode" to activate
delay 0.4
tell application "System Events"
    tell process "Xcode"
        keystroke "r" using {command down}
    end tell
end tell
EOF

echo "Mac app should be running with debugger attached. Logger.notice output appears in Xcode console."
