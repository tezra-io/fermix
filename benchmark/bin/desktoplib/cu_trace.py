"""Computer-use rows in the daemon's JSONL traces: read them, cut them into
turns, classify the failures, count the images.

Shared by `run_desktop.py` (one task's turn) and `cu_baseline.py` (every turn a
machine recorded). The rows are what `FermixCore.Trace` writes under
`<FERMIX_HOME>/traces/<UTC date>/<type>.jsonl` (`trace.ex` `build_entry/3`: every
row has `ts`, `type` and `agent`):

  * `tool_exec` rows from `Tools.Telemetry.exec/5`. A computer-use row adds
    `action`, `success`, `duration_ms`, the turn's `session_id` (`main-<n>`, from
    `agents/turn_runner.ex` `session_id/1`), the closed fields the tool puts on
    it (`outcome`, `courtesy`, `geometry_refusal`, …), and, with content capture
    on, `input` (an Elixir `inspect` of the arguments) and `output` (the summary
    the model read, or the error sentence of a failed call);
  * `llm_call` rows from `Providers.Telemetry.emit_call/3`, one per model call,
    with the same `session_id` and the call's `duration_ms`.

A trace file is not a run (AGENTS.md, "Trace files"): rows are bucketed into
TURNS by `(agent, session_id)`, and a turn id the daemon reused after a restart
is split off by a gap in time. The sentences a failed row is classified by are
anchored on the function that renders each one; `test_cu_baseline.py` re-reads
the engine source so a reworded sentence fails a test instead of silently
moving every row it matched into `other`.
"""

from __future__ import annotations

import json
import os
import re
import statistics
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

from aimlib.traces import MAIN_AGENT, TraceError, parse_elixir_input, parse_ts

# A turn is far shorter than this; the same `main-<n>` this far apart is a
# restarted daemon counting from the start again, not one turn.
TURN_GAP_MS = 30 * 60 * 1000
# The plan's image-token estimate (M86 §2): width × height / 750 per image.
PIXELS_PER_TOKEN = 750
# The engine's default for `[fermix_core.computer_use] max_retained_screenshots`
# (`computer_use/config.ex`): how many tool-result images stay live in replayed
# history, so how many each later model call carries.
DEFAULT_RETAINED = 3

# Actions aimed at a POINT that change something, so the ones that can miss.
# `press` / `set_value` name a control and cannot land beside it.
AIMED_ACTIONS = frozenset({"left_click", "right_click", "double_click", "left_click_drag",
                           "scroll"})
# `Compux.Protocol` `@read_only`: these dispatch no input, so an aim survives them.
READ_ONLY_ACTIONS = frozenset({"screenshot", "mouse_move", "wait", "inspect", "wait_for_change",
                               "elements", "windows", "select_target", "release_target"})

FAILURE_CLASSES = ("refusal", "timeout", "permission", "stale_observation", "other")
# `Tools.ComputerUse` `@geometry_refusals` that mean the picture an action was
# aimed through no longer matches the screen: the image it named is no longer
# the helper's (`action_error_message/1` gives those three one sentence), or the
# helper's capture does not match the display's geometry, which the engine says
# is never the model's doing.
STALE_CODES = frozenset({"unknown_observation", "expired_observation", "stale_observation",
                         "capture_geometry_mismatch"})

# Checked in this order; the first class with a matching anchor wins. Permission
# and timeout come before the generic "this action was not sent" lead that
# several of their sentences start with. All from `tools/computer_use.ex`, each
# rendered by the function named above it.
FAILURE_ANCHORS = (
    ("permission", (
        # refusal_message({:refused, :strict_mode})
        "strict (look-only) access",
        # refusal_message({:refused, :input_control_denied})
        "the Accessibility permission is not granted",
        # background_code_message("screen_recording_not_granted")
        "screen capture is NOT granted",
    )),
    ("timeout", (
        # action_error_message({:timeout, :cu_sidecar_action, _}) and helper_fault/1
        "stopped responding",
        # action_error_message({:timeout, :cu_session_call, _})
        "was still working",
        # ax_cause("ax_timed_out", :sent) and ax_cause("ax_timed_out", _not_sent)
        "was made and never came back",
        "timed out before its message went anywhere",
    )),
    ("stale_observation", (
        # action_error_message/1 for the three stale observation codes
        "the image its `observation_id` names is no longer one",
        # action_error_message("stale_element")
        "its `element_ref` is not one this request can use",
    )),
    ("refusal", (
        "this action was not sent",            # the lead of every typed refusal
        "ambiguous coordinates: ",             # ambiguous_grid_message/1
        "computer use is paused",              # refusal_message({:refused, :paused})
        "is actively using the machine",       # action_error_message(:user_active)
        "another conversation is driving",     # refusal_message({:refused, :input_busy})
    )),
)
# The helper's typed codes a task may EXPECT (`expect_refusal`), each with the
# fragment of the one sentence the engine renders for it,
# `action_error_message("<code>")` in `tools/computer_use.ex`. Only a geometry
# refusal reaches a row as a field; any other code reaches it only as that
# sentence in `output`, so the sentence is how a row carries the code.
TYPED_CODE_ANCHORS = {
    "element_disabled": "that control is DISABLED right now",
    # Protocol 12 (M86 P2): the control refusals macOS answers ...
    "stale_element": "its `element_ref` is not one this request can use",
    "ax_action_unsupported": "that control has no route for this verb",
    "state_unreadable": "the control's current state could not be read",
    "focus_refused": "`focus` never brings a window forward",
    "scope_not_found": "that scope gave nothing to list right now",
    # ... and the ones only the Linux helper answers at first.
    "accessibility_unavailable": "cannot read or act on controls at all",
    "pixels_unavailable": "cannot do this by pixels on this desktop",
    "toolkit_accessibility_off": "this application is not publishing its controls",
    "text_outside_layout": "the keyboard layout in use cannot type some of that text",
    "consent_refused": "the person declined the desktop's request",
    "consent_timeout": "request for permission to see or control the screen was not answered",
    "no_active_window": "no single window is active to take the keys",
    "keyboard_not_neutral": "the keyboard is not in its plain state",
    "capture_unavailable": "the desktop's screen-sharing service could not serve it",
}
# The routes a labelled sanity case may require (`sanity_route` in the desktop
# corpus; AGENTS.md allows a route assertion only for safety and in labelled
# sanity cases). A computer-use row takes one whatever its outcome: `wait_for` by
# the action itself or by an `until` among any action's arguments,
# `type_by_reference` by `type` with an `element_ref`.
ROUTES = ("wait_for", "type_by_reference")
# `computer_use/session.ex` `delivery_suffix/1`: the helper's own word that the
# cursor did not end where the action aimed.
AIM_NOT_CONFIRMED = "Aim NOT confirmed at ("
# `computer_use/session.ex` `image_lead/2`: every image an action returns leads
# with its own size, addressable or not.
_IMAGE_RE = re.compile(r"(?:Image [^,\s]+, |Screenshot )(\d+)x(\d+)")
_UNSIZED_RE = re.compile(r"(?:Image [^,\s]+, |Screenshot )size unreported")
_DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
# A row's own `ts`. `Trace` encodes each row with Jason over a map, so its keys
# are sorted and `ts` follows the large `input`/`output` strings; inside a JSON
# string every quote is escaped, so `"ts":"` can only be the row's own key.
_TS_RE = re.compile(r'"ts":\s*"([^"]+)"')
# A sentinel for an `input` that would not decode: neither a point nor "no point".
UNREADABLE = object()


class TurnSelectionError(TraceError):
    """A task's window did not hold exactly one main-agent turn. `kind` says which."""

    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind


# --- reading ----------------------------------------------------------------------

def iter_rows(path: str, window: tuple[float, float] | None = None):
    """Every row of one JSONL file, one at a time (a day of `llm_call` rows with
    content capture is large). The daemon appends whole lines, so a last line
    with no newline is still being written: it is left for the next read. With a
    `window` (`start_ms`, `end_ms`), a line whose `ts` falls outside it is
    skipped before it is parsed."""
    with open(path, encoding="utf-8") as handle:
        yield from _rows(path, handle, window)


def _rows(path: str, handle, window: tuple[float, float] | None):
    for number, line in enumerate(handle, start=1):
        if not line.endswith("\n"):
            return
        if line.strip() and _may_be_inside(line, window):
            yield _parse_line(path, number, line)


def _may_be_inside(line: str, window: tuple[float, float] | None) -> bool:
    """False only for a line whose own `ts` is outside the window; a line with no
    readable `ts` is parsed, and the caller's exact check decides."""
    match = _TS_RE.search(line) if window else None
    if match is None:
        return True
    return window[0] <= parse_ts(match.group(1)) <= window[1]


def _parse_line(path: str, number: int, line: str) -> dict:
    try:
        return json.loads(line)
    except json.JSONDecodeError as exc:
        raise TraceError(f"{path}:{number} is not valid JSON: {exc}") from exc


def trace_days(root: str, since: str | None, until: str | None) -> list[str]:
    """The `YYYY-MM-DD` directories under `root`, inside `[since, until]`."""
    days = sorted(name for name in os.listdir(root)
                  if _DAY_RE.match(name) and os.path.isdir(os.path.join(root, name)))
    return [day for day in days if (since is None or day >= since)
            and (until is None or day <= until)]


def rows_between(root: str, start_ms: float, end_ms: float,
                 kinds: tuple[str, ...] = ("tool_exec", "llm_call")) -> list[dict]:
    """Rows of `kinds` stamped inside `[start_ms, end_ms]`, from the UTC days the
    window touches. A day or file that does not exist yet holds no rows."""
    first = datetime.fromtimestamp(start_ms / 1000.0, tz=timezone.utc).date()
    last = datetime.fromtimestamp(end_ms / 1000.0, tz=timezone.utc).date()
    days = [(first + timedelta(days=offset)).isoformat()
            for offset in range((last - first).days + 1)]
    paths = [os.path.join(root, day, f"{kind}.jsonl") for day in days for kind in kinds]
    rows = []
    for path in (p for p in paths if os.path.isfile(p)):
        rows.extend(r for r in iter_rows(path, (start_ms, end_ms))
                    if start_ms <= parse_ts(r["ts"]) <= end_ms)
    return rows


def end_ms(row: dict) -> float:
    return parse_ts(row["ts"])


def start_ms(row: dict) -> float:
    """`ts` is stamped once the call is over, so it began `duration_ms` earlier."""
    return parse_ts(row["ts"]) - float(row.get("duration_ms") or 0)


# --- turns --------------------------------------------------------------------------

def bucket_turns(rows: list[dict], gap_ms: float = TURN_GAP_MS) -> list[list[dict]]:
    """Rows grouped by `(agent, session_id)`, each group split where two rows are
    more than `gap_ms` apart, each turn in time order."""
    groups = defaultdict(list)
    for row in rows:
        groups[(row.get("agent"), row.get("session_id"))].append(row)
    return [turn for group in groups.values() for turn in _split_on_gap(group, gap_ms)]


def _split_on_gap(group: list[dict], gap_ms: float) -> list[list[dict]]:
    ordered = sorted(group, key=end_ms)
    turns, current = [], [ordered[0]]
    for previous, row in zip(ordered, ordered[1:]):
        if end_ms(row) - end_ms(previous) > gap_ms:
            turns.append(current)
            current = []
        current.append(row)
    return turns + [current]


def select_turn(rows: list[dict], start: float, end: float) -> tuple[str, list[dict]]:
    """The one main-agent turn stamped inside `[start, end]`: its id and rows.
    The CLI's `--session` name reaches no trace field, so the window plus the
    rule that exactly one turn ran in it is the correlation."""
    inside = [r for r in rows if r.get("agent") == MAIN_AGENT and start <= end_ms(r) <= end]
    sessions = sorted({r.get("session_id") or "" for r in inside})
    if not sessions:
        raise TurnSelectionError("no_trace", "no main-agent trace row inside the task's window: "
                                 "the turn left no rows where the runner reads them")
    if len(sessions) > 1:
        raise TurnSelectionError("several_turns", "more than one main-agent turn ran inside the "
                                 f"task's window ({', '.join(sessions)}); something else is "
                                 "talking to this daemon")
    return sessions[0], inside


# --- one row -------------------------------------------------------------------------

def is_computer_use(row: dict) -> bool:
    return row.get("type") == "tool_exec" and row.get("tool") == "computer_use"


def took_route(row: dict, route: str) -> bool:
    """True for a computer-use row that went through and took `route` (one of ROUTES).

    A refused row took no route: the model then reached the task some other way.
    `type_by_reference` is `type` with an `element_ref` or with a `mark`, which the
    session sends as the badged control's `element_ref` (`observations.ex`
    `@element_actions`; a mark with no reference is refused, so never sent).
    """
    if route not in ROUTES:
        raise ValueError(f"{route!r} is not a route a sanity case can require "
                         f"({', '.join(ROUTES)})")
    if not is_computer_use(row) or not row.get("success"):
        return False
    if route == "wait_for" and row.get("action") == "wait_for":
        return True
    if not row.get("input"):
        return False
    try:
        args = parse_elixir_input(row["input"])
    except TraceError:
        # An input that would not decode shows no route, so the sanity case fails
        # rather than passing on a guess.
        return False
    if route == "wait_for":
        return "until" in args
    return row.get("action") == "type" and ("element_ref" in args or "mark" in args)


def classify_failure(row: dict) -> str:
    """One of FAILURE_CLASSES for a FAILED computer-use row."""
    if row.get("success"):
        raise ValueError("classify_failure takes a failed computer-use row")
    code = row.get("geometry_refusal")
    if code in STALE_CODES:
        return "stale_observation"
    text = row.get("output") or ""
    for kind, anchors in FAILURE_ANCHORS:
        if any(anchor in text for anchor in anchors):
            return kind
    if code or row.get("outcome") == "refused":
        return "refusal"
    return "other"


def carries_code(row: dict, code: str) -> bool:
    """True for a FAILED computer-use row refused with the typed `code`. A paused,
    busy or user-active refusal carries a different sentence and never matches."""
    if code not in TYPED_CODE_ANCHORS:
        raise ValueError(f"{code!r} is not a code the classifier recognises on a row")
    return not row.get("success") and TYPED_CODE_ANCHORS[code] in (row.get("output") or "")


def image_dims(output: str) -> list[tuple[int, int]]:
    return [(int(w), int(h)) for w, h in _IMAGE_RE.findall(output or "")]


def image_tokens(width: int, height: int) -> float:
    return width * height / PIXELS_PER_TOKEN


def aimed_point(row: dict):
    """The point(s) an aimed action was sent to, `None` when it was not aimed at a
    point (another action, a control reference, a mark), or UNREADABLE when its
    recorded input would not decode."""
    if row.get("action") not in AIMED_ACTIONS or not row.get("input"):
        return None
    try:
        args = parse_elixir_input(row["input"])
    except TraceError:
        return UNREADABLE
    if "element_ref" in args or "mark" in args or "x" not in args or "y" not in args:
        return None
    to = args.get("to") if isinstance(args.get("to"), dict) else {}
    return (args["x"], args["y"], to.get("x"), to.get("y"))


def missed_aims(cu_rows: list[dict]) -> list[int]:
    """Indexes of aimed actions that MISSED: an aimed action that went through,
    followed (with only looks in between) by the same action at a different
    point. The same point again is a retry, which the engine's own sentence asks
    for; an unreadable input ends the aim, since nothing can be said about it."""
    missed, pending = [], None
    for index, row in enumerate(cu_rows):
        point = aimed_point(row)
        if point is None and row.get("action") in READ_ONLY_ACTIONS:
            continue
        if point is None or point is UNREADABLE:
            pending = None
            continue
        if pending and pending[1] == row["action"] and pending[2] != point:
            missed.append(pending[0])
        pending = (index, row["action"], point) if row.get("success") else None
    return missed


# --- one turn ------------------------------------------------------------------------

def turn_counts(rows: list[dict], retained: int = DEFAULT_RETAINED) -> dict:
    """What one turn cost and how its computer-use calls went."""
    cu = sorted((r for r in rows if is_computer_use(r)), key=end_ms)
    calls = sorted((r for r in rows if r.get("type") == "llm_call"), key=end_ms)
    failures = [r for r in cu if not r.get("success")]
    classes = Counter(classify_failure(r) for r in failures)
    images = [(end_ms(r), image_tokens(w, h)) for r in cu for w, h in image_dims(r.get("output"))]
    return {
        "model_calls": len(calls),
        "cu_calls": len(cu),
        "cu_failures": len(failures),
        "failure_classes": {kind: classes.get(kind, 0) for kind in FAILURE_CLASSES},
        "missed_aims": len(missed_aims(cu)),
        "aim_not_confirmed": sum(AIM_NOT_CONFIRMED in (r.get("output") or "") for r in cu),
        "images": len(images),
        "images_unsized": sum(len(_UNSIZED_RE.findall(r.get("output") or "")) for r in cu),
        "image_tokens": sum(tokens for _at, tokens in images),
        "image_tokens_sent": replayed_image_tokens(images, calls, retained),
        "cu_rows_without_output": sum("output" not in r for r in cu),
        "unreadable_inputs": sum(aimed_point(r) is UNREADABLE for r in cu),
    }


def replayed_image_tokens(images: list[tuple[float, float]], calls: list[dict],
                          retained: int) -> float:
    """The image tokens the turn's model calls carried: each call carries the
    last `retained` images any tool returned before it began."""
    total = 0.0
    for call in calls:
        began = start_ms(call)
        before = [tokens for at, tokens in images if at <= began]
        total += sum(before[-retained:]) if retained > 0 else 0.0
    return total


def distribution(values: list[float]) -> dict:
    """Total, median, p90 (nearest rank) and max; `None`s when there are no values."""
    if not values:
        return {"n": 0, "total": 0, "median": None, "p90": None, "max": None}
    ordered = sorted(values)
    rank = max(1, -(-9 * len(ordered) // 10))
    return {"n": len(ordered), "total": sum(ordered), "median": statistics.median(ordered),
            "p90": ordered[rank - 1], "max": ordered[-1]}
