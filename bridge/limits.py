"""
Reads the Claude subscription usage limits, and keeps the best reading we have.

Two sources: Claude Code's own cache (~/.claude.json -> cachedUsageUtilization)
and the live reading the menu bar app fetches from Anthropic, which lands here
through the bridge and is kept in ~/.wisp/limits.json.

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
from datetime import datetime, timedelta, timezone
from pathlib import Path

CONFIG = Path.home() / ".claude.json"

# Where the LIVE reading is kept — the one the menu bar app fetches straight
# from Anthropic with its own keychain access.
#
# On disk, not only in the bridge's memory, because the bridge dies far more
# often than the number goes stale: every app relaunch restarts it. Until this
# existed, a restart threw away a reading from a minute ago in order to show
# the fallback underneath — Claude Code's own cache, measured here at 43h old,
# with every window already past its reset.
LIVE = Path.home() / ".wisp" / "limits.json"

# kind -> short label (the screen is 480px; a long name does not fit)
LABELS = {
    "session": "Session 5h",
    "weekly_all": "Weekly",
    "weekly_scoped": "Weekly (model)",
}

# kind -> how long the window lasts, in seconds.
#
# The payload says WHEN a window resets, never how long it is, so the length has
# to live here to turn "resets at 16:20" into "40% of the way through". A kind
# missing from this table simply gets no pace mark: an absent mark costs the
# reader nothing, while one drawn against a guessed length is a lie with a
# pixel-perfect finish.
WINDOW_SECONDS = {
    "session": 5 * 3600,
    "weekly_all": 7 * 86400,
    "weekly_scoped": 7 * 86400,
}

# severity -> suggested colour (RGB565-friendly)
SEVERITY_COLOR = {
    "normal": "#5FCF8E",
    "warning": "#E8C15A",
    "critical": "#E8624A",
}


def _elapsed_pct(iso: str | None, kind: str, measured_at: datetime) -> int | None:
    """How much of the window was already spent, 0-100, or None if unknowable.

    `measured_at` is the instant the percentage was READ, not the instant we are
    drawing. Those differ by `age_s` whenever the source is the on-disk cache,
    and using "now" here would be the same class of bug this module already
    guards against: the mark would keep advancing while the frozen percentage
    stood still, so an old cache would render as "far under pace" — a wrong
    reading produced entirely by the data being old, which is exactly the shape
    of wrongness nobody notices.
    """
    window = WINDOW_SECONDS.get(kind)
    if not window or not iso:
        return None
    try:
        reset = datetime.fromisoformat(iso)
    except ValueError:
        return None
    remaining = (reset - measured_at).total_seconds()
    # Past its reset, or further out than the window can reach: in both cases
    # this window cannot describe the number, so there is nothing to mark.
    if remaining <= 0 or remaining > window:
        return None
    return int(round((window - remaining) / window * 100))


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


# Last parse of ~/.claude.json, keyed by (mtime, size).
#
# The file is 80 KB and every /state from the board — every 600ms — goes
# through here to compare its freshness against the live reading. Parsing 80 KB
# of JSON twice a second to discover that nothing changed is work nobody asked
# for. A stat is enough to find out.
_memo = [None]   # [(key, cached)] — a single slot, swapped atomically


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
    try:
        st = CONFIG.stat()
    except OSError:
        return {"ok": False, "reason": "~/.claude.json does not exist"}

    key = (st.st_mtime_ns, st.st_size)
    seen = _memo[0]
    if seen and seen[0] == key:
        cached = seen[1]
    else:
        try:
            with CONFIG.open(errors="replace") as fh:
                cfg = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            return {"ok": False, "reason": f"could not read the config: {exc}"}
        cached = cfg.get("cachedUsageUtilization")
        # Memoised even when absent: a file with nothing to offer should not be
        # re-parsed 100 times a minute to say so again. One assignment, because
        # the server is threaded — key and value have to become visible together.
        _memo[0] = (key, cached)

    if not cached:
        return {"ok": False, "reason": "no cachedUsageUtilization (run /usage once)"}

    now = datetime.now(timezone.utc)
    fetched_ms = cached.get("fetchedAtMs", 0)
    age_s = max(0, (now.timestamp() * 1000 - fetched_ms) / 1000)
    r = normalize(cached.get("utilization"), int(age_s))
    # The ABSOLUTE instant, not just the age: whoever chooses between this and
    # the live reading has to compare two clocks, and an age is only comparable
    # to another age measured at the same moment.
    r["fetched_at"] = fetched_ms / 1000
    return r


def save_live(utilization: dict, when: float) -> None:
    """Records the live reading so a bridge restart does not lose it."""
    try:
        LIVE.parent.mkdir(parents=True, exist_ok=True)
        tmp = LIVE.with_suffix(".tmp")
        tmp.write_text(json.dumps({"fetched_at": when, "utilization": utilization}))
        # Atomic swap: the bridge reads this file at boot, and a half-written
        # one would be a crash on startup, the worst possible moment.
        tmp.replace(LIVE)
    except OSError:
        pass  # a cache we cannot write is never a reason to take the bridge down


def load_live() -> tuple:
    """(utilization, fetched_at) from the last live reading, or (None, 0)."""
    try:
        d = json.loads(LIVE.read_text())
    except (OSError, json.JSONDecodeError):
        return None, 0.0
    u = d.get("utilization")
    if not isinstance(u, dict):
        return None, 0.0
    try:
        return u, float(d.get("fetched_at") or 0)
    except (TypeError, ValueError):
        return None, 0.0


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
    # The moment the numbers below were true. For a live fetch it is ~now; for
    # the disk cache it can be hours back, and the pace mark has to be pinned
    # to it (see _elapsed_pct).
    measured_at = now - timedelta(seconds=max(0, age_s))
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
        resets_in = _fmt_reset(item.get("resets_at"), now)
        expired = resets_in == "now"
        bars.append({
            "kind": kind,
            "label": label,
            "pct": int(pct),
            "resets_in": resets_in,
            # Where the average-pace mark goes on the bar, or None for no mark.
            #
            # Gated on `expired` below, and not only on the arithmetic: a cache
            # read 10 minutes ago can describe a window that had 8 minutes left
            # AT THE TIME, which is a truthful 97% and still the wrong thing to
            # draw. The card already declares that number untrustworthy, and a
            # pace mark on it would invite exactly the comparison the flag says
            # not to make.
            "elapsed_pct": None if expired else _elapsed_pct(item.get("resets_at"), kind, measured_at),
            # EXPIRED window: the reset time has already passed, so this
            # percentage describes a period that no longer exists. It only
            # happens with cached data — live, a "resets_at" in the past would
            # be a race of seconds.
            #
            # It matters because the number does not merely go stale: it goes
            # WRONG in a predictable direction. After a reset the real usage
            # drops, so an expired "52%" alarms you for nothing. Better to say
            # we do not know than to say a number we know is wrong.
            "expired": expired,
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
