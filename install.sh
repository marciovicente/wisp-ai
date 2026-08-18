#!/bin/bash
#
# Installs Wisp on your Mac.
#
#   curl -fsSL https://raw.githubusercontent.com/marciovicente/wisp-ai/main/install.sh | bash
#   or, with the repository already cloned:  ./install.sh
#
# WHY BUILD INSTEAD OF SHIPPING A .DMG
# ------------------------------------
# An app downloaded from the internet gets macOS's quarantine flag, and without
# a developer signature (US$ 99/year) the system refuses to open it with a
# malware warning. An app built on your own machine never gets that flag.
# Building here is not laziness about packaging — it is what removes the
# friction.
#
# What this script does, in order:
#   1. clones the repository, if you came in through curl
#   2. checks the prerequisites
#   3. builds Wisp.app
#   4. installs it into ~/Applications
#   5. offers to register the Claude Code hooks (with a backup, and your ok)
#   6. offers to flash the board, if one is plugged in
#
# It installs nothing globally, asks for no sudo and touches no system config.
#
#   ./install.sh --no-hooks    do not ask about or register hooks
#   ./install.sh --no-board    ignore any connected board

set -euo pipefail

BLUE=$'\033[34m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
step() { echo "${BLUE}==>${RESET} $*"; }
ok()   { echo "${GREEN} ok${RESET} $*"; }
warn() { echo "${YELLOW} !${RESET} $*"; }
die()  { echo "error: $*" >&2; exit 1; }

# Test by OPENING /dev/tty, not with -r: in a session with no controlling
# terminal (CI, cron, an agent) the file exists and is readable, but the open
# fails with "Device not configured" — and the installer used to die there.
have_tty() { { : < /dev/tty; } 2>/dev/null; }

# Always ask through the terminal, even when stdin is busy with a pipe.
ask() {
    local answer
    if [[ -t 0 ]]; then read -r -p "$1" answer
    elif have_tty; then read -r -p "$1" answer < /dev/tty
    else return 1
    fi
    echo "$answer"
}

REPO="${WISP_REPO:-marciovicente/wisp-ai}"
DEST="$HOME/Applications"
NO_HOOKS=0; NO_BOARD=0
for a in "$@"; do
    case "$a" in
        --no-hooks) NO_HOOKS=1 ;;
        --no-board) NO_BOARD=1 ;;
        *) die "unknown option: $a" ;;
    esac
done

# ————————————————————————————————— 0. where are we running from
#
# Through a pipe (`curl | bash`) there is no $BASH_SOURCE and no file on disk:
# the script has to go fetch the rest of the project itself. This used to blow
# up with "BASH_SOURCE[0]: unbound variable" — the install line at the top did
# not actually work.

SOURCE="${BASH_SOURCE[0]:-}"
ROOT=""
if [[ -n "$SOURCE" && -f "$(dirname "$SOURCE")/mac/build.sh" ]]; then
    ROOT="$(cd "$(dirname "$SOURCE")" && pwd)"
fi

if [[ -z "$ROOT" ]]; then
    command -v git >/dev/null 2>&1 || die "I need git.  xcode-select --install"
    ROOT="${WISP_SRC:-$HOME/.wisp/src}"
    if [[ -d "$ROOT/.git" ]]; then
        step "updating $ROOT"
        git -C "$ROOT" pull --ff-only --quiet || warn "could not update; going on with what is here"
    else
        step "cloning $REPO into $ROOT"
        mkdir -p "$(dirname "$ROOT")"
        git clone --depth 1 --quiet "https://github.com/$REPO.git" "$ROOT" \
            || die "failed to clone https://github.com/$REPO.git"
    fi
    # Re-run from the clone, with a real terminal: through a pipe stdin is the
    # script itself, and without this none of the questions below could be asked.
    if have_tty; then
        exec bash "$ROOT/install.sh" "$@" < /dev/tty
    else
        exec bash "$ROOT/install.sh" "$@" --no-hooks --no-board
    fi
fi

# ————————————————————————————————— 1. prerequisites

step "checking the environment"

[[ "$(uname -s)" == "Darwin" ]] || die "this is a macOS app."

version="$(sw_vers -productVersion)"
major="${version%%.*}"
(( major >= 14 )) || die "needs macOS 14 or newer (you have $version).
   The app uses SwiftUI's MenuBarExtra, which does not exist before that."
ok "macOS $version"

if ! command -v swiftc >/dev/null 2>&1; then
    die "could not find swiftc.
   Install the command line tools and run this again:

       xcode-select --install

   That is ~700MB and comes from Apple. Without it there is no way to build."
fi
ok "swift $(swiftc --version 2>/dev/null | head -1 | sed 's/.*version //;s/ .*//')"

# The bridge runs on the Python that ships with macOS. That is deliberate: it
# means the app does not break when you switch versions in asdf/pyenv/homebrew.
[[ -x /usr/bin/python3 ]] || die "could not find /usr/bin/python3."
ok "python $(/usr/bin/python3 --version 2>&1 | sed 's/Python //')"

command -v dns-sd >/dev/null 2>&1 || warn "no dns-sd: the board will need a fixed IP."

# ————————————————————————————————— 2. build

step "building"
# Anchored at the end of the command line on purpose: without the $, the
# pattern also matches the swiftc that is compiling (the path shows up in its
# -o argument) and the build kills itself.
if pgrep -f "/Wisp\.app/Contents/MacOS/Wisp$" >/dev/null 2>&1; then
    warn "Wisp was running — closing it so it can be replaced"
    pkill -f "/Wisp\.app/Contents/MacOS/Wisp$" || true
    sleep 2
fi
"$ROOT/mac/build.sh" >/dev/null || die "the build failed. Run ./mac/build.sh to see the error."
ok "Wisp.app built"

# ————————————————————————————————— 3. install

step "installing into $DEST"
mkdir -p "$DEST"
rm -rf "$DEST/Wisp.app"
cp -R "$ROOT/mac/build/Wisp.app" "$DEST/Wisp.app"
ok "$DEST/Wisp.app"

# Reading the config the first time generates the token and finds your city
# from your IP.
/usr/bin/python3 "$ROOT/bridge/config.py" | sed 's/^/   /'

# The Terminal character, the same art the board draws. Without this the Mac
# falls back to the built-in vector and the two halves of the project look
# like different products. Copied, not linked, so deleting the clone does not
# take the mascot with it.
ARTE="$HOME/.wisp/mascots/terminal"
if [[ ! -f "$ARTE/idle.png" ]]; then
    mkdir -p "$ARTE"
    cp "$ROOT"/firmware/assets/*.png "$ARTE"/ 2>/dev/null && ok "mascot installed"
fi

# ————————————————————————————————— 4. Claude Code hooks

echo
step "Claude Code hooks"
echo "   Without them the mascot has no idea what Claude is doing — they are"
echo "   what feeds the states. The installer appends ours and does not touch"
echo "   the ones you already have, keeping a copy of the file first."
echo

if (( NO_HOOKS )); then
    echo "   skipped (--no-hooks). Whenever you want:"
    echo "   /usr/bin/python3 $ROOT/bridge/install_hook.py"
elif answer="$(ask '   register the hooks now? [Y/n] ')"; then
    if [[ "${answer:-Y}" =~ ^[YySs]?$ ]]; then
        /usr/bin/python3 "$ROOT/bridge/install_hook.py" | sed 's/^/   /' \
            || warn "the hooks failed; run bridge/install_hook.py later"
    else
        echo "   skipped. Whenever you want: /usr/bin/python3 $ROOT/bridge/install_hook.py"
    fi
else
    warn "no terminal to ask on — hooks not registered"
fi

# ————————————————————————————————— 5. the board, if there is one

if (( ! NO_BOARD )) && compgen -G "/dev/cu.usbmodem*" >/dev/null; then
    echo
    step "found a board on USB"
    echo "   Flashing Wisp onto it erases Waveshare's demo firmware."
    echo "   The flasher saves a copy of that first, and asks for WiFi at the end."
    echo
    if answer="$(ask '   flash the board now? [y/N] ')" && [[ "$answer" =~ ^[YySs]$ ]]; then
        "$ROOT/flash.sh" || warn "flashing failed; run ./flash.sh to see the error"
    else
        echo "   skipped. Whenever you want:  $ROOT/flash.sh"
    fi
fi

# ————————————————————————————————— done

cat <<END

${GREEN}done.${RESET}

  open it:   open ~/Applications/Wisp.app

  The icon shows up in the menu bar. The bridge comes up with the app and
  goes down with it — nothing keeps running behind your back.

  Tick "Open at login" in the panel if you want it to start on its own.

  The app alone already shows usage and sessions. For the screen on your desk:
  ${BLUE}$ROOT/flash.sh${RESET}
END
