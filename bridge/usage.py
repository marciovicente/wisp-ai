"""
Agrega consumo de tokens do Claude Code a partir dos transcripts em ~/.claude/projects.

Sem dependências externas — só stdlib.

Preços: tabela oficial Anthropic (USD por 1M tokens), input/output.
Cache: leitura ~0.1x do input; escrita 1.25x (TTL 5m) ou 2x (TTL 1h).

ATENÇÃO: se você usa Claude Code por assinatura (Pro/Max), você NÃO é cobrado
por token. O custo abaixo é uma estimativa do "preço de tabela" (list price) —
serve para comparar sessões e modelos, não é a sua fatura.
"""


# Anotacoes preguicosas: deixa o modulo rodar no Python 3.9 do sistema
# (/usr/bin/python3), que nunca muda e nao depende do asdf. Sem isto,
# `str | None` e avaliado na definicao da funcao e explode no 3.9.
from __future__ import annotations

import json
import os
from collections import defaultdict
from datetime import datetime, timezone, timedelta
from pathlib import Path

PROJECTS_DIR = Path.home() / ".claude" / "projects"

# USD por 1M tokens: (input, output)
PRICING = {
    "claude-fable-5": (10.00, 50.00),
    "claude-mythos-5": (10.00, 50.00),
    "claude-opus-5": (5.00, 25.00),
    "claude-opus-4-8": (5.00, 25.00),
    "claude-opus-4-7": (5.00, 25.00),
    "claude-opus-4-6": (5.00, 25.00),
    "claude-opus-4-5": (5.00, 25.00),
    "claude-sonnet-5": (3.00, 15.00),
    "claude-sonnet-4-6": (3.00, 15.00),
    "claude-sonnet-4-5": (3.00, 15.00),
    "claude-haiku-4-5": (1.00, 5.00),
}

CACHE_READ_MULT = 0.1
CACHE_WRITE_5M_MULT = 1.25
CACHE_WRITE_1H_MULT = 2.0


def _price(model: str):
    """Resolve preço, tolerando sufixos de data (claude-haiku-4-5-20251001)."""
    if model in PRICING:
        return PRICING[model]
    for known, p in PRICING.items():
        if model.startswith(known):
            return p
    return None


def _cost(model: str, u: dict) -> float:
    p = _price(model)
    if not p:
        return 0.0
    inp, out = p
    cc = u.get("cache_creation") or {}
    w1h = cc.get("ephemeral_1h_input_tokens", 0)
    w5m = cc.get("ephemeral_5m_input_tokens", 0)
    # fallback quando o detalhamento por TTL não existe
    if not (w1h or w5m):
        w5m = u.get("cache_creation_input_tokens", 0)
    return (
        u.get("input_tokens", 0) * inp
        + u.get("cache_read_input_tokens", 0) * inp * CACHE_READ_MULT
        + w5m * inp * CACHE_WRITE_5M_MULT
        + w1h * inp * CACHE_WRITE_1H_MULT
        + u.get("output_tokens", 0) * out
    ) / 1_000_000


def _blank():
    return {
        "input": 0, "output": 0, "cache_read": 0, "cache_write": 0,
        "cost": 0.0, "requests": 0,
    }


def collect(since_days: int | None = None) -> dict:
    """Varre os transcripts e agrega. since_days=None varre tudo."""
    cutoff = None
    if since_days is not None:
        cutoff = datetime.now(timezone.utc) - timedelta(days=since_days)

    by_model = defaultdict(_blank)
    by_day = defaultdict(_blank)
    by_project = defaultdict(_blank)
    seen = set()
    files_read = 0

    if not PROJECTS_DIR.is_dir():
        return {"error": f"não encontrei {PROJECTS_DIR}"}

    for path in PROJECTS_DIR.rglob("*.jsonl"):
        if cutoff and datetime.fromtimestamp(path.stat().st_mtime, timezone.utc) < cutoff:
            continue
        files_read += 1
        project = path.parent.name
        try:
            with path.open(errors="replace") as fh:
                for line in fh:
                    try:
                        d = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if d.get("type") != "assistant":
                        continue
                    msg = d.get("message") or {}
                    u = msg.get("usage")
                    if not u:
                        continue

                    # dedup: uma requisição pode aparecer em vários arquivos
                    # (resume de sessão, sidechains, compactação)
                    key = d.get("requestId") or msg.get("id") or d.get("uuid")
                    if key in seen:
                        continue
                    seen.add(key)

                    ts = d.get("timestamp")
                    if cutoff and ts:
                        try:
                            when = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                            if when < cutoff:
                                continue
                        except ValueError:
                            pass

                    model = msg.get("model") or "unknown"
                    cost = _cost(model, u)
                    day = (ts or "")[:10] or "unknown"

                    for bucket in (by_model[model], by_day[day], by_project[project]):
                        bucket["input"] += u.get("input_tokens", 0)
                        bucket["output"] += u.get("output_tokens", 0)
                        bucket["cache_read"] += u.get("cache_read_input_tokens", 0)
                        bucket["cache_write"] += u.get("cache_creation_input_tokens", 0)
                        bucket["cost"] += cost
                        bucket["requests"] += 1
        except OSError:
            continue

    total = _blank()
    for b in by_model.values():
        for k in total:
            total[k] += b[k]

    return {
        "total": total,
        "by_model": dict(by_model),
        "by_day": dict(by_day),
        "by_project": dict(by_project),
        "files_read": files_read,
        "unique_requests": len(seen),
    }


if __name__ == "__main__":
    import sys
    import time

    days = int(sys.argv[1]) if len(sys.argv) > 1 else None
    t0 = time.time()
    r = collect(days)
    elapsed = time.time() - t0

    if "error" in r:
        print(r["error"])
        raise SystemExit(1)

    t = r["total"]
    scope = f"últimos {days} dias" if days else "tudo"
    print(f"=== CONSUMO ({scope}) — {elapsed:.2f}s, {r['files_read']} arquivos ===")
    print(f"requisições : {t['requests']:,}")
    print(f"input       : {t['input']:,}")
    print(f"output      : {t['output']:,}")
    print(f"cache read  : {t['cache_read']:,}")
    print(f"cache write : {t['cache_write']:,}")
    print(f"custo (list): ${t['cost']:,.2f}")

    print("\n--- por modelo ---")
    for m, b in sorted(r["by_model"].items(), key=lambda kv: -kv[1]["cost"]):
        print(f"{m:<28} {b['requests']:>6} req  out {b['output']:>10,}  ${b['cost']:>9,.2f}")

    print("\n--- últimos 7 dias ---")
    for d in sorted(r["by_day"])[-7:]:
        b = r["by_day"][d]
        print(f"{d}  {b['requests']:>5} req  ${b['cost']:>8,.2f}")
