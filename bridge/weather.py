"""
Previsão do tempo para a tela ociosa.

Usa a Open-Meteo: gratuita, sem cadastro e sem chave de API — por isso não há
segredo nenhum para guardar aqui. A busca acontece NO MAC, não na placa: o
ESP32 não precisa falar HTTPS nem embutir certificados, e a localização fica
definida em um lugar só.

Só stdlib.
"""


# Anotacoes preguicosas: deixa o modulo rodar no Python 3.9 do sistema
# (/usr/bin/python3), que nunca muda e nao depende do asdf. Sem isto,
# `str | None` e avaliado na definicao da funcao e explode no 3.9.
from __future__ import annotations

import json
import threading
import time
import urllib.error
import urllib.request

import config

ATUALIZA_S = 900        # 15 min: o tempo não muda mais rápido que isso
TIMEOUT_S = 8


def _url() -> str | None:
    """
    Monta a consulta a partir da configuração do usuário.

    A cidade saía cravada aqui (São Paulo). Agora vem do config.json, que a
    descobre sozinho pelo IP no primeiro uso — quem instala não edita nada.
    Sem coordenadas, devolvemos None e o relógio aparece sem temperatura;
    é degradação, não erro.

    `timezone=auto` deixa o próprio Open-Meteo deduzir o fuso das coordenadas,
    o que evita carregarmos uma tabela de fusos só pra isso.
    """
    t = config.ler().get("tempo") or {}
    lat, lon = t.get("lat"), t.get("lon")
    if lat is None or lon is None:
        return None
    return (
        "https://api.open-meteo.com/v1/forecast"
        f"?latitude={lat}&longitude={lon}"
        "&current=temperature_2m,weather_code,is_day"
        "&daily=temperature_2m_max,temperature_2m_min"
        "&timezone=auto"
        "&forecast_days=1"
    )

# WMO weather code -> rótulo curto (cabe na tela) e ASCII (fonte sem acento).
# Tabela oficial: https://open-meteo.com/en/docs
_CODIGOS = [
    ({0}, "clear"),
    ({1, 2}, "partly cloudy"),
    ({3}, "cloudy"),
    ({45, 48}, "fog"),
    ({51, 53, 55, 56, 57}, "drizzle"),
    ({61, 63, 65, 66, 67}, "rain"),
    ({71, 73, 75, 77, 85, 86}, "snow"),
    ({80, 81, 82}, "showers"),
    ({95, 96, 99}, "thunderstorm"),
]


def _rotulo(codigo) -> str:
    for cods, nome in _CODIGOS:
        if codigo in cods:
            return nome
    return "-"


# Codigo WMO -> icone que o firmware sabe desenhar. Mantemos o conjunto
# pequeno de proposito: cada icone e desenhado por primitivas no ESP32, entao
# variedade custa codigo. Condicoes proximas caem no mesmo desenho.
def _icone(codigo, is_day: bool) -> str:
    if codigo in (0, 1):
        return "sun" if is_day else "moon"
    if codigo == 2:
        return "cloudsun" if is_day else "cloudmoon"
    if codigo in (3, 45, 48):
        return "cloud"
    if codigo in (71, 73, 75, 77, 85, 86):
        return "snow"
    if codigo in (95, 96, 99):
        return "storm"
    if codigo is None:
        return "cloud"
    return "rain"


class Tempo:
    """Busca em background e serve o último resultado bom."""

    def __init__(self):
        self._lock = threading.Lock()
        self._dados = None
        self._buscado_em = 0.0
        self._erros = 0

    def iniciar(self) -> None:
        threading.Thread(target=self._laco, daemon=True).start()

    def _laco(self) -> None:
        while True:
            try:
                url = _url()
                if not url:
                    # Sem coordenadas configuradas: dormimos e tentamos de
                    # novo, caso o usuário preencha o config depois.
                    time.sleep(ATUALIZA_S)
                    continue
                with urllib.request.urlopen(url, timeout=TIMEOUT_S) as r:
                    d = json.load(r)
                atual = d.get("current") or {}
                diario = d.get("daily") or {}
                dia = bool(atual.get("is_day", 1))
                novo = {
                    "t": round(atual.get("temperature_2m", 0)),
                    "c": _rotulo(atual.get("weather_code")),
                    "i": _icone(atual.get("weather_code"), dia),
                    "hi": round((diario.get("temperature_2m_max") or [0])[0]),
                    "lo": round((diario.get("temperature_2m_min") or [0])[0]),
                }
                with self._lock:
                    self._dados = novo
                    self._buscado_em = time.time()
                    self._erros = 0
            except (urllib.error.URLError, OSError, ValueError, KeyError) as exc:
                with self._lock:
                    self._erros += 1
                # Mantém o último valor bom: tempo de 15 min atrás ainda é
                # melhor do que tela vazia. Só desiste depois de muita falha.
                if self._erros == 1:
                    print(f"[weather] falhou: {exc}")
            time.sleep(ATUALIZA_S)

    def ler(self) -> dict | None:
        with self._lock:
            if not self._dados:
                return None
            # Depois de ~2h sem atualizar, o dado deixa de ser informação.
            if time.time() - self._buscado_em > 7200:
                return None
            return dict(self._dados)


if __name__ == "__main__":
    t = Tempo()
    t.iniciar()
    for _ in range(20):
        if (d := t.ler()):
            print(f"agora {d['t']}C ({d['c']}) [{d['i']}]   max {d['hi']}C  min {d['lo']}C")
            break
        time.sleep(1)
    else:
        print("não consegui buscar a previsão")
