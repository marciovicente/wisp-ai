"""
Grava as credenciais de WiFi direto na partição NVS da placa.

Por que assim, e não um portal na tela: nenhuma senha entra no código-fonte,
no git, nem em conversa. Ela é digitada aqui no seu terminal (oculta), vira
um binário NVS por uma ferramenta oficial do ESP-IDF, é gravada, e o arquivo
temporário é apagado — inclusive se o script falhar no meio.

    python3 bridge/provision_wifi.py

Requer a placa conectada e o ESP-IDF exportado (source ~/esp/esp-idf/export.sh).
"""

import os
import shutil
import subprocess
import sys
import tempfile
from getpass import getpass
from pathlib import Path

# Da partitions.csv do firmware: nvs em 0x9000, tamanho 0x6000 (24KB).
NVS_OFFSET = "0x9000"
NVS_TAMANHO = "0x6000"
NAMESPACE = "fagulha"


def achar_ferramenta() -> Path:
    idf = os.environ.get("IDF_PATH") or str(Path.home() / "esp" / "esp-idf")
    p = Path(idf) / "components" / "nvs_flash" / "nvs_partition_generator" / "nvs_partition_gen.py"
    if not p.exists():
        sys.exit(f"não achei o nvs_partition_gen.py em {p}\n"
                 f"rode primeiro: source ~/esp/esp-idf/export.sh")
    return p


def python_do_idf() -> str:
    """
    O gerador de NVS depende do módulo esp_idf_nvs_partition_gen, que só existe
    no virtualenv do ESP-IDF — não no Python do sistema (nem no do asdf).
    Rodar com o interpretador errado dá "No module named esp_idf_nvs_partition_gen".
    """
    candidatos = []
    if env := os.environ.get("IDF_PYTHON_ENV_PATH"):
        candidatos.append(Path(env) / "bin" / "python")
    # Mais novo primeiro (idf5.5 antes de idf5.4).
    candidatos += sorted((Path.home() / ".espressif" / "python_env").glob("*/bin/python"),
                         reverse=True)
    candidatos.append(Path(sys.executable))

    for c in candidatos:
        if not c.exists():
            continue
        try:
            subprocess.run([str(c), "-c", "import esp_idf_nvs_partition_gen"],
                           check=True, capture_output=True)
            return str(c)
        except subprocess.CalledProcessError:
            continue

    sys.exit("nenhum Python com o módulo esp_idf_nvs_partition_gen.\n"
             "rode: source ~/esp/esp-idf/export.sh   e tente de novo.")


def achar_porta() -> str:
    candidatos = sorted(Path("/dev").glob("cu.usbmodem*"))
    if not candidatos:
        sys.exit("nenhuma porta cu.usbmodem* encontrada — a placa está conectada?")
    if len(candidatos) > 1:
        print("várias portas encontradas:")
        for i, c in enumerate(candidatos):
            print(f"  [{i}] {c}")
        return str(candidatos[int(input("qual? ") or 0)])
    return str(candidatos[0])


def hostname_do_mac() -> str:
    try:
        nome = subprocess.check_output(["scutil", "--get", "LocalHostName"], text=True).strip()
        return f"{nome}.local"
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def main() -> int:
    ferramenta = achar_ferramenta()
    porta = achar_porta()

    print(f"placa   : {porta}")
    padrao_host = hostname_do_mac()

    ssid = input("SSID do WiFi: ").strip()
    if not ssid:
        sys.exit("SSID vazio.")
    senha = getpass("senha (não aparece na tela): ")

    host = input(f"host do bridge [{padrao_host}]: ").strip() or padrao_host
    if not host:
        sys.exit("host vazio — preciso saber onde a placa procura o bridge.")

    if len(ssid) > 32 or len(senha) > 64:
        sys.exit("SSID (máx 32) ou senha (máx 64) longos demais para o WiFi.")

    # Token: o mesmo segredo que o bridge exige de quem vem pela rede. Sai do
    # config do usuário, gerado sozinho no primeiro uso — ninguém digita nada.
    # Gravar aqui é o que permite fechar a rede: com a placa sabendo o token,
    # `exigir_token` pode virar true e o bridge para de responder a estranhos.
    sys.path.insert(0, str(Path(__file__).parent))
    import config as _cfg
    token = _cfg.ler()["token"]

    # A placa só faz 2.4GHz. Não dá pra detectar a banda daqui, então avisamos.
    print("\nlembrete: o ESP32-S3 só conecta em 2.4GHz. Se sua rede for "
          "5GHz-only, a conexão vai falhar mesmo com a senha certa.")

    tmp = Path(tempfile.mkdtemp(prefix="fagulha-nvs-"))
    os.chmod(tmp, 0o700)
    csv, binario = tmp / "nvs.csv", tmp / "nvs.bin"
    try:
        # O gerador exige a linha de namespace antes das chaves.
        csv.write_text(
            "key,type,encoding,value\n"
            f"{NAMESPACE},namespace,,\n"
            f"ssid,data,string,{ssid}\n"
            f"pass,data,string,{senha}\n"
            f"host,data,string,{host}\n"
            f"token,data,string,{token}\n"
        )
        os.chmod(csv, 0o600)

        print("\ngerando partição NVS…")
        subprocess.run(
            [python_do_idf(), str(ferramenta), "generate",
             str(csv), str(binario), NVS_TAMANHO],
            check=True, capture_output=True, text=True,
        )

        print(f"gravando em {NVS_OFFSET}…")
        venv_esptool = Path(__file__).resolve().parent.parent / ".venv" / "bin" / "esptool"
        esptool = str(venv_esptool) if venv_esptool.exists() else "esptool.py"
        subprocess.run(
            [esptool, "--port", porta, "write-flash", NVS_OFFSET, str(binario)],
            check=True,
        )
    except subprocess.CalledProcessError as exc:
        saida = (exc.stderr or exc.stdout or "").strip()
        print(f"\nfalhou: {saida or exc}", file=sys.stderr)
        return 1
    finally:
        # A senha esteve em disco; some com ela mesmo se algo explodiu acima.
        shutil.rmtree(tmp, ignore_errors=True)

    print("\npronto. Reinicie a placa (ou desconecte e reconecte o USB).")
    print(f"A Fagulha vai procurar o bridge em http://{host}:4666/state")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
