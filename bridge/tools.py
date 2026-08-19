"""
Gets esptool and the NVS generator without ESP-IDF installed.

WHY THIS EXISTS
---------------
Flashing the board used to require cloning ESP-IDF: ~2GB, fifteen minutes and
a whole compiler toolchain — for someone who only wants to write a finished
binary. It is the project's biggest source of friction and it does not need to
exist: the two tools flashing depends on are on PyPI and compile nothing.

    esptool                        talks to the bootloader over USB
    esp-idf-nvs-partition-gen      turns WiFi+token into an NVS binary

They go into a venv of ours under ~/.wisp/tools, built once and reused. We do
not touch the system Python, nor your pyenv/asdf, and we install nothing
globally — uninstalling is deleting the folder.

Anyone who already has ESP-IDF exported loses nothing: the venv is small
(~15MB) and independent of the IDF version, so the result is the same either
way.
"""

import json
import subprocess
import sys
import venv
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FOLDER = Path.home() / ".wisp" / "tools"
PYTHON = FOLDER / "bin" / "python"

# esptool 4, not 5, for a concrete reason: macOS 15 still ships Python 3.9.6
# and esptool 5 requires 3.10+. Pinned to the major because 5 renamed the
# subcommands (write_flash -> write-flash) and would break flashing silently.
# With 4 the system requirement becomes ZERO: the Python already on the Mac
# does the job.
PACKAGES = ["esptool>=4.8,<5", "esp-idf-nvs-partition-gen"]

# The system Python, deliberately: the venv has to survive you switching
# versions in asdf/pyenv, and /usr/bin/python3 does not move.
BASE = "/usr/bin/python3"


def _has_packages() -> bool:
    if not PYTHON.exists():
        return False
    try:
        subprocess.run([str(PYTHON), "-c", "import esptool, esp_idf_nvs_partition_gen"],
                       check=True, capture_output=True)
        return True
    except (subprocess.CalledProcessError, OSError):
        return False


def ensure(quiet: bool = False) -> Path:
    """Returns the Python that has the tools, building the venv if needed."""
    if _has_packages():
        return PYTHON

    if not quiet:
        print(f"==> preparing the flashing tools in {FOLDER}")
        print("    (once only, ~15MB, nothing global)")

    base = BASE if Path(BASE).exists() else sys.executable
    FOLDER.parent.mkdir(parents=True, exist_ok=True)
    if not PYTHON.exists():
        venv.EnvBuilder(with_pip=True, clear=True).create(FOLDER)

    r = subprocess.run([str(PYTHON), "-m", "pip", "install", "--quiet",
                        "--disable-pip-version-check", *PACKAGES],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("could not install esptool/nvs-partition-gen.\n"
                 f"   base: {base}\n"
                 f"   {r.stderr.strip().splitlines()[-1] if r.stderr.strip() else ''}\n"
                 "   No network? Try again with internet.")
    if not quiet:
        print("    ok")
    return PYTHON


def chip(folder: "Path | None" = None) -> str:
    """
    Which chip to tell esptool it is talking to.

    Read from the binaries' own flasher_args.json — the file ESP-IDF writes at
    build time — instead of hardcoded. This used to say "esp32s3" in four
    places, which was true while the S3 was the only supported board.

    Getting it wrong is not cosmetic: the S3 is Xtensa and the C6 is RISC-V,
    and an image built for one does not run on the other. Passing the chip
    explicitly is what makes esptool REFUSE the mismatch instead of writing a
    binary that boot-loops.

    Falls back to "auto" (esptool asks the chip itself) when there is nothing
    to read from — writing NVS, for instance, which is data and identical on
    every target.
    """
    candidates = []
    if folder:
        candidates.append(Path(folder) / "flasher_args.json")
    candidates.append(ROOT / "firmware" / "build" / "flasher_args.json")
    for c in candidates:
        try:
            value = json.loads(c.read_text())["extra_esptool_args"]["chip"]
        except (OSError, KeyError, ValueError):
            continue
        if value:
            return value
    return "auto"


def esptool(*args: str, **kw) -> subprocess.CompletedProcess:
    return subprocess.run([str(ensure(quiet=True)), "-m", "esptool", *args], **kw)


def nvs_gen(*args: str, **kw) -> subprocess.CompletedProcess:
    return subprocess.run([str(ensure(quiet=True)), "-m",
                           "esp_idf_nvs_partition_gen", *args], **kw)


def port(interactive: bool = True) -> str:
    """
    The board has native USB (no bridge chip), so it shows up as cu.usbmodem*.
    A charge-only cable does not enumerate — the most common cause of "I could
    not find the board".
    """
    found = sorted(Path("/dev").glob("cu.usbmodem*"))
    if not found:
        sys.exit("no cu.usbmodem* port found.\n"
                 "   - is the board plugged in?\n"
                 "   - does the cable carry data? Plenty of USB-C cables only charge.")
    if len(found) == 1:
        return str(found[0])
    if not interactive:
        return str(found[0])
    print("more than one board connected:")
    for i, c in enumerate(found):
        print(f"  [{i}] {c}")
    choice = input("which one? [0] ").strip() or "0"
    return str(found[int(choice)])


if __name__ == "__main__":
    p = ensure()
    print(f"\npython : {p}")
    esptool("version")
