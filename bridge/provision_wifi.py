"""
Writes WiFi, token and the bridge address straight into the board's NVS
partition.

Why this way and not an on-screen portal: no password ends up in the source, in
git, or in a conversation. It is typed here in your terminal (hidden), turned
into an NVS binary by an official Espressif tool, flashed, and the temporary
file is deleted — including when the script blows up halfway.

    /usr/bin/python3 bridge/provision_wifi.py

It does not require ESP-IDF: the tools come from PyPI into a venv of ours,
built the first time. See bridge/tools.py.
"""

from __future__ import annotations

import csv as _csv
import os
import shutil
import subprocess
import sys
import tempfile
from getpass import getpass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tools  # noqa: E402

# From the firmware's partitions.csv: nvs at 0x9000, size 0x6000 (24KB).
NVS_OFFSET = "0x9000"
NVS_SIZE = "0x6000"
NAMESPACE = "wisp"

# The bridge publishes this name over mDNS, and it is born and dies with the
# bridge — unlike the Mac's hostname, which macOS renumbers on its own when it
# detects a conflict on the network, leaving the board orphaned. It is the
# default on purpose.
DEFAULT_HOST = "wisp.local"


def _prompt(question: str) -> str:
    """
    Reads one answer, from the terminal even when stdin is not one.

    Run from inside a tool that pipes stdin — an editor's task runner, an agent
    shell — `input()` gets EOF immediately and the script dies with EOFError
    before asking anything. install.sh already deals with this by reading from
    /dev/tty; this is the same trick, and getpass() below does it on its own.

    When there is no terminal at all (CI, cron) there is nothing to ask, and
    saying so beats an EOFError traceback.
    """
    if sys.stdin.isatty():
        return input(question).strip()
    try:
        with open("/dev/tty", "r+") as tty:
            tty.write(question)
            tty.flush()
            answer = tty.readline()
    except OSError:
        sys.exit("no terminal to ask on: run this from a terminal, "
                 "or set the WiFi with ./flash.sh instead.")
    if not answer:
        sys.exit("no answer (end of input).")
    return answer.strip()


def ask(port: str) -> dict:
    print(f"board   : {port}\n")

    ssid = _prompt("WiFi SSID: ")
    if not ssid:
        sys.exit("empty SSID.")
    # DUAS VEZES, e nao por burocracia.
    #
    # A senha e digitada as cegas e vai direto para a NVS; um caractere errado
    # nao aparece em lugar nenhum. O aparelho associa ao AP normalmente e falha
    # so no handshake WPA, e na tela isso se parece com qualquer outro problema
    # de rede: "connecting" para sempre. Custou uma sessao inteira de debug
    # descobrir que era isso — o reason 15 do driver e um dos poucos sinais, e
    # ele nao chega a quem esta olhando a telinha.
    for tentativa in range(3):
        password = getpass("password (not shown): ")
        if password == getpass("password again: "):
            break
        print("  the two do not match; try again.")
    else:
        sys.exit("password typed differently three times.")

    host = _prompt(f"bridge host [{DEFAULT_HOST}]: ") or DEFAULT_HOST

    if len(ssid) > 32 or len(password) > 64:
        sys.exit("SSID (max 32) or password (max 64) too long for WiFi.")

    # Token: the same secret the bridge demands from anything arriving over the
    # network. It comes from the user's config, generated on its own on first
    # use — nobody types anything. Writing it here is what allows closing the
    # network: with the board knowing the token, `require_token` can go true
    # and the bridge stops answering strangers.
    import config as _cfg
    token = _cfg.read()["token"]

    return {"ssid": ssid, "pass": password, "host": host, "token": token}


def write(port: str, data: dict) -> int:
    # The board only does 2.4GHz. We cannot detect the band from here, so we
    # warn instead.
    print("\nreminder: the board only connects to 2.4GHz (true of both the S3 and "
          "the C6). If your network is 5GHz-only, the connection fails even "
          "with the right password.")

    tools.ensure()

    tmp = Path(tempfile.mkdtemp(prefix="wisp-nvs-"))
    os.chmod(tmp, 0o700)
    csv, binary = tmp / "nvs.csv", tmp / "nvs.bin"
    try:
        # QUOTING PELO MODULO csv, nao por interpolacao.
        #
        # Isto era montado com f"{k},data,string,{v}". Uma senha com virgula
        # saia partida em duas colunas, e o gerador (que le com csv.DictReader)
        # engolia so o primeiro pedaco: a placa recebia uma senha diferente da
        # digitada, sem erro nenhum no caminho. Aspas na senha davam no mesmo.
        # O writer do modulo csv cita e escapa o que precisa, e o DictReader do
        # outro lado desfaz — os dois falam o mesmo dialeto.
        with open(csv, "w", newline="", encoding="utf-8") as fh:
            w = _csv.writer(fh)
            w.writerow(["key", "type", "encoding", "value"])
            # O gerador exige a linha de namespace antes das chaves.
            w.writerow([NAMESPACE, "namespace", "", ""])
            for k, v in data.items():
                w.writerow([k, "data", "string", v])
        os.chmod(csv, 0o600)

        print("\ngenerating the NVS partition…")
        tools.nvs_gen("generate", str(csv), str(binary), NVS_SIZE,
                      check=True, capture_output=True, text=True)

        print(f"writing at {NVS_OFFSET}…")
        tools.esptool("--chip", tools.chip(), "--port", port, "--after", "hard_reset",
                      "write_flash", NVS_OFFSET, str(binary), check=True)
    except subprocess.CalledProcessError as exc:
        out = (exc.stderr or exc.stdout or "").strip()
        print(f"\nfailed: {out or exc}", file=sys.stderr)
        return 1
    finally:
        # The password was on disk; make it go away even if something above
        # exploded.
        shutil.rmtree(tmp, ignore_errors=True)

    print("\ndone. The board restarts on its own and looks for the bridge at "
          f"http://{data['host']}:4666/state")
    return 0


def main() -> int:
    port = tools.port()
    return write(port, ask(port))


if __name__ == "__main__":
    raise SystemExit(main())
