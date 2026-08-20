# Working on this fork

Read this before touching the firmware. It is the shortest path to not
rediscovering things the hard way — every trap below cost real time, and most of
them fail in a way that looks like something else.

This fork adds the **ESP32-C6-Touch-AMOLED-2.16** alongside the original
**ESP32-S3-Touch-AMOLED-2.16**. Both boards are supported and both must keep
building.

## The one rule

> **Board differences go in `firmware/main/board.h`. Style differences do not
> exist.**

The two boards are sister products with the same 480x480 panel, the same touch,
the same IMU and the same PMIC. Only the MCU differs, so nothing about the
interface depends on the chip.

`main.c` and `ui.c` contain **zero** `#if CONFIG_IDF_TARGET_*`. Keep it that
way. If you are about to add one, ask which of these it is:

- a hardware fact (a pin, a memory limit, how a sensor is mounted) → `board.h`;
- anything about layout, fonts, colours, spacing → common code, both boards.

This existed as scattered `#if`s once, and the cost was not ugliness: interface
work kept getting tied to a target, so the same improvement had to be made twice
or existed on only one board.

## Build and flash

```bash
. ~/esp/esp-idf/export.sh          # ESP-IDF 5.5+
cd firmware
idf.py set-target esp32c6          # or esp32s3
idf.py build
cd .. && ./flash.sh --no-wifi --no-backup
```

`./flash.sh` reads the chip from the build's own `flasher_args.json`, so the
command is the same for both boards. On the C6 it will **not** download a
release: the published binary is Xtensa and that board is RISC-V, so you build
locally or you get nothing.

## Traps

Symptom on the left, cause in the middle, what to do on the right. The point of
this table is that none of these announce themselves.

| Symptom | Cause | Fix |
|---|---|---|
| `set-target` refuses: *doesn't seem to be a CMake build directory* | build dir belongs to the other target | `rm -rf build sdkconfig` first |
| Edited `sdkconfig.defaults*` and nothing changed | IDF does not reapply defaults over an existing sdkconfig | delete `firmware/sdkconfig` |
| cmake: `xtensa-esp32s3-elf-gcc` not in PATH | `export.sh` only exports toolchains for registered targets | `~/esp/esp-idf/install.sh esp32c6,esp32s3` |
| Build dies at *Build assets binary*, `No module named 'png'` | the LVGL asset converter imports pypng from IDF's own venv, and it is not an IDF requirement | `~/.espressif/python_env/idf5.5_py3.9_env/bin/python -m pip install pypng` |
| `install.sh` of IDF fails creating its venv | the venv is born from whatever `python3` is in PATH | run it with a clean PATH: `env PATH=/usr/bin:/bin bash ~/esp/esp-idf/install.sh esp32c6` |
| cmake/ninja missing | IDF's installer does not always bring them | `python $IDF_PATH/tools/idf_tools.py install cmake ninja` |
| Screen black, firmware clearly running | on the C6 the panel has no reset and no backlight pin: power is the AXP2101's **ALDO3** rail | cycle ALDO3 before `esp_lcd_panel_init()` — `bsp_c6_amoled_216` already does |
| Artwork never appears, `mmap_assets: The free size is less than storage partition required` | `esp_mmap_assets` maps the WHOLE partition and checks free MMU pages first; the C6 has less address space | keep the assets partition small (3MB works, 7MB does not) — the firmware survives by falling back to the vector mascot, which is why it is easy to miss |
| Rotation ignores `lv_display_set_rotation()` | LVGL needs DIRECT/FULL render mode and we run PARTIAL | rotate in the panel via MADCTL, and rotate touch with it |
| `swap_xy` returns `ESP_ERR_NOT_SUPPORTED` | you are on `esp_lcd_sh8601` | use `esp_lcd_co5300`; it implements mirror and swap_xy, and the S3 init table works byte for byte |
| Serial goes silent after a flash | after `hard_reset` the USB device **re-enumerates**: the old `/dev/cu.usbmodem*` node is gone (`OSError: Device not configured`) | wait ~3s, re-glob the path, reopen with retry |
| Serial silent and esptool cannot connect | do not toggle DTR/RTS to force a reset — on native USB-JTAG those lines drive reset and boot mode, and it leaves the port mute | unplug and replug the USB-C cable; **this board has no reset button**, the cable is the reset |
| esptool still refuses | board not in download mode | unplug, hold **BOOT**, plug in, release |
| A button does nothing | on the C6 the KEY is **GPIO10**, not GPIO18 — every source including Waveshare's example config says 18, and there is no button there. The middle button is the PWR: not a GPIO at all, it arrives as an interrupt bit in the AXP2101 | find pins by measuring: every free pin as input with pull-up, log which one drops. Careful — "the button does nothing" is also what a brightness request at the limit produces |
| Board associates to WiFi then drops, stuck at "connecting" | could be the password, a missing SSID, a 5GHz-only network, or a post-association failure — all identical on screen | read the disconnect `reason` in the log: 15/204 password, 201 no AP, 205 connection fail |
| Limits on screen are days old | the source is Claude Code's own cache in `~/.claude.json` (`cachedUsageUtilization`), which can sit unrefreshed | tick **"Fetch real limits"** in the Wisp.app panel: the app then fetches from Anthropic with keychain access and publishes to the bridge, taking precedence over the cache |

## Not bugs — do not "fix" these

- **The mascot does not animate when image art is loaded.** Deliberate, and
  measured: keeping the frame loop running reinvalidated the whole alpha image
  every frame — 6 FPS and 1.6KB of internal RAM at the minimum. An image is
  already the whole character; it only needs to change when the state changes.
  The vector mascot (the fallback when assets fail to mount) *is* animated, so
  "it used to animate" usually means the assets partition stopped mounting.
- **`ui: FPS: 0` or `1` with image art.** That is a quiet screen, not a slow
  one. The counter only counts real refreshes.
- **`esp_mmap_assets`'s `checksum` config field is 0 on purpose.** When the
  binary starts with the `MMAP` magic the component uses the checksum from the
  header and ignores the config. A constant there validates nothing and goes
  stale the moment the art changes — it reads like verification and isn't.
- **`QMI8658: Failed to read WHO_AM_I` at boot.** The IMU address depends on how
  SA0 is strapped, and the code tries both. The first failure is the probe.

## Where things are

| Path | What |
|---|---|
| `firmware/main/board.h` | the only place that knows which board this is |
| `firmware/components/bsp_c6_amoled_216/` | the nine BSP symbols, reimplemented for the C6 |
| `firmware/main/ui.c` | everything visual, common to both boards |
| `firmware/sdkconfig.defaults` + `.esp32s3` / `.esp32c6` | shared config plus per-chip; the split is required because `CONFIG_SPIRAM` and `ESP32S3_*_CACHE` do not exist in the C6's Kconfig |
| `firmware/README.md` | the hardware detail behind all of the above |

## Verification expectations

State what you actually checked. Compiling for a target is not the same as
running on it, and the difference matters here: at the time of writing, the C6
path is verified on hardware and **the S3 path is verified by compilation
only** — there is no S3 board on this bench.
