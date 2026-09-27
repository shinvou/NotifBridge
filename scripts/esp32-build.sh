#!/usr/bin/env bash
# Build the ESP32 firmware. First run downloads the xtensa toolchain + NimBLE
# library — expect ~5–8 min. Subsequent builds are incremental and quick.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIO="${PIO:-$(command -v pio || true)}"
if [[ -z "$PIO" ]]; then PIO="$HOME/.platformio/penv/bin/pio"; fi
if [[ ! -x "$PIO" ]]; then echo "Install PlatformIO or set PIO to its executable." >&2; exit 1; fi
cd "$ROOT/esp32"
exec "$PIO" run "$@"
