"""
Per-user configuration. Nothing machine-specific in the source.

Lives in ~/.wisp/config.json, created on first use with sensible values.
The file is 0600 because it holds the bridge access token.

WHY THIS EXISTS
---------------
Until now one person's Mac hostname was hardcoded in announce.py and São Paulo
was hardcoded in weather.py. That works on one machine; it is garbage on every
other one. Publishing like that would mean every user editing source code to
change their city.

And the more serious part: the bridge listens on the local network and serves
project names and usage to whoever asks. On a coworking network that is a free
read. The token here fixes it — the board sends it, nobody else has it.
"""

from __future__ import annotations

import json
import os
import secrets
import urllib.request
from pathlib import Path

FOLDER = Path.home() / ".wisp"
FILE = FOLDER / "config.json"

DEFAULTS = {
    "port": 4666,

    # Token the board presents on every request. Generated on first use.
    "token": "",

    # With the token required, /state only answers whoever presents the secret.
    # A fresh install is born true. It only goes false while there is a board
    # running old firmware that does not know how to send the token yet.
    "require_token": True,

    # Weather forecast. Without this the bridge tries to figure it out from
    # your IP on first use; failing that, the clock shows up with no
    # temperature.
    "weather": {"lat": None, "lon": None, "name": ""},

    # Old hostnames to republish over mDNS, so already-flashed boards keep
    # finding the bridge after macOS renames the machine.
    "legacy_hostnames": [],
}


def _detect_location() -> dict:
    """
    Finds the city from the public IP, once, on first use.

    It is the difference between "it just works" and "edit a JSON before using
    it". One call, saved forever. If it fails the weather simply does not show
    up — it is never a reason to bring anything down.
    """
    try:
        req = urllib.request.Request(
            "http://ip-api.com/json/?fields=status,city,lat,lon",
            headers={"User-Agent": "wisp"})
        with urllib.request.urlopen(req, timeout=6) as r:
            d = json.loads(r.read())
        if d.get("status") == "success":
            return {"lat": d["lat"], "lon": d["lon"], "name": d.get("city", "")}
    except Exception:
        pass
    return {"lat": None, "lon": None, "name": ""}


def _merge(base: dict, new: dict) -> dict:
    """Keeps the keys the user already has and adds the missing ones."""
    out = dict(base)
    for k, v in (new or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = v
    return out


_cache: dict | None = None


def read(reload: bool = False) -> dict:
    global _cache
    if _cache is not None and not reload:
        return _cache

    current = {}
    if FILE.exists():
        try:
            current = json.loads(FILE.read_text())
        except (OSError, json.JSONDecodeError):
            current = {}

    cfg = _merge(DEFAULTS, current)
    changed = cfg != current

    if not cfg["token"]:
        # 32 urlsafe bytes: plenty for a local network and small enough for a
        # header.
        cfg["token"] = secrets.token_urlsafe(24)
        changed = True

    w = cfg["weather"]
    if w.get("lat") is None and "weather_detected" not in current:
        cfg["weather"] = _detect_location()
        # Record the attempt even if it failed: we do not retry on every boot.
        cfg["weather_detected"] = True
        changed = True

    if changed:
        write(cfg)

    _cache = cfg
    return cfg


def write(cfg: dict) -> None:
    FOLDER.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(cfg, indent=2, ensure_ascii=False))
    os.chmod(tmp, 0o600)   # it holds the token
    tmp.replace(FILE)


if __name__ == "__main__":
    c = read()
    print(f"config: {FILE}")
    print(f"  port          : {c['port']}")
    print(f"  token         : {c['token'][:6]}… ({len(c['token'])} chars)")
    print(f"  require_token : {c['require_token']}")
    w = c["weather"]
    print(f"  weather       : {w['name'] or '—'} ({w['lat']}, {w['lon']})")
    print(f"  legacy        : {c['legacy_hostnames'] or '—'}")
