"""
Regression tests for the average-pace mark. Run it: python3 test_limits.py

WHY THIS FILE EXISTS
--------------------
The mark is only meaningful next to the percentage it sits beside: one says how
much of the window was spent, the other how much of the window is gone. Get the
second one wrong and the bar does not go vague, it goes confidently false —
which is the kind of wrongness nobody catches by looking.

Two traps are worth holding down, and both are about WHICH INSTANT the mark
describes.

The first is staleness. `read()` can serve a cache that is hours old; that is
why `age_s` exists and why the screen says "X min ago" instead of pretending.
The percentage in such a payload is frozen at the moment it was measured, so the
mark has to be frozen there too. Computed against "now" instead, it would keep
advancing beside a fill that never moved, and an old cache would render as "far
under pace" purely for being old.

The second is expiry. A cache read ten minutes ago can describe a window that
still had eight minutes left AT THE TIME — arithmetically a truthful 97%, and
still the wrong thing to draw, because the same payload flags that bar expired.
A mark on it would invite exactly the comparison the flag says not to make.

NO FRAMEWORK, ON PURPOSE
------------------------
Same reason the bridge itself has no dependencies: it runs on the system
python3, which never changes. A test suite that needs installing is a test suite
that does not get run.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import limits

FAILURES = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(("  ok    " if ok else "  FAIL  ") + name + (f"  — {detail}" if detail else ""))
    if not ok:
        FAILURES.append(name)


def _iso(**delta) -> str:
    return (datetime.now(timezone.utc) + timedelta(**delta)).isoformat()


def _bar(kind: str, pct: int, resets_at: str, active: bool = False) -> dict:
    return {"kind": kind, "percent": pct, "severity": "normal",
            "resets_at": resets_at, "is_active": active}


def _one(kind: str, pct: int, resets_at: str, age_s: int = 0):
    """The elapsed_pct of a single-bar payload."""
    r = limits.normalize({"limits": [_bar(kind, pct, resets_at, active=True)]}, age_s=age_s)
    return r["bars"][0].get("elapsed_pct")


print("\nelapsed_pct() — where the pace mark goes")

check("half of a 5h window spent puts the mark at 50%",
      _one("session", 20, _iso(hours=2, minutes=30)) == 50,
      f"got {_one('session', 20, _iso(hours=2, minutes=30))}")

check("half of the 7d window spent puts the mark at 50%",
      _one("weekly_all", 30, _iso(days=3, hours=12)) == 50,
      f"got {_one('weekly_all', 30, _iso(days=3, hours=12))}")

check("a model-scoped weekly window uses the 7d length too",
      _one("weekly_scoped", 10, _iso(days=5, hours=6)) == 25,
      f"got {_one('weekly_scoped', 10, _iso(days=5, hours=6))}")

# The staleness trap, and the reason normalize() passes age_s down at all.
check("a stale cache marks the pace at the instant it was MEASURED",
      _one("session", 5, _iso(hours=3), age_s=2 * 3600) == 0,
      f"got {_one('session', 5, _iso(hours=3), age_s=2 * 3600)}")

check("a window that just opened marks 0, not nothing",
      _one("session", 0, _iso(hours=5)) == 0,
      f"got {_one('session', 0, _iso(hours=5))}")

# No length known for the kind -> no mark. An absent mark costs the reader
# nothing; one drawn against a guessed window length is a lie with a
# pixel-perfect finish.
check("an unknown kind gets no mark at all",
      _one("monthly_mystery", 40, _iso(days=2)) is None,
      f"got {_one('monthly_mystery', 40, _iso(days=2))}")

check("a reset beyond the window length gets no mark",
      _one("session", 40, _iso(hours=9)) is None,
      f"got {_one('session', 40, _iso(hours=9))}")

# The expiry trap. The 5h window here reset two minutes ago while the weekly one
# is still open, so the payload as a whole is kept — half of it is still true —
# and only the expired bar loses its mark.
r = limits.normalize({"limits": [_bar("session", 3, _iso(minutes=-2)),
                                 _bar("weekly_all", 41, _iso(days=5), active=True)]},
                     age_s=600)
check("an expired window gets no mark, even when the arithmetic would give one",
      r["bars"][0]["elapsed_pct"] is None and r["bars"][1]["elapsed_pct"] is not None,
      f"got {[b.get('elapsed_pct') for b in r['bars']]}")


print()
if FAILURES:
    print(f"FAILED: {len(FAILURES)} — {', '.join(FAILURES)}")
    raise SystemExit(1)
print("all passed")
