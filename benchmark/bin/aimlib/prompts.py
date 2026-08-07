"""Batch prompt templates and the model's self-report parser.

Runner contract: `BATCH_PLAN` is the whole run structure (suite, condition,
batches, probes per batch) — six batches of four probes for the grid suite, so
every batch contributes one probe that no FIRED marker could have coached;
`batch_prompt(plan, url, profile)` renders the single turn that opens the page,
waits for `READY`, runs the batch, and ends with the JSON self-report; and
`parse_model_report(reply)` turns that reply into probe rows or raises
`ReportError` (which score.py records as `report_unparseable` — hits still score,
the fired column goes null).

Every template pins the rail: the model may take exactly two browser-tool actions
(open, then act/wait for text) and must click only with computer_use. That pin is
necessary but not sufficient — the page cannot tell the two rails apart, so
score.py re-checks the trace. Each probe also takes ONE fresh screenshot AFTER
its click and judges the target's fired state from that image, never from the
click action's own check echo, which can predate the page's paint.
"""

from __future__ import annotations

import json
import re

from . import page

# (suite, condition, batches, probes per batch). Constants, not knobs: the sample
# size is what makes the C2 gate readable, and a flag that shrinks it silently
# invalidates a comparison.
BATCH_PLAN = (
    ("s1", "full_screen", 6, 4),
    ("s1", "crop", 6, 4),
    ("s2", "full_screen", 1, 8),
    ("s2", "crop", 1, 8),
    ("s3", "na", 1, 8),
)
CAL_BATCH = ("cal", "na", 1, 1)

SUITE_TITLES = {"s1": "grid arithmetic", "s2": "singleton locate",
                "s3": "marks comparator", "cal": "calibration"}
ABORT_TOKEN = "ABORT"


class ReportError(ValueError):
    """The model's final JSON self-report was missing or unusable."""


_HEADER = ("This is an automated measurement of your computer_use screen-pixel aiming. "
           "Follow these steps exactly, in order, and do nothing else.\n")

_STEP_OPEN = (
    '1. Open {url} in the managed browser, profile "{profile}". Then wait for the page to '
    "show the text READY using the browser tool with EXACTLY these arguments: action act, "
    'kind wait, wait_until "text", text "READY", timeout_ms 60000, target = the tab id the '
    "open returned. "
    'Pass profile "{profile}" on EVERY browser call, the wait included — a browser call '
    "without it targets a different browser and the task fails. "
    "These are the ONLY two browser-tool actions you may use in this task — never click, "
    "click_coords, get, or navigate with it. The page must stay open.\n"
    "   If the wait errors or times out, re-send it once with exactly those arguments; if "
    "READY still has not appeared, reply with exactly: {abort}.\n")

_AIM_FULL_SCREEN = (
    "2. For each target below, in order: take a fresh full-screen screenshot with "
    "computer_use, find the labeled grid, compute the target cell's center from the edge "
    "coordinate labels (columns A-L left to right, rows 1-6 top to bottom), and left_click "
    "it at pixel coordinates with computer_use. Exactly one click per target. If "
    "computer_use refuses with a typed message, follow the refusal's own recovery "
    "instruction and re-send — the re-send is that target's one click.\n")

_AIM_CROP = (
    "2. For each target below, in order: take a fresh full-screen screenshot with "
    "computer_use, then take a magnified screenshot of the grid using region = the grid's "
    "bounding box you read off the full screenshot, and click the target inside that "
    "magnified crop, sending the SAME region with your click. Compute the target cell's "
    "center from the edge coordinate labels (columns A-L left to right, rows 1-6 top to "
    "bottom). Exactly one click per target. If computer_use refuses with a typed message, "
    "follow the refusal's own recovery instruction and re-send — the re-send is that "
    "target's one click.\n")

_AIM_SINGLE_FULL = (
    "2. The page shows exactly ONE blue ring at a time. For each probe below, in order: "
    "take a fresh full-screen screenshot with computer_use, find the ring, and left_click "
    "its center at pixel coordinates with computer_use. Exactly one click per probe; the "
    "next ring appears only after you click. If computer_use refuses with a typed message, "
    "follow the refusal's own recovery instruction and re-send — the re-send is that "
    "probe's one click.\n")

_AIM_SINGLE_CROP = (
    "2. The page shows exactly ONE blue ring at a time. For each probe below, in order: "
    "take a fresh full-screen screenshot with computer_use, then take a magnified "
    "screenshot of the area around the ring using a region you read off the full "
    "screenshot, and click the ring inside that magnified crop, sending the SAME region "
    "with your click. Exactly one click per probe; the next ring appears only after you "
    "click. If computer_use refuses with a typed message, follow the refusal's own "
    "recovery instruction and re-send — the re-send is that probe's one click.\n")

_AIM_MARKS = (
    "2. For each button below, in order: take a screenshot with marks: true, find the mark "
    "number badged on the button with that label, and click it by sending mark: <that "
    "number> — never x/y. Take a fresh marks screenshot before EVERY click. Exactly one "
    "click per button. If computer_use refuses with a typed message, follow the refusal's "
    "own recovery instruction and re-send — the re-send is that button's one click.\n")

_AIM_CAL = (
    "2. Take a fresh full-screen screenshot with computer_use, find the button labeled "
    "CAL, and left_click its center at pixel coordinates with computer_use. Exactly one "
    "click.\n")

_AIM_CLAUSES = {
    ("s1", "full_screen"): _AIM_FULL_SCREEN,
    ("s1", "crop"): _AIM_CROP,
    ("s2", "full_screen"): _AIM_SINGLE_FULL,
    ("s2", "crop"): _AIM_SINGLE_CROP,
    ("s3", "na"): _AIM_MARKS,
    ("cal", "na"): _AIM_CAL,
}

# F3: the click's own check capture has no paint settle, so it can show the page
# BEFORE the FIRED repaint. The fired judgment must come from a later image.
_STEP_VERIFY = (
    "3. After each click, take ONE more fresh screenshot the same way you took the one you "
    "aimed from, and look at THAT image: a target that fired is solid orange and says "
    "FIRED. Note whether the target you were aiming at fired. Never judge this from the "
    "picture attached to the click action itself.\n")

_STEP_REPORT = ("4. When every probe is done, reply with ONLY a JSON array, one object per "
                "probe, in probe order:\n   {shape}\n")

_REPORT_SHAPES = {
    "s1": '[{"probe":1,"cell":"D3","x":<x you clicked>,"y":<y you clicked>,"fired":true|false}, ...]',
    "s2": '[{"probe":1,"x":<x you clicked>,"y":<y you clicked>,"fired":true|false}, ...]',
    "s3": '[{"probe":1,"label":"Anchor","mark":<mark number you sent>,"fired":true|false}, ...]',
    "cal": '[{"probe":1,"x":<x you clicked>,"y":<y you clicked>,"fired":true|false}, ...]',
}


def batch_prompt(plan: page.BatchPlan, url: str, profile: str = "fermix_visible") -> str:
    """The full text of the one turn that runs `plan`."""
    key = (plan.suite, plan.condition)
    if key not in _AIM_CLAUSES:
        raise ReportError(f"no prompt template for suite/condition {key}")
    if not url or not profile:
        raise ReportError("batch_prompt needs a page url and a browser profile name")
    return (_HEADER
            + _STEP_OPEN.format(url=url, profile=profile, abort=ABORT_TOKEN)
            + _AIM_CLAUSES[key]
            + _STEP_VERIFY
            + _targets_line(plan)
            + _STEP_REPORT.format(shape=_REPORT_SHAPES[plan.suite]))


def _targets_line(plan: page.BatchPlan) -> str:
    if plan.suite == "s2":
        return f"Probes, in order: {plan.probes} rings, one click each.\n"
    label = "Buttons, in order" if plan.suite == "s3" else "Targets, in order"
    listed = ", ".join(f"{i + 1}: {t}" for i, t in enumerate(plan.targets))
    return f"{label}: {listed}\n"


# --- self-report parsing ----------------------------------------------------

_FENCE_RE = re.compile(r"```(?:json)?\s*(.+?)```", re.DOTALL)


def parse_model_report(reply: str) -> list[dict]:
    """Probe rows from the model's reply. Accepts a bare array or one inside a code
    fence; anything else raises with what was actually seen."""
    if not isinstance(reply, str) or not reply.strip():
        raise ReportError("the model reply was empty")
    if reply.strip() == ABORT_TOKEN:
        raise ReportError(f"the model replied {ABORT_TOKEN}: the page never reached READY")
    raw = _extract_array(reply)
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ReportError(f"the report is not valid JSON: {exc}") from exc
    if not isinstance(parsed, list):
        raise ReportError(f"the report decoded to {type(parsed).__name__}, expected an array")
    return [_report_row(item, index) for index, item in enumerate(parsed, start=1)]


def _extract_array(reply: str) -> str:
    fenced = _FENCE_RE.search(reply)
    text = fenced.group(1).strip() if fenced else reply.strip()
    start = text.find("[")
    if start < 0:
        raise ReportError("no JSON array in the model reply")
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "[":
            depth += 1
        elif text[index] == "]":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise ReportError("the JSON array in the model reply is unterminated")


def _report_row(item, index: int) -> dict:
    if not isinstance(item, dict):
        raise ReportError(f"report entry {index} is {type(item).__name__}, expected an object")
    if "fired" not in item or not isinstance(item["fired"], bool):
        raise ReportError(f"report entry {index} has no boolean `fired`")
    probe = item.get("probe", index)
    if not isinstance(probe, int) or isinstance(probe, bool):
        raise ReportError(f"report entry {index} has a non-integer `probe`")
    return {"probe": probe, "fired": item["fired"],
            "x": _optional_number(item.get("x"), index, "x"),
            "y": _optional_number(item.get("y"), index, "y"),
            "cell": item.get("cell"), "label": item.get("label"),
            "mark": _optional_number(item.get("mark"), index, "mark")}


def _optional_number(value, index: int, field: str):
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ReportError(f"report entry {index} has a non-numeric `{field}`")
    return value
