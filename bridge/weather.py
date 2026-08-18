"""
Weather forecast for the idle screen.

Uses Open-Meteo: free, no signup and no API key — which is why there is no
secret to keep here. The fetch happens ON THE MAC, not on the board: the ESP32
does not have to speak HTTPS or embed certificates, and the location is defined
in exactly one place.

Stdlib only.
"""


# Lazy annotations: lets the module run on the system Python 3.9
# (/usr/bin/python3), which never changes and does not depend on asdf. Without
# this, `str | None` is evaluated at definition time and blows up on 3.9.
from __future__ import annotations

import json
import threading
import time
import urllib.error
import urllib.request

import config

REFRESH_S = 900        # 15 min: the weather does not change faster than that
TIMEOUT_S = 8


def _url() -> str | None:
    """
    Builds the query from the user's configuration.

    The city used to be hardcoded here (São Paulo). Now it comes from
    config.json, which discovers it from the IP on first use — whoever installs
    edits nothing. Without coordinates we return None and the clock shows up
    without a temperature; that is degradation, not an error.

    `timezone=auto` lets Open-Meteo itself derive the timezone from the
    coordinates, which saves us carrying a timezone table just for this.
    """
    w = config.read().get("weather") or {}
    lat, lon = w.get("lat"), w.get("lon")
    if lat is None or lon is None:
        return None
    return (
        "https://api.open-meteo.com/v1/forecast"
        f"?latitude={lat}&longitude={lon}"
        "&current=temperature_2m,weather_code,is_day"
        "&daily=temperature_2m_max,temperature_2m_min"
        "&timezone=auto"
        "&forecast_days=1"
    )

# WMO weather code -> short label (fits the screen) and ASCII (the embedded
# font has no accents). Official table: https://open-meteo.com/en/docs
_CODES = [
    ({0}, "clear"),
    ({1, 2}, "partly cloudy"),
    ({3}, "cloudy"),
    ({45, 48}, "fog"),
    ({51, 53, 55, 56, 57}, "drizzle"),
    ({61, 63, 65, 66, 67}, "rain"),
    ({71, 73, 75, 77, 85, 86}, "snow"),
    ({80, 81, 82}, "showers"),
    ({95, 96, 99}, "thunderstorm"),
]


def _label(code) -> str:
    for codes, name in _CODES:
        if code in codes:
            return name
    return "-"


# WMO code -> an icon the firmware knows how to draw. We keep the set small on
# purpose: every icon is drawn from primitives on the ESP32, so variety costs
# code. Nearby conditions fall onto the same drawing.
def _icon(code, is_day: bool) -> str:
    if code in (0, 1):
        return "sun" if is_day else "moon"
    if code == 2:
        return "cloudsun" if is_day else "cloudmoon"
    if code in (3, 45, 48):
        return "cloud"
    if code in (71, 73, 75, 77, 85, 86):
        return "snow"
    if code in (95, 96, 99):
        return "storm"
    if code is None:
        return "cloud"
    return "rain"


class Weather:
    """Fetches in the background and serves the last good result."""

    def __init__(self):
        self._lock = threading.Lock()
        self._data = None
        self._fetched_at = 0.0
        self._errors = 0

    def start(self) -> None:
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self) -> None:
        while True:
            try:
                url = _url()
                if not url:
                    # No coordinates configured: sleep and try again, in case
                    # the user fills the config in later.
                    time.sleep(REFRESH_S)
                    continue
                with urllib.request.urlopen(url, timeout=TIMEOUT_S) as r:
                    d = json.load(r)
                current = d.get("current") or {}
                daily = d.get("daily") or {}
                day = bool(current.get("is_day", 1))
                fresh = {
                    "t": round(current.get("temperature_2m", 0)),
                    "c": _label(current.get("weather_code")),
                    "i": _icon(current.get("weather_code"), day),
                    "hi": round((daily.get("temperature_2m_max") or [0])[0]),
                    "lo": round((daily.get("temperature_2m_min") or [0])[0]),
                }
                with self._lock:
                    self._data = fresh
                    self._fetched_at = time.time()
                    self._errors = 0
            except (urllib.error.URLError, OSError, ValueError, KeyError) as exc:
                with self._lock:
                    self._errors += 1
                # Keep the last good value: weather from 15 minutes ago still
                # beats an empty screen. It only gives up after many failures.
                if self._errors == 1:
                    print(f"[weather] failed: {exc}")
            time.sleep(REFRESH_S)

    def read(self) -> dict | None:
        with self._lock:
            if not self._data:
                return None
            # After ~2h without an update, the data stops being information.
            if time.time() - self._fetched_at > 7200:
                return None
            return dict(self._data)


if __name__ == "__main__":
    w = Weather()
    w.start()
    for _ in range(20):
        if (d := w.read()):
            print(f"now {d['t']}C ({d['c']}) [{d['i']}]   high {d['hi']}C  low {d['lo']}C")
            break
        time.sleep(1)
    else:
        print("could not fetch the forecast")
