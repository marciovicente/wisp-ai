"""
Reads the Claude subscription usage limits from Claude Code's local cache.

Source: ~/.claude.json -> cachedUsageUtilization

This is the same data the /usage panel draws. Claude Code fetches it from the
server and stores it here; we only read. There is no computation of ours — you
cannot derive "43% of the weekly limit" from the transcripts because the
denominator is not public.

Because it is a CACHE, it can be stale. Every read returns `age_s` precisely so
the screen can say "X min ago" instead of pretending the number is live.
"""


# Lazy annotations: lets the module run on the system Python 3.9
# (/usr/bin/python3), which never changes and does not depend on asdf. Without
# this, `str | None` is evaluated at definition time and blows up on 3.9.
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

CONFIG = Path.home() / ".claude.json"

# kind -> short label (the screen is 480px; a long name does not fit)
LABELS = {
    "session": "Session 5h",
    "weekly_all": "Weekly",
    "weekly_scoped": "Weekly (model)",
}

# severity -> suggested colour (RGB565-friendly)
SEVERITY_COLOR = {
    "normal": "#5FCF8E",
    "warning": "#E8C15A",
    "critical": "#E8624A",
}


def _fmt_reset(iso: str | None, now: datetime) -> str:
    """'3h', '4d' — short enough to sit next to the bar."""
    if not iso:
        return ""
    try:
        dt = datetime.fromisoformat(iso)
    except ValueError:
        return ""
    secs = (dt - now).total_seconds()
    if secs <= 0:
        return "now"
    if secs < 3600:
        return f"{secs / 60:.0f}min"
    if secs < 86400:
        return f"{secs / 3600:.0f}h"
    return f"{secs / 86400:.0f}d"


def read() -> dict:
    """
    Returns:
      {
        "ok": True,
        "age_s": 156,                      # cache age in seconds
        "bars": [
          {"kind","label","pct","resets_in","severity","color","active"}, ...
        ],
        "peak": 43,                        # highest percentage (the tight one)
        "peak_severity": "normal",
      }
    or {"ok": False, "reason": "..."} — it never raises, because this runs
    inside the bridge loop and broken stats must not take the status down.
    """
    if not CONFIG.exists():
        return {"ok": False, "reason": "~/.claude.json does not exist"}

    try:
        with CONFIG.open(errors="replace") as fh:
            cfg = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        return {"ok": False, "reason": f"could not read the config: {exc}"}

    cached = cfg.get("cachedUsageUtilization")
    if not cached:
        return {"ok": False, "reason": "no cachedUsageUtilization (run /usage once)"}

    now = datetime.now(timezone.utc)
    age_s = max(0, (now.timestamp() * 1000 - cached.get("fetchedAtMs", 0)) / 1000)
    return normalize(cached.get("utilization"), int(age_s))


def normalize(utilization, age_s: int) -> dict:
    """
    Turns the utilization object into bars ready for the screen.

    Split out of read() because there are now TWO sources: the cache Claude
    Code keeps on disk, and the live fetch the menu bar app performs. Both
    deliver the same shape and both pass through here — one single place to
    label, colour and compute the peak.

    It accepts both {"limits": [...]} and the already-unwrapped object, because
    the API response and what is stored on disk are not guaranteed to arrive at
    the same nesting level.
    """
    if isinstance(utilization, dict) and "limits" not in utilization:
        # Some shapes wrap one more time.
        for key in ("utilization", "usage", "data"):
            if isinstance(utilization.get(key), dict):
                utilization = utilization[key]
                break

    now = datetime.now(timezone.utc)
    raw = (utilization or {}).get("limits") or []
    bars = []
    for item in raw:
        kind = item.get("kind", "?")
        pct = item.get("percent")
        if pct is None:
            continue
        sev = item.get("severity") or "normal"
        label = LABELS.get(kind, kind.replace("_", " "))
        # scope is nested: {"model": {"display_name": "Fable"}, "surface": null}
        scope = item.get("scope") or {}
        if name := ((scope.get("model") or {}).get("display_name")):
            label = f"Weekly {name}"
        bars.append({
            "kind": kind,
            "label": label,
            "pct": int(pct),
            "resets_in": _fmt_reset(item.get("resets_at"), now),
            # EXPIRED window: the reset time has already passed, so this
            # percentage describes a period that no longer exists. It only
            # happens with cached data — live, a "resets_at" in the past would
            # be a race of seconds.
            #
            # It matters because the number does not merely go stale: it goes
            # WRONG in a predictable direction. After a reset the real usage
            # drops, so an expired "52%" alarms you for nothing. Better to say
            # we do not know than to say a number we know is wrong.
            "expired": _fmt_reset(item.get("resets_at"), now) == "now",
            "severity": sev,
            "color": SEVERITY_COLOR.get(sev, SEVERITY_COLOR["normal"]),
            "active": bool(item.get("is_active")),
        })

    if not bars:
        return {"ok": False, "reason": "no limits in the payload"}

    peak = max(bars, key=lambda b: b["pct"])
    return {
        "ok": True,
        "age_s": int(age_s),
        "bars": bars,
        "peak": peak["pct"],
        "peak_severity": peak["severity"],
    }


if __name__ == "__main__":
    r = read()
    if not r["ok"]:
        print(f"unavailable: {r['reason']}")
        raise SystemExit(1)

    stale = " (STALE)" if r["age_s"] > 900 else ""
    print(f"=== LIMITS — cache from {r['age_s'] // 60}min ago{stale} ===\n")
    for b in r["bars"]:
        filled = round(b["pct"] / 5)
        bar = "█" * filled + "░" * (20 - filled)
        flag = " ←" if b["active"] else ""
        print(f"  {b['label']:<18} {bar} {b['pct']:>3}%  resets in {b['resets_in']:<5}{flag}")
    print(f"\n  peak: {r['peak']}% ({r['peak_severity']})")
