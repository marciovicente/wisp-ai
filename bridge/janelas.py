"""
Consumo nas MESMAS janelas dos limites da assinatura — calculado aqui.

POR QUE ISTO EXISTE
-------------------
Os percentuais da assinatura vêm de um cache que o Claude Code mantém em
~/.claude.json e que deveria renovar a cada 5 minutos. Numa das máquinas de
teste ele ficou parado por três dias sem causa identificável, e não existe
caminho local para forçar: o dado real chega em cabeçalhos HTTP que vivem
dentro do cliente do Claude Code e nunca tocam o disco.

Buscar direto da Anthropic resolveria, mas exige a credencial de OUTRO
aplicativo, o que dispara um pedido de senha do chaveiro e pede uma confiança
desproporcional para um mascote de mesa.

Então aqui a gente calcula o que dá para calcular sozinho, dos transcripts,
sempre fresco e sem pedir nada a ninguém: quanto você consumiu nas últimas 5
horas e nos últimos 7 dias — as mesmas janelas que a Anthropic usa.

O QUE ISTO **NÃO** É
--------------------
Não é o percentual da assinatura. O denominador da Anthropic não é público e
os pesos por modelo também não, então derivar "43% do semanal" daqui seria
inventar número — e número inventado sobre limite é pior que nenhum.

O que entregamos é você contra você mesmo: o consumo da janela atual comparado
ao seu próprio pico recente. Responde "hoje está fora do normal?", que na
prática é a pergunta que faz alguém olhar para o mascote.
"""

from __future__ import annotations

import json
from bisect import bisect_left
from datetime import datetime, timedelta, timezone
from pathlib import Path

PROJECTS_DIR = Path.home() / ".claude" / "projects"

JANELA_SESSAO = timedelta(hours=5)     # mesma janela do limite "Session 5h"
JANELA_SEMANA = timedelta(days=7)      # mesma janela do limite semanal

# Histórico varrido para descobrir o seu pico pessoal.
#
# Precisa ser BEM maior que a maior janela. Com 7 dias de histórico, o pico de
# 7 dias é a própria janela atual e a barra marcava 100% sempre — comparação
# degenerada, informação zero. 30 dias dá margem para a janela semanal ter com
# o que se comparar.
HISTORICO = timedelta(days=30)

# Abaixo disso a comparação não se sustenta: sem pelo menos o dobro da janela
# em histórico, o "pico" é quase a janela atual e o percentual mente.
# Preferimos dizer que não sabemos.
FOLGA_MINIMA = 2.0


def _eventos(desde: datetime) -> list:
    """
    [(quando, saida, requests)] por requisição única, em ordem cronológica.

    A deduplicação por requestId é a mesma do usage.py e existe porque uma
    requisição reaparece em vários arquivos: retomada de sessão, sidechains
    de subagente e compactação de contexto reescrevem o mesmo evento.
    """
    if not PROJECTS_DIR.is_dir():
        return []

    vistos = set()
    fora = []
    for path in PROJECTS_DIR.rglob("*.jsonl"):
        try:
            if datetime.fromtimestamp(path.stat().st_mtime, timezone.utc) < desde:
                continue
            with path.open(errors="replace") as fh:
                for linha in fh:
                    try:
                        d = json.loads(linha)
                    except json.JSONDecodeError:
                        continue
                    if d.get("type") != "assistant":
                        continue
                    msg = d.get("message") or {}
                    u = msg.get("usage")
                    if not u:
                        continue
                    chave = d.get("requestId") or msg.get("id") or d.get("uuid")
                    if chave in vistos:
                        continue
                    vistos.add(chave)

                    ts = d.get("timestamp")
                    if not ts:
                        continue
                    try:
                        quando = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                    except ValueError:
                        continue
                    if quando < desde:
                        continue
                    fora.append((quando, u.get("output_tokens", 0)))
        except OSError:
            continue

    fora.sort(key=lambda e: e[0])
    return fora


def _pico_movel(eventos: list, janela: timedelta) -> int:
    """
    Maior soma de saída dentro de qualquer janela deslizante do período.

    Dois ponteiros sobre a lista ordenada: o de trás avança enquanto o evento
    mais antigo cair fora da janela. Percorre a lista uma vez só.
    """
    if not eventos:
        return 0
    melhor = soma = 0
    i = 0
    for j, (t_j, out_j) in enumerate(eventos):
        soma += out_j
        limite = t_j - janela
        while i <= j and eventos[i][0] < limite:
            soma -= eventos[i][1]
            i += 1
        melhor = max(melhor, soma)
    return melhor


def _soma_desde(eventos: list, instantes: list, desde: datetime) -> tuple:
    """
    (saída, requisições) a partir de um instante. Busca binária: já ordenado.

    O `key=` do bisect só existe no Python 3.10, e rodamos no 3.9 que vem com
    o macOS — de propósito, para não depender de asdf/pyenv. Daí a lista
    paralela de instantes, que é o que se fazia antes do parâmetro existir.
    """
    i = bisect_left(instantes, desde)
    trecho = eventos[i:]
    return sum(e[1] for e in trecho), len(trecho)


def calcular() -> dict:
    """
    {
      "ok": True,
      "sessao": {"saida": 812345, "reqs": 210, "pico": 1200000, "pct": 68},
      "semana": {"saida": 5739065, "reqs": 19144, "pico": 5739065, "pct": 100},
    }

    `pct` é sempre relativo ao SEU pico no período — nunca ao limite da
    Anthropic. Quem consome o dado precisa rotular assim, ou vira mentira.
    """
    agora = datetime.now(timezone.utc)
    eventos = _eventos(agora - HISTORICO)
    if not eventos:
        return {"ok": False, "motivo": "sem transcripts no período"}
    instantes = [e[0] for e in eventos]

    # Quanto histórico REALMENTE existe — não o que pedimos. Quem instalou
    # ontem tem um dia, por mais que a gente varra trinta.
    abrangencia = agora - instantes[0]

    def faixa(janela: timedelta) -> dict:
        saida, reqs = _soma_desde(eventos, instantes, agora - janela)
        pico = _pico_movel(eventos, janela)
        # pct = -1 significa "ainda não dá para comparar", e quem exibe deve
        # mostrar só o número absoluto. Melhor do que uma barra em 100%
        # sugerindo aperto quando o que falta é histórico.
        confiavel = abrangencia >= janela * FOLGA_MINIMA and pico > 0
        return {
            "saida": saida,
            "reqs": reqs,
            "pico": pico,
            "pct": round(saida / pico * 100) if confiavel else -1,
        }

    return {
        "ok": True,
        "sessao": faixa(JANELA_SESSAO),
        "semana": faixa(JANELA_SEMANA),
        "historico_d": round(abrangencia.total_seconds() / 86400, 1),
    }


if __name__ == "__main__":
    import time
    t0 = time.time()
    r = calcular()
    if not r["ok"]:
        raise SystemExit(r["motivo"])
    print(f"=== CONSUMO POR JANELA (local, {time.time() - t0:.1f}s, "
          f"{r['historico_d']}d de histórico) ===\n")
    for chave, nome in (("sessao", "Sessão 5h"), ("semana", "Semana 7d")):
        f = r[chave]
        if f["pct"] < 0:
            print(f"  {nome:<11} {'—' * 20}  histórico curto demais p/ comparar")
        else:
            cheio = round(f["pct"] / 5)
            barra = "█" * min(cheio, 20) + "░" * max(0, 20 - cheio)
            print(f"  {nome:<11} {barra} {f['pct']:>3}% do seu pico")
        print(f"  {'':<11} {f['reqs']:>6} reqs   saída {f['saida']:>10,}"
              f"   (pico {f['pico']:,})\n")
