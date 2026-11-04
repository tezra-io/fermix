#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7"]
# ///
"""Tests for the open-loop judgment tooling (M83 §06): the suite builder
(build_judgment_suite.py) and the agreement report (judgment_agreement.py). Pure and
temp-dir only; no daemon. Run: `uv run bin/test_judgment.py`."""
from __future__ import annotations

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402
import yaml  # noqa: E402

import build_judgment_suite as build  # noqa: E402
import judgment_agreement as agree  # noqa: E402
from evallib import suites  # noqa: E402

MOMENTS = [
    {"id": "s01", "when": "Thu 22:10",
     "messages": ["Dad's biopsy results should come back Monday. Trying not to think about it."]},
    {"id": "s03", "when": "Wed 08:12", "messages": ["Train's stuck outside Halden again. Classic."]},
    {"id": "s28", "when": "Wed 19:30",
     "messages": ["Worst board meeting of my life today.", "I don't want to talk about it."]},
    {"id": "s37", "when": "Sat 14:00", "messages": ["Bought a new plant. His name is Gerald."]},
]


def _write(tmp_path, name, value):
    path = tmp_path / name
    path.write_text(json.dumps(value), encoding="utf-8")
    return str(path)


def _labels(**by_id):
    return [{"id": mid, "data": {"label": label, "note": ""}} for mid, label in by_id.items()]


def _build(tmp_path, labels, moments=MOMENTS):
    out = tmp_path / "open_loop_judgment.yaml"
    lines = build.build(_write(tmp_path, "moments.json", moments),
                        _write(tmp_path, "labels.json", labels), str(out))
    return out, lines


# --- the builder ----------------------------------------------------------------

def test_the_shipped_moments_are_the_sixty_on_the_labelling_page():
    moments = build.load_moments(build.MOMENTS_PATH)
    assert [m["id"] for m in moments] == [f"s{i:02d}" for i in range(1, 61)]
    assert [len(m["messages"]) for m in moments if len(m["messages"]) > 1] == [2, 2]


def test_a_built_suite_loads_and_holds_one_task_per_labelled_moment(tmp_path):
    out, lines = _build(tmp_path, _labels(s01="check_in", s03="let_go", s28="when_around"))
    loaded = suites.load_all(str(tmp_path))
    assert [s.name for s in loaded] == ["cap_open_loop_judgment"]
    suite = loaded[0]
    assert {scn.risk for scn in suite.scenarios} == {"isolated_mutation"}
    assert [scn.id for scn in suite.scenarios] == ["s01", "s03", "s28"]
    assert all(len(scn.cases) == 1 for scn in suite.scenarios)
    assert "skipped 1 unlabelled: s37" in lines
    assert lines[0] == "labelled 3 of 4: let_go 1, when_around 1, check_in 1"


def test_each_task_carries_its_label_the_reset_and_the_job_ban(tmp_path):
    out, _lines = _build(tmp_path, _labels(s01="check_in", s28="when_around"))
    doc = yaml.safe_load(out.read_text(encoding="utf-8"))
    first = doc["scenarios"][0]
    case = first["cases"][0]
    assert "label_check_in" in first["tags"]
    assert case["query"] == MOMENTS[0]["messages"][0]
    assert case["expect"] == {"tools_none": ["schedule_job"]}
    assert case["checker"]["state"] == build.RESET_STATE
    assert case["checker"]["expect"] == {"label": "check_in", "moment": "s01",
                                         "labelled_when": "Thu 22:10"}
    # A two-message moment is two turns, in the order the owner sent them.
    multi = doc["scenarios"][1]["cases"][0]
    assert [t["query"] for t in multi["turns"]] == MOMENTS[2]["messages"]
    assert "query" not in multi


def test_the_reset_spec_seeds_nothing_so_seed_state_only_resets(tmp_path):
    with open(os.path.join(build.SKILL_DIR, build.RESET_STATE), encoding="utf-8") as fh:
        assert json.load(fh) == {"open_loops": []}


def test_the_owners_notes_never_reach_the_suite(tmp_path):
    labels = [{"id": "s01", "data": {"label": "check_in", "note": "ZEBRA-private-reason"}}]
    out, lines = _build(tmp_path, labels)
    assert "ZEBRA" not in out.read_text(encoding="utf-8")
    assert "1 note(s) left out of the suite (they stay on the page)" in lines


def test_no_gate_reads_a_date_and_the_header_says_why(tmp_path):
    out, _lines = _build(tmp_path, _labels(s01="check_in"))
    text = out.read_text(encoding="utf-8")
    assert "no gate reads a date" in text
    doc = yaml.safe_load(text)
    for scn in doc["scenarios"]:
        assert set(scn["cases"][0]["checker"]["expect"]) == {"label", "moment",
                                                             "labelled_when"}


def test_the_header_names_the_moments_read_with_the_run_date(tmp_path):
    import re
    out, _lines = _build(tmp_path, _labels(s01="check_in"))
    text = out.read_text(encoding="utf-8")
    start = text.index("# READ WITH THE DATE.")
    paragraph = text[start:text.index("\n#\n", start)]
    listed = re.findall(r"\bs\d\d\b", paragraph)
    shipped = {m["id"] for m in build.load_moments(build.MOMENTS_PATH)}
    assert len(listed) == len(set(listed)) and set(listed) <= shipped, listed
    assert {"s02", "s22", "s35", "s53"} <= set(listed)


def test_the_stage_0_recipe_names_files_that_exist():
    """The recipe copies M83 files onto the pre-M83 engine by path; a renamed file
    would make it copy nothing, silently."""
    import re
    recipe = build.__doc__[build.__doc__.index("STAGE 0"):]
    paths = re.findall(r"\b((?:bin|suites)/[\w/.]+\.(?:py|json|yaml|exs))\b", recipe)
    assert "bin/run_capability.py" in paths and "bin/evallib/aggregate.py" in paths
    assert "bin/seed_state.exs" in paths            # named, as the file NOT to copy
    for path in paths:
        assert os.path.isfile(os.path.join(build.SKILL_DIR, path)), path


@pytest.mark.parametrize("labels, defect", [
    ([{"id": "s99", "data": {"label": "let_go"}}], "does not hold"),
    (_labels(s01="let_go") + _labels(s01="check_in"), "labelled twice"),
    ([{"id": "s01", "data": {"label": "remind_me"}}], "not one of"),
    ([{"id": "s01"}], "malformed"),
    ({"s01": "let_go"}, "JSON list"),
    ([{"id": "s01", "data": {"label": None, "note": ""}}], "no moment is labelled"),
])
def test_a_bad_export_writes_nothing(tmp_path, labels, defect):
    out = tmp_path / "open_loop_judgment.yaml"
    with pytest.raises(build.BuildError, match=defect):
        build.build(_write(tmp_path, "moments.json", MOMENTS),
                    _write(tmp_path, "labels.json", labels), str(out))
    assert not out.exists()


def test_main_exits_2_on_a_bad_export(tmp_path, capsys):
    code = build.main(["--labels", _write(tmp_path, "labels.json", {"x": 1}),
                       "--moments", _write(tmp_path, "moments.json", MOMENTS),
                       "--out", str(tmp_path / "out.yaml")])
    assert code == 2 and "JSON list" in capsys.readouterr().err


# --- the agreement report -------------------------------------------------------

def _detail(pred, want, stage=1, refused="none"):
    reach = {"check_in": "message", "when_around": "conversation"}.get(pred, "-")
    if stage == 0:
        reach = "n/a"
    noted = 0 if pred == "let_go" and refused == "none" else 1
    return (f"pred={pred} want={want} new={0 if pred == 'let_go' else 1} live=0 "
            f"reach={reach} kind=n/a class=- stage={stage} refused={refused} "
            f"noted={noted} | something")


def _results(tmp_path, moments, name="results.json", suite=agree.SUITE):
    """moments: id -> list of (pred, want[, stage[, status[, refused]]]) or None for an
    invalid trial."""
    tasks = {}
    for mid, trials in moments.items():
        records = []
        for trial in trials:
            if trial is None:
                records.append({"success": 0.0, "valid": False, "status": "no_trace",
                                "detail": ""})
                continue
            pred, want, *rest = trial
            stage = rest[0] if rest else 1
            target = want if stage == 1 else agree.collapse(want)
            ok = pred == target
            records.append({"success": 1.0 if ok else 0.0, "valid": True,
                            "status": rest[1] if len(rest) > 1 else "ok",
                            "detail": _detail(pred, want, stage,
                                              rest[2] if len(rest) > 2 else "none")})
        tasks[f"{suite}/{mid}"] = {"mean_success": 0.0, "n": len(records),
                                   "trial_records": records}
    return _write(tmp_path, name, {"arm": "fermix", "valid": True, "tasks": tasks})


def test_wilson_matches_the_designs_interval_at_80_percent_of_60():
    low, high = agree.wilson(48, 60)
    assert round(100 * low) == 68 and round(100 * high) == 88


def test_kappa_and_mcnemar_known_values():
    assert agree.kappa([("a", "a"), ("b", "b")]) == 1.0
    assert agree.kappa([("a", "a"), ("a", "a")]) is None          # chance is total
    pairs = [("a", "a")] * 20 + [("a", "b")] * 5 + [("b", "a")] * 10 + [("b", "b")] * 15
    assert round(agree.kappa(pairs), 3) == 0.4
    assert agree.mcnemar_exact(0, 0) == 1.0
    assert round(agree.mcnemar_exact(1, 9), 4) == 0.0215
    assert agree.mcnemar_exact(5, 5) == 1.0


def test_majority_needs_more_than_half_of_the_valid_trials():
    assert agree.majority(["check_in", "check_in", "let_go"]) == "check_in"
    assert agree.majority(["check_in", "let_go", "when_around"]) == "split"
    assert agree.majority(["check_in", "let_go"]) == "split"
    assert agree.majority([]) == "split"


def test_the_report_names_agreement_the_costliest_error_and_the_misses(tmp_path):
    path = _results(tmp_path, {
        "s01": [("check_in", "check_in")] * 3,
        "s03": [("check_in", "let_go"), ("check_in", "let_go"), ("let_go", "let_go")],
        "s28": [("when_around", "when_around"), ("let_go", "when_around"), None],
        "s37": [None, None, None],
    })
    run = agree.load_run(path)
    text = "\n".join(agree.report(run))
    assert "stage 1 (reach graded)" in text
    assert "3 measured, 1 with no valid trial (s37)" in text
    assert "trials: 8 valid, 4 invalid (excluded)" in text
    # Per moment: s01 agrees, s03 is a costly miss, s28 splits 1-1.
    assert "overall agreement: 1/3 = 33.3%" in text
    assert ("costliest error (check in where the owner said let it go): 1 moment(s)"
            in text)
    assert "    at: s03" in text
    assert "  s03: owner let_go · Fermix check_in, check_in, let_go" in text
    assert "  s28: owner when_around · Fermix when_around, let_go" in text
    # Per trial: 5 of 8 agree, and two trials checked in on a let-go moment.
    assert "overall agreement: 5/8 = 62.5%" in text
    assert "costliest error (check in where the owner said let it go): 2 trial(s)" in text


def _section(lines, title):
    start = lines.index(title)
    end = next((i for i in range(start + 1, len(lines)) if not lines[i]), len(lines))
    return lines[start:end]


def test_the_wilson_interval_is_per_moment_only(tmp_path):
    path = _results(tmp_path, {"s01": [("check_in", "check_in")] * 3,
                               "s03": [("check_in", "let_go")] * 3})
    lines = agree.report(agree.load_run(path))
    per_moment = _section(lines, "per moment (majority of its valid trials)")
    per_trial = _section(lines, "per trial")
    assert any("95% Wilson" in line for line in per_moment), per_moment
    assert not any("Wilson" in line for line in per_trial), per_trial
    # Agreement, kappa and the costliest error stay on the per-trial lines.
    assert "  overall agreement: 3/6 = 50.0%" in per_trial
    assert any(line.startswith("  Cohen's kappa: ") for line in per_trial)
    assert ("  costliest error (check in where the owner said let it go): 3 trial(s)"
            in per_trial), per_trial


REFUSAL = "that_date_is_too_close_for_fermix_to"


def test_a_refused_note_is_counted_apart_and_named_on_its_miss(tmp_path):
    path = _results(tmp_path, {
        "s01": [("let_go", "check_in", 1, "ok", REFUSAL)] * 2 + [("check_in", "check_in")],
        "s08": [("let_go", "check_in", 1, "ok", REFUSAL)] * 3,
        "s03": [("let_go", "let_go", 1, "ok", REFUSAL), ("let_go", "let_go")],
        "s28": [("let_go", "when_around")] * 2,
    })
    text = "\n".join(agree.report(agree.load_run(path)))
    assert ("trials where code refused an open_loop_note call: 6, 5 of them disagreeing "
            "with the owner (a code limit, not a judgment miss)") in text
    assert (f"  s08: owner check_in · Fermix let_go (refused: {REFUSAL}), "
            f"let_go (refused: {REFUSAL}), let_go (refused: {REFUSAL})") in text
    # A miss with no refusal reads as the model's own judgment.
    assert "  s28: owner when_around · Fermix let_go, let_go" in text
    assert "not recorded" not in text


def test_an_unrecorded_note_result_is_counted_as_unknown_not_as_a_refusal(tmp_path):
    path = _results(tmp_path, {"s01": [("let_go", "check_in", 1, "ok", "unread")] * 3})
    text = "\n".join(agree.report(agree.load_run(path)))
    assert "trials where code refused an open_loop_note call: 0, 0 of them" in text
    assert "result was not recorded: 3 (refusal unknown" in text
    assert "  s01: owner check_in · Fermix let_go (refused: unread)" in text


def test_the_confusion_table_rows_are_the_owner_and_columns_fermix(tmp_path):
    path = _results(tmp_path, {"s01": [("when_around", "check_in")] * 3,
                               "s03": [("let_go", "let_go")] * 3})
    lines = agree.report(agree.load_run(path))
    start = next(i for i, line in enumerate(lines) if line.strip().startswith("confusion"))
    header, rows = lines[start + 1].split(), [line.split() for line in lines[start + 2:start + 5]]
    assert header == ["let_go", "when_around", "check_in", "other", "split"]
    assert rows[0] == ["let_go", "1", "0", "0", "0", "0"]
    assert rows[2] == ["check_in", "0", "1", "0", "0", "0"]


def test_a_stage_0_run_is_read_as_keep_or_let_go(tmp_path):
    path = _results(tmp_path, {
        "s01": [("keep", "check_in", 0)] * 3,
        "s03": [("keep", "let_go", 0)] * 3,
        "s28": [("keep", "when_around", 0)] * 3,
    })
    run = agree.load_run(path)
    assert run.stage == 0
    text = "\n".join(agree.report(run))
    assert "stage 0 (keep or let go only; no reach column)" in text
    assert "overall agreement: 2/3 = 66.7%" in text
    assert "per label: let_go 0/1 = 0.0% · keep 2/2 = 100.0%" in text
    assert "costliest error, upper bound (kept where the owner said let it go" in text


def test_a_constraint_failure_is_counted_on_its_own_line(tmp_path):
    path = _results(tmp_path, {"s01": [("check_in", "check_in", 1, "constraint_fail"),
                                       ("check_in", "check_in")]})
    text = "\n".join(agree.report(agree.load_run(path)))
    assert "failed the declared constraint (schedule_job ban): 1" in text


def test_a_paired_comparison_counts_regressions_and_improvements(tmp_path):
    before = _results(tmp_path, {"s01": [("check_in", "check_in")] * 3,
                                 "s03": [("check_in", "let_go")] * 3,
                                 "s28": [("let_go", "when_around")] * 3},
                      name="before.json")
    after = _results(tmp_path, {"s01": [("let_go", "check_in")] * 3,
                                "s03": [("let_go", "let_go")] * 3,
                                "s28": [("when_around", "when_around")] * 3},
                     name="after.json")
    text = "\n".join(agree.compare(agree.load_run(after), agree.load_run(before)))
    assert "on 3 moment(s), full labels" in text
    assert "regressed 1 (s01) · improved 2 (s03, s28)" in text
    assert "exact McNemar p = 1.000" in text
    assert "baseline 1 → this run 0 moment(s)" in text


def test_a_comparison_with_a_stage_0_run_collapses_both_and_skips_relabelled(tmp_path):
    before = _results(tmp_path, {"s01": [("keep", "check_in", 0)] * 3,
                                 "s03": [("keep", "let_go", 0)] * 3},
                      name="before.json")
    after = _results(tmp_path, {"s01": [("when_around", "check_in")] * 3,
                                "s03": [("let_go", "when_around")] * 3},
                     name="after.json")
    text = "\n".join(agree.compare(agree.load_run(after), agree.load_run(before)))
    assert "keep or let go (a run is stage 0)" in text
    assert "relabelled between the runs: s03" in text
    assert "on 1 moment(s)" in text and "regressed 0 · improved 0" in text


@pytest.mark.parametrize("tasks, defect", [
    ({"cap_open_loop_judgment/s01": {"mean_success": 1.0}}, "no trial_records"),
    ({"cap_other/s01": {"trial_records": []}}, "no cap_open_loop_judgment task"),
    ({"cap_open_loop_judgment/s01": {"trial_records": [
        {"valid": True, "status": "ok", "detail": "score 1"}]}}, "not open_loop_judgment"),
    ({"cap_open_loop_judgment/s01": {"trial_records": [
        {"valid": True, "status": "ok", "detail": _detail("keep", "check_in", 1)}]}},
     "not open_loop_judgment"),
    ({"cap_open_loop_judgment/s01": {"trial_records": [            # no refusal tokens
        {"valid": True, "status": "ok",
         "detail": _detail("let_go", "let_go").replace(" refused=none noted=0", "")}]}},
     "not open_loop_judgment"),
    ({"cap_open_loop_judgment/s01": {"trial_records": [
        {"valid": True, "status": "ok", "detail": _detail("let_go", "let_go", 0)}]},
      "cap_open_loop_judgment/s03": {"trial_records": [
          {"valid": True, "status": "ok", "detail": _detail("let_go", "let_go", 1)}]}},
     "both stage 0 and stage 1"),
])
def test_a_run_this_script_cannot_read_is_refused(tmp_path, tasks, defect):
    path = _write(tmp_path, "results.json", {"tasks": tasks})
    with pytest.raises(agree.InputError, match=defect):
        agree.load_run(path)
    assert agree.main([path]) == 2


def test_main_prints_a_report(tmp_path, capsys):
    path = _results(tmp_path, {"s01": [("check_in", "check_in")] * 3})
    assert agree.main([path]) == 0
    assert "overall agreement: 1/1 = 100.0%" in capsys.readouterr().out


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
