"""
Captura leituras do acelerômetro pela serial, para calibrar o mapeamento
de eixos -> rotação da tela.

    python3 bridge/capture_imu.py [segundos]

Gire a placa pelas quatro posições enquanto roda.
"""

import os
import re
import select
import sys
import termios
import time
from collections import Counter

PORT = "/dev/cu.usbmodem101"
LINHA = re.compile(r"accel x=(-?[\d.]+) y=(-?[\d.]+) z=(-?[\d.]+)")


def abrir():
    for _ in range(6):
        try:
            return os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        except OSError:
            time.sleep(1)
    sys.exit(f"não consegui abrir {PORT} (porta ocupada?)")


def main() -> int:
    dur = int(sys.argv[1]) if len(sys.argv) > 1 else 45
    fd = abrir()
    a = termios.tcgetattr(fd)
    a[4] = a[5] = termios.B115200
    a[0] = termios.IGNPAR
    a[1] = 0
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[3] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIFLUSH)

    print(f"capturando {dur}s — gire a placa pelas 4 posições", flush=True)
    buf, fim = b"", time.time() + dur
    while time.time() < fim:
        if select.select([fd], [], [], 0.3)[0]:
            try:
                c = os.read(fd, 4096)
            except OSError:
                break
            if c:
                buf += c
    os.close(fd)

    leituras = []
    for linha in buf.decode("utf-8", "replace").splitlines():
        if m := LINHA.search(linha):
            leituras.append(tuple(float(g) for g in m.groups()))

    if not leituras:
        print("nenhuma leitura — a placa está logando? o firmware é o novo?")
        return 1

    # Agrupa por eixo dominante: é isso que define a orientação.
    grupos = Counter()
    exemplo = {}
    for x, y, z in leituras:
        if abs(x) >= abs(y) and abs(x) >= abs(z):
            k = "+X" if x > 0 else "-X"
        elif abs(y) >= abs(z):
            k = "+Y" if y > 0 else "-Y"
        else:
            k = "+Z" if z > 0 else "-Z"
        grupos[k] += 1
        exemplo.setdefault(k, (x, y, z))

    print(f"\n{len(leituras)} leituras, {len(grupos)} posições distintas:\n")
    for k, n in grupos.most_common():
        x, y, z = exemplo[k]
        print(f"  gravidade em {k:>2}  ({n:>3} leituras)   x={x:6.1f} y={y:6.1f} z={z:6.1f}")

    if len(grupos) < 3:
        print("\n(menos de 3 posições — gire mais devagar, segurando cada uma)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
