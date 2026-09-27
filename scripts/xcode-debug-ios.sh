#!/usr/bin/env bash
# Open the iOS project in Xcode and trigger Build & Run on the connected device.
#
# Why: `devicectl device process launch` runs the app but doesn't attach a
# debugger to the extension processes. Their `Logger.notice()` output never
# appears anywhere host-readable. Xcode's debugger attaches to every spawned
# extension (DataProvider, TransportSecurity, TransportApp) and pipes their
# `os_log` stream to the debug console — the **only** practical way to see
# extension logs on a real iOS 26 device today.
#
# Usage:
#   ./scripts/xcode-debug-ios.sh        # opens + runs
#   ./scripts/xcode-debug-ios.sh stop   # sends Cmd+. to halt
#
# After running:
#   1. Watch the Xcode debug console (View → Debug Area → Show)
#   2. Fire a test notif:  ./scripts/test-e2e.sh
#   3. Logs from all three extensions interleave in that console
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$ROOT/ios/NotifBridge-iOS.xcodeproj"

if [[ "${1:-}" == "stop" ]]; then
    /usr/bin/osascript <<'EOF'
tell application "System Events"
    if exists process "Xcode" then
        tell process "Xcode" to keystroke "." using {command down}
    end if
end tell
EOF
    echo "Sent Cmd+. to Xcode (stops debug session)."
    exit 0
fi

if [[ ! -d "$PROJ" ]]; then
    echo "Project not found: $PROJ"
    echo "Run 'cd ios && xcodegen generate' first."
    exit 1
fi

echo "Opening $PROJ in Xcode…"
open -a Xcode "$PROJ"

# Give Xcode time to load the project + index. Skip indexing wait — Run still
# works on partial index.
echo "Waiting 6s for Xcode to load…"
sleep 6

echo "Triggering Build & Run (Cmd+R)…"
/usr/bin/osascript <<'EOF'
tell application "Xcode" to activate
delay 0.4
tell application "System Events"
    tell process "Xcode"
        keystroke "r" using {command down}
    end tell
end tell
EOF

cat <<'TIP'

Xcode is now building + running the iOS app on the device.
  • Debug console: View → Debug Area → Show  (or Cmd+Shift+Y)
  • Filter:        type "[dp-ext]" / "[sec-ext]" / "[tx-ext]" in the filter bar
  • Fire test:     ./scripts/test-e2e.sh
  • Stop:          ./scripts/xcode-debug-ios.sh stop

If the destination is wrong (simulator instead of device), pick the connected
iPhone from the scheme menu at the top of the Xcode window, then re-run.
TIP
