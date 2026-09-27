#!/usr/bin/env bash
# Build + upload firmware over USB serial. Wraps PlatformIO so the user only
# needs ./scripts/esp32-flash.sh.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIO="${PIO:-$(command -v pio || true)}"
if [[ -z "$PIO" ]]; then PIO="$HOME/.platformio/penv/bin/pio"; fi
if [[ ! -x "$PIO" ]]; then echo "Install PlatformIO or set PIO to its executable." >&2; exit 1; fi
cd "$ROOT/esp32"
exec "$PIO" run --target upload "$@"
