"""
Bridge between Claude Code and the mascot on the ESP32-S3.

Takes hook events from Claude Code, derives a state, and serves that state to
the board over HTTP.

Stdlib only — nothing to install.

Endpoints
    POST /hook    <- Claude Code sends its events here
    GET  /state   <- the board fetches state here (lean payload)
    GET  /health  <- liveness
    GET  /debug   <- full state, for a human to inspect

Usage:
    python3 bridge/server.py [port]
"""


# Lazy annotations: lets the module run on the system Python 3.9
# (/usr/bin/python3), which never changes and does not depend on asdf. Without
# this, `str | None` is evaluated at definition time and blows up on 3.9.
from __future__ import annotations

import json
import os
import secrets
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(__import__("pathlib").Path(__file__).parent))
import usage    # noqa: E402
import limits   # noqa: E402
import weather  # noqa: E402
import announce  # noqa: E402
import config   # noqa: E402
import rolling  # noqa: E402

PORT = 4666

# How long the "done" state stays visible before decaying to idle.
DONE_LINGER_S = 8.0
# How often usage is recomputed (incremental scan).
USAGE_REFRESH_S = 60.0
# Idle for longer than this: the board swaps the mascot for clock + weather.
# A motionless character tells you nothing; the time and temperature do.
#
# 5 minutes, not 2: at 2 the clock cut into an ordinary working pause —
# reading a diff, writing a long prompt — and the board looked like it had
# given up on a session that was still alive. The swap has to mean "done for
# now", not "you took a while".
REST_S = 300

# Mascot states. The board only receives the string.
IDLE = "idle"            # still, breathing
WORKING = "working"      # processing
TOOL = "tool"            # running a tool
ASKING = "asking"        # asked a question, blocked waiting for your answer
WAITING = "waiting"      # waiting for permission to act
DONE = "done"            # just finished
ERROR = "error"          # failed

# Tools that mean "Claude stopped and the ball is in your court".
# AskUserQuestion: a question with options. ExitPlanMode: a plan to approve.
BLOCKING_TOOLS = {"AskUserQuestion", "ExitPlanMode"}


def _question_label(tool: str, tool_input) -> str:
    """
    Extracts a short label for whatever is being asked.

    AskUserQuestion carries questions[].header, which already arrives at ~12
    chars max because it is designed to become a chip in the UI — a perfect fit
    for a 480px screen.
    """
    if tool == "ExitPlanMode":
        return "approve plan"
    qs = (tool_input or {}).get("questions") or []
    if not qs:
        return "question"
    first = qs[0] if isinstance(qs[0], dict) else {}
    label = first.get("header") or first.get("question") or "question"
    if len(qs) > 1:
        label = f"{label} +{len(qs) - 1}"
    return label


def _notification_label(msg) -> str:
    """Shortens the Claude Code notification so it fits in a bubble.

    What arrives here is a whole sentence: "Claude needs your permission to use
    AskUserQuestion" is 51 characters. The floating bubble is 190pt wide and the
    board truncates at 40 — the sentence overflowed both.

    And the sentence does not need saying: the mascot ALREADY looks like it
    asked for permission, and the panel ALREADY says which project. The only new
    information is the last word, the tool name. Same reasoning as
    _question_label just above, which already solved this for the other path.
    """
    m = (msg or "").strip()
    if not m:
        return "needs you"
    marker = "permission to use "
    i = m.lower().find(marker)
    if i >= 0:
        return m[i + len(marker):].strip(" .") or "permission"
    if "waiting for your input" in m.lower():
        return "waiting for input"
    # Unknown format: return it whole instead of cutting blind. The display
    # side wraps to two lines now, so a long sentence looks ugly — not
    # unreadable.
    return m


# How many sessions the board can show at once. Beyond that the mascots would
# be too small to say anything.
MAX_SESSIONS = 4
# A session only appears on screen while it is ACTIVE. Stop iterating for this
# long and it disappears — an open, forgotten session is not information, it is
# clutter.
SESSION_ACTIVE_S = 30
# States in which a session does NOT expire from inactivity.
#
# A session blocked waiting for you stops emitting hooks — that is exactly what
# "blocked" means. Under the 30-second rule it counted as inactive and vanished
# from the screen, with the clock taking its place. The state that most needs
# to be seen was the first one to disappear.
#
# These stay until you answer, until another event overwrites them, or until
# the session dies for good. ERROR is in here too: a failure that clears itself
# in half a minute is a failure you never saw.
BLOCKED = {ASKING, WAITING, ERROR}
# ...but not forever. A request left unanswered for 15 minutes is an orphaned
# request: you walked away, the session died without saying so, or the answer
# came through a path that fires no hook. A permanently blocked state stops
# being information and becomes noise — worse, noise that looks urgent.
BLOCKED_MAX_S = 15 * 60
# States in which silence means "still busy", not "stopped".
#
# A hook only fires on the EDGES of a tool: PreToolUse when it starts,
# PostToolUse when it ends. Nothing comes between them. A nine-minute test
# suite is, from the bridge's point of view, nine minutes of absolute silence —
# indistinguishable from an abandoned terminal if all you look at is the clock.
#
# That is how two working sessions disappeared from the screen at the same
# time. The mascot went idle and then gave way to the clock, while both Claudes
# were running tests at full speed.
#
# BLOCKED just above already carries exactly this reasoning for whoever is
# waiting on YOU. It holds equally for whoever is waiting on a TOOL: in both
# cases the lack of news IS the signature of the state, not the absence of one.
BUSY = {TOOL, WORKING}
# Its own ceiling, and larger than the blocked one: 15 minutes is a lot for a
# human to leave a request unanswered, and very little for a big build or test
# suite. Past this, the terminal probably died halfway.
BUSY_MAX_S = 45 * 60
# After this we drop it from memory: the terminal probably died without firing
# SessionEnd (tab closed, ssh dropped).
SESSION_DEAD_S = 3 * 3600


def _local_ips() -> set:
    """Every address of this machine, so we never mistake one for the board."""
    import socket as _s
    try:
        return {i[4][0] for i in _s.getaddrinfo(_s.gethostname(), None)}
    except OSError:
        return set()


def _new_session() -> dict:
    return {"status": IDLE, "detail": "", "model": "", "project": "",
            "last_event": 0.0, "done_at": 0.0}


class State:
    def __init__(self):
        self.lock = threading.Lock()
        # session_id -> dict. There used to be a single global state; the
        # session_id arrived in every hook and was ignored. Now it is the key.
        self.sessions = {}
        self.events_seen = 0
        self.usage = {}
        self.usage_at = 0.0
        # Usage over the 5h and 7d windows, computed from the transcripts.
        # It exists because Claude Code's limits cache can go stale (seen: 3
        # days) and there is no local way to force it to refresh.
        self.windows = {}
        # Limits fetched LIVE by the menu bar app, which has its own keychain
        # access. Takes precedence over Claude Code's on-disk cache, which is
        # only rewritten when something triggers a fetch — seen stuck 3 days.
        #
        # Loaded from disk on boot, on purpose: restarting the bridge is not a
        # reason to forget a reading. The app restarts the bridge whenever it
        # is relaunched, and starting empty meant falling straight back to a
        # two-day-old cache showing windows that had already reset.
        self.live_limits, self.live_limits_at = limits.load_live()
        self.limits_error = ""
        # Who was the last NON-local client to fetch /state, and when. That is
        # how we know the board is alive: it is the only thing fetching from
        # outside. The menu bar app reads this to show the link.
        self.board_ip = ""
        self.board_at = 0.0
        # The board's battery charge. It measures on the AXP2101 and sends it
        # along with the /state request; we only store it here. -1 = never
        # reported (board on the cable, old firmware, or no cell installed).
        self.board_bat = -1
        self.board_bat_chg = False
        # How many tasks have finished. The menu bar app watches this counter
        # to know WHEN it is worth asking Anthropic for the limits: the number
        # only moves when you consume, so asking right after consuming is the
        # only moment the answer can be different.
        self.tasks_done = 0
        self.started_at = time.time()
        # Parade: shows each state for a few seconds, so you can check the
        # visuals without provoking eight real situations. It expires on its
        # own — a demo mode left running becomes a lie on the screen.
        self.parade_until = 0.0
        self.parade_secs = 10.0

    def apply(self, payload: dict) -> None:
        """Translates a Claude Code hook event into a mascot state."""
        ev = payload.get("hook_event_name") or ""
        now = time.time()

        sid = payload.get("session_id") or "?"

        with self.lock:
            self.events_seen += 1
            ss = self.sessions.setdefault(sid, _new_session())
            ss["last_event"] = now

            if cwd := payload.get("cwd"):
                ss["project"] = cwd.rstrip("/").split("/")[-1]
            if model := (payload.get("model") or {}).get("id"):
                ss["model"] = model

            if ev == "SessionEnd":
                # The session really ended: disappear from the screen instead
                # of becoming a ghost idle mascot.
                self.sessions.pop(sid, None)
                return

            if ev == "UserPromptSubmit":
                ss["status"], ss["detail"] = WORKING, "thinking"
            elif ev == "PreToolUse":
                tool = payload.get("tool_name") or "tool"
                if tool in BLOCKING_TOOLS:
                    # Claude is not working: it is blocked waiting for you.
                    ss["status"] = ASKING
                    ss["detail"] = _question_label(tool, payload.get("tool_input"))
                else:
                    ss["status"], ss["detail"] = TOOL, tool
            elif ev == "PostToolUse":
                ss["status"], ss["detail"] = WORKING, "processing"
            elif ev == "PostToolUseFailure":
                ss["status"] = ERROR
                ss["detail"] = payload.get("tool_name") or "failed"
            elif ev in ("Notification", "PermissionRequest"):
                ss["status"] = WAITING
                ss["detail"] = _notification_label(payload.get("message"))
            elif ev in ("Stop", "TaskCompleted"):
                ss["status"], ss["detail"] = DONE, "done"
                ss["done_at"] = now
                self.tasks_done += 1
            elif ev == "StopFailure":
                ss["status"], ss["detail"] = ERROR, "error"
            elif ev == "SessionStart":
                ss["status"], ss["detail"] = IDLE, "ready"
            elif ev == "SessionEnd":
                ss["status"], ss["detail"] = IDLE, ""
            elif ev in ("SubagentStart", "SubagentStop"):
                ss["status"], ss["detail"] = WORKING, "subagent"

    PARADE_ORDER = [IDLE, WORKING, TOOL, ASKING, WAITING, DONE, ERROR]

    def snapshot(self) -> dict:
        """Lean payload for the board — an ESP32 parsing JSON, no fat."""
        now = time.time()
        with self.lock:
            if now < self.parade_until:
                i = int((now - (self.parade_until - self._parade_total))
                        / self.parade_secs) % len(self.PARADE_ORDER)
                st = self.PARADE_ORDER[i]
                left = int(self.parade_until - now)
                return {"s": [{"st": st, "dt": st, "pj": f"demo {left}s",
                               "md": "", "age": 0}],
                        "n": 1, "age": 0, "reqs": 0, "tok_out": 0,
                        "clk": time.strftime("%H:%M"), "day": time.strftime("%a %d %b"),
                        "rest": 0, "lim": [], "lim_age": -1, "peak": -1,
                        "lim_src": ""}

            # Clean out sessions whose terminal died without saying so.
            for sid in [k for k, v in self.sessions.items()
                        if now - v["last_event"] > SESSION_DEAD_S]:
                del self.sessions[sid]

            # Only the ACTIVE ones go to the screen. The rest stay in memory
            # (they come back on their own on a new event), they just do not
            # show.
            alive = [v for v in self.sessions.values()
                     if now - v["last_event"] <= SESSION_ACTIVE_S
                     or (v["status"] in BLOCKED
                         and now - v["last_event"] <= BLOCKED_MAX_S)
                     or (v["status"] in BUSY
                         and now - v["last_event"] <= BUSY_MAX_S)]
            # Most recent first: with little room, whoever is working now
            # matters more than whoever stopped 25 seconds ago.
            ordered = sorted(alive, key=lambda v: -v["last_event"])[:MAX_SESSIONS]

            sessions = []
            for v in ordered:
                status, detail = v["status"], v["detail"]
                # "done" decays to idle on its own
                if status == DONE and now - v["done_at"] > DONE_LINGER_S:
                    status, detail = IDLE, ""
                # We no longer demote to idle because of silence.
                #
                # This used to say: WORKING/TOOL quiet for more than
                # STALE_AFTER_S (3 min) became IDLE, justified as "it is not
                # really running". The justification was false — a long tool
                # emits no hook, and that was the most common cause of silence.
                #
                # The BUSY_MAX_S ceiling already covers the terminal that died
                # halfway: it drops out of the list entirely, instead of
                # becoming an idle mascot lying that nothing is happening.
                sessions.append({
                    "st": status,
                    "dt": detail[:40],
                    "pj": v["project"][:24],
                    "md": v["model"].replace("claude-", "")[:20],
                    "age": int(now - v["last_event"]),
                })

            u = self.usage.get("total", {})
            # Silence since the last event of ANY session, alive or not.
            #
            # This number used to come only from the ACTIVE ones, so it turned
            # into -1 at the exact instant the list emptied — that is, it
            # vanished right when it starts to matter. It is what the board
            # uses to count down to the clock, so it has to keep existing after
            # the mascot leaves.
            last_any = max((v["last_event"] for v in self.sessions.values()),
                         default=0.0)

        # -1 = no session known since the bridge came up. It is not "idle for
        # zero seconds"; it is "there is nothing to wait for", and the board
        # treats it that way.
        idle_age = int(now - last_any) if last_any else -1

        snap = {
            "s": sessions,
            "n": len(sessions),
            "age": idle_age,
            "reqs": u.get("requests", 0),
            "tok_out": u.get("output", 0),
        }

        # Clock: we send it preformatted so the ESP32 does no calendar maths.
        # Pure ASCII — the LVGL fonts have no accents.
        snap["clk"] = time.strftime("%H:%M")
        snap["day"] = time.strftime("%a %d %b")
        snap["rest"] = REST_S

        if (wx := WEATHER.read()):
            snap["wx"] = wx

        lim = self.subscription_limits()
        if lim.get("ok"):
            snap["lim"] = [
                {"l": b["label"], "p": b["pct"], "r": b["resets_in"],
                 "s": b["severity"], "a": b["active"],
                 "x": bool(b.get("expired"))}
                for b in lim["bars"]
            ]
            snap["lim_age"] = lim["age_s"]
            snap["lim_src"] = lim.get("source", "cache")
            snap["peak"] = lim["peak"]
        else:
            snap["lim"] = []
            snap["lim_age"] = -1
            snap["lim_src"] = ""
            snap["peak"] = -1

        return snap

    def subscription_limits(self) -> dict:
        """
        Subscription limits, from whichever source read them MOST RECENTLY.

        There are two: what the app fetched live, and Claude Code's on-disk
        cache. The app can only fetch because it has its own keychain access,
        through the macOS API and with your consent — the bridge never sees the
        credential, which is why it can still run on its own in a terminal.

        The rule used to be a deadline: past 10 minutes the live reading
        "stopped counting" and we fell back to the cache. It was the wrong
        rule, and it is what produced the bug this replaces. The app only
        refreshes every 10 min while you are spending and up to an hour when
        you are not, so the live reading expired BEFORE it was renewed — and
        what took its place was Claude Code's cache, which had been sitting
        untouched for 43 hours with every window past its reset. The panel
        spent most of the day showing "cache from 1d" and a frozen 52%.

        A deadline answers the wrong question. What matters is not whether a
        reading is old, it is whether anything KNOWS BETTER. Between two
        readings the newer one wins, and its age is reported so nobody has to
        take it on faith. A live reading half an hour old only misses what you
        spent in that half hour; the cache underneath misses two days.
        """
        with self.lock:
            live, fetched = self.live_limits, self.live_limits_at
        cache = limits.read()
        if live:
            r = limits.normalize(live, int(max(0, time.time() - fetched)))
            if r.get("ok") and fetched >= cache.get("fetched_at", 0):
                r["source"] = "live"
                return r
        if cache.get("ok"):
            cache["source"] = "cache"
        return cache

    def refresh_usage(self) -> None:
        """Recomputes today's usage in the background."""
        while True:
            try:
                r = usage.collect(since_days=1)
                if "error" not in r:
                    with self.lock:
                        self.usage = r
                        self.usage_at = time.time()
                j = rolling.calculate()
                if j.get("ok"):
                    with self.lock:
                        self.windows = j
            except Exception as exc:  # never take the server down over stats
                print(f"[usage] failed: {exc}", file=sys.stderr)
            time.sleep(USAGE_REFRESH_S)


STATE = State()
WEATHER = weather.Weather()


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: dict) -> None:
        raw = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _local(self) -> bool:
        ip = self.client_address[0]
        return ip.startswith("127.") or ip == "::1"

    def _authorized(self) -> bool:
        """
        Anything coming from outside has to present the token.

        The bridge listens on 0.0.0.0 out of necessity: the board talks to it
        over the network. Without this check, anyone on the same network —
        coworking space, café, office — could read project names and usage
        volume just by pointing a browser at it. The menu bar app runs on the
        machine itself and is therefore exempt.
        """
        if self._local():
            return True
        cfg = config.read()
        if not cfg.get("require_token"):
            return True   # explicitly open mode (board on old firmware)
        expected = cfg.get("token") or ""
        given = self.headers.get("X-Wisp-Token") or ""
        if not given:
            # ?t= exists so you can test from a browser.
            given = (parse_qs(urlparse(self.path).query).get("t") or [""])[0]
        # compare_digest: constant-time comparison, so the token does not leak
        # character by character through response timing.
        return bool(expected) and secrets.compare_digest(given, expected)

    def do_GET(self):
        route = urlparse(self.path).path

        if not self._authorized():
            self._send(401, {"error": "token"})
            return

        if route == "/parade":
            if not self._local():
                self._send(403, {"error": "local only"})
                return
            q = parse_qs(urlparse(self.path).query)
            secs = float((q.get("s") or ["10"])[0])
            with STATE.lock:
                STATE.parade_secs = secs
                STATE._parade_total = secs * len(STATE.PARADE_ORDER)
                STATE.parade_until = time.time() + STATE._parade_total
            self._send(200, {"ok": True, "seconds": STATE._parade_total})
            return

        if route == "/state":
            # Only something from OUTSIDE this machine counts as "the board".
            #
            # It used to be enough not to be 127.0.0.1, so any test of mine over
            # the LAN IP was recorded as if it were the board — the panel said
            # it was alive when it was really just me knocking. A diagnostic
            # that lies is worse than no diagnostic.
            ip = self.client_address[0]
            if not self._local() and ip not in _local_ips():
                # The charge rides along on this same request, as a query. We
                # only accept it from something we already recognise as the
                # board, for the same reason as the block above: a number
                # planted by another machine would become a false diagnostic.
                q = parse_qs(urlparse(self.path).query)
                bat = chg = None
                try:
                    if "bat" in q:
                        bat = int(q["bat"][0])
                        # Outside 0-100 is not a reading, it is a fault. Drop
                        # it instead of propagating: better to keep the last
                        # good value.
                        if not 0 <= bat <= 100:
                            bat = None
                    if "chg" in q:
                        chg = q["chg"][0] == "1"
                except (ValueError, IndexError):
                    bat = chg = None
                with STATE.lock:
                    STATE.board_ip = ip
                    STATE.board_at = time.time()
                    if bat is not None:
                        STATE.board_bat = bat
                    if chg is not None:
                        STATE.board_bat_chg = chg
            self._send(200, STATE.snapshot())
        elif route == "/app":
            # Menu bar app payload. Kept apart from /state on purpose: the
            # board should not carry bytes that only matter to the Mac.
            snap = STATE.snapshot()
            now = time.time()
            with STATE.lock:
                board_ip, board_at = STATE.board_ip, STATE.board_at
                board_bat = STATE.board_bat
                board_bat_chg = STATE.board_bat_chg
                tasks_done = STATE.tasks_done
                started, events = STATE.started_at, STATE.events_seen
                total = STATE.usage.get("total", {})
                models = STATE.usage.get("by_model", {})
                win = dict(STATE.windows)
            self._send(200, {
                "uptime_s": int(now - started),
                "events": events,
                "board_ip": board_ip,
                # -1 = the board has never shown up since the bridge started
                "board_age_s": int(now - board_at) if board_at else -1,
                # -1 = the board never reported a charge
                "board_bat": board_bat,
                "board_bat_chg": board_bat_chg,
                "tasks_done": tasks_done,
                "sessions": snap["s"],
                "limits": snap["lim"],
                "limits_age_s": snap["lim_age"],
                "limits_source": snap.get("lim_src", ""),
                "limits_error": STATE.limits_error,
                "peak": snap["peak"],
                "usage": total,
                "models": models,
                "weather": snap.get("wx"),
                # The app says so plainly when the network is open. A silent
                # insecure mode becomes a permanent insecure mode.
                "open_network": not config.read().get("require_token", True),
                "windows": win,
            })
        elif route == "/health":
            self._send(200, {"ok": True})
        elif route == "/debug":
            with STATE.lock:
                self._send(200, {
                    "sessions": STATE.sessions,
                    "events_seen": STATE.events_seen,
                    "usage_total": STATE.usage.get("total"),
                    "by_model": STATE.usage.get("by_model"),
                })
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._authorized():
            self._send(401, {"error": "token"})
            return
        route = urlparse(self.path).path

        if route == "/limits":
            # From inside the machine only: the menu bar app is what delivers
            # this. Accepting it from outside would let anyone on the network
            # plant false numbers on your screen.
            if not self._local():
                self._send(403, {"error": "local only"})
                return
            try:
                n = int(self.headers.get("Content-Length") or 0)
                payload = json.loads(self.rfile.read(n) or b"{}")
            except (ValueError, json.JSONDecodeError):
                self._send(400, {"error": "json"})
                return
            now = time.time()
            with STATE.lock:
                if "error" in payload:
                    # App failure: we keep the reason and do NOT touch the last
                    # good reading, which is still the best one we have.
                    STATE.limits_error = str(payload["error"])[:200]
                    fresh = False
                else:
                    STATE.live_limits = payload
                    STATE.live_limits_at = now
                    STATE.limits_error = ""
                    fresh = True
            # Outside the lock: this writes a file, and the /state the board is
            # polling every 600ms takes the same lock.
            if fresh:
                limits.save_live(payload, now)
            self._send(200, {"ok": True})
            return

        if route != "/hook":
            self._send(404, {"error": "not found"})
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, json.JSONDecodeError):
            payload = {}
        STATE.apply(payload)
        # Empty response: the hook must not influence Claude in any way.
        self._send(200, {})

    def log_message(self, *args):
        pass  # no noise in the terminal


def _shutdown(signum=None, frame=None):
    """
    Clean exit: bring the dns-sd processes down before dying.

    Without this they become orphans of PID 1 and go on announcing a bridge
    that no longer exists — the board would find the name, connect, and get
    refused. announce.py's atexit does NOT cover this case: the default SIGTERM
    handling ends the process without going through it.
    """
    announce.stop()
    sys.stdout.flush()
    sys.stderr.flush()
    # os._exit and not sys.exit: this same code is called from the thread that
    # watches the app, and there sys.exit() would only raise SystemExit in THAT
    # thread — measured, the dns-sd processes died and the server stayed up
    # answering on the port. os._exit ends the process wherever it is called.
    os._exit(0)


def _watch_parent():
    """
    If the menu bar app dies, we die with it.

    The app calls terminate() on exit, which covers the clean shutdown. It does
    not cover force-quit or a crash: measured, the bridge outlived the app and
    was re-adopted by PID 1, serving forever after.

    macOS has no PR_SET_PDEATHSIG, so we check by hand. It only engages when
    WISP_PARENT is set — running from a terminal this should not apply, because
    there the process legitimately starts with its parent already gone.
    """
    parent = os.environ.get("WISP_PARENT", "")
    if not parent.isdigit():
        return
    pid = int(parent)

    def loop():
        while True:
            time.sleep(3)
            try:
                os.kill(pid, 0)   # signal 0 sends nothing: it only tests existence
            except OSError:
                print(f"[bridge] the app (pid {pid}) is gone, shutting down",
                      file=sys.stderr)
                _shutdown()

    threading.Thread(target=loop, daemon=True).start()


def main():
    cfg = config.read()
    port = int(sys.argv[1]) if len(sys.argv) > 1 else cfg["port"]
    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)
    _watch_parent()
    threading.Thread(target=STATE.refresh_usage, daemon=True).start()
    WEATHER.start()
    # Announce the bridge under a fixed name, so the board does not depend on
    # the Mac's hostname (which macOS renames on its own on a conflict).
    announce.start(port)
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"bridge listening on 0.0.0.0:{port}")
    print(f"  board fetch : GET  /state")
    print(f"  hooks       : POST /hook")
    print(f"  inspect     : GET  /debug")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down")


if __name__ == "__main__":
    main()
