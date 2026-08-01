"""The harness's own Chrome DevTools Protocol client.

Runner contract, in call order: `discover_port(profiles_root, profile)` finds the
port the daemon-launched Chrome published in `DevToolsActivePort` (the daemon
launches with `--remote-debugging-port=0`, so the port is OS-assigned and the
profile directory name is an unpredictable conversation-key hash — a glob over
`<FERMIX_HOME>/browser/profiles/*/<profile>/` picking the newest mtime is the only
way to find it), cross-checked against `GET /json/version`;
`wait_for_target(port, needle, ...)` polls `/json/list` until the fixture page
exists; `CdpClient(ws_url)` opens ONE browser-level websocket and
`attach(target_id)` gets a flattened page session (`Target.attachToTarget` with
`flatten: true`, the same shape the daemon's own ProfileServer uses — a second
concurrent CDP client is a platform fact this harness asserts at calibration
rather than assumes); `apply_window_bounds` + `bring_to_front` make geometry
deterministic and harness-owned; `PageWatcher.poll_once()` is the 500 ms readback
that snapshots `window.__aim` and one focus/visibility/scroll sample per tick.

`CdpClient.closed_at_ms` timestamps the socket close, which is what lets score.py
tell a browser death (`browser_lost`) apart from a stray off-page click.
Everything above the `--- live ---` marker is pure and hermetically tested; the
socket half is exercised only against a real daemon.
"""

from __future__ import annotations

import glob
import json
import os
import time
import urllib.request
from dataclasses import dataclass

POLL_INTERVAL_S = 0.5
POLL_INTERVAL_MS = 500
DISCOVERY_TIMEOUT_S = 120.0
TARGET_TIMEOUT_S = 120.0
# A response can be preceded by unsolicited protocol events; read past a bounded
# number of them, then fail loud rather than block forever on a chatty target.
MAX_INTERLEAVED_MESSAGES = 500
RECV_TIMEOUT_S = 20.0
DEFAULT_PROFILE = "fermix_visible"


class CdpError(RuntimeError):
    """A CDP discovery, transport, or evaluation step failed. Always typed and named."""


# --- port discovery (pure over a filesystem tree) ----------------------------

def profile_glob(profiles_root: str, profile: str = DEFAULT_PROFILE) -> str:
    return os.path.join(profiles_root, "*", profile, "DevToolsActivePort")


def read_devtools_port(path: str) -> int | None:
    """Line 1 of `DevToolsActivePort` is the bound port. Returns None for a missing
    or malformed file — a half-written file during Chrome start is expected, and
    the caller keeps polling."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            first = handle.readline().strip()
    except (OSError, UnicodeDecodeError):
        return None
    if not first.isdigit():
        return None
    port = int(first)
    return port if 0 < port < 65536 else None


def newest_port_file(profiles_root: str, profile: str = DEFAULT_PROFILE,
                     since_ms: float | None = None) -> str | None:
    """Newest `DevToolsActivePort` across all owner-key directories, or None.
    `since_ms` is a freshness floor in epoch ms: a home accumulates one profile
    directory per conversation and Chrome does not always remove the file, so
    without a floor the newest one can belong to a browser this run never
    launched — attaching to that is measuring the wrong window."""
    paths = glob.glob(profile_glob(profiles_root, profile))
    stamped = [(os.path.getmtime(p), p) for p in paths if os.path.exists(p)]
    if since_ms is not None:
        stamped = [(mtime, p) for mtime, p in stamped if mtime * 1000.0 >= since_ms]
    if not stamped:
        return None
    return max(stamped)[1]


def count_profile_dirs(profiles_root: str) -> int:
    """How many browser-profile directories exist. Each batch conversation creates
    one and nothing cleans them; the report records the growth so the accumulation
    is visible. The harness NEVER deletes anything in the operator's home."""
    if not os.path.isdir(profiles_root):
        return 0
    return sum(1 for name in os.listdir(profiles_root)
               if os.path.isdir(os.path.join(profiles_root, name)))


def discover_port(profiles_root: str, profile: str = DEFAULT_PROFILE,
                  timeout_s: float = DISCOVERY_TIMEOUT_S, sleep=time.sleep,
                  since_ms: float | None = None) -> int:
    """Poll for the newest readable DevTools port written since `since_ms`. Fails
    loud at the cap instead of waiting on a Chrome that never started."""
    deadline = time.monotonic() + timeout_s
    while True:
        path = newest_port_file(profiles_root, profile, since_ms)
        port = read_devtools_port(path) if path else None
        if port is not None:
            return port
        if time.monotonic() >= deadline:
            raise CdpError(f"no readable DevToolsActivePort under {profile_glob(profiles_root, profile)} "
                           f"after {timeout_s:.0f}s — the managed browser never started")
        sleep(POLL_INTERVAL_S)


# --- message framing (pure) --------------------------------------------------

class Framer:
    """Monotonic CDP message ids plus request encoding. One framer per socket."""

    def __init__(self, start: int = 1) -> None:
        if start < 1:
            raise CdpError(f"message ids start at 1, got {start}")
        self._next = start

    def next_id(self) -> int:
        value = self._next
        self._next += 1
        return value

    def command(self, method: str, params: dict | None = None,
                session_id: str | None = None) -> tuple[int, str]:
        if not method:
            raise CdpError("a CDP command needs a method name")
        msg_id = self.next_id()
        payload: dict = {"id": msg_id, "method": method, "params": params or {}}
        if session_id:
            payload["sessionId"] = session_id
        return msg_id, json.dumps(payload)


def decode(text: str) -> dict:
    try:
        msg = json.loads(text)
    except json.JSONDecodeError as exc:
        raise CdpError(f"undecodable CDP frame: {exc}") from exc
    if not isinstance(msg, dict):
        raise CdpError(f"CDP frame is not an object: {type(msg).__name__}")
    return msg


def is_response(msg: dict, msg_id: int) -> bool:
    return msg.get("id") == msg_id


def result_of(msg: dict) -> dict:
    """The `result` of a command reply, or a typed error carrying the protocol's
    own words (never a bare status)."""
    if "error" in msg:
        err = msg["error"]
        raise CdpError(f"CDP error {err.get('code')}: {err.get('message')}")
    result = msg.get("result")
    if not isinstance(result, dict):
        raise CdpError(f"CDP reply carried no result object: {msg!r}")
    return result


def evaluate_params(expression: str) -> dict:
    if not expression:
        raise CdpError("Runtime.evaluate needs an expression")
    return {"expression": expression, "returnByValue": True, "awaitPromise": False}


def evaluate_value(result: dict):
    """The value from a `Runtime.evaluate` result. A page-side throw surfaces the
    page's own exception text — the harness must never see a bare failure."""
    details = result.get("exceptionDetails")
    if details:
        text = (details.get("exception") or {}).get("description") or details.get("text")
        raise CdpError(f"page evaluation threw: {text}")
    return (result.get("result") or {}).get("value")


# --- focus/occlusion sampling (pure) ----------------------------------------

@dataclass(frozen=True)
class FocusSample:
    t_ms: float
    has_focus: bool
    visible: bool
    scroll_x: float
    scroll_y: float


SAMPLE_EXPRESSION = ("JSON.stringify({t: Date.now(), f: document.hasFocus(), "
                     "v: document.visibilityState, sx: window.scrollX, sy: window.scrollY})")


def parse_sample(payload) -> FocusSample:
    raw = json.loads(payload) if isinstance(payload, str) else payload
    if not isinstance(raw, dict):
        raise CdpError(f"focus sample is not an object: {raw!r}")
    return FocusSample(t_ms=float(raw["t"]), has_focus=bool(raw["f"]),
                       visible=raw["v"] == "visible",
                       scroll_x=float(raw["sx"]), scroll_y=float(raw["sy"]))


def focus_gaps(samples: list[FocusSample]) -> list[tuple[float, float]]:
    """Merged spans in which the page was not focused or not visible. Each span is
    padded by one poll interval on both sides: a click between two samples is
    unobservable, so the conservative reading is that the gap covers it."""
    gaps: list[tuple[float, float]] = []
    for sample in samples:
        if sample.has_focus and sample.visible:
            continue
        start, end = sample.t_ms - POLL_INTERVAL_MS, sample.t_ms + POLL_INTERVAL_MS
        if gaps and start <= gaps[-1][1]:
            gaps[-1] = (gaps[-1][0], max(gaps[-1][1], end))
        else:
            gaps.append((start, end))
    return gaps


def in_gap(t_ms: float, gaps: list[tuple[float, float]]) -> bool:
    return any(start <= t_ms <= end for start, end in gaps)


# --- live -------------------------------------------------------------------

def http_json(port: int, path: str, timeout_s: float = 5.0):
    url = f"http://127.0.0.1:{port}{path}"
    try:
        with urllib.request.urlopen(url, timeout=timeout_s) as resp:  # noqa: S310 - loopback only
            return json.loads(resp.read().decode("utf-8"))
    except (OSError, ValueError) as exc:
        raise CdpError(f"CDP endpoint {url} unreachable or unreadable: {exc}") from exc


def browser_websocket_url(port: int) -> str:
    """Cross-check the discovered port really belongs to a DevTools endpoint and
    return its browser-level websocket url."""
    version = http_json(port, "/json/version")
    url = version.get("webSocketDebuggerUrl")
    if not url:
        raise CdpError(f"port {port} answered /json/version without a webSocketDebuggerUrl")
    return url


def browser_version(port: int) -> str:
    return str(http_json(port, "/json/version").get("Browser") or "unknown")


def find_target(port: int, needle: str) -> dict | None:
    for target in http_json(port, "/json/list"):
        if target.get("type") == "page" and needle in (target.get("url") or ""):
            return target
    return None


def wait_for_target(port: int, needle: str, timeout_s: float = TARGET_TIMEOUT_S,
                    sleep=time.sleep) -> dict:
    deadline = time.monotonic() + timeout_s
    while True:
        target = find_target(port, needle)
        if target:
            return target
        if time.monotonic() >= deadline:
            raise CdpError(f"no page target matching {needle!r} after {timeout_s:.0f}s — "
                           "the model never opened the fixture page")
        sleep(POLL_INTERVAL_S)


class CdpClient:
    """One browser-level websocket. Page work rides a flattened attached session."""

    def __init__(self, ws_url: str) -> None:
        self._ws_url = ws_url
        self._framer = Framer()
        self._conn = None
        self.closed_at_ms: float | None = None

    def __enter__(self) -> "CdpClient":
        from websockets.sync.client import connect  # imported here: only the live path needs it

        self._conn = connect(self._ws_url, max_size=32 * 1024 * 1024,
                             open_timeout=RECV_TIMEOUT_S)
        return self

    def __exit__(self, *_exc) -> None:
        self.close()

    def close(self) -> None:
        if self._conn is None:
            return
        self._conn.close()
        self._conn = None
        # First observed close wins: a transport failure already stamped the moment
        # the browser went away, and overwriting it with the tidy-up time would
        # hide every click that happened after a dead browser (`browser_lost`).
        if self.closed_at_ms is None:
            self.closed_at_ms = time.time() * 1000.0

    def send(self, method: str, params: dict | None = None, session_id: str | None = None) -> dict:
        if self._conn is None:
            raise CdpError(f"socket is closed; cannot send {method}")
        msg_id, text = self._framer.command(method, params, session_id)
        self._conn.send(text)
        return result_of(self._await_response(msg_id, method))

    def _await_response(self, msg_id: int, method: str) -> dict:
        """Read past unsolicited events up to a hard cap. Reaching the cap is a
        named failure, not a longer wait."""
        for _ in range(MAX_INTERLEAVED_MESSAGES):
            try:
                msg = decode(self._conn.recv(timeout=RECV_TIMEOUT_S))
            except CdpError:
                raise
            except Exception as exc:  # transport failures carry the library's words
                self.closed_at_ms = time.time() * 1000.0
                raise CdpError(f"CDP transport failed waiting for {method}: {exc}") from exc
            if is_response(msg, msg_id):
                return msg
        raise CdpError(f"no reply to {method} after {MAX_INTERLEAVED_MESSAGES} intervening frames")

    def attach(self, target_id: str) -> str:
        result = self.send("Target.attachToTarget", {"targetId": target_id, "flatten": True})
        session_id = result.get("sessionId")
        if not session_id:
            raise CdpError(f"Target.attachToTarget returned no sessionId for {target_id}")
        return session_id

    def evaluate(self, expression: str, session_id: str):
        return evaluate_value(self.send("Runtime.evaluate", evaluate_params(expression), session_id))


def apply_window_bounds(client: CdpClient, target_id: str, session_id: str) -> dict:
    """Own the window geometry deterministically: fill the available screen at the
    origin, normal state, front-most. Chrome is launched with no size/position
    flags, so nothing else in the system decides this."""
    avail = client.evaluate("JSON.stringify([screen.availWidth, screen.availHeight])", session_id)
    width, height = json.loads(avail)
    window_id = client.send("Browser.getWindowForTarget", {"targetId": target_id})["windowId"]
    client.send("Browser.setWindowBounds", {
        "windowId": window_id,
        "bounds": {"left": 0, "top": 0, "width": int(width), "height": int(height),
                   "windowState": "normal"}})
    client.send("Page.bringToFront", {}, session_id)
    return client.send("Browser.getWindowBounds", {"windowId": window_id})["bounds"]


class PageWatcher:
    """Idempotent full-state readback of the fixture page plus one focus sample per
    tick. `latest` always holds the newest complete `window.__aim`, so the record
    survives the browser being reaped at turn end."""

    def __init__(self, client: CdpClient, session_id: str) -> None:
        self._client = client
        self._session = session_id
        self.latest: dict | None = None
        self.samples: list[FocusSample] = []

    def poll_once(self) -> tuple[dict, FocusSample]:
        raw = self._client.evaluate("JSON.stringify(window.__aim)", self._session)
        if not isinstance(raw, str):
            raise CdpError(f"the attached page returned no window.__aim state (got {raw!r}) — "
                           "the fixture page is no longer the target this session is on")
        state = json.loads(raw)
        sample = parse_sample(self._client.evaluate(SAMPLE_EXPRESSION, self._session))
        self.latest = state
        self.samples.append(sample)
        return state, sample

    def set_ready(self) -> bool:
        return bool(self._client.evaluate("window.__aim.setReady()", self._session))
