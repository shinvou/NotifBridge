#!/usr/bin/env bash
#
# End-to-end auto test: launch the iPhone app with `--send-test-notif
# --test-notif-body=<unique>`, wait for the notification to fire and propagate
# through the AccessoryNotifications pipeline, then pull Mac receiver logs and
# confirm the unique body string appears in the decrypted plaintext.
#
# Known iOS quirk: bluetoothd intermittently classifies the TransportApp
# extension at XPC check-in as `isExtension=false` on its first launch (most
# common right after a reinstall). When that happens, BT stays poweredOff for
# the extension, the writer can't connect, and decrypt fails. The next launch
# usually classifies correctly. This script auto-retries once when decrypt
# misses.
#
# Usage: scripts/test-e2e.sh [body]
set -e

DEVICE="${DEVICE:-9822EAFB-7B58-58BC-BD07-DF17CA6A7F9B}"
BUNDLE="com.shinvou.NotifBridge"
BODY="${1:-e2e-$(date +%s)-$RANDOM}"
WAIT_SEC=15
MAX_ATTEMPTS=2

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAC_APP="$ROOT/macos/Build/Products/Debug/NotifBridge.app"

ensure_mac_receiver() {
    # NOTE: do NOT kill + relaunch the Mac. Each CBPeripheralManager instance
    # gets a fresh bluetoothIdentifier; killing it invalidates the iPhone's ASK
    # bond and the extensions can no longer reach the peripheral. To recover
    # from a hard restart the user must re-pair via Settings →
    # Privacy & Security → Accessories.
    if ! pgrep -q NotifBridge; then
        echo "  NotifBridge (Mac) not running — launching"
        open "$MAC_APP"
        sleep 3
    fi
    echo "  NotifBridge (Mac) PID=$(pgrep NotifBridge || echo none)"
}

run_once() {
    local attempt=$1
    local start_ts end_ts log
    start_ts=$(date +%s)

    echo "[2/4] (attempt $attempt) Launching iPhone app with body=\"$BODY\"..."
    xcrun devicectl device process launch \
        --device "$DEVICE" \
        --terminate-existing \
        "$BUNDLE" \
        --send-test-notif \
        "--test-notif-body=$BODY" 2>&1 | sed 's/^/  /' | head -8

    echo "[3/4] Waiting ${WAIT_SEC}s for notification to fire + propagate..."
    sleep "$WAIT_SEC"

    echo "[4/4] Pulling Mac receiver log..."
    end_ts=$(date +%s)
    log=$(bash -c "log show --predicate 'subsystem == \"com.shinvou.NotifBridge.Mac\"' --info --last $((end_ts - start_ts + 10))s")

    echo ""
    echo "=== Decrypt results ==="
    echo "$log" | grep -E "decrypted .*B from .*B sess=|decrypt failed|HPKE-PLAINTEXT ascii=" | tail -10 || true

    local win
    win=$(echo "$log" | grep "HPKE-PLAINTEXT ascii=" | tail -1 || true)
    if [[ -n "$win" ]]; then
        echo ""
        echo "✅ DECRYPT OK — $win"
        if echo "$log" | grep -q -F "$BODY"; then
            echo "✅ unique body string \"$BODY\" found in decrypted plaintext"
            return 0
        else
            echo "⚠️  decrypt succeeded but unique body \"$BODY\" not in plaintext (framing?)"
            return 1
        fi
    fi
    return 2
}

echo "[1/4] Ensuring Mac receiver is running..."
ensure_mac_receiver

for attempt in $(seq 1 $MAX_ATTEMPTS); do
    set +e
    run_once "$attempt"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        exit 0
    fi
    if [[ $rc -eq 1 ]]; then
        exit 1
    fi
    if [[ $attempt -lt $MAX_ATTEMPTS ]]; then
        echo ""
        echo "❌ no decrypt on attempt $attempt — retrying (known bluetoothd isExtension=false quirk)..."
        sleep 2
    fi
done

echo ""
echo "❌ FAIL — no decrypt after $MAX_ATTEMPTS attempts"
exit 1
