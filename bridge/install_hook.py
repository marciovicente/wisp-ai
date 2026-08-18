"""
Registers (or removes) the Wisp hook in ~/.claude/settings.json.

Surgical on purpose: it appends an entry next to the ones already there and
touches nothing else. It always backs up first and validates the JSON
afterwards — a corrupted settings.json breaks all of Claude Code.

    /usr/bin/python3 bridge/install_hook.py --dry-run   # show what it would do
    /usr/bin/python3 bridge/install_hook.py             # apply
    /usr/bin/python3 bridge/install_hook.py --remove    # undo

The script it registers is a COPY at ~/.wisp/hook.sh, not the file in the
repository. That way you can delete the clone after installing without the
hooks pointing at a path that no longer exists — which, in a hook, produces no
visible error: it just stops working.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import time
from pathlib import Path

SETTINGS = Path.home() / ".claude" / "settings.json"
SOURCE = Path(__file__).resolve().parent / "hook.sh"
DEST = Path.home() / ".wisp" / "hook.sh"

# The events that feed the mascot's state machine.
EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "Notification",
    "PermissionRequest",
    "Stop",
    "StopFailure",
    "TaskCompleted",
    "SessionEnd",
]


def entry() -> dict:
    # async: Claude fires and moves on. Without it we would pay ~230ms per
    # event whenever the bridge is down.
    return {
        "matcher": "",
        "hooks": [{"type": "command", "command": str(DEST), "async": True}],
    }


def is_ours(group: dict) -> bool:
    """
    Recognises the hook by path suffix, never by the full path: the user picks
    where to clone the repository, and an old install points there. Without
    this, `--remove` would leave litter behind.
    """
    for h in group.get("hooks", []):
        cmd = str(h.get("command", ""))
        if cmd.endswith("/.wisp/hook.sh") or cmd.endswith("/bridge/hook.sh"):
            return True
    return False


def install_script() -> None:
    DEST.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(SOURCE, DEST)
    DEST.chmod(0o755)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--remove", action="store_true")
    args = ap.parse_args()

    if not SETTINGS.exists():
        print(f"could not find {SETTINGS}.\n"
              "   Run Claude Code once so it creates the file.", file=sys.stderr)
        return 1
    if not SOURCE.exists() and not args.remove:
        print(f"could not find {SOURCE}", file=sys.stderr)
        return 1

    original = SETTINGS.read_text()
    try:
        cfg = json.loads(original)
    except json.JSONDecodeError as exc:
        print(f"settings.json is already invalid, I will not make it worse: {exc}",
              file=sys.stderr)
        return 1

    hooks = cfg.setdefault("hooks", {})
    added, removed, migrated, skipped = [], [], [], []

    for ev in EVENTS:
        groups = hooks.setdefault(ev, [])
        mine = [g for g in groups if is_ours(g)]

        if args.remove:
            if mine:
                hooks[ev] = [g for g in groups if not is_ours(g)]
                removed.append(ev)
            continue

        if not mine:
            groups.append(entry())
            added.append(ev)
            continue

        # Something of ours is already there. It may be an old install pointing
        # at the repository: point it at the stable copy and deduplicate.
        current = {str(h.get("command")) for g in mine for h in g.get("hooks", [])}
        if current == {str(DEST)} and len(mine) == 1:
            skipped.append(ev)
        else:
            hooks[ev] = [g for g in groups if not is_ours(g)] + [entry()]
            migrated.append(ev)

    # Validate by serialising BEFORE writing anything.
    try:
        out = json.dumps(cfg, indent=2, ensure_ascii=False) + "\n"
        json.loads(out)
    except (TypeError, ValueError) as exc:
        print(f"the result would be invalid JSON, aborting: {exc}", file=sys.stderr)
        return 1

    if added:     print(f"{'would add' if args.dry_run else 'added'} to: {', '.join(added)}")
    if migrated:  print(f"{'would migrate' if args.dry_run else 'migrated'} (old path) in: {', '.join(migrated)}")
    if removed:   print(f"{'would remove' if args.dry_run else 'removed'} from: {', '.join(removed)}")
    if skipped:   print(f"already correct: {', '.join(skipped)}")
    if not (added or removed or migrated):
        print("nothing to do.")
        return 0

    if args.dry_run:
        print(f"\n--dry-run: nothing was written. Size difference: "
              f"{len(original)} -> {len(out)} bytes")
        return 0

    backup = SETTINGS.with_suffix(f".json.bak-wisp-{int(time.time())}")
    shutil.copy2(SETTINGS, backup)

    if args.remove:
        DEST.unlink(missing_ok=True)
    else:
        install_script()

    tmp = SETTINGS.with_suffix(".json.tmp-wisp")
    tmp.write_text(out)
    tmp.replace(SETTINGS)   # atomic swap: a half-written file never exists

    print(f"\nbackup : {backup}")
    print(f"written: {SETTINGS}")
    if not args.remove:
        print(f"hook   : {DEST}")
        print(f"undo   : /usr/bin/python3 {Path(__file__).name} --remove")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
