"""
Lê os limites de uso da assinatura Claude a partir do cache local do Claude Code.

Fonte: ~/.claude.json -> cachedUsageUtilization

Esse é o mesmo dado que o painel /usage desenha. O Claude Code busca do servidor
e guarda aqui; nós só lemos. Não existe cálculo nosso — não dá pra derivar
"43% do semanal" dos transcripts porque o denominador não é público.

Como é CACHE, ele pode estar velho. Toda leitura devolve `age_s` justamente pra
a tela poder dizer "há X min" em vez de fingir que o número é ao vivo.
"""


# Anotacoes preguicosas: deixa o modulo rodar no Python 3.9 do sistema
# (/usr/bin/python3), que nunca muda e nao depende do asdf. Sem isto,
# `str | None` e avaliado na definicao da funcao e explode no 3.9.
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

CONFIG = Path.home() / ".claude.json"

# kind -> rótulo curto (a tela tem 480px, nome grande não cabe)
# Em inglês porque vão direto para a tela, e as fontes do LVGL não têm acento.
LABELS = {
    "session": "Session 5h",
    "weekly_all": "Weekly",
    "weekly_scoped": "Weekly (model)",
}

# severity -> cor sugerida (RGB565-friendly)
SEVERITY_COLOR = {
    "normal": "#5FCF8E",
    "warning": "#E8C15A",
    "critical": "#E8624A",
}


def _fmt_reset(iso: str | None, now: datetime) -> str:
    """'3h', '4d' — curto o bastante pra caber ao lado da barra."""
    if not iso:
        return ""
    try:
        dt = datetime.fromisoformat(iso)
    except ValueError:
        return ""
    secs = (dt - now).total_seconds()
    if secs <= 0:
        # Em inglês: isto vai direto pro visor, e as fontes do LVGL
        # embarcadas não têm acento.
        return "now"
    if secs < 3600:
        return f"{secs / 60:.0f}min"
    if secs < 86400:
        return f"{secs / 3600:.0f}h"
    return f"{secs / 86400:.0f}d"


def read() -> dict:
    """
    Devolve:
      {
        "ok": True,
        "age_s": 156,                      # idade do cache em segundos
        "bars": [
          {"kind","label","pct","resets_in","severity","color","active"}, ...
        ],
        "peak": 43,                        # maior percentual (o que aperta)
        "peak_severity": "normal",
      }
    ou {"ok": False, "reason": "..."} — nunca levanta exceção, porque isso roda
    dentro do loop do bridge e stats quebrada não pode derrubar o status.
    """
    if not CONFIG.exists():
        return {"ok": False, "reason": "~/.claude.json não existe"}

    try:
        with CONFIG.open(errors="replace") as fh:
            cfg = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        return {"ok": False, "reason": f"não consegui ler o config: {exc}"}

    cached = cfg.get("cachedUsageUtilization")
    if not cached:
        return {"ok": False, "reason": "sem cachedUsageUtilization (rode /usage uma vez)"}

    now = datetime.now(timezone.utc)
    age_s = max(0, (now.timestamp() * 1000 - cached.get("fetchedAtMs", 0)) / 1000)
    return normalizar(cached.get("utilization"), int(age_s))


def normalizar(utilization, age_s: int) -> dict:
    """
    Transforma o objeto de utilização em barras prontas para a tela.

    Separado de read() porque agora existem DUAS fontes: o cache que o Claude
    Code mantém em disco, e a busca ao vivo que o app da barra faz. As duas
    entregam o mesmo formato, e ambas passam por aqui — um lugar só para
    rotular, colorir e calcular o pico.

    Aceita tanto {"limits": [...]} quanto o objeto já desembrulhado, porque a
    resposta da API e o que está gravado em disco não têm garantia de vir com
    o mesmo nível de aninhamento.
    """
    if isinstance(utilization, dict) and "limits" not in utilization:
        # Alguns formatos embrulham mais uma vez.
        for chave in ("utilization", "usage", "data"):
            if isinstance(utilization.get(chave), dict):
                utilization = utilization[chave]
                break

    now = datetime.now(timezone.utc)
    raw = (utilization or {}).get("limits") or []
    bars = []
    for item in raw:
        kind = item.get("kind", "?")
        pct = item.get("percent")
        if pct is None:
            continue
        sev = item.get("severity") or "normal"
        label = LABELS.get(kind, kind.replace("_", " "))
        # scope é aninhado: {"model": {"display_name": "Fable"}, "surface": null}
        scope = item.get("scope") or {}
        if name := ((scope.get("model") or {}).get("display_name")):
            label = f"Weekly {name}"
        bars.append({
            "kind": kind,
            "label": label,
            "pct": int(pct),
            "resets_in": _fmt_reset(item.get("resets_at"), now),
            "severity": sev,
            "color": SEVERITY_COLOR.get(sev, SEVERITY_COLOR["normal"]),
            "active": bool(item.get("is_active")),
        })

    if not bars:
        return {"ok": False, "reason": "sem limites no payload"}

    peak = max(bars, key=lambda b: b["pct"])
    return {
        "ok": True,
        "age_s": int(age_s),
        "bars": bars,
        "peak": peak["pct"],
        "peak_severity": peak["severity"],
    }


if __name__ == "__main__":
    r = read()
    if not r["ok"]:
        print(f"indisponível: {r['reason']}")
        raise SystemExit(1)

    stale = " (DESATUALIZADO)" if r["age_s"] > 900 else ""
    print(f"=== LIMITES — cache de {r['age_s'] // 60}min atrás{stale} ===\n")
    for b in r["bars"]:
        filled = round(b["pct"] / 5)
        bar = "█" * filled + "░" * (20 - filled)
        flag = " ←" if b["active"] else ""
        print(f"  {b['label']:<18} {bar} {b['pct']:>3}%  reseta em {b['resets_in']:<5}{flag}")
    print(f"\n  pico: {r['peak']}% ({r['peak_severity']})")
