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


def ask(port: str) -> dict:
    print(f"board   : {port}\n")

    ssid = input("WiFi SSID: ").strip()
    if not ssid:
        sys.exit("empty SSID.")
    password = getpass("password (not shown): ")

    host = input(f"bridge host [{DEFAULT_HOST}]: ").strip() or DEFAULT_HOST

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
    print("\nreminder: the ESP32-S3 only connects to 2.4GHz. If your network is "
          "5GHz-only, the connection fails even with the right password.")

    tools.ensure()

    tmp = Path(tempfile.mkdtemp(prefix="wisp-nvs-"))
    os.chmod(tmp, 0o700)
    csv, binary = tmp / "nvs.csv", tmp / "nvs.bin"
    try:
        # The generator requires the namespace line before the keys.
        lines = ["key,type,encoding,value", f"{NAMESPACE},namespace,,"]
        lines += [f"{k},data,string,{v}" for k, v in data.items()]
        csv.write_text("\n".join(lines) + "\n")
        os.chmod(csv, 0o600)

        print("\ngenerating the NVS partition…")
        tools.nvs_gen("generate", str(csv), str(binary), NVS_SIZE,
                      check=True, capture_output=True, text=True)

        print(f"writing at {NVS_OFFSET}…")
        tools.esptool("--chip", "esp32s3", "--port", port, "--after", "hard_reset",
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
