"""
Usage over the SAME windows as the subscription limits — computed here.

WHY THIS EXISTS
---------------
The subscription percentages come from a cache Claude Code keeps in
~/.claude.json and is supposed to refresh every 5 minutes. On one of the test
machines it sat unchanged for three days with no identifiable cause, and there
is no local way to force it: the real data arrives in HTTP headers that live
inside the Claude Code client and never touch disk.

Fetching straight from Anthropic solves that, but it requires ANOTHER
application's credential, which triggers a keychain password prompt and asks
for trust out of all proportion to a desk mascot.

So here we compute what can be computed on our own, from the transcripts,
always fresh and without asking anyone for anything: how much you used in the
last 5 hours and in the last 7 days — the same windows Anthropic uses.

WHAT THIS IS **NOT**
--------------------
It is not the subscription percentage. Anthropic's denominator is not public
and neither are the per-model weights, so deriving "43% of the weekly limit"
from here would be inventing a number — and an invented number about a limit
is worse than none.

What we deliver is you against yourself: the current window's usage compared
to your own recent peak. It answers "is today outside my normal?", which in
practice is the question that makes someone look at the mascot.
"""

from __future__ import annotations

import json
from bisect import bisect_left
from datetime import datetime, timedelta, timezone
from pathlib import Path

PROJECTS_DIR = Path.home() / ".claude" / "projects"

SESSION_WINDOW = timedelta(hours=5)     # same window as the "Session 5h" limit
WEEK_WINDOW = timedelta(days=7)         # same window as the weekly limit

# How much history we scan to find your personal peak.
#
# It has to be MUCH larger than the largest window. With 7 days of history the
# 7-day peak is the current window itself and the bar read 100% every time — a
# degenerate comparison, zero information. 30 days gives the weekly window
# something to compare against.
HISTORY = timedelta(days=30)

# Below this the comparison does not hold up: without at least twice the window
# in history, the "peak" is nearly the current window and the percentage lies.
# We would rather say we do not know.
MIN_HEADROOM = 2.0


def _events(since: datetime) -> list:
    """
    [(when, output, requests)] per unique request, in chronological order.

    Deduplicating by requestId is the same thing usage.py does, and it exists
    because one request reappears in several files: session resumption,
    subagent sidechains and context compaction all rewrite the same event.
    """
    if not PROJECTS_DIR.is_dir():
        return []

    seen = set()
    out = []
    for path in PROJECTS_DIR.rglob("*.jsonl"):
        try:
            if datetime.fromtimestamp(path.stat().st_mtime, timezone.utc) < since:
                continue
            with path.open(errors="replace") as fh:
                for line in fh:
                    try:
                        d = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if d.get("type") != "assistant":
                        continue
                    msg = d.get("message") or {}
                    u = msg.get("usage")
                    if not u:
                        continue
                    key = d.get("requestId") or msg.get("id") or d.get("uuid")
                    if key in seen:
                        continue
                    seen.add(key)

                    ts = d.get("timestamp")
                    if not ts:
                        continue
                    try:
                        when = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                    except ValueError:
                        continue
                    if when < since:
                        continue
                    out.append((when, u.get("output_tokens", 0)))
        except OSError:
            continue

    out.sort(key=lambda e: e[0])
    return out


def _rolling_peak(events: list, window: timedelta) -> int:
    """
    Largest output sum inside any sliding window of the period.

    Two pointers over the sorted list: the trailing one advances while the
    oldest event falls outside the window. Walks the list exactly once.
    """
    if not events:
        return 0
    best = total = 0
    i = 0
    for j, (t_j, out_j) in enumerate(events):
        total += out_j
        edge = t_j - window
        while i <= j and events[i][0] < edge:
            total -= events[i][1]
            i += 1
        best = max(best, total)
    return best


def _sum_since(events: list, instants: list, since: datetime) -> tuple:
    """
    (output, requests) from a given instant. Binary search: already sorted.

    bisect's `key=` only exists in Python 3.10, and we run on the 3.9 that
    ships with macOS — deliberately, so we do not depend on asdf/pyenv. Hence
    the parallel list of instants, which is what people did before the
    parameter existed.
    """
    i = bisect_left(instants, since)
    slice_ = events[i:]
    return sum(e[1] for e in slice_), len(slice_)


def calculate() -> dict:
    """
    {
      "ok": True,
      "session": {"output": 812345, "reqs": 210, "peak": 1200000, "pct": 68},
      "week": {"output": 5739065, "reqs": 19144, "peak": 5739065, "pct": 100},
    }

    `pct` is always relative to YOUR peak in the period — never to Anthropic's
    limit. Whoever consumes this has to label it that way, or it becomes a lie.
    """
    now = datetime.now(timezone.utc)
    events = _events(now - HISTORY)
    if not events:
        return {"ok": False, "reason": "no transcripts in the period"}
    instants = [e[0] for e in events]

    # How much history REALLY exists — not how much we asked for. Someone who
    # installed yesterday has one day, however far back we scan.
    span = now - instants[0]

    def band(window: timedelta) -> dict:
        output, reqs = _sum_since(events, instants, now - window)
        peak = _rolling_peak(events, window)
        # pct = -1 means "cannot compare yet", and whoever displays it should
        # show only the absolute number. Better than a bar at 100% suggesting
        # pressure when what is missing is history.
        trustworthy = span >= window * MIN_HEADROOM and peak > 0
        return {
            "output": output,
            "reqs": reqs,
            "peak": peak,
            "pct": round(output / peak * 100) if trustworthy else -1,
        }

    return {
        "ok": True,
        "session": band(SESSION_WINDOW),
        "week": band(WEEK_WINDOW),
        "history_d": round(span.total_seconds() / 86400, 1),
    }


if __name__ == "__main__":
    import time
    t0 = time.time()
    r = calculate()
    if not r["ok"]:
        raise SystemExit(r["reason"])
    print(f"=== USAGE PER WINDOW (local, {time.time() - t0:.1f}s, "
          f"{r['history_d']}d of history) ===\n")
    for key, name in (("session", "Session 5h"), ("week", "Week 7d")):
        b = r[key]
        if b["pct"] < 0:
            print(f"  {name:<11} {'—' * 20}  history too short to compare")
        else:
            filled = round(b["pct"] / 5)
            bar = "█" * min(filled, 20) + "░" * max(0, 20 - filled)
            print(f"  {name:<11} {bar} {b['pct']:>3}% of your peak")
        print(f"  {'':<11} {b['reqs']:>6} reqs   output {b['output']:>10,}"
              f"   (peak {b['peak']:,})\n")
