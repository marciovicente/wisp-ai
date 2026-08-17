"""
Anuncia o bridge na rede local com nomes que o BRIDGE controla.

POR QUE ISTO EXISTE
-------------------
A placa achava o Mac resolvendo o hostname (`Marcios-MacBook-Pro-6.local`).
Isso quebrou: o macOS deriva o LocalHostName do ComputerName e acrescenta um
sufixo numérico sempre que detecta conflito na rede. Neste Mac, com muitas
interfaces se anunciando (anpi0-2, en1, en2, en4-7), isso já aconteceu 7 vezes.
Quando ele virou "-7", o nome gravado na NVS deixou de existir e o firmware
ficou preso em "connecting" — WiFi de pé, bridge de pé, e mesmo assim órfão.

Fixar o LocalHostName resolveria hoje e quebraria de novo no próximo conflito,
além de mexer em configuração do sistema. Aqui a placa passa a procurar por
nomes que nascem e morrem com o bridge:

    _fagulha._tcp        serviço; o firmware novo procura por ele e não depende
                         de hostname nenhum
    fagulha.local        nome fixo nosso, para provisionar daqui pra frente
    <LEGADO>.local       o hostname antigo, republicado como alias — é o que
                         faz a placa já gravada voltar a funcionar sem reflash

Tudo com `dns-sd`, que já vem no macOS. Nada a instalar, nada a configurar.

O IP é reconferido de tempos em tempos: se o DHCP trocar o endereço do Mac, os
registros são refeitos sozinhos (foi o que aconteceu: .106 -> .142).
"""


# Anotacoes preguicosas: deixa o modulo rodar no Python 3.9 do sistema
# (/usr/bin/python3), que nunca muda e nao depende do asdf. Sem isto,
# `str | None` e avaliado na definicao da funcao e explode no 3.9.
from __future__ import annotations

import atexit
import shutil
import socket
import subprocess
import sys
import threading
import time

SERVICO = "_fagulha._tcp"
INSTANCIA = "Fagulha Bridge"

# Nome próprio, para provisionar daqui pra frente.
NOME_FIXO = "fagulha.local"

def _legados() -> list:
    """
    Hostnames antigos a republicar, vindos do config do usuário.

    Serve pra quem já tem placa gravada com um nome que o macOS aposentou:
    republicando o nome velho, a placa volta a achar o bridge sem reflash.
    Vazio por padrão — isto é remendo de migração, não configuração normal.
    """
    try:
        import config
        return list(config.ler().get("hostnames_legados") or [])
    except Exception:
        return []

# De quanto em quanto tempo reconferimos o IP local.
INTERVALO_IP_S = 30.0

_procs: list[subprocess.Popen] = []
_ip_atual = ""
_lock = threading.Lock()
_parar = threading.Event()


def _ip_local() -> str:
    """
    IP da interface que realmente sai para a rede.

    Um socket UDP "conectado" não manda pacote nenhum — só faz o kernel
    escolher a rota e preencher o endereço de origem. Assim não dependemos
    de adivinhar o nome da interface (en0 hoje, en7 amanhã).
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return ""
    finally:
        s.close()


def _spawn(args: list[str]) -> bool:
    try:
        _procs.append(subprocess.Popen(
            args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        return True
    except OSError as exc:
        print(f"[anuncio] falhou: {exc}", file=sys.stderr)
        return False


def _derrubar() -> None:
    for p in _procs:
        if p.poll() is None:
            p.terminate()
    for p in _procs:
        try:
            p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            p.kill()
    _procs.clear()


def _publicar(dns_sd: str, porta: int, ip: str) -> None:
    """(Re)publica tudo para o IP dado. Assume o lock tomado."""
    _derrubar()

    # Serviço. Sem -P: o próprio macOS mantém o endereço em dia, então este
    # aqui nem depende do IP que calculamos.
    _spawn([dns_sd, "-R", INSTANCIA, SERVICO, "local", str(porta)])

    # Registros de host. O `-P` é o único jeito pelo dns-sd de publicar um
    # nome com endereço escolhido; o serviço que vem junto é só o carona.
    legados = _legados()
    if ip:
        for i, nome in enumerate([NOME_FIXO] + legados):
            _spawn([dns_sd, "-P", f"FagulhaHost{i}", SERVICO, "local",
                    str(porta), nome, ip])

    nomes = ", ".join([SERVICO, NOME_FIXO] + legados)
    print(f"[anuncio] {ip or '?'}:{porta} como {nomes}")


def _vigia(dns_sd: str, porta: int) -> None:
    global _ip_atual
    while not _parar.wait(INTERVALO_IP_S):
        ip = _ip_local()
        if not ip or ip == _ip_atual:
            continue
        with _lock:
            print(f"[anuncio] IP mudou {_ip_atual or '?'} -> {ip}, republicando")
            _ip_atual = ip
            _publicar(dns_sd, porta, ip)


def iniciar(porta: int) -> bool:
    """Publica os nomes. Devolve False se não deu — nunca levanta."""
    global _ip_atual

    dns_sd = shutil.which("dns-sd")
    if not dns_sd:
        print("[anuncio] dns-sd nao encontrado — a placa vai depender do "
              "hostname gravado na NVS", file=sys.stderr)
        return False

    with _lock:
        if _procs:
            return True
        _ip_atual = _ip_local()
        _publicar(dns_sd, porta, _ip_atual)

    threading.Thread(target=_vigia, args=(dns_sd, porta), daemon=True).start()
    atexit.register(parar)
    return True


def parar() -> None:
    """Os registros vivem enquanto os processos do dns-sd viverem."""
    _parar.set()
    with _lock:
        _derrubar()


def ativo() -> bool:
    return any(p.poll() is None for p in _procs)


if __name__ == "__main__":
    if not iniciar(4666):
        raise SystemExit(1)
    print("anunciando. Ctrl-C para parar.")
    try:
        while ativo():
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        parar()
