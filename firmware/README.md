# Firmware — Waveshare ESP32-S3-Touch-AMOLED-2.16 (and the C6 sister board)

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
~/esp/esp-idf/install.sh esp32s3      # esp32c6 for the C6 board
source ~/esp/esp-idf/export.sh
```

The asset generator imports `pypng` from inside IDF's own venv, and it is not
part of IDF's requirements. Without it the build stops at "Build assets binary"
with `ModuleNotFoundError: No module named 'png'`:

```bash
~/.espressif/python_env/idf5.5_py3.9_env/bin/python -m pip install pypng
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


## The C6 board

There is a sister board — **ESP32-C6-Touch-AMOLED-2.16** — with the same
panel, touch, IMU and PMIC, but a different MCU. This firmware builds for it
too:

```bash
idf.py set-target esp32c6
idf.py build
```

`./flash.sh` picks the chip up from the build's own `flasher_args.json`, so
flashing is the same command. What it will NOT do is download a release: the
published binary is Xtensa and the C6 is RISC-V, so on that board you build
locally or you get nothing.

### What differs, and why it is not just a recompile

**No PSRAM.** The C6 has no interface for it. 512KB of SRAM is all there is,
shared by WiFi, lwIP, the LVGL buffer and the SPI DMA. That inverts one
decision: on the S3 the LVGL buffer could live in PSRAM and every flush paid
for a bounce buffer in internal RAM, which is what pushed `ALTURA_BUFFER` down
to 4 lines. Here the buffer is already where DMA reads, so it is 40 lines
(38KB, against 127KB of internal RAM free with the display up) and 12 flushes
per frame instead of 120.

**No BSP.** `waveshare/esp32_s3_touch_amoled_2_16` declares
`targets: [esp32s3]` and has no C6 counterpart in the registry.
`components/bsp_c6_amoled_216` reimplements the nine symbols this firmware
actually uses — same names, same signatures — so `main.c` and `ui.c` compile
unchanged. It registers itself empty on any other target, and the S3 BSP is
gated behind `rules: if target == esp32s3`, so an S3 build is byte-for-byte
what it was.

**The panel has no reset pin and no backlight pin.** Power for the AMOLED is
the AXP2101's ALDO3 rail, and "resetting the panel" means cycling it. Skip that
and the screen stays black with the firmware happily running — the classic
symptom of a bad port on this board.

**Less flash-mapping address space.** `esp_mmap_assets` maps the whole
partition and checks `spi_flash_mmap_get_free_pages()` first. The 7MB
`storage` partition fails that check on the C6; the firmware survives (it falls
back to the vector mascot) but the artwork never shows up. `partitions.esp32c6.csv`
uses 2MB, which the 1.3MB of mascots fit into with room to spare.

**Use `esp_lcd_co5300`, not `esp_lcd_sh8601`.** Waveshare's own C6 example uses
the sh8601 driver, and it works — but it answers `ESP_ERR_NOT_SUPPORTED` to
`swap_xy`, and the accelerometer rotation here is built on
`esp_lcd_panel_swap_xy()` + `mirror()`. With co5300 the S3's init table works
byte for byte, MADCTL base `0xA0` included — which matters, because
`aplicar_rotacao()` is calibrated against exactly that value.

**Two `#if` in main.c beyond the buffer**: the LVGL task stack cannot ask for
PSRAM, and the buttons move to GPIO 9 (BOOT) and 18 (KEY). GPIO 0, the left
button on the S3, is the display's QSPI clock on the C6 — configuring it as an
input would fight the panel.

### Editing sdkconfig

`sdkconfig.defaults` holds what both boards share; `sdkconfig.defaults.esp32s3`
and `sdkconfig.defaults.esp32c6` hold the rest. ESP-IDF applies the pair
automatically. The split is not cosmetic: `CONFIG_SPIRAM` and the
`ESP32S3_*_CACHE` options do not exist in the C6's Kconfig at all.

If you edit any of those files after the first build, **delete `sdkconfig`** —
IDF does not reapply defaults over an existing one, and the change looks like
it was ignored.
