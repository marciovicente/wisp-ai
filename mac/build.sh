#!/bin/bash
#
# Assembles Wisp.app without an Xcode project — just swiftc and a bundle built
# by hand.
#
# Why no project: an .xcodeproj is a huge generated file, hard to review, that
# nobody edits by hand. Here the entire build fits on one screen and you can
# read what it does.
#
# The Python bridge goes INSIDE the bundle. That makes the app self-contained:
# it can go to /Applications without dragging the repository along.
#
# Usage:  ./mac/build.sh [--run]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
APP="$HERE/build/Wisp.app"
TARGET="arm64-apple-macosx14.0"   # onChange with 2 params needs 14; MenuBarExtra, 13

echo "==> cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bridge"

echo "==> compiling Swift"
swiftc -O \
    -target "$TARGET" \
    -o "$APP/Contents/MacOS/Wisp" \
    "$HERE"/Sources/*.swift

echo "==> packaging"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"

# A NEGATIVE list on purpose: we copy everything and exclude what is bench
# tooling. With a positive list, every new module had to be remembered here —
# and forgetting one is not a build error, just an app that starts and dies on
# an import. That is exactly what happened with config.py.
BENCH="provision_wifi.py install_hook.py capture_imu.py flash.py tools.py"
for f in "$ROOT"/bridge/*.py; do
    name="$(basename "$f")"
    case " $BENCH " in *" $name "*) continue ;; esac
    cp "$f" "$APP/Contents/Resources/bridge/$name"
done

# Ad-hoc signature: without it macOS treats the app as damaged after the first
# copy. It does not replace a developer signature, but it is enough to run on
# your own machine.
# An ad-hoc signature derives from the CONTENT of the binary: it changes on
# every rebuild, and since macOS ties keychain permission to the signature,
# each build becomes "a different app" and the previous "Always Allow" stops
# counting. With your own identity the signature derives from the CERTIFICATE
# and stays stable across builds. Create yours with ./mac/create-identity.sh —
# it is local and free.
IDENT="Wisp Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENT"; then
    echo "==> signing as '$IDENT'"
    codesign --force --sign "$IDENT" --timestamp=none "$APP" 2>&1 | sed 's/^/    /' || true
else
    echo "==> signing (ad-hoc — the keychain will ask on every build)"
    codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /' || true
fi

echo
echo "done: $APP"
du -sh "$APP" | sed 's/^/    /'

if [[ "${1:-}" == "--run" ]]; then
    echo "==> opening"
    pkill -f "/Wisp\.app/Contents/MacOS/Wisp$" 2>/dev/null || true
    sleep 1
    open "$APP"
fi
