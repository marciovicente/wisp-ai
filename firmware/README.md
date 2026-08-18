# Firmware — Waveshare ESP32-S3-Touch-AMOLED-2.16

The board is optional. The menu bar app works on its own; this is for putting
the mascot on a little screen on your desk.

**If you only want to flash it, you do not need any of this.** Run `./flash.sh`
from the repository root: it pulls a prebuilt binary and writes it with tools
that come from PyPI, no ESP-IDF involved. This document is for changing the
firmware.

## Hardware

**ESP32-S3-Touch-AMOLED-2.16** — ESP32-S3R8 (8MB octal PSRAM, 16MB flash),
CO5300 AMOLED 480×480 over QSPI, CST9217 touch, QMI8658 accelerometer, AXP2101
power management, native USB.

Power: USB-C, or a 3.7V lithium battery on the 2-pin MX1.25 connector.

> **Polarity.** The connector is keyed and only goes in one way, but battery
> manufacturers do not agree on which wire goes to which pin. Check the silk
> screen for `+` and confirm the red wire lands on it **before** plugging it
> in. Reversed, it damages both the board and the cell.

## Prerequisites

ESP-IDF **v5.5 or newer** — Waveshare's BSP declares `idf: ">=5.5"` and will
not build on 5.4.

```bash
git clone -b v5.5 --recursive https://github.com/espressif/esp-idf.git ~/esp/esp-idf
~/esp/esp-idf/install.sh esp32s3
source ~/esp/esp-idf/export.sh
```

## Before flashing: keep the factory firmware

The board ships with a Waveshare demo you cannot get back afterwards. The
`./flash.sh` flow offers to save it for you; by hand it is:

```bash
esptool.py --chip esp32s3 -p /dev/cu.usbmodem* read_flash 0 0x1000000 backup/waveshare-factory-16MB.bin
```

Use the default speed. The board's USB is native (there is no bridge chip), so
`--baud 921600` buys nothing and provokes failures mid-read.

## Build and flash

```bash
cd firmware
idf.py set-target esp32s3
idf.py build
idf.py -p /dev/cu.usbmodem* flash monitor
```

With a local build present in `firmware/build/`, `./flash.sh` uses yours
instead of downloading a release — which is the fast path while developing.

If the board does not show up under `/dev/cu.*`, check that the cable carries
data — plenty of USB-C cables only charge. If it does not enumerate, there is
nothing to flash.

## Provisioning WiFi and the token

Credentials never live in the source: they go straight into the NVS partition.

```bash
/usr/bin/python3 ../bridge/provision_wifi.py
```

It asks for the network, the password (which does not appear on screen) and
writes the token the bridge requires alongside them. This does not need
ESP-IDF either. After that you can close the network:

```json
// ~/.wisp/config.json
"require_token": true
```

The board only does **2.4GHz**. A 5GHz-only network will not connect, correct
password or not.

## How the board finds the Mac

It looks for the `_wisp._tcp` mDNS service, which the bridge publishes. That
does not depend on the machine's name — macOS renames the computer on its own
when it detects a conflict on the network, and a board pinned to a hostname is
orphaned when that happens. As a fallback it still tries the hostname stored
in NVS.

## Use

- **Swipe sideways** — usage and limits panel
- **Turn the device** — the image rotates with it, via the accelerometer
- **No active session** — clock and weather forecast

## Implementation notes

Two non-obvious decisions, measured rather than assumed:

**16-line buffer.** `bsp_display_start()` hardcodes 50 lines, which makes the
SPI driver allocate a 48KB bounce buffer in internal RAM. Without WiFi it
fits; with the network stack up there is little left and it turns into
`ESP_ERR_NO_MEM` in the middle of a draw. At 16 lines the ceiling drops to
15KB and the screen draws again with the network up — a stable 66fps.

**Rotation in hardware.** LVGL's `lv_display_set_rotation()` requires DIRECT
or FULL render mode, and we run PARTIAL because of the item above — it only
logged a warning and rotated nothing. Rotation uses the panel's MADCTL
instead, which costs zero CPU. Touch has to rotate with it, or taps land in
the wrong place.
