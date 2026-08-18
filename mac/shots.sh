#!/bin/bash
#
# Renders the app's screens into docs/ for the README.
#
#   ./mac/shots.sh
#
# Synthetic data on purpose — see the comment at the top of Shots/main.swift.
# Regenerate these whenever the interface changes; a stale screenshot documents
# a version nobody runs.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
mkdir -p "$HERE/build" "$ROOT/docs"

# Every source EXCEPT Wisp.swift: that one carries the @main App, and a module
# with top-level code cannot also declare an entry point.
FONTES=()
for f in "$HERE"/Sources/*.swift; do
    [[ "$(basename "$f")" == "Wisp.swift" ]] && continue
    FONTES+=("$f")
done

swiftc -O -target arm64-apple-macosx14.0 \
    -o "$HERE/build/shots" \
    "$HERE/Shots/main.swift" "${FONTES[@]}"

cd "$ROOT" && "$HERE/build/shots"
