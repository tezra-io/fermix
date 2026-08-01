"""Readers and parsers for the daemon's local JSONL traces.

Runner contract: `read_jsonl(traces_root, "tool_exec")` returns every tool row the
daemon wrote under `<FERMIX_HOME>/traces/YYYY-MM-DD/`, `rows_for_turn` narrows
to one batch, and `classify_row` labels each row as a delivered click, another
pointer action, a screenshot, or a typed refusal. `parse_cursor_echo`,
`parse_not_delivered`, `parse_sent_dims` and `classify_refusal` read the exact
strings the daemon renders (each anchor below carries its file:line), and
`parse_elixir_input` decodes the `input` field — which Fermix writes as an Elixir
`inspect` map, not JSON.

Two trace preconditions are separate on purpose (they have different causes and
different fixes): `check_trace_visibility` asks whether the run's rows are on disk
where the harness is looking at all, and `check_capture_content` asks whether
those rows carry `input`. `browser_rail_violations` is the rail guard: the fixture
page cannot tell a real OS click from a browser-tool CDP click, so the trace is
the only place a rail violation is visible.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from datetime import datetime

# `session.ex:341-345` — the complete pointer-action set. Only the three that put a
# button down count as a probe's click; the rest are recorded and never matched,
# so a stray scroll can never masquerade as an off-page click (F6).
DELIVERED_ACTIONS = frozenset({"left_click", "right_click", "double_click"})
OTHER_POINTER_ACTIONS = frozenset({"mouse_move", "left_click_drag", "scroll", "inspect"})
CLICK_EVENTS_PER_ACTION = {"left_click": 1, "right_click": 0, "double_click": 2}

# `browser.ex:19` actions plus `browser.ex:35` act kinds. The batch prompt pins the
# browser tool to open + act/wait; anything else could have produced the page click.
# `doctor` is a deliberate addition to F2's literal set: `browser.ex:48-50` shows it
# returns `chrome_diagnostics(config)` and never reaches a page, so it cannot have
# produced the click — voiding a batch over it would discard real data.
BROWSER_ALLOWED_ACTIONS = frozenset({"open", "navigate", "status", "doctor", "act"})
BROWSER_ALLOWED_ACT_KINDS = frozenset({"wait"})

# Correlation is by TURN WINDOW, never by the CLI `--session` name: the daemon
# mints each main-agent turn its own `session_id: "main-<n>"`
# (`agents/turn_runner.ex:221`) and `Telemetry` copies only `:session_id`/
# `:parent_session` into a row (`telemetry.ex:16`), so the name handed to
# `fermix ask` reaches no trace field at all.
MAIN_AGENT = "main"

MAX_ROWS = 500_000

# Rendered by `computer_use/session.ex`: screenshot dims `:920` area, cursor echo
# `:981`, full-screen equivalent `:993`, delivery marker `:965`.
_DIMS_RE = re.compile(r"screenshot (\d+)x(\d+) \(display (\d+)\)")
_CURSOR_RE = re.compile(r"Cursor at \((-?\d+),(-?\d+)\)")
_FULLSCREEN_RE = re.compile(r"= \((-?\d+),(-?\d+)\) on the full screen")
_NOT_DELIVERED_RE = re.compile(r"NOT delivered at \((-?\d+),(-?\d+)\)")
_MARKS_ZERO = "0 accessibility marks"
_MARKS_RE = re.compile(r"(\d+) numbered mark\(s\) badged on the image")

# Typed refusals, anchored on `tools/computer_use.ex`: ambiguous `:454`,
# region mismatch `:410`, no marks `:428`, stale marks `:433`, unknown mark `:439`.
_REFUSALS = (
    ("ambiguous_coordinates", "ambiguous coordinates: "),
    ("region_mismatch", "your latest coordinate source uses region "),
    ("no_marks", "no live marks — take a fresh "),
    ("stale_marks", "the marks were taken on a view you have since left"),
    ("unknown_mark", " does not exist — the latest marks screenshot has "),
)


class TraceError(RuntimeError):
    """A trace file could not be read, or a row did not carry what it must."""


@dataclass(frozen=True)
class CheckResult:
    name: str
    passed: bool
    detail: str


# --- reading ----------------------------------------------------------------

def read_jsonl(traces_root: str, kind: str, dates: list[str] | None = None,
               max_rows: int = MAX_ROWS) -> list[dict]:
    """Every `<traces_root>/<date>/<kind>.jsonl` row, in file order. `dates`
    restricts the scan (a run that crosses midnight passes both days). Blows the
    cap loudly rather than loading an unbounded home into memory."""
    if not os.path.isdir(traces_root):
        raise TraceError(f"trace directory does not exist: {traces_root}")
    rows: list[dict] = []
    for day in sorted(dates if dates is not None else os.listdir(traces_root)):
        path = os.path.join(traces_root, day, f"{kind}.jsonl")
        if not os.path.isfile(path):
            continue
        rows.extend(_read_file(path, max_rows - len(rows)))
        if len(rows) >= max_rows:
            raise TraceError(f"more than {max_rows} {kind} rows under {traces_root}; "
                             "narrow the scan with an explicit date list")
    return rows


def _read_file(path: str, remaining: int) -> list[dict]:
    out: list[dict] = []
    with open(path, "r", encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            if len(out) >= remaining:
                return out
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise TraceError(f"{path}:{lineno} is not valid JSON: {exc}") from exc
    return out


def rows_in_window(rows: list[dict], start_ms: float, end_ms: float,
                   agent: str = MAIN_AGENT) -> list[dict]:
    """`agent`'s rows stamped inside `[start_ms, end_ms]`, in file order."""
    if end_ms < start_ms:
        raise TraceError(f"trace window ends ({end_ms}) before it starts ({start_ms})")
    return [r for r in rows
            if r.get("agent") == agent and start_ms <= parse_ts(r.get("ts")) <= end_ms]


def rows_for_turn(rows: list[dict], start_ms: float, end_ms: float) -> list[dict]:
    """One batch turn's rows. The window runs from just before `fermix ask`
    launched to after the reply settled, and the daemon's own per-turn
    `main-<n>` id must be the ONLY one in it — a second id means another
    conversation was driving the same daemon, and no click in the window can be
    attributed to a probe any more."""
    window = rows_in_window(rows, start_ms, end_ms)
    ids = sorted({r.get("session_id") or "" for r in window})
    if len(ids) > 1:
        raise TraceError(
            f"correlation_ambiguous: main-agent rows from {len(ids)} turns ({', '.join(ids)}) "
            "fall inside this batch's window, so a delivered click cannot be attributed to a "
            "probe. Quiesce this daemon's channels for the run (CONFIRM_AIM_HANDS_OFF) and rerun")
    return window


def parse_ts(value: str) -> float:
    """Trace `ts` is an ISO-8601 UTC string (`trace.ex:71-81`); scoring needs epoch ms."""
    try:
        return datetime.fromisoformat(value).timestamp() * 1000.0
    except (TypeError, ValueError) as exc:
        raise TraceError(f"unparseable trace timestamp {value!r}") from exc


def row_start_ms(row: dict) -> float:
    """When the action began: `ts` is stamped after execution, so the start is
    `ts - duration_ms` whenever the duration was recorded."""
    return parse_ts(row["ts"]) - float(row.get("duration_ms") or 0)


# --- Elixir `inspect` decoding ----------------------------------------------

def parse_elixir_input(text: str) -> dict:
    """Decode the `input` preview, which `Telemetry.preview/1` writes with
    `inspect/2` — e.g. `%{"action" => "left_click", "x" => 418}`. Only the subset
    tool args can contain is supported; anything else fails loud."""
    if not isinstance(text, str):
        raise TraceError(f"trace input is not a string: {type(text).__name__}")
    value, index = _term(text, _skip(text, 0))
    if _skip(text, index) != len(text):
        raise TraceError(f"trailing characters in trace input at offset {index}")
    if not isinstance(value, dict):
        raise TraceError(f"trace input decoded to {type(value).__name__}, expected a map")
    return value


def _skip(text: str, i: int) -> int:
    while i < len(text) and text[i] in " \t\r\n":
        i += 1
    return i


def _term(text: str, i: int):
    if i >= len(text):
        raise TraceError("trace input ended mid-term")
    if text.startswith("%{", i):
        return _map(text, i + 2)
    if text[i] == "[":
        return _list(text, i + 1)
    if text[i] == '"':
        return _string(text, i + 1)
    return _scalar(text, i)


def _map(text: str, i: int):
    out: dict = {}
    i = _skip(text, i)
    if i < len(text) and text[i] == "}":
        return out, i + 1
    while True:
        key, i = _term(text, _skip(text, i))
        i = _skip(text, i)
        if not text.startswith("=>", i):
            raise TraceError(f"expected `=>` in trace input at offset {i}")
        value, i = _term(text, _skip(text, i + 2))
        out[key] = value
        i = _skip(text, i)
        if i < len(text) and text[i] == ",":
            i += 1
            continue
        if i < len(text) and text[i] == "}":
            return out, i + 1
        raise TraceError(f"unterminated map in trace input at offset {i}")


def _list(text: str, i: int):
    out: list = []
    i = _skip(text, i)
    if i < len(text) and text[i] == "]":
        return out, i + 1
    while True:
        value, i = _term(text, _skip(text, i))
        out.append(value)
        i = _skip(text, i)
        if i < len(text) and text[i] == ",":
            i += 1
            continue
        if i < len(text) and text[i] == "]":
            return out, i + 1
        raise TraceError(f"unterminated list in trace input at offset {i}")


def _string(text: str, i: int):
    chars: list[str] = []
    escapes = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}
    while i < len(text):
        char = text[i]
        if char == "\\":
            if i + 1 >= len(text):
                raise TraceError("trace input ended after an escape")
            chars.append(escapes.get(text[i + 1], text[i + 1]))
            i += 2
            continue
        if char == '"':
            return "".join(chars), i + 1
        chars.append(char)
        i += 1
    raise TraceError("unterminated string in trace input")


_SCALARS = {"true": True, "false": False, "nil": None}
_SCALAR_RE = re.compile(r"[^,}\]\s]+")


def _scalar(text: str, i: int):
    match = _SCALAR_RE.match(text, i)
    if not match:
        raise TraceError(f"unreadable scalar in trace input at offset {i}")
    token = match.group(0)
    if token in _SCALARS:
        return _SCALARS[token], match.end()
    if token.startswith(":"):
        return token[1:], match.end()
    try:
        return (float(token) if "." in token else int(token)), match.end()
    except ValueError as exc:
        raise TraceError(f"unsupported term {token!r} in trace input") from exc


# --- output parsing ---------------------------------------------------------

def parse_sent_dims(output: str) -> tuple[int, int] | None:
    """`(w, h)` of the image the model was sent. On a full-screen capture this IS
    the full-sent grid the cursor echo is expressed in (F1)."""
    match = _DIMS_RE.search(output or "")
    return (int(match.group(1)), int(match.group(2))) if match else None


def parse_cursor_echo(output: str) -> tuple[int, int] | None:
    match = _CURSOR_RE.search(output or "")
    return (int(match.group(1)), int(match.group(2))) if match else None


def parse_fullscreen_echo(output: str) -> tuple[int, int] | None:
    """The `= (fx,fy) on the full screen` half, present only on a magnified crop."""
    match = _FULLSCREEN_RE.search(output or "")
    return (int(match.group(1)), int(match.group(2))) if match else None


def full_sent_echo(output: str, had_region: bool) -> tuple[int, int] | None:
    """The cursor position in the FULL-SENT grid, whichever half carries it: the
    explicit full-screen equivalent on a crop, else the bare echo on a full
    capture (which is already that grid). Never mixes the two spaces."""
    explicit = parse_fullscreen_echo(output)
    if explicit is not None:
        return explicit
    return None if had_region else parse_cursor_echo(output)


def parse_not_delivered(output: str) -> tuple[int, int] | None:
    match = _NOT_DELIVERED_RE.search(output or "")
    return (int(match.group(1)), int(match.group(2))) if match else None


def parse_marks_count(output: str) -> int | None:
    text = output or ""
    if _MARKS_ZERO in text:
        return 0
    match = _MARKS_RE.search(text)
    return int(match.group(1)) if match else None


def classify_refusal(output: str) -> str | None:
    for kind, anchor in _REFUSALS:
        if anchor in (output or ""):
            return kind
    return None


def classify_row(row: dict) -> str:
    """One of: `delivered_click`, `other_pointer`, `screenshot`, `refusal`, `other`.
    A refusal is a failed computer_use row; its kind comes from `classify_refusal`
    and an unrecognised one stays `refusal` rather than disappearing."""
    if row.get("tool") != "computer_use":
        return "other"
    action = row.get("action")
    if not row.get("success"):
        return "refusal"
    if parse_not_delivered(row.get("output") or ""):
        return "refusal"
    if action in DELIVERED_ACTIONS:
        return "delivered_click"
    if action in OTHER_POINTER_ACTIONS:
        return "other_pointer"
    if action in ("screenshot", "wait_for_change"):
        return "screenshot"
    return "other"


# --- rail guard (F2) --------------------------------------------------------

def browser_rail_violations(rows: list[dict]) -> list[dict]:
    """Browser-tool rows that could have produced a page click. `Input.dispatchMouseEvent`
    (`browser/profile_server.ex:1375-1389`) arrives as `isTrusted: true`, so the page
    cannot distinguish it from a real OS click — the trace is the only guard."""
    return [r for r in rows if r.get("tool") == "browser" and _browser_click_capable(r)]


def _browser_click_capable(row: dict) -> bool:
    action = row.get("action")
    if action not in BROWSER_ALLOWED_ACTIONS:
        return True
    return action == "act" and row.get("kind") not in BROWSER_ALLOWED_ACT_KINDS


# --- preconditions (F10: two checks, two causes, two messages) --------------

def check_trace_visibility(rows: list[dict], label: str) -> CheckResult:
    """`rows` is already this turn's window (`rows_for_turn`)."""
    if rows:
        return CheckResult("trace_visibility", True, f"{len(rows)} main-agent row(s) for {label}")
    return CheckResult("trace_visibility", False,
                       f"no main-agent tool_exec row for {label} inside the turn's own time "
                       "window, under the traces directory the harness reads. Either the daemon "
                       "runs with FERMIX_TRACE_DIR set (its traces are somewhere else), or the "
                       "turn executed no tools at all and there is nothing to score")


def check_capture_content(rows: list[dict], label: str) -> CheckResult:
    with_input = [r for r in rows if r.get("input")]
    if with_input:
        return CheckResult("capture_content", True, f"{len(with_input)} row(s) carry input")
    return CheckResult("capture_content", False,
                       f"tool_exec rows for {label} carry no `input` — content capture is "
                       "off, so the coordinates the model sent are not recorded. Set "
                       "FERMIX_TRACE_CONTENT=1 (or FERMIX_OPIK_ENABLED=1) on the daemon and restart it")


# --- config id --------------------------------------------------------------

def detect_config_id(llm_rows: list[dict], windows: list[tuple[float, float]]) -> str | None:
    """Most-common `provider/model/effort` across the run's own llm_call rows,
    selected by the same turn windows the tool rows were (an llm_call row carries
    the per-turn `main-<n>` id, not the CLI session name). Returns None when
    nothing matched — the caller refuses rather than labelling a report with a
    guessed model."""
    counts: dict[str, int] = {}
    for row in llm_rows:
        if not _in_any_window(row, windows):
            continue
        provider, model = row.get("provider"), row.get("model")
        if not provider or not model:
            continue
        effort = row.get("reasoning_effort") or "default"
        key = f"{provider}/{model}/{effort}"
        counts[key] = counts.get(key, 0) + 1
    if not counts:
        return None
    return max(sorted(counts), key=lambda k: counts[k])


def _in_any_window(row: dict, windows: list[tuple[float, float]]) -> bool:
    if row.get("agent") != MAIN_AGENT:
        return False
    at = parse_ts(row.get("ts"))
    return any(start <= at <= end for start, end in windows)
