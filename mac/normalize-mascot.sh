#!/bin/bash
# Prepares a mascot set: removes the background and aligns the eight states.
#
#   ./mac/normalize-mascot.sh [folder]
#   (default: ~/.wisp/mascots/terminal)
#
# It writes a `normalized/` subfolder. Look at it and, if you like it, move it
# over the originals. It never overwrites anything without you looking first.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HERE/build"
swiftc -O -target arm64-apple-macosx14.0 -o "$HERE/build/normalize" "$HERE/Normalize/main.swift"
"$HERE/build/normalize" "${1:-$HOME/.wisp/mascots/terminal}"
