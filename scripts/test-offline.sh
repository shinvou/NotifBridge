#!/usr/bin/env bash
# All hardware-independent regressions. Requires Apple silicon and macOS 26+.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/macos/Build"
for mode in --features --receiver --ble-writer --reverse-crypto; do
    bash "$ROOT/scripts/test-e2e.sh" "$mode"
done
for suite in window-lifecycle native-notifications notification-order banner-order host-restoration transport-startup delivery-reliability key-rotation key-preparation security-delivery; do
    bash "$ROOT/scripts/test-$suite.sh"
done
