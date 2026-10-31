#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7"]
# ///
"""Tests for the computer-use trace baseline (`bin/cu_baseline.py`) and the
classifier it shares with the desktop runner (`bin/desktoplib/cu_trace.py`).

Hermetic: synthetic trace directories under the test's temporary directory, and
nothing under `~/.fermix*` is read. The failure sentences below are the ones
`Tools.ComputerUse` renders (`tools/computer_use.ex`, the function named beside
each), and `test_every_anchor_is_still_rendered_by_the_engine` re-reads that
source so a reworded sentence fails here instead of silently reclassifying every
row it used to match. Run: `uv run bin/test_cu_baseline.py`.
"""
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

import cu_baseline  # noqa: E402
from desktoplib import cu_trace  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))
ENGINE_SOURCES = [
    os.path.join(REPO, "apps/fermix_core/lib/fermix_core/tools/computer_use.ex"),
    os.path.join(REPO, "apps/fermix_core/lib/fermix_core/computer_use/session.ex"),
]
BASE_MS = 1_790_000_000_000
TURN = "main-9"


def iso(ms: float) -> str:
    return datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc).isoformat()


def cu_row(at_ms, action, *, success=True, output=None, args=None, session=TURN, **extra):
    row = {"ts": iso(at_ms), "type": "tool_exec", "agent": "main", "tool": "computer_use",
           "action": action, "success": success, "duration_ms": 120, "session_id": session}
    if output is not None:
        row["output"] = output
    if args is not None:
        row["input"] = args
    row.update(extra)
    return row


def llm_row(at_ms, *, session=TURN, duration=2000):
    return {"ts": iso(at_ms), "type": "llm_call", "agent": "main", "session_id": session,
            "provider": "openai", "model": "gpt-5.5", "duration_ms": duration}


def click(x, y, observation="7c1e-1", action="left_click"):
    return (f'%{{"action" => "{action}", "observation_id" => "{observation}", '
            f'"x" => {x}, "y" => {y}}}')


# --- one failed row, one class ---------------------------------------------------

@pytest.mark.parametrize("output,expected", [
    # refusal_message({:refused, :strict_mode})
    ("computer use is in strict (look-only) access — only screenshot, mouse_move, and wait "
     "run; this mutating action was refused.", "permission"),
    # refusal_message({:refused, :input_control_denied})
    ("macOS is silently dropping synthetic clicks and keystrokes: the Accessibility "
     "permission is not granted, so mutating actions are refused", "permission"),
    # background_code_message("screen_recording_not_granted")
    ("this action was not sent: the computer-use helper cannot capture this window because "
     "screen capture is NOT granted. Do not retry.", "permission"),
    # action_error_message({:timeout, :cu_sidecar_action, ms})
    ("outcome unknown: the computer-use helper stopped responding 30000 ms into this action, "
     "so whether it reached the screen cannot be told from here.", "timeout"),
    # action_error_message({:timeout, :cu_session_call, ms})
    ("outcome unknown: the computer-use session was still working 35000 ms after this action "
     "was sent, so whether it finished cannot be told from here.", "timeout"),
    # ax_dispatch_message(ax_cause("ax_timed_out", :not_sent), _)
    ("this action was not sent: the accessibility call timed out before its message went "
     "anywhere, so this control was not touched.", "timeout"),
    # action_error_message("expired_observation") and its two siblings
    ("this action was not sent: the image its `observation_id` names is no longer one the "
     "computer-use helper holds — it has been replaced by newer ones", "stale_observation"),
    # action_error_message("stale_element")
    ("this action was not sent: the control its `element_ref` names is no longer one the "
     "computer-use helper holds", "stale_observation"),
    # refusal_message(:observation_required)
    ("this action was not sent: it names no `observation_id`, so there is no reply its "
     "target belongs to", "refusal"),
    # action_error_message("element_disabled")
    ("this action was not sent: that control is DISABLED right now, so it would do nothing",
     "refusal"),
    # ambiguous_grid_message/1
    ("ambiguous coordinates: (640,360) fits both image 7c1e-2, which is a 800x600 magnified "
     "crop", "refusal"),
    # refusal_message({:refused, :paused})
    ("computer use is paused — the user took the machine back with /pause.", "refusal"),
    # action_error_message({:sidecar_exited, status})
    ("outcome unknown: the computer-use helper exited (status 1) during this action",
     "other"),
    ("action failed: something new", "other"),
])
def test_a_failed_row_is_classified_by_the_sentence_it_carries(output, expected):
    assert cu_trace.classify_failure(cu_row(BASE_MS, "left_click", success=False,
                                            output=output)) == expected


@pytest.mark.parametrize("fields,expected", [
    ({"geometry_refusal": "expired_observation"}, "stale_observation"),
    # never the model's doing: the helper's picture no longer matches the display
    ({"geometry_refusal": "capture_geometry_mismatch"}, "stale_observation"),
    ({"geometry_refusal": "observation_required"}, "refusal"),
    ({"outcome": "refused"}, "refusal"),
    ({"courtesy": "paused", "outcome": "refused"}, "refusal"),
    ({"outcome": "unknown"}, "other"),
])
def test_a_row_without_content_is_classified_by_its_structured_fields(fields, expected):
    row = cu_row(BASE_MS, "left_click", success=False, **fields)
    assert cu_trace.classify_failure(row) == expected


def test_the_structured_code_wins_over_a_generic_lead():
    row = cu_row(BASE_MS, "left_click", success=False, geometry_refusal="stale_observation",
                 output="this action was not sent: something the sentence table does not know")
    assert cu_trace.classify_failure(row) == "stale_observation"


def test_classifying_a_successful_row_is_a_caller_error():
    with pytest.raises(ValueError):
        cu_trace.classify_failure(cu_row(BASE_MS, "screenshot"))


# --- missed aims ------------------------------------------------------------------

def test_a_click_repeated_at_other_coordinates_is_a_missed_aim():
    rows = [cu_row(BASE_MS, "left_click", args=click(100, 200)),
            cu_row(BASE_MS + 1000, "screenshot", args='%{"action" => "screenshot"}'),
            cu_row(BASE_MS + 2000, "left_click", args=click(130, 210, "7c1e-2"))]
    assert cu_trace.missed_aims(rows) == [0]


def test_the_same_point_again_is_a_retry_not_a_missed_aim():
    rows = [cu_row(BASE_MS, "left_click", args=click(100, 200)),
            cu_row(BASE_MS + 2000, "left_click", args=click(100, 200, "7c1e-2"))]
    assert cu_trace.missed_aims(rows) == []


def test_another_mutating_action_in_between_ends_the_aim():
    rows = [cu_row(BASE_MS, "left_click", args=click(100, 200)),
            cu_row(BASE_MS + 1000, "type", args='%{"action" => "type", "text" => "hi"}'),
            cu_row(BASE_MS + 2000, "left_click", args=click(300, 400))]
    assert cu_trace.missed_aims(rows) == []


def test_a_refused_first_click_is_not_an_aim_that_missed():
    rows = [cu_row(BASE_MS, "left_click", success=False, args=click(100, 200)),
            cu_row(BASE_MS + 2000, "left_click", args=click(300, 400))]
    assert cu_trace.missed_aims(rows) == []


def test_a_press_by_reference_cannot_miss():
    press = '%{"action" => "left_click", "observation_id" => "7c1e-1", "element_ref" => "e4"}'
    rows = [cu_row(BASE_MS, "left_click", args=press),
            cu_row(BASE_MS + 2000, "left_click", args=click(300, 400))]
    assert cu_trace.missed_aims(rows) == []


def test_a_drag_compares_both_ends():
    drag = ('%{"action" => "left_click_drag", "observation_id" => "o", "x" => 1, "y" => 2, '
            '"to" => %{"x" => 50, "y" => 60}}')
    moved = drag.replace('"x" => 50', '"x" => 70')
    rows = [cu_row(BASE_MS, "left_click_drag", args=drag),
            cu_row(BASE_MS + 2000, "left_click_drag", args=moved)]
    assert cu_trace.missed_aims(rows) == [0]


def test_aim_not_confirmed_is_counted_from_the_helpers_own_marker():
    output = SHOT + " Aim NOT confirmed at (640,360): the cursor ended at (12,40)."
    rows = [cu_row(BASE_MS, "left_click", output=output, args=click(640, 360))]
    assert cu_trace.turn_counts(rows, retained=3)["aim_not_confirmed"] == 1


SHOT = ("Image 7c1e-1, 1280x800 (display 0). Coordinates are pixels in this exact image: "
        'pass observation_id "7c1e-1" with any click, move, drag, scroll or inspect.')


def test_image_dims_read_both_image_leads():
    assert cu_trace.image_dims(SHOT) == [(1280, 800)]
    assert cu_trace.image_dims("Screenshot 1024x768, not addressable.") == [(1024, 768)]
    assert cu_trace.image_dims("List 7c1e-3. The coordinates below are pixels") == []
    assert cu_trace.image_tokens(1280, 800) == pytest.approx(1280 * 800 / 750)


# --- turns ----------------------------------------------------------------------

def test_turns_split_by_session_and_by_a_long_gap():
    rows = [cu_row(BASE_MS, "screenshot"), llm_row(BASE_MS + 1000),
            cu_row(BASE_MS + 5000, "screenshot", session="main-10"),
            # main-9 again two hours later: a restarted daemon reuses the counter
            cu_row(BASE_MS + 2 * 3600_000, "screenshot")]
    turns = cu_trace.bucket_turns(rows, gap_ms=cu_trace.TURN_GAP_MS)
    assert sorted(len(t) for t in turns) == [1, 1, 2]


# --- the engine still renders every anchor ----------------------------------------

def _engine_text() -> str:
    """The source with adjacent string literals joined (`"a " <> "b"` reads
    `a b`), which is how the sentences reach a trace row."""
    text = ""
    for path in ENGINE_SOURCES:
        with open(path, encoding="utf-8") as handle:
            text += handle.read()
    return re.sub(r'"\s*<>\s*\n\s*"', "", text)


def test_every_anchor_is_still_rendered_by_the_engine():
    text = _engine_text()
    for kind, anchors in cu_trace.FAILURE_ANCHORS:
        for anchor in anchors:
            assert anchor in text, f"{kind} anchor {anchor!r} is no longer in the engine source"
    for anchor in (cu_trace.AIM_NOT_CONFIRMED, "Screenshot #{sent_size(response)}",
                   '"Image #{id}, #{sent_size(response)} (display'):
        assert anchor in text, anchor


def test_each_expectable_code_is_the_sentence_its_own_clause_renders():
    text = _engine_text()
    assert cu_trace.TYPED_CODE_ANCHORS, "no typed code can be expected"
    for code, anchor in cu_trace.TYPED_CODE_ANCHORS.items():
        clause = re.search(r'defp action_error_message\("' + re.escape(code)
                           + r'"\) do\n(.*?)\n  end', text, re.DOTALL)
        assert clause, f"the engine no longer renders a sentence for {code}"
        assert anchor in clause.group(1), f"{code}: {anchor!r} is not its sentence"


# The protocol-12 refusals a desktop task may expect (M86 P2): the control
# refusals macOS answers, and the ones only the Linux helper answers at first.
PROTOCOL_12_EXPECTABLE = {"stale_element", "ax_action_unsupported", "state_unreadable",
                          "focus_refused", "scope_not_found", "accessibility_unavailable",
                          "pixels_unavailable", "toolkit_accessibility_off", "text_outside_layout",
                          "consent_refused", "consent_timeout"}


def test_the_protocol_12_refusals_can_be_expected():
    missing = PROTOCOL_12_EXPECTABLE - set(cu_trace.TYPED_CODE_ANCHORS)
    assert not missing, f"no anchor for {sorted(missing)}"


def _sentence(text: str, code: str) -> str:
    """The sentence `action_error_message("<code>")` renders: its string literals,
    joined as the `<>` joins them."""
    clause = re.search(r'defp action_error_message\("' + re.escape(code)
                       + r'"\) do\n(.*?)\n  end', text, re.DOTALL)
    assert clause, f"the engine no longer renders a sentence for {code}"
    return "".join(re.findall(r'"((?:[^"\\]|\\.)*)"', clause.group(1)))


# Two anchors that both match one sentence would let a task pass on the wrong
# refusal, so each sentence carries its own code and no other.
def test_each_expectable_sentence_carries_its_own_code_alone():
    text = _engine_text()
    for code in cu_trace.TYPED_CODE_ANCHORS:
        row = cu_row(BASE_MS, "focus", success=False, output=_sentence(text, code))
        carried = {other for other in cu_trace.TYPED_CODE_ANCHORS
                   if cu_trace.carries_code(row, other)}
        assert carried == {code}, f"{code}'s sentence carries {sorted(carried)}"


DISABLED = ("this action was not sent: that control is DISABLED right now, so it would do "
            "nothing however it were reached")


def test_a_row_carries_a_typed_code_only_by_its_own_sentence():
    disabled = cu_row(BASE_MS, "press", success=False, output=DISABLED)
    paused = cu_row(BASE_MS, "press", success=False, courtesy="paused", outcome="refused",
                    output="computer use is paused — the user took the machine back with /pause.")
    assert cu_trace.carries_code(disabled, "element_disabled")
    assert not cu_trace.carries_code(paused, "element_disabled")
    assert not cu_trace.carries_code({**disabled, "success": True}, "element_disabled")


def test_the_stale_codes_are_the_engines_geometry_refusals():
    text = _engine_text()
    match = re.search(r"@geometry_refusals ~w\(([^)]*)\)", text)
    assert match, "the engine no longer names its geometry refusals"
    codes = set(match.group(1).split())
    assert cu_trace.STALE_CODES <= codes


# --- the baseline over a traces directory -----------------------------------------

def _write_day(root, day, tool_rows, llm_rows=()):
    directory = os.path.join(root, day)
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, "tool_exec.jsonl"), "w", encoding="utf-8") as handle:
        handle.writelines(json.dumps(row) + "\n" for row in tool_rows)
    if llm_rows:
        with open(os.path.join(directory, "llm_call.jsonl"), "w", encoding="utf-8") as handle:
            handle.writelines(json.dumps(row) + "\n" for row in llm_rows)


def _snapshot(root):
    return sorted((p, os.path.getmtime(os.path.join(d, p)))
                  for d, _dirs, files in os.walk(root) for p in files)


def test_the_baseline_classifies_counts_and_writes_a_report(tmp_path, capsys):
    root = str(tmp_path / "traces")
    day = datetime.fromtimestamp(BASE_MS / 1000, tz=timezone.utc).date().isoformat()
    _write_day(root, day, [
        cu_row(BASE_MS + 100, "screenshot", output=SHOT),
        cu_row(BASE_MS + 4000, "left_click", args=click(100, 200)),
        cu_row(BASE_MS + 9000, "left_click", args=click(150, 250)),
        cu_row(BASE_MS + 12000, "left_click", success=False,
               geometry_refusal="expired_observation"),
        {"ts": iso(BASE_MS + 13000), "type": "tool_exec", "agent": "main", "tool": "shell",
         "success": False, "session_id": TURN},
    ], [llm_row(BASE_MS + 3000, duration=2500), llm_row(BASE_MS + 8000, duration=3000)])
    before = _snapshot(root)
    out = tmp_path / "report"
    assert cu_baseline.main(["--traces", root, "--out", str(out)]) == 0
    assert _snapshot(root) == before, "the baseline must never write into a traces directory"
    doc = json.loads((out / "baseline.json").read_text(encoding="utf-8"))
    cu = doc["computer_use"]
    assert cu["rows"] == 4
    assert cu["failed"] == 1
    assert cu["failure_classes"] == {"refusal": 0, "timeout": 0, "permission": 0,
                                     "stale_observation": 1, "other": 0}
    assert cu["missed_aims"] == 1
    assert doc["turns"]["count"] == 1
    assert doc["turns"]["image_tokens"]["total"] == pytest.approx(1280 * 800 / 750)
    assert doc["turns"]["model_calls"]["total"] == 2
    assert doc["by_day"] == [{"root": root, "day": day, "cu_rows": 4, "failed": 1, "turns": 1}]
    assert (out / "baseline.md").exists()
    assert "stale_observation" in capsys.readouterr().out


@pytest.mark.parametrize("until", [None, "2026-10-30"])
def test_a_turn_across_utc_midnight_keeps_its_model_calls(tmp_path, until):
    root = str(tmp_path / "traces")
    midnight = datetime(2026, 10, 31, tzinfo=timezone.utc).timestamp() * 1000
    _write_day(root, "2026-10-30", [cu_row(midnight - 20_000, "screenshot", output=SHOT)],
               [llm_row(midnight - 30_000, duration=1000)])
    _write_day(root, "2026-10-31", [], [llm_row(midnight + 5_000, duration=1000)])
    out = tmp_path / "report"
    args = ["--traces", root, "--out", str(out)] + (["--until", until] if until else [])
    assert cu_baseline.main(args) == 0
    doc = json.loads((out / "baseline.json").read_text(encoding="utf-8"))
    assert doc["turns"]["count"] == 1
    assert doc["turns"]["model_calls"]["total"] == 2


def test_the_baseline_says_so_when_there_is_nothing_to_count(tmp_path, capsys):
    root = str(tmp_path / "traces")
    os.makedirs(os.path.join(root, "2026-10-24"))
    out = tmp_path / "report"
    assert cu_baseline.main(["--traces", root, "--out", str(out)]) == 0
    doc = json.loads((out / "baseline.json").read_text(encoding="utf-8"))
    assert doc["computer_use"]["rows"] == 0
    assert doc["computer_use"]["failure_rate"] is None
    assert "no computer-use rows" in capsys.readouterr().out


def test_a_named_traces_directory_that_does_not_exist_is_refused(tmp_path, capsys):
    code = cu_baseline.main(["--traces", str(tmp_path / "missing"), "--out", str(tmp_path / "r")])
    assert code == cu_baseline.EXIT_USAGE
    assert "does not exist" in capsys.readouterr().err


def test_the_day_window_narrows_the_scan(tmp_path):
    root = str(tmp_path / "traces")
    for day in ("2026-10-01", "2026-10-02", "2026-10-03"):
        os.makedirs(os.path.join(root, day))
    assert cu_trace.trace_days(root, since="2026-10-02", until=None) == ["2026-10-02",
                                                                        "2026-10-03"]
    assert cu_trace.trace_days(root, since=None, until="2026-10-01") == ["2026-10-01"]


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
