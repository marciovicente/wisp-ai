#!/bin/bash
#
# Draws the mascot's eight states into a PNG and opens it.
#
#   ./mac/preview.sh
#
# To work on the character: edit mac/Sources/Mascot.swift, run this, look.
# A five-second loop, without opening the app.
#
# Where to touch, from what changes most to what changes least:
#
#   MascotState.expression   eyebrow, mouth, gaze and eye opening per state.
#                            This is where the emotion lives. The eyebrow alone
#                            carries more than everything else combined.
#   MascotState.colors       the body gradient (top, bottom).
#   bodyPath()               the silhouette. Changing this changes the character.
#   flamePath()              the light floating above its head.
#   drawMouth()              the seven mouths.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/build/mascot.png}"
mkdir -p "$(dirname "$OUT")"

# Sprites.swift comes along because Mascot.swift falls back to it when the
# user has image art installed. Without it this did not build at all.
swiftc -O -target arm64-apple-macosx14.0 \
    -o "$HERE/build/preview" \
    "$HERE/Preview/main.swift" "$HERE/Sources/Mascot.swift" "$HERE/Sources/Sprites.swift"

"$HERE/build/preview" "$OUT"
open "$OUT"
