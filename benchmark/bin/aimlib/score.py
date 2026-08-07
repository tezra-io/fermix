"""Correlation, outcome classification, and the run's two report artifacts.

Runner contract: build one `BatchInput` per batch (the plan, the batch's CLI
session label, that turn's trace rows, the final `window.__aim` snapshot, the focus
samples, the CDP socket-close timestamp, and the parsed model report), call
`score_batch` for each, then `build_results(...)` + `write_results` +
`render_report`. Scoring is closed-form arithmetic — no LLM judge, no page
content, no screenshots; results carry counts and vectors only.

Two rules deserve naming here. First, correlation is a TIME MERGE: each trusted
page hit attaches to the most recent delivered-click trace row whose start
precedes it inside `PAIR_WINDOW_MS`, and ordinals only break ties — pure ordinal
matching silently mis-attributes as soon as one action produces no page event.
Second, coordinate spaces never mix: miss vectors are page-side CSS px on both
ends and need no transform, while `sent_from_screen` exists solely for the one
place a TRACE coordinate meets a PAGE coordinate (the delivery cross-check), where
the trace echo lives in the full-sent image grid, not in screen points.
"""

from __future__ import annotations

import json
import math
import os
import statistics
from dataclasses import dataclass, field

from . import cdp, page, traces

OUTCOMES = ("hit", "miss", "no_click", "refused_unrecovered", "off_page",
            "browser_lost", "occluded", "scrolled", "rail_violation", "extra_click",
            "unscored")
SCORED_OUTCOMES = frozenset({"hit", "miss"})
# A halt names a broken world, not a bad aim: the run stops and writes a partial
# report rather than injecting more OS clicks into an unknown surface.
HALT_OUTCOMES = frozenset({"off_page", "browser_lost"})
BATCH_FLAGS = ("sequence_mismatch", "report_unparseable", "rail_violation",
               "marks_unavailable")

PAIR_WINDOW_MS = 5_000.0
MAX_OCCLUDED_PER_BATCH = 2
CROSS_CHECK_TOLERANCE_SENT_PX = 2.0

# F4: the grid suite's fired column is a composite (finding the fired cell re-runs
# the same arithmetic), so it is never reported as the click-effect number. The
# singleton suite's column is.
FIRED_METRIC = {"s1": "fired_target_verification", "s2": "fired_report_accuracy",
                "s3": "fired_report_accuracy", "cal": "fired_report_accuracy"}


class ScoreError(RuntimeError):
    """A batch could not be scored because its inputs contradict themselves."""


@dataclass(frozen=True)
class Hit:
    seq: int
    t: float
    target_id: str | None
    x: float
    y: float
    sx: float
    sy: float
    trusted: bool
    scroll_x: float
    scroll_y: float


@dataclass(frozen=True)
class Delivered:
    index: int
    action: str
    ts_ms: float
    start_ms: float
    x: float | None
    y: float | None
    region: dict | None
    output: str
    had_input: bool


@dataclass
class BatchInput:
    plan: page.BatchPlan
    session: str
    rows: list[dict]
    aim: dict
    samples: list[cdp.FocusSample] = field(default_factory=list)
    socket_closed_ms: float | None = None
    report: list[dict] | None = None
    report_error: str | None = None


# --- coordinate transform (F1) ----------------------------------------------

def sent_from_screen(screen_x: float, screen_y: float, dpr: float,
                     screen_w_css: float, screen_h_css: float,
                     sent_w: float, sent_h: float) -> tuple[float, float]:
    """A page `event.screenX/Y` (screen points) expressed in the FULL-SENT image
    grid the trace's cursor echo uses. The echo is in sent-image coordinates
    (`session.ex:977`) and its full-screen equivalent stays on that grid
    (`session.ex:990-993`), so comparing either against screen points raw is a
    ~2x error on a downscaled capture. DPR-general: no branch at DPR != 1."""
    for name, value in (("dpr", dpr), ("screen width", screen_w_css),
                        ("screen height", screen_h_css), ("sent width", sent_w),
                        ("sent height", sent_h)):
        if not value or value <= 0:
            raise ScoreError(f"cannot transform screen coordinates: {name} is {value!r}")
    physical_w = screen_w_css * dpr
    physical_h = screen_h_css * dpr
    return (screen_x * dpr * (sent_w / physical_w), screen_y * dpr * (sent_h / physical_h))


# --- inputs -----------------------------------------------------------------

def parse_hits(aim: dict) -> list[Hit]:
    raw = aim.get("hits")
    if not isinstance(raw, list):
        raise ScoreError("the page snapshot carries no `hits` array")
    return [Hit(seq=int(h["seq"]), t=float(h["t"]), target_id=h.get("target_id"),
                x=float(h["x"]), y=float(h["y"]), sx=float(h["sx"]), sy=float(h["sy"]),
                trusted=bool(h.get("trusted")), scroll_x=float(h.get("scroll_x") or 0),
                scroll_y=float(h.get("scroll_y") or 0)) for h in raw]


def partition_rows(rows: list[dict]) -> tuple[list[Delivered], list[dict], int, int | None]:
    """Delivered clicks (in file order), refusal records, the other-pointer count,
    and the smallest marks count any marks screenshot reported."""
    delivered: list[Delivered] = []
    refusals: list[dict] = []
    other_pointer = 0
    marks_min: int | None = None
    for index, row in enumerate(rows):
        kind = traces.classify_row(row)
        if kind == "delivered_click":
            delivered.append(_delivered(index, row))
        elif kind == "other_pointer":
            other_pointer += 1
        elif kind == "refusal":
            refusals.append({"row_index": index, "action": row.get("action"),
                             "kind": traces.classify_refusal(row.get("output") or "") or "other",
                             "not_delivered": bool(traces.parse_not_delivered(row.get("output") or "")),
                             # The tool's own words — a bare outcome kind sent the
                             # 2026-08-01 calibration debugging through the trace
                             # files for what the row had said all along.
                             "message": (row.get("output") or "")[:160]})
        elif kind == "screenshot":
            count = traces.parse_marks_count(row.get("output") or "")
            if count is not None:
                marks_min = count if marks_min is None else min(marks_min, count)
    return delivered, refusals, other_pointer, marks_min


def _delivered(index: int, row: dict) -> Delivered:
    args = traces.parse_elixir_input(row["input"]) if row.get("input") else {}
    return Delivered(index=index, action=row["action"], ts_ms=traces.parse_ts(row["ts"]),
                     start_ms=traces.row_start_ms(row), x=args.get("x"), y=args.get("y"),
                     region=args.get("region"), output=row.get("output") or "",
                     had_input=bool(row.get("input")))


def full_sent_dims(rows: list[dict]) -> tuple[int, int] | None:
    """Dimensions of the last FULL-screen capture in the batch. A region capture
    reports the crop's dimensions, so it is never usable as the full-sent grid;
    without `input` the two cannot be told apart and the answer is None."""
    for row in reversed(rows):
        if traces.classify_row(row) != "screenshot" or not row.get("input"):
            continue
        args = traces.parse_elixir_input(row["input"])
        if args.get("region"):
            continue
        dims = traces.parse_sent_dims(row.get("output") or "")
        if dims:
            return dims
    return None


# --- correlation (F7) -------------------------------------------------------

def click_quota(action: str) -> int:
    """How many page click events one delivered action is expected to produce
    (`traces.CLICK_EVENTS_PER_ACTION`). This is a pairing QUOTA, not a label: a
    right_click produces none and so is never a candidate, and a double_click
    absorbs both of its events instead of lending the second to an earlier
    hitless row — which would turn a real `off_page` into a phantom score."""
    return traces.CLICK_EVENTS_PER_ACTION.get(action, 1)


def pair_clicks(delivered: list[Delivered],
                hits: list[Hit]) -> tuple[dict[int, list[Hit]], list[Hit]]:
    """Time-merge: each trusted hit takes the most recent delivered row with quota
    left whose start precedes it within the pairing window. Ordinals break ties
    only. A row's hits come back in arrival order — the first is the probe's."""
    assigned: dict[int, list[Hit]] = {}
    unpaired: list[Hit] = []
    for hit in hits:
        if not hit.trusted:
            continue
        candidates = [d for d in delivered
                      if len(assigned.get(d.index, ())) < click_quota(d.action)
                      and d.start_ms <= hit.t and hit.t - d.start_ms <= PAIR_WINDOW_MS]
        if not candidates:
            unpaired.append(hit)
            continue
        chosen = max(candidates, key=lambda d: (d.start_ms, -d.index))
        assigned.setdefault(chosen.index, []).append(hit)
    return assigned, unpaired


# --- scoring ----------------------------------------------------------------

def score_batch(bi: BatchInput) -> dict:
    """One batch's probe rows plus its typed flags. Never reconciles a
    contradiction silently: every irregularity becomes a named, counted outcome."""
    rails = traces.browser_rail_violations(bi.rows)
    if rails:
        return _rail_violation_batch(bi, rails)
    delivered, refusals, other_pointer, marks_min = partition_rows(bi.rows)
    hits = parse_hits(bi.aim)
    assigned, unpaired = pair_clicks(delivered, hits)
    gaps = cdp.focus_gaps(bi.samples)
    ctx = {"gaps": gaps, "closed": bi.socket_closed_ms, "hits": hits,
           "dims": full_sent_dims(bi.rows), "meta": bi.aim.get("meta") or {}}
    probes = _probe_rows(bi, delivered, refusals, assigned, ctx)
    leftovers = [_leftover(d, assigned.get(d.index) or [], ctx)
                 for d in delivered[len(bi.plan.targets):]]
    return _batch_result(bi, probes, leftovers, delivered, refusals,
                         other_pointer, unpaired, marks_min)


def _probe_rows(bi: BatchInput, delivered, refusals, assigned, ctx) -> list[dict]:
    aligned = min(len(delivered), len(bi.plan.targets))
    rows = []
    for index, target in enumerate(bi.plan.targets):
        if index < aligned:
            rows.append(_scored_probe(bi, index, target, delivered, refusals, assigned, ctx))
        else:
            rows.append(_unrun_probe(bi, index, target, delivered, refusals, aligned, ctx))
    return rows


def _scored_probe(bi, index, target, delivered, refusals, assigned, ctx) -> dict:
    click = delivered[index]
    paired = assigned.get(click.index) or []
    hit = paired[0] if paired else None
    outcome = _classify(click, hit, target, ctx)
    box = _target_box(bi.aim, target)
    row = {"probe": index + 1, "batch": bi.plan.batch_id, "session": bi.session,
           "target": {"id": target, "center_css": [box["cx"], box["cy"]],
                      "rect_css": [box["x"], box["y"], box["w"], box["h"]]},
           "outcome": outcome,
           "click_css": [hit.x, hit.y] if hit else None,
           "click_trusted": bool(hit.trusted) if hit else None,
           # A double_click legitimately produces two; the probe is scored from
           # the first, and the count keeps the second visible rather than silent.
           "click_events": len(paired),
           "miss_vector_css": _miss_css(hit, box),
           "miss_vector_cells": _miss_cells(bi.plan, hit, box),
           "refusals": _refusals_for(refusals, delivered, index),
           "trace": _trace_facts(click, hit, ctx)}
    row.update(_fired_columns(bi, index, target, ctx["hits"], hit, click.ts_ms))
    return row


def _unrun_probe(bi, index, target, delivered, refusals, aligned, ctx) -> dict:
    """A probe with no delivered click of its own. The FIRST such probe is named by
    cause — an unrecovered refusal after the last click, or a probe never attempted.
    Anything past it is explicitly `unscored`: with the chain already broken there
    is no evidence to attribute, and inventing one would be a silent reconciliation."""
    last_click = delivered[-1].index if delivered else -1
    trailing = [r for r in refusals if r["row_index"] > last_click]
    if index > aligned:
        outcome = "unscored"
    else:
        outcome = "refused_unrecovered" if trailing else "no_click"
    box = _target_box(bi.aim, target)
    return {"probe": index + 1, "batch": bi.plan.batch_id, "session": bi.session,
            "target": {"id": target, "center_css": [box["cx"], box["cy"]],
                       "rect_css": [box["x"], box["y"], box["w"], box["h"]]},
            "outcome": outcome, "click_css": None, "click_trusted": None,
            "click_events": 0,
            "miss_vector_css": None, "miss_vector_cells": None,
            "refusals": [{"kind": r["kind"], "recovered": False,
                          "message": r.get("message", "")}
                         for r in (trailing if outcome == "refused_unrecovered" else [])],
            # No click means no moment at which the model judged anything, so
            # there is no fired state to be right or wrong about.
            "fired_truth": None,
            "fired_reported": None, "fired_correct": None, "model_reported_xy": None,
            "trace": {"input_xy": None, "region": None, "echo_full_sent": None,
                      "delivered": False, "sent_cross_check_px": None}}


def _classify(click: Delivered, hit: Hit | None, target: str, ctx) -> str:
    """F9: three distinct no-hit causes, three names. A browser that died and a
    click that left the page are different problems with different fixes."""
    if hit is None:
        if traces.CLICK_EVENTS_PER_ACTION.get(click.action, 1) == 0:
            return "no_click"
        if ctx["closed"] is not None and click.ts_ms > ctx["closed"]:
            return "browser_lost"
        if cdp.in_gap(click.ts_ms, ctx["gaps"]):
            return "occluded"
        return "off_page"
    if hit.scroll_x or hit.scroll_y:
        return "scrolled"
    if cdp.in_gap(hit.t, ctx["gaps"]):
        return "occluded"
    return "hit" if hit.target_id == target else "miss"


def _leftover(click: Delivered, paired: list[Hit], ctx) -> dict:
    """A delivered click beyond the batch's probe count. One that DID land on the
    page is an `extra_click`: re-clicking a target it wrongly judged un-fired is
    the very model behaviour this harness exists to measure, so it is counted
    (the count mismatch already raises `sequence_mismatch`) and never halts the
    run. Only a leftover with no page event at all can name a dead browser or a
    click that left the page."""
    outcome = "extra_click" if paired else _classify(click, None, "", ctx)
    return {"row_index": click.index, "action": click.action, "outcome": outcome,
            "click_events": len(paired)}


def _target_box(aim: dict, target: str) -> dict:
    layout = aim.get("layout") or {}
    if target not in layout:
        raise ScoreError(f"the page reported no layout rect for target {target!r}")
    return layout[target]


def _miss_css(hit: Hit | None, box: dict) -> list[float] | None:
    if hit is None:
        return None
    return [hit.x - box["cx"], hit.y - box["cy"]]


def _miss_cells(plan: page.BatchPlan, hit: Hit | None, box: dict) -> list[int] | None:
    """Off-by-N in cell units — the diagnostic that separates a shaky aim from a
    row/column confusion or an origin flip. Grid only; the other modes have no
    lattice to count in."""
    if hit is None or plan.mode != "grid":
        return None
    return [_round_away(v / page.CELL_PX) for v in (hit.x - box["cx"], hit.y - box["cy"])]


def _round_away(value: float) -> int:
    return int(math.copysign(math.floor(abs(value) + 0.5), value))


def _refusals_for(refusals, delivered: list[Delivered], index: int) -> list[dict]:
    """Refusals attach to the probe of the NEXT delivered click — they are that
    probe's recovery chain, not a failure of the one before it."""
    lower = -1 if index == 0 else delivered[index - 1].index
    return [{"kind": r["kind"], "recovered": True, "message": r.get("message", "")}
            for r in refusals if lower < r["row_index"] < delivered[index].index]


def _trace_facts(click: Delivered, hit: Hit | None, ctx) -> dict:
    echo = traces.full_sent_echo(click.output, bool(click.region))
    return {"input_xy": [click.x, click.y] if click.x is not None else None,
            "region": click.region, "echo_full_sent": list(echo) if echo else None,
            "delivered": traces.parse_not_delivered(click.output) is None,
            "sent_cross_check_px": _cross_check(hit, echo, ctx)}


def _cross_check(hit: Hit | None, echo, ctx) -> float | None:
    """The one place a trace coordinate meets a page coordinate. Both ends are put
    on the full-sent grid first (F1)."""
    meta, dims = ctx["meta"], ctx["dims"]
    if hit is None or echo is None or dims is None or not meta:
        return None
    missing = [key for key in ("dpr", "screen_w", "screen_h") if meta.get(key) is None]
    if missing:
        raise ScoreError(f"the page snapshot's meta is missing {', '.join(missing)}")
    sent_x, sent_y = sent_from_screen(hit.sx, hit.sy, meta["dpr"], meta["screen_w"],
                                      meta["screen_h"], dims[0], dims[1])
    return max(abs(sent_x - echo[0]), abs(sent_y - echo[1]))


def _fired_columns(bi: BatchInput, index: int, target: str, hits,
                   hit: Hit | None, click_ts_ms: float) -> dict:
    truth = _fired_truth(target, hits, hit, click_ts_ms)
    reported = _reported(bi.report, index + 1)
    return {"fired_truth": truth,
            "fired_reported": None if reported is None else reported["fired"],
            "fired_correct": None if reported is None else truth == reported["fired"],
            "model_reported_xy": None if reported is None else [reported["x"], reported["y"]]}


def _fired_truth(target: str, hits: list[Hit], hit: Hit | None, click_ts_ms: float) -> bool:
    """Whether the target is orange at the moment this probe's click landed — an
    earlier stray click on the same cell counts, because the model can see it. A
    probe with no page event of its own is bounded by TIME instead of by hit
    order: the row's `ts` is stamped after the action returned, so every event
    its click could have caused precedes it, and a LATER probe's stray hit on
    this target must not retroactively flip a judgment already made."""
    if hit is not None:
        return any(h.trusted and h.target_id == target and h.seq <= hit.seq for h in hits)
    return any(h.trusted and h.target_id == target and h.t <= click_ts_ms for h in hits)


def _reported(report, probe: int) -> dict | None:
    if report is None:
        return None
    for row in report:
        if row.get("probe") == probe:
            return row
    return None


def _rail_violation_batch(bi: BatchInput, rails: list[dict]) -> dict:
    """F2: a click-capable browser-tool call means the page's `isTrusted` clicks are
    no longer attributable to computer_use. The whole batch is unscored and named."""
    probes = [{"probe": i + 1, "batch": bi.plan.batch_id, "session": bi.session,
               "target": {"id": t, "center_css": None, "rect_css": None},
               "outcome": "rail_violation", "click_css": None, "click_trusted": None,
               "click_events": None,
               "miss_vector_css": None, "miss_vector_cells": None, "refusals": [],
               "fired_truth": None, "fired_reported": None, "fired_correct": None,
               "model_reported_xy": None,
               "trace": {"input_xy": None, "region": None, "echo_full_sent": None,
                         "delivered": None, "sent_cross_check_px": None}}
              for i, t in enumerate(bi.plan.targets)]
    return {"batch_id": bi.plan.batch_id, "suite": bi.plan.suite,
            "condition": bi.plan.condition, "session": bi.session, "probes": probes,
            "flags": {**{f: False for f in BATCH_FLAGS}, "rail_violation": True},
            "rail_rows": [{"action": r.get("action"), "kind": r.get("kind")} for r in rails],
            "other_pointer": 0, "unpaired_hits": 0, "leftover_clicks": [],
            "halt_reason": None, "abort_reason": "rail_violation"}


def _batch_result(bi, probes, leftovers, delivered, refusals,
                  other_pointer, unpaired, marks_min) -> dict:
    outcomes = [p["outcome"] for p in probes] + [lo["outcome"] for lo in leftovers]
    halt = next((o for o in outcomes if o in HALT_OUTCOMES), None)
    occluded = sum(1 for o in outcomes if o == "occluded")
    flags = {f: False for f in BATCH_FLAGS}
    flags["sequence_mismatch"] = len(delivered) != len(bi.plan.targets)
    flags["report_unparseable"] = bi.report is None
    flags["marks_unavailable"] = bi.plan.mode == "marks" and marks_min == 0
    return {"batch_id": bi.plan.batch_id, "suite": bi.plan.suite,
            "condition": bi.plan.condition, "session": bi.session, "probes": probes,
            "flags": flags, "report_error": bi.report_error,
            "delivered_clicks": len(delivered), "refusal_rows": len(refusals),
            "other_pointer": other_pointer, "unpaired_hits": len(unpaired),
            "leftover_clicks": leftovers, "halt_reason": halt,
            "abort_reason": "occluded_batch" if occluded > MAX_OCCLUDED_PER_BATCH else None}


# --- summaries --------------------------------------------------------------

def summarize(suite: str, batches: list[dict]) -> dict:
    probes = [p for b in batches for p in b["probes"]]
    scored = [p for p in probes if p["outcome"] in SCORED_OUTCOMES]
    misses = [p["miss_vector_css"] for p in scored if p["miss_vector_css"]]
    magnitudes = [math.hypot(dx, dy) for dx, dy in misses]
    return {"batches": len(batches), "n": len(scored),
            "hits": sum(1 for p in scored if p["outcome"] == "hit"),
            "hit_rate": _rate(sum(1 for p in scored if p["outcome"] == "hit"), len(scored)),
            "first_probe_hit_rate": _first_probe_rate(batches),
            "by_probe_index": _by_probe_index(batches),
            FIRED_METRIC[suite]: _fired_accuracy(probes),
            # Aim error over EVERY scored probe, hits included (an exact hit
            # contributes its residual, not a gap in the distribution).
            "aim_error_css": _distribution(magnitudes),
            "col_off_by": _off_by(scored, 0), "row_off_by": _off_by(scored, 1),
            "refusal_counts": _refusal_counts(probes),
            "recovery_rate": _recovery_rate(probes),
            "outcome_counts": {o: sum(1 for p in probes if p["outcome"] == o) for o in OUTCOMES},
            "flag_counts": _flag_counts(batches),
            "other_pointer": sum(b.get("other_pointer", 0) for b in batches),
            "unpaired_hits": sum(b.get("unpaired_hits", 0) for b in batches),
            # Leftover clicks that DID land on the page — a re-click of a target
            # the model judged un-fired. Counted here or it is visible only in
            # the raw batch record.
            "extra_clicks": _extra_clicks(batches)}


def _extra_clicks(batches: list[dict]) -> int:
    return sum(1 for b in batches for lo in b.get("leftover_clicks", [])
               if lo["outcome"] == "extra_click")


def _rate(numerator: int, denominator: int) -> float | None:
    return None if denominator == 0 else round(numerator / denominator, 4)


def _first_probe_rate(batches: list[dict]) -> float | None:
    """F4's headline: probe 1 of each batch is the only probe no FIRED marker from
    an earlier probe could have coached."""
    firsts = [p for b in batches for p in b["probes"]
              if p["probe"] == 1 and p["outcome"] in SCORED_OUTCOMES]
    return _rate(sum(1 for p in firsts if p["outcome"] == "hit"), len(firsts))


def _by_probe_index(batches: list[dict]) -> dict:
    out: dict[str, dict] = {}
    for batch in batches:
        for probe in batch["probes"]:
            if probe["outcome"] not in SCORED_OUTCOMES:
                continue
            slot = out.setdefault(str(probe["probe"]), {"n": 0, "hits": 0})
            slot["n"] += 1
            slot["hits"] += int(probe["outcome"] == "hit")
    for slot in out.values():
        slot["hit_rate"] = _rate(slot["hits"], slot["n"])
    return out


def _fired_accuracy(probes: list[dict]) -> float | None:
    graded = [p for p in probes if p["fired_correct"] is not None]
    return _rate(sum(1 for p in graded if p["fired_correct"]), len(graded))


def _distribution(values: list[float]) -> dict:
    if not values:
        return {"n": 0, "mean": None, "median": None, "p90": None}
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, math.ceil(0.9 * len(ordered)) - 1))
    return {"n": len(ordered), "mean": round(statistics.fmean(ordered), 2),
            "median": round(statistics.median(ordered), 2), "p90": round(ordered[index], 2)}


def _off_by(scored: list[dict], axis: int) -> dict:
    counts: dict[str, int] = {}
    for probe in scored:
        cells = probe["miss_vector_cells"]
        if cells is None:
            continue
        key = str(cells[axis])
        counts[key] = counts.get(key, 0) + 1
    return dict(sorted(counts.items(), key=lambda kv: int(kv[0])))


def _refusal_counts(probes: list[dict]) -> dict:
    counts: dict[str, int] = {}
    for probe in probes:
        for refusal in probe["refusals"]:
            counts[refusal["kind"]] = counts.get(refusal["kind"], 0) + 1
    return dict(sorted(counts.items()))


def _recovery_rate(probes: list[dict]) -> float | None:
    all_refusals = [r for p in probes for r in p["refusals"]]
    return _rate(sum(1 for r in all_refusals if r["recovered"]), len(all_refusals))


def _flag_counts(batches: list[dict]) -> dict:
    return {flag: sum(1 for b in batches if b["flags"].get(flag)) for flag in BATCH_FLAGS}


# --- calibration ------------------------------------------------------------

def calibration_checks(*, aim: dict, batch: dict, bounds: dict, multi_client: bool,
                       trace_checks: list[traces.CheckResult]) -> list[traces.CheckResult]:
    """The run-start assertion list, each carrying its OBSERVED value so a failure
    names what was actually seen. Calibration is the spike: it probes the same
    world the run works in — a live click through the real driver onto the real
    page — instead of a stand-in the run never uses."""
    probe = batch["probes"][0]
    meta = aim.get("meta") or {}
    hits = parse_hits(aim)
    clearance_ok = (meta.get("min_clearance") or -1) >= page.MIN_EDGE_CLEARANCE_PX
    return [_check("cdp_multi_client", multi_client,
                   "a second concurrent CDP client attached alongside the daemon's own"),
            _check("cu_ready", probe["outcome"] == "hit", _cu_ready_detail(probe)),
            _check("trusted_click", probe["click_trusted"] is True,
                   f"click_trusted={probe['click_trusted']}"),
            _check("zoom_guard", meta.get("vv_scale") == 1,
                   f"visualViewport.scale={meta.get('vv_scale')}"),
            _check("no_scroll", _unscrolled(meta, hits),
                   f"page scroll=({meta.get('scroll_x')},{meta.get('scroll_y')})"),
            _check("window_bounds_applied", _bounds_applied(meta, bounds),
                   f"bounds={bounds} avail=({meta.get('avail_w')},{meta.get('avail_h')}) "
                   f"screen=({meta.get('screen_w')},{meta.get('screen_h')})"),
            _check("clearance", clearance_ok,
                   f"min_clearance={meta.get('min_clearance')}px, "
                   f"floor {page.MIN_EDGE_CLEARANCE_PX}px"
                   + ("" if clearance_ok else " — the window is too small for safe aiming")),
            _check("echo_cross_check", _cross_check_ok(probe),
                   f"trace echo vs page hit = {probe['trace']['sent_cross_check_px']} sent px, "
                   f"tolerance {CROSS_CHECK_TOLERANCE_SENT_PX}")] + list(trace_checks)


def _cu_ready_detail(probe: dict) -> str:
    """The outcome plus the last refusal's own message: 'refused_unrecovered' alone
    cannot tell an asleep display from a tripwire from a sandbox refusal."""
    detail = f"probe outcome {probe['outcome']}"
    refusals = probe.get("refusals") or []
    if refusals:
        last = refusals[-1]
        detail += f" — {last['kind']}: {last.get('message') or '(no message recorded)'}"
    return detail


def _check(name: str, passed: bool, detail: str) -> traces.CheckResult:
    return traces.CheckResult(name=name, passed=bool(passed), detail=detail)


def _unscrolled(meta: dict, hits: list[Hit]) -> bool:
    return (not meta.get("scroll_x") and not meta.get("scroll_y")
            and all(not h.scroll_x and not h.scroll_y for h in hits))


def _bounds_applied(meta: dict, bounds: dict) -> bool:
    """The window fills the available WORKAREA. Deliberately not `top == 0`: macOS
    never places a normal window under the menu bar, so the top the harness asks
    for is clamped to the workarea origin and `Browser.getWindowBounds` reports
    the clamped value (25 on the 3840x1080 target). The workarea offset
    `screen_h - avail_h` is exactly how far down the clamp may push it."""
    screen_h, avail_h, avail_w = meta.get("screen_h"), meta.get("avail_h"), meta.get("avail_w")
    top = bounds.get("top")
    if None in (screen_h, avail_h, avail_w, top):
        return False
    return (bounds.get("left") == 0 and 0 <= top <= max(0, screen_h - avail_h)
            and bounds.get("width") == avail_w and bounds.get("height") == avail_h)


def _cross_check_ok(probe: dict) -> bool:
    delta = probe["trace"]["sent_cross_check_px"]
    return delta is not None and delta <= CROSS_CHECK_TOLERANCE_SENT_PX


# --- results document -------------------------------------------------------

def build_results(*, run_id: str, seed: int, started_at: str, finished_at: str,
                  config_id: str, config_id_source: str, harness_git_rev: str,
                  environment: dict, calibration: dict, batches: list[dict],
                  incomplete: dict | None = None) -> dict:
    """`incomplete` names why a run stopped early (halt outcome or typed abort).
    A partial report must say so in the document itself: a reader comparing two
    runs cannot see a missing batch, but can see this key."""
    if not run_id or not config_id:
        raise ScoreError("a results document needs a run id and a config id")
    return {"run_id": run_id, "seed": seed, "started_at": started_at,
            "finished_at": finished_at, "config_id": config_id,
            "config_id_source": config_id_source, "harness_git_rev": harness_git_rev,
            "environment": environment, "calibration": calibration,
            "incomplete": incomplete, "suites": _group(batches)}


def _group(batches: list[dict]) -> dict:
    suites: dict[str, dict] = {}
    for batch in batches:
        conditions = suites.setdefault(batch["suite"], {"conditions": {}})["conditions"]
        conditions.setdefault(batch["condition"], {"batches": []})["batches"].append(batch)
    for suite, body in suites.items():
        for condition in body["conditions"].values():
            condition["summary"] = summarize(suite, condition["batches"])
    return suites


def write_results(path: str, doc: dict) -> str:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(doc, handle, indent=2, sort_keys=False)
        handle.write("\n")
    return path


def render_report(doc: dict) -> str:
    lines = [f"# Aimed-click accuracy — {doc['run_id']}", "",
             f"- config: `{doc['config_id']}` ({doc['config_id_source']})",
             f"- seed: `{doc['seed']}` · harness: `{doc['harness_git_rev']}`",
             f"- window: {doc['started_at']} → {doc['finished_at']}",
             f"- environment: `{json.dumps(doc['environment'], sort_keys=True)}`",
             f"- calibration: `{json.dumps(doc['calibration'], sort_keys=True)}`",
             _incomplete_line(doc.get("incomplete")), "",
             "Headline M1 number is the **probe-1 hit rate** — the only probe in a batch",
             "that no earlier FIRED marker could coach. The all-probe rate and the",
             "per-probe-index trajectory are reported beside it: a rate that climbs within",
             "a batch is feedback exploitation, which is itself signal for the C2 gate.", ""]
    for suite, body in sorted(doc["suites"].items()):
        lines.append(f"## {suite}")
        lines.append("")
        for condition, payload in sorted(body["conditions"].items()):
            lines.extend(_render_condition(suite, condition, payload["summary"]))
    return "\n".join(lines) + "\n"


def _incomplete_line(incomplete: dict | None) -> str:
    if not incomplete:
        return "- run: complete"
    return (f"- **run INCOMPLETE** — {incomplete['reason']} at batch "
            f"`{incomplete['batch']}`: {incomplete['detail']}")


def _render_condition(suite: str, condition: str, summary: dict) -> list[str]:
    fired_key = FIRED_METRIC[suite]
    rows = [("batches", summary["batches"]), ("scored probes", summary["n"]),
            ("probe-1 hit rate", summary["first_probe_hit_rate"]),
            ("all-probe hit rate", summary["hit_rate"]),
            (fired_key, summary[fired_key]),
            ("aim error px mean/median/p90",
             f"{summary['aim_error_css']['mean']}/{summary['aim_error_css']['median']}"
             f"/{summary['aim_error_css']['p90']}"),
            ("col off-by", json.dumps(summary["col_off_by"])),
            ("row off-by", json.dumps(summary["row_off_by"])),
            ("refusals", json.dumps(summary["refusal_counts"])),
            ("recovery rate", summary["recovery_rate"]),
            ("other pointer actions", summary["other_pointer"]),
            ("unpaired page hits", summary["unpaired_hits"]),
            ("extra on-page clicks", summary["extra_clicks"])]
    out = [f"### {condition}", "", "| metric | value |", "| --- | --- |"]
    out += [f"| {name} | {value} |" for name, value in rows]
    out += ["", "| outcome | n |", "| --- | --- |"]
    out += [f"| {name} | {count} |" for name, count in summary["outcome_counts"].items() if count]
    out += ["", "| batch flag | n |", "| --- | --- |"]
    out += [f"| {name} | {count} |" for name, count in summary["flag_counts"].items() if count]
    out += ["", "| probe index | n | hit rate |", "| --- | --- | --- |"]
    out += [f"| {index} | {slot['n']} | {slot['hit_rate']} |"
            for index, slot in sorted(summary["by_probe_index"].items(), key=lambda kv: int(kv[0]))]
    return out + [""]
