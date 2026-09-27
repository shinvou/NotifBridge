#!/usr/bin/env bash
# Wipe ESP32 flash (incl. NVS bonding) so iPhone + Mac will need to re-pair.
# Useful when fixture bonds get out of sync during dev.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIO="${PIO:-$(command -v pio || true)}"
if [[ -z "$PIO" ]]; then PIO="$HOME/.platformio/penv/bin/pio"; fi
if [[ ! -x "$PIO" ]]; then echo "Install PlatformIO or set PIO to its executable." >&2; exit 1; fi
cd "$ROOT/esp32"
exec "$PIO" run --target erase
