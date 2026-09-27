#!/usr/bin/env bash
# Stream ESP32 serial output. Ctrl-C to exit. Reset the board to capture boot
# logs from the start: pio device monitor honors RTS by default.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIO="${PIO:-$(command -v pio || true)}"
if [[ -z "$PIO" ]]; then PIO="$HOME/.platformio/penv/bin/pio"; fi
if [[ ! -x "$PIO" ]]; then echo "Install PlatformIO or set PIO to its executable." >&2; exit 1; fi
cd "$ROOT/esp32"
exec "$PIO" device monitor --baud 115200 "$@"
