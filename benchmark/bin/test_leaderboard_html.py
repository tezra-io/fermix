#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8"]
# ///
"""Specs for the HTML leaderboard: what it reads from a run directory, how it ranks,
and that time and cost sit beside the score without ever moving a rank."""

from __future__ import annotations

import json
import math
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from evallib import leaderboard_html as lh  # noqa: E402

HISTORY = "\n".join([
    "c" * 40 + "\t2026-09-20T10:00:00+00:00\tthird",
    "b" * 40 + "\t2026-08-01T10:00:00+00:00\tsecond",
    "a" * 40 + "\t2026-07-01T10:00:00+00:00\tfirst",
])


def _task(success=1.0, n=5, durations=None, cost=None, tokens=None):
    task = {"mean_success": success, "pass_hat_k": success, "n": n}
    if durations is not None:
        task["durations_ms"] = durations
    if cost is not None:
        task["priced_cost_usd"] = cost
    if tokens is not None:
        task["total_tokens"] = tokens
    return task


def _write_run(root: Path, run_id: str, config_id: str, tasks: dict, *, valid=True,
               run_json=None, report=None) -> None:
    run_dir = root / run_id
    run_dir.mkdir(parents=True)
    name = "results.invalid.json" if valid is False else "results.json"
    payload = {"arm": "fermix", "config_id": config_id, "suite": "cap_x", "k": 5,
               "threshold": 1.0, "tasks": tasks}
    if valid is not None:
        payload["valid"] = valid
    (run_dir / name).write_text(json.dumps(payload))
    if run_json is not None:
        (run_dir / "run.json").write_text(json.dumps(run_json))
    if report is not None:
        (run_dir / "report.md").write_text(report)


def _meta(run_id, selection="all", sha=None, tasks_hash="feedfacefeedface"):
    return {"run_id": run_id, "selection": selection, "tasks_hash": tasks_hash,
            "hash_version": 3, "k": 5, "threshold": 1.0, "judge": "off",
            "repo": {"sha": sha or "c" * 40, "dirty_digest": "clean"}}


def _score(success, pass_hat_k=None, cost=None, successes=10):
    return {"mean_task_success": success, "mean_pass_hat_k": pass_hat_k or success,
            "mean_pass_at_1": success, "priced_cost_usd": cost, "pricing_basis": "ceiling",
            "total_successes": successes, "safety_trials_evaluated": 0,
            "safety_violations": 0}


def _runs(root: Path) -> list[dict]:
    runs = lh.load_runs(str(root), {"rows": {}})
    lh.attach_commits(runs, lh.GitHistory.parse(HISTORY))
    return runs


def test_a_new_run_is_read_from_run_json_with_per_task_time_and_cost(tmp_path):
    run_id = "20260923T010000Z"
    _write_run(tmp_path, run_id, "openai/m/high",
               {"cap_x/a": _task(durations=[1000, 3000, 2000], cost=0.5, tokens=500)},
               run_json={"meta": _meta(run_id), "score": _score(1.0, cost=61.4),
                         "problems": []})
    run = _runs(tmp_path)[0]
    assert run["score"]["source"] == "recorded"
    assert run["score"]["cost_usd"] == 61.4
    task = run["tasks"][0]
    assert task["median_ms"] == 2000 and task["total_ms"] == 6000
    assert lh._per_trial(task) == pytest.approx(0.1)
    assert run["commit"] == {"sha": "c" * 40, "subject": "third", "date": "2026-09-20",
                             "inferred": False, "dirty": False}


def test_a_legacy_run_scores_from_its_results_and_infers_its_commit(tmp_path):
    _write_run(tmp_path, "20260705T120000Z", "openai/old/xhigh",
               {"cap_x/a": _task(1.0), "cap_x/b": _task(0.5)}, valid=None)
    run = _runs(tmp_path)[0]
    assert run["valid"] is True and run["valid_recorded"] is False
    assert run["score"]["source"] == "results"
    assert run["score"]["success"] == 0.75
    assert run["score"]["cost_usd"] is None
    assert run["tasks"][0]["median_ms"] is None             # never recorded, never zero
    assert run["commit"]["sha"] == "a" * 40 and run["commit"]["inferred"] is True


def test_an_invalid_run_keeps_its_reasons_from_the_report(tmp_path):
    report = ("# capability run 20260907T200000Z\n\n- config: `openai/m/medium`\n"
              "- repo: `9de25413c73d` (uncommitted diff: clean)\n\n"
              "## MEASUREMENT INVALID\n\nThis run is evidence about the harness.\n\n"
              "- cap_x/a trial 2: no usable evidence\n")
    _write_run(tmp_path, "20260907T200000Z", "openai/m/medium", {"cap_x/a": _task(0.0)},
               valid=False, report=report)
    run = _runs(tmp_path)[0]
    assert run["valid"] is False
    assert run["problems"] == ["cap_x/a trial 2: no usable evidence"]
    assert run["commit"]["sha"] == "9de25413c73d" and run["commit"]["subject"] is None


def test_the_board_ranks_on_shared_tasks_and_ties_share_a_rank(tmp_path):
    shared = {"cap_x/a": _task(1.0), "cap_x/b": _task(1.0)}
    _write_run(tmp_path, "20260901T000000Z", "openai/zeta/high",
               {**shared, "cap_x/only_here": _task(0.0)},
               run_json={"meta": _meta("20260901T000000Z"), "score": _score(0.66),
                         "problems": []})
    _write_run(tmp_path, "20260902T000000Z", "openai/alpha/high", shared,
               run_json={"meta": _meta("20260902T000000Z"), "score": _score(1.0),
                         "problems": []})
    _write_run(tmp_path, "20260903T000000Z", "openai/weak/high",
               {"cap_x/a": _task(1.0), "cap_x/b": _task(0.0)},
               run_json={"meta": _meta("20260903T000000Z"), "score": _score(0.5),
                         "problems": []})
    board = lh.leaderboard_view(_runs(tmp_path))
    assert board["shared"] == ["cap_x/a", "cap_x/b"]
    assert [(r["rank"], r["config_id"]) for r in board["rows"]] == [
        (1, "openai/alpha/high"), (1, "openai/zeta/high"), (3, "openai/weak/high")]
    assert board["saturated_tasks"] == ["cap_x/a"]


def test_cost_and_time_never_move_a_rank(tmp_path):
    for run_id, config, success, cost in (("20260901T000000Z", "openai/cheap/low", 0.5, 1.0),
                                          ("20260902T000000Z", "openai/dear/max", 1.0, 900.0)):
        _write_run(tmp_path, run_id, config, {"cap_x/a": _task(success, durations=[10.0])},
                   run_json={"meta": _meta(run_id), "score": _score(success, cost=cost),
                             "problems": []})
    rows = lh.leaderboard_view(_runs(tmp_path))["rows"]
    assert [r["config_id"] for r in rows] == ["openai/dear/max", "openai/cheap/low"]


def test_subset_runs_smoke_labels_and_soft_axes_stay_off_the_board(tmp_path):
    full = {"cap_x/a": _task(1.0)}
    _write_run(tmp_path, "20260901T000000Z", "openai/m/high", full,
               run_json={"meta": _meta("20260901T000000Z"), "score": _score(1.0),
                         "problems": []})
    _write_run(tmp_path, "20260902T000000Z", "openai/m/high", {"cap_x/b": _task(0.0)},
               run_json={"meta": _meta("20260902T000000Z", selection="suite:cap_x"),
                         "score": _score(0.0), "problems": []})
    _write_run(tmp_path, "20260903T000000Z", "cap-smoke", full, valid=None)
    _write_run(tmp_path, "20260904T000000Z", "openai/m/high:cap_response_quality", full,
               run_json={"meta": _meta("20260904T000000Z"), "score": _score(1.0),
                         "problems": []})
    board = lh.leaderboard_view(_runs(tmp_path))
    assert [(r["config_id"], r["run"]["run_id"]) for r in board["rows"]] == [
        ("openai/m/high", "20260901T000000Z")]


def test_cohorts_rank_only_a_pinned_task_set_with_two_models(tmp_path):
    tasks = {"cap_x/a": _task(1.0)}
    for run_id, config in (("20260901T000000Z", "openai/a/high"),
                           ("20260902T000000Z", "openai/b/high")):
        _write_run(tmp_path, run_id, config, tasks,
                   run_json={"meta": _meta(run_id), "score": _score(1.0), "problems": []})
    _write_run(tmp_path, "20260703T000000Z", "openai/legacy/high", tasks, valid=None)
    cohorts = lh.cohort_views(_runs(tmp_path))
    assert [(c["pinned"], c["ranked"], len(c["runs"])) for c in cohorts] == [
        (True, True, 2), (False, False, 1)]


def test_runs_group_by_commit_newest_first(tmp_path):
    for run_id in ("20260702T000000Z", "20260921T000000Z", "20260922T000000Z"):
        _write_run(tmp_path, run_id, "openai/m/high", {"cap_x/a": _task(1.0)}, valid=None)
    groups = lh.change_groups(_runs(tmp_path))
    assert [g["commit"]["subject"] for g in groups] == ["third", "first"]
    assert [r["run_id"] for r in groups[0]["runs"]] == ["20260922T000000Z",
                                                        "20260921T000000Z"]


def test_run_file_text_is_escaped_and_cannot_close_the_data_script(tmp_path):
    hostile = 'cap_x/<script>alert(1)</script>'
    _write_run(tmp_path, "20260901T000000Z", "openai/<b>m</b>/high", {hostile: _task(1.0)},
               valid=None)
    page = lh.render(_runs(tmp_path), datetime(2026, 10, 1, tzinfo=timezone.utc))
    assert "<script>alert(1)" not in page
    assert "<b>m</b>" not in page
    data = page.split('id="runs-data">', 1)[1].split("</script>", 1)[0]
    assert json.loads(data)[0]["tasks"][0]["id"] == hostile


def test_a_malformed_run_directory_is_named_in_the_error(tmp_path):
    _write_run(tmp_path, "20260901T000000Z", "openai/m/high", {"cap_x/a": {"n": 5}},
               valid=None)
    with pytest.raises(ValueError, match="unreadable run directory .*20260901T000000Z"):
        lh.load_runs(str(tmp_path), {"rows": {}})


def test_no_reports_directory_is_an_empty_board(tmp_path):
    assert lh.load_runs(str(tmp_path / "missing"), {"rows": {}}) == []


def test_a_board_with_no_full_sweep_says_so(tmp_path):
    page = lh.render([], datetime(2026, 10, 1, tzinfo=timezone.utc))
    assert "No valid full sweep on record yet." in page


def test_the_run_record_writes_inf_as_null(tmp_path):
    from evallib import aggregate
    stats = aggregate.aggregate_task(
        [aggregate.score_trial("c1", task_success=0.0, safety_ok=True, cost=0.0,
                               duration_ms=10.0, tokens=5, tool_calls=1, status="ok",
                               trace_id="tr")], k=1, threshold=1.0, family="f")
    score = aggregate.aggregate_config("openai/m/high", [stats])
    assert math.isinf(score.cost_per_success)
    lh.write_run_record(str(tmp_path), {"run_id": "x"}, score, [])
    record = json.loads((tmp_path / "run.json").read_text())
    assert record["score"]["cost_per_success"] is None
    assert record["problems"] == []


def test_git_history_finds_the_tip_at_a_time():
    history = lh.GitHistory.parse(HISTORY)
    assert history.at(datetime(2026, 6, 1, tzinfo=timezone.utc)) is None
    assert history.at(datetime(2026, 8, 15, tzinfo=timezone.utc))["subject"] == "second"
    assert history.describe("cccc")["subject"] == "third"
    assert history.describe("dddd") is None


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
