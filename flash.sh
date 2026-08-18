#!/bin/bash
#
# Flashes Wisp onto the Waveshare ESP32-S3-Touch-AMOLED-2.16 board.
#
#   ./flash.sh              # flash and provision WiFi
#   ./flash.sh --no-wifi    # firmware only
#   ./flash.sh --erase      # erase the flash first (board in a boot loop)
#
# No ESP-IDF needed. The flashing tools are pulled from PyPI into a venv under
# ~/.wisp/tools the first time — nothing global, no sudo.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
exec /usr/bin/python3 "$ROOT/bridge/flash.py" "$@"
