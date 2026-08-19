"""
Flashes the Wisp firmware onto the Waveshare board, from scratch, in one
command.

    ./flash.sh

WHY THIS EXISTS
---------------
Flashing used to require ESP-IDF: ~2GB and fifteen minutes of toolchain for
someone who only wants a finished binary on the board. Nothing is compiled
here — the binaries come from the GitHub release (or from your local build, if
you have one) and go into flash through an esptool pulled from PyPI. The
system requirement is the Python that already ships with macOS.

What it does, in order:
    1. finds the board on USB
    2. offers to save the factory firmware (gone forever afterwards)
    3. writes bootloader, partition table, app and assets
    4. asks for WiFi and writes it alongside the bridge token

Anyone who wants to change the firmware still builds it with ESP-IDF the
normal way; see firmware/README.md.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import provision_wifi  # noqa: E402
import tools  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "firmware" / "build"

# Where to look for a prebuilt binary when there is no local build. It comes
# from the git remote when you cloned — so a fork flashes its own firmware
# without anybody having to edit this.
DEFAULT_REPO = "marciovicente/wisp-ai"


def repo() -> str:
    if env := os.environ.get("WISP_REPO"):
        return env
    try:
        url = subprocess.check_output(["git", "-C", str(ROOT), "remote", "get-url", "origin"],
                                      text=True, stderr=subprocess.DEVNULL).strip()
        # git@github.com:user/repo.git  or  https://github.com/user/repo.git
        slug = url.split("github.com")[-1].lstrip(":/").removesuffix(".git")
        if slug.count("/") == 1:
            return slug
    except (subprocess.CalledProcessError, FileNotFoundError, IndexError):
        pass
    return DEFAULT_REPO


# ————————————————————————————————————————————— where the binaries come from

def from_local_build() -> Path | None:
    args = BUILD / "flasher_args.json"
    return BUILD if args.exists() else None


def from_release(dest: Path) -> Path:
    slug = repo()
    url = f"https://github.com/{slug}/releases/latest/download/wisp-firmware.zip"
    print(f"==> downloading the firmware from {slug}")
    zip_path = dest / "wisp-firmware.zip"
    try:
        with urllib.request.urlopen(url, timeout=60) as r, open(zip_path, "wb") as f:
            shutil.copyfileobj(r, f)
    except urllib.error.HTTPError as e:
        sys.exit(f"could not find a prebuilt firmware ({e.code} at {url}).\n"
                 "   If you are the one developing it: build with ESP-IDF\n"
                 "   (see firmware/README.md) and run this again — it uses\n"
                 "   firmware/build/ whenever it exists.")
    except urllib.error.URLError as e:
        sys.exit(f"download failed: {e.reason}")

    with zipfile.ZipFile(zip_path) as z:
        z.extractall(dest)
    args = next(dest.rglob("flasher_args.json"), None)
    if not args:
        sys.exit("the release zip has no flasher_args.json — broken release.")
    return args.parent


def files(folder: Path) -> list:
    """
    Reads the offsets from the flasher_args.json ESP-IDF generates itself.
    Hardcoding the addresses here would be copying a truth that already exists
    — and one that changes on its own when partitions.csv changes.
    """
    data = json.loads((folder / "flasher_args.json").read_text())
    out = []
    for offset, rel in sorted(data["flash_files"].items(), key=lambda kv: int(kv[0], 16)):
        p = folder / rel
        if not p.exists():                    # the release zip comes flattened
            p = folder / Path(rel).name
        if not p.exists():
            sys.exit(f"missing {rel} in {folder}")
        out.append((offset, p))
    return out


# ——————————————————————————————————————————————————————————————————— steps

def save_factory_firmware(port: str, folder: Path) -> None:
    """
    The board ships with a Waveshare demo nobody gets back afterwards: it is
    not distributed anywhere. We ask BEFORE writing anything, because asking
    later is useless.
    """
    dest = ROOT / "backup" / "waveshare-factory-16MB.bin"
    if dest.exists():
        print(f"==> factory backup already exists ({dest.name}), skipping")
        return

    print("\nThe board ships with a Waveshare demo you cannot get back afterwards.")
    print("Saving it takes ~3 minutes and 16MB of disk.")
    if (input("save the factory firmware before flashing? [Y/n] ").strip() or "Y")[0] not in "YySs":
        print("   skipped.")
        return

    dest.parent.mkdir(parents=True, exist_ok=True)
    print("==> reading 16MB of flash (do not unplug)")
    # Default speed on purpose: the board's USB is native, --baud 921600 buys
    # nothing and provokes failures mid-read.
    r = tools.esptool("--chip", tools.chip(folder), "--port", port,
                      "read_flash", "0", "0x1000000", str(dest))
    if r.returncode != 0:
        dest.unlink(missing_ok=True)
        sys.exit("the read failed — nothing was written to the board.")
    print(f"    saved to {dest}")


def write_firmware(port: str, folder: Path, erase: bool) -> None:
    chip = tools.chip(folder)
    if erase:
        print("==> erasing the whole flash")
        tools.esptool("--chip", chip, "--port", port, "erase_flash", check=True)

    parts = files(folder)
    print(f"==> writing {len(parts)} partitions to {chip}")
    args = []
    for offset, path in parts:
        print(f"    {offset:>10}  {path.name}")
        args += [offset, str(path)]

    r = tools.esptool("--chip", chip, "--port", port,
                      "--before", "default_reset", "--after", "hard_reset",
                      "write_flash", "--flash_mode", "dio",
                      "--flash_freq", "80m", "--flash_size", "16MB", *args)
    if r.returncode != 0:
        sys.exit("flashing failed. If the board is unresponsive, hold BOOT and\n"
                 "   replug USB to force download mode.")


def main() -> int:
    ap = argparse.ArgumentParser(description="Flashes Wisp onto the Waveshare board.")
    ap.add_argument("--erase", action="store_true",
                    help="erase the flash first (use if the board is stuck in a boot loop)")
    ap.add_argument("--no-wifi", action="store_true",
                    help="firmware only; provision later")
    ap.add_argument("--no-backup", action="store_true",
                    help="do not save the factory firmware")
    args = ap.parse_args()

    if sys.platform != "darwin":
        print("warning: tested on macOS. On Linux the port is usually /dev/ttyACM0.")

    tools.ensure()
    port = tools.port()
    print(f"board   : {port}")

    local = from_local_build()
    tmp = None
    if local:
        print(f"firmware: local build ({local.relative_to(ROOT)})")
        folder = local
    else:
        tmp = Path(tempfile.mkdtemp(prefix="wisp-fw-"))
        folder = from_release(tmp)

    try:
        if not args.no_backup:
            save_factory_firmware(port, folder)
        write_firmware(port, folder, args.erase)
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)

    print("\n==> firmware written.")

    if args.no_wifi:
        print("   To provision later: /usr/bin/python3 bridge/provision_wifi.py")
        return 0

    print("\nNow the WiFi. The board needs it to find the bridge on your Mac.")
    return provision_wifi.write(port, provision_wifi.ask(port))


if __name__ == "__main__":
    raise SystemExit(main())
