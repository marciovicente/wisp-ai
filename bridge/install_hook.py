"""
Registra (ou remove) o hook do mascote no ~/.claude/settings.json.

Cirúrgico de propósito: acrescenta uma entrada ao lado das que já existem e
não encosta em mais nada. Sempre faz backup antes e valida o JSON depois —
um settings.json corrompido quebra o Claude Code inteiro.

    python3 bridge/install_hook.py --dry-run   # mostra o que faria
    python3 bridge/install_hook.py             # aplica
    python3 bridge/install_hook.py --remove    # desfaz
"""

import argparse
import json
import shutil
import sys
import time
from pathlib import Path

SETTINGS = Path.home() / ".claude" / "settings.json"
HOOK = Path(__file__).resolve().parent / "hook.sh"

# Eventos que alimentam a máquina de estados do mascote.
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
    # async: o Claude dispara e segue. Sem isso, pagaríamos ~230ms por evento
    # sempre que o bridge estivesse fora do ar.
    return {
        "matcher": "",
        "hooks": [{"type": "command", "command": str(HOOK), "async": True}],
    }


def is_ours(group: dict) -> bool:
    return any(
        str(h.get("command", "")).endswith("waveshare/bridge/hook.sh")
        for h in group.get("hooks", [])
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--remove", action="store_true")
    args = ap.parse_args()

    if not SETTINGS.exists():
        print(f"não encontrei {SETTINGS}", file=sys.stderr)
        return 1
    if not HOOK.exists() and not args.remove:
        print(f"não encontrei {HOOK}", file=sys.stderr)
        return 1

    original = SETTINGS.read_text()
    try:
        cfg = json.loads(original)
    except json.JSONDecodeError as exc:
        print(f"settings.json já está inválido, não vou piorar: {exc}", file=sys.stderr)
        return 1

    hooks = cfg.setdefault("hooks", {})
    added, removed, skipped = [], [], []

    for ev in EVENTS:
        groups = hooks.setdefault(ev, [])
        mine = [g for g in groups if is_ours(g)]

        if args.remove:
            if mine:
                hooks[ev] = [g for g in groups if not is_ours(g)]
                removed.append(ev)
            continue

        if mine:
            skipped.append(ev)
        else:
            groups.append(entry())
            added.append(ev)

    # Valida serializando ANTES de escrever qualquer coisa.
    try:
        out = json.dumps(cfg, indent=2, ensure_ascii=False) + "\n"
        json.loads(out)
    except (TypeError, ValueError) as exc:
        print(f"resultado seria JSON inválido, abortando: {exc}", file=sys.stderr)
        return 1

    action = "removeria" if args.remove else "adicionaria"
    if added:   print(f"{action} em: {', '.join(added)}")
    if removed: print(f"{action} em: {', '.join(removed)}")
    if skipped: print(f"já presente (pulando): {', '.join(skipped)}")
    if not (added or removed):
        print("nada a fazer.")
        return 0

    if args.dry_run:
        print(f"\n--dry-run: nada foi escrito. Diferença de tamanho: "
              f"{len(original)} -> {len(out)} bytes")
        return 0

    backup = SETTINGS.with_suffix(f".json.bak-mascote-{int(time.time())}")
    shutil.copy2(SETTINGS, backup)

    tmp = SETTINGS.with_suffix(".json.tmp-mascote")
    tmp.write_text(out)
    tmp.replace(SETTINGS)   # troca atômica: nunca existe arquivo pela metade

    print(f"\nbackup : {backup}")
    print(f"escrito: {SETTINGS}")
    print(f"desfazer: python3 {Path(__file__).name} --remove   (ou restaure o backup)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
