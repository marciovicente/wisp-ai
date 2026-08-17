"""
Configuração por usuário. Nada de específico de uma máquina no código.

Vive em ~/.fagulha/config.json, criado no primeiro uso com valores sensatos.
O arquivo é 0600 porque guarda o token de acesso ao bridge.

POR QUE ISTO EXISTE
-------------------
Até agora o hostname do Mac de uma pessoa estava cravado no anuncio.py e São
Paulo estava cravada no weather.py. Funciona numa máquina; é lixo em todas as
outras. Publicar assim significaria cada usuário editando código-fonte pra
mudar a cidade.

E o mais sério: o bridge escuta na rede local e serve nomes de projeto e
consumo pra quem pedir. Numa rede de coworking isso é leitura livre. O token
aqui resolve — a placa manda, mais ninguém tem.
"""

from __future__ import annotations

import json
import os
import secrets
import urllib.request
from pathlib import Path

PASTA = Path.home() / ".fagulha"
ARQUIVO = PASTA / "config.json"

PADRAO = {
    "porta": 4666,

    # Token que a placa apresenta em cada consulta. Gerado no primeiro uso.
    "token": "",

    # Com token exigido, /state só responde a quem apresentar o segredo.
    # Instalação nova nasce em true. Fica false apenas enquanto houver uma
    # placa gravada com firmware antigo, que ainda não sabe mandar o token.
    "exigir_token": True,

    # Previsão do tempo. Sem isto o bridge tenta descobrir pelo IP no primeiro
    # uso; falhando, o relógio aparece sem temperatura.
    "tempo": {"lat": None, "lon": None, "nome": ""},

    # Hostnames antigos a republicar por mDNS, para placas já gravadas
    # continuarem achando o bridge depois que o macOS renomeia a máquina.
    "hostnames_legados": [],
}


def _detectar_local() -> dict:
    """
    Descobre a cidade pelo IP público, uma vez só, no primeiro uso.

    É a diferença entre "funciona sozinho" e "edite um JSON antes de usar".
    Uma chamada, gravada pra sempre. Falhando, o tempo simplesmente não
    aparece — nunca é motivo pra derrubar nada.
    """
    try:
        req = urllib.request.Request(
            "http://ip-api.com/json/?fields=status,city,lat,lon",
            headers={"User-Agent": "fagulha"})
        with urllib.request.urlopen(req, timeout=6) as r:
            d = json.loads(r.read())
        if d.get("status") == "success":
            return {"lat": d["lat"], "lon": d["lon"], "nome": d.get("city", "")}
    except Exception:
        pass
    return {"lat": None, "lon": None, "nome": ""}


def _fundir(base: dict, novo: dict) -> dict:
    """Mantém as chaves que o usuário já tem e acrescenta as que faltarem."""
    saida = dict(base)
    for k, v in (novo or {}).items():
        if isinstance(v, dict) and isinstance(saida.get(k), dict):
            saida[k] = _fundir(saida[k], v)
        else:
            saida[k] = v
    return saida


_cache: dict | None = None


def ler(recarregar: bool = False) -> dict:
    global _cache
    if _cache is not None and not recarregar:
        return _cache

    atual = {}
    if ARQUIVO.exists():
        try:
            atual = json.loads(ARQUIVO.read_text())
        except (OSError, json.JSONDecodeError):
            atual = {}

    cfg = _fundir(PADRAO, atual)
    mudou = cfg != atual

    if not cfg["token"]:
        # 32 bytes urlsafe: sobra pra uma rede local e cabe num header.
        cfg["token"] = secrets.token_urlsafe(24)
        mudou = True

    t = cfg["tempo"]
    if t.get("lat") is None and "tempo_detectado" not in atual:
        cfg["tempo"] = _detectar_local()
        # Marca a tentativa mesmo se falhou: não insistimos a cada boot.
        cfg["tempo_detectado"] = True
        mudou = True

    if mudou:
        gravar(cfg)

    _cache = cfg
    return cfg


def gravar(cfg: dict) -> None:
    PASTA.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = ARQUIVO.with_suffix(".tmp")
    tmp.write_text(json.dumps(cfg, indent=2, ensure_ascii=False))
    os.chmod(tmp, 0o600)   # guarda o token
    tmp.replace(ARQUIVO)


if __name__ == "__main__":
    c = ler()
    print(f"config: {ARQUIVO}")
    print(f"  porta         : {c['porta']}")
    print(f"  token         : {c['token'][:6]}… ({len(c['token'])} chars)")
    print(f"  exigir_token  : {c['exigir_token']}")
    t = c["tempo"]
    print(f"  tempo         : {t['nome'] or '—'} ({t['lat']}, {t['lon']})")
    print(f"  legados       : {c['hostnames_legados'] or '—'}")
