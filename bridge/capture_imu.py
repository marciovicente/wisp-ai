"""
Captures accelerometer readings over serial, to calibrate the mapping from
axes to screen rotation.

    python3 bridge/capture_imu.py [seconds]

Turn the board through all four positions while it runs.
"""

import os
import re
import select
import sys
import termios
import time
from collections import Counter

PORT = "/dev/cu.usbmodem101"
LINE = re.compile(r"accel x=(-?[\d.]+) y=(-?[\d.]+) z=(-?[\d.]+)")


def open_port():
    for _ in range(6):
        try:
            return os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        except OSError:
            time.sleep(1)
    sys.exit(f"could not open {PORT} (port busy?)")


def main() -> int:
    dur = int(sys.argv[1]) if len(sys.argv) > 1 else 45
    fd = open_port()
    a = termios.tcgetattr(fd)
    a[4] = a[5] = termios.B115200
    a[0] = termios.IGNPAR
    a[1] = 0
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[3] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIFLUSH)

    print(f"capturing {dur}s — turn the board through all 4 positions", flush=True)
    buf, end = b"", time.time() + dur
    while time.time() < end:
        if select.select([fd], [], [], 0.3)[0]:
            try:
                c = os.read(fd, 4096)
            except OSError:
                break
            if c:
                buf += c
    os.close(fd)

    readings = []
    for line in buf.decode("utf-8", "replace").splitlines():
        if m := LINE.search(line):
            readings.append(tuple(float(g) for g in m.groups()))

    if not readings:
        print("no readings — is the board logging? is this the new firmware?")
        return 1

    # Group by dominant axis: that is what defines the orientation.
    groups = Counter()
    sample = {}
    for x, y, z in readings:
        if abs(x) >= abs(y) and abs(x) >= abs(z):
            k = "+X" if x > 0 else "-X"
        elif abs(y) >= abs(z):
            k = "+Y" if y > 0 else "-Y"
        else:
            k = "+Z" if z > 0 else "-Z"
        groups[k] += 1
        sample.setdefault(k, (x, y, z))

    print(f"\n{len(readings)} readings, {len(groups)} distinct positions:\n")
    for k, n in groups.most_common():
        x, y, z = sample[k]
        print(f"  gravity on {k:>2}  ({n:>3} readings)   x={x:6.1f} y={y:6.1f} z={z:6.1f}")

    if len(groups) < 3:
        print("\n(fewer than 3 positions — turn more slowly, holding each one)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
