#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7"]
# ///
"""Specs for configuration arms: what the arms file must say, the three commands
an arm runs, teardown on every path, the comparison against the control, and the
seeder's `--extra-config` refusals. Every arm is executed through an INJECTED
runner that records commands and writes fake results — no daemon is started, no
provider is called, nothing is seeded.
Run: `uv run bin/test_arms.py`."""
from __future__ import annotations

import json
import os
import sys

import pytest
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import run_arms  # noqa: E402
import seed_capability_home as seed  # noqa: E402
from evallib import uplift  # noqa: E402

_ARMS_DOC = {
    "title": "Two models",
    "suites": ["cap_browser_corpus"],
    "trials": 3,
    "arms": [{"name": "control"}, {"name": "alternative",
                                   "seed_args": ["--provider", "openai",
                                                 "--model", "gpt-5.6-sol"]}],
}


def _write_arms(tmp_path, doc=None, name="two.yaml") -> str:
    path = os.path.join(str(tmp_path), name)
    with open(path, "w", encoding="utf-8") as handle:
        yaml.safe_dump(doc if doc is not None else _ARMS_DOC, handle)
    return path


def _plan(tmp_path, doc=None) -> run_arms.Plan:
    return run_arms.load_plan(_write_arms(tmp_path, doc), os.path.join(str(tmp_path), "out"))


def _problems(tmp_path, doc) -> list[str]:
    with pytest.raises(run_arms.PlanError) as exc:
        _plan(tmp_path, doc)
    return exc.value.problems


def _results(tasks: dict, *, trials: int = 3, valid: bool = True) -> dict:
    return {"arm": "fermix", "config_id": "x", "suite": "cap_browser_corpus",
            "k": trials, "threshold": 1.0, "valid": valid,
            "tasks": {task: {"mean_success": score, "pass_hat_k": score, "n": trials,
                             "durations_ms": [1000.0, 2000.0, 9000.0],
                             "mean_main_llm_calls": 4.0}
                      for task, score in tasks.items()}}


# --- the arms file ----------------------------------------------------------

def test_a_valid_arms_file_plans_two_arms(tmp_path):
    plan = _plan(tmp_path)
    assert [arm.name for arm in plan.arms] == ["control", "alternative"]
    assert plan.control.name == "control"
    assert plan.trials == 3 and plan.suites == ("cap_browser_corpus",)


def test_each_arm_gets_its_own_home_and_project(tmp_path):
    plan = _plan(tmp_path)
    homes = {arm.home for arm in plan.arms}
    projects = {arm.project for arm in plan.arms}
    assert len(homes) == len(projects) == 2
    for arm in plan.arms:
        # Every runner and the seeder refuse a home whose leaf does not carry
        # 'eval', and refuse the dev/production homes outright.
        assert "eval" in os.path.basename(arm.home)
        assert arm.home not in (os.path.expanduser("~/.fermix"),
                                os.path.expanduser("~/.fermix-dev"))
        assert "eval" in arm.project


def test_one_arm_is_not_a_comparison(tmp_path):
    problems = _problems(tmp_path, {**_ARMS_DOC, "arms": [{"name": "only"}]})
    assert any("at least 2" in problem for problem in problems), problems


def test_a_duplicate_arm_name_is_refused(tmp_path):
    problems = _problems(tmp_path, {**_ARMS_DOC,
                                    "arms": [{"name": "a"}, {"name": "a"}]})
    assert any("duplicate" in problem for problem in problems), problems


def test_an_unusable_arm_name_is_refused(tmp_path):
    problems = _problems(tmp_path, {**_ARMS_DOC,
                                    "arms": [{"name": "Control Arm"}, {"name": "b"}]})
    assert any("name" in problem for problem in problems), problems


def test_seed_args_with_whitespace_are_refused(tmp_path):
    # FERMIX_CAP_SEED_ARGS is whitespace-split by capability-daemon.sh, so an
    # argument with a space would silently become two.
    problems = _problems(tmp_path, {**_ARMS_DOC, "arms": [
        {"name": "a"}, {"name": "b", "seed_args": ["--model", "gpt 5"]}]})
    assert any("whitespace-free" in problem for problem in problems), problems


def test_a_missing_extra_config_is_refused(tmp_path):
    problems = _problems(tmp_path, {**_ARMS_DOC, "arms": [
        {"name": "a"}, {"name": "b", "extra_config": "nope.toml"}]})
    assert any("not found" in problem for problem in problems), problems


def test_an_unknown_key_is_refused(tmp_path):
    problems = _problems(tmp_path, {**_ARMS_DOC, "runs": 3})
    assert any("unknown top-level key" in problem for problem in problems), problems


def test_an_empty_suite_list_is_refused(tmp_path):
    problems = _problems(tmp_path, {**_ARMS_DOC, "suites": []})
    assert any("suites" in problem for problem in problems), problems


def test_the_shipped_example_arms_file_is_valid(tmp_path):
    example = os.path.join(os.path.dirname(HERE), "arms", "model_choice.example.yaml")
    plan = run_arms.load_plan(example, str(tmp_path))
    assert plan.control.name == "control" and len(plan.arms) == 2


# --- the commands an arm runs -----------------------------------------------

def test_an_arm_seeds_scores_and_tears_down(tmp_path):
    plan = _plan(tmp_path)
    up, score, down = run_arms.arm_steps(plan, plan.arms[1])
    assert [step.label for step in (up, score, down)] == ["up", "score", "down"]
    assert up.argv[1] == "up" and down.argv[1] == "down"
    assert up.env["FERMIX_CAP_HOME"] == plan.arms[1].home
    assert up.env["FERMIX_CAP_PROJECT"] == plan.arms[1].project
    assert up.env["FERMIX_CAP_SEED_ARGS"] == "--provider openai --model gpt-5.6-sol"
    assert score.env == {"FERMIX_EVAL_HOME": plan.arms[1].home,
                         "OPIK_PROJECT": plan.arms[1].project}
    assert "--results-out" in score.argv
    assert score.argv[score.argv.index("--results-out") + 1] == plan.arms[1].results_path
    assert "--suite" in score.argv and "cap_browser_corpus" in score.argv
    assert "--trials" in score.argv and "3" in score.argv
    # The corpus is parked under candidates/ so it cannot join the ranking
    # sweep; an arms run names its suites, so it loads that pool explicitly.
    assert "--candidates" in score.argv
    for attestation in ("--confirm-daemon-isolated", "--confirm-isolated-env"):
        assert attestation in score.argv


def test_an_extra_config_reaches_the_seeder(tmp_path):
    fragment = os.path.join(str(tmp_path), "arm.toml")
    with open(fragment, "w", encoding="utf-8") as handle:
        handle.write("[fermix_core.browser]\nallowed_hosts = []\n")
    plan = _plan(tmp_path, {**_ARMS_DOC, "arms": [
        {"name": "a"}, {"name": "b", "extra_config": "arm.toml"}]})
    up, _score, _down = run_arms.arm_steps(plan, plan.arms[1])
    assert up.env["FERMIX_CAP_SEED_ARGS"].split() == ["--extra-config", fragment]


class _Recorder:
    """A fake for the ONE function that touches the machine."""

    def __init__(self, codes=None, results=None):
        self.codes = codes or {}
        self.results = results
        self.labels: list[str] = []

    def __call__(self, step: run_arms.Step) -> int:
        self.labels.append(step.label)
        code = self.codes.get(step.label, 0)
        # The real runner writes --results-out for a valid measurement, whether
        # the release gate ends green (0) or red (5).
        if (step.label == "score" and code in run_arms.MEASURED_EXITS
                and self.results is not None):
            path = step.argv[step.argv.index("--results-out") + 1]
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(self.results, handle)
        return code


def test_a_successful_arm_reads_back_its_results(tmp_path):
    plan = _plan(tmp_path)
    runner = _Recorder(results=_results({"cap/one": 1.0}))
    run = run_arms.execute_arm(plan, plan.arms[0], runner)
    assert runner.labels == ["up", "score", "down"]
    assert run.error is None and run.results["tasks"]["cap/one"]["mean_success"] == 1.0


def test_a_daemon_that_never_came_up_still_tears_down(tmp_path):
    plan = _plan(tmp_path)
    runner = _Recorder(codes={"up": 1})
    run = run_arms.execute_arm(plan, plan.arms[0], runner)
    # A daemon left running would answer for the NEXT arm's home probe and score
    # that configuration against this one's process.
    assert runner.labels == ["up", "down"]
    assert run.results is None and "did not come up" in run.error


def test_a_red_release_gate_is_still_a_measurement(tmp_path):
    """Exit 5 is "valid measurement, recorded, release gate RED" — which every
    shipped capability suite produces BY DESIGN, none of them declaring a safety
    gate. Reading it as a failed arm discarded every arm and made a comparison
    impossible."""
    plan = _plan(tmp_path)
    runner = _Recorder(codes={"score": 5}, results=_results({"cap/one": 1.0}))
    run = run_arms.execute_arm(plan, plan.arms[0], runner)
    assert runner.labels == ["up", "score", "down"]
    assert run.error is None
    assert run.results["tasks"]["cap/one"]["mean_success"] == 1.0


def test_an_invalid_sweep_tears_down_and_records_the_exit_code(tmp_path):
    # 4 is the INVALID exit: the runner writes no --results-out for it at all.
    plan = _plan(tmp_path)
    runner = _Recorder(codes={"score": 4})
    run = run_arms.execute_arm(plan, plan.arms[0], runner)
    assert runner.labels == ["up", "score", "down"]
    assert run.results is None and "exited 4" in run.error


def test_a_refused_selection_is_not_a_measurement(tmp_path):
    plan = _plan(tmp_path)
    run = run_arms.execute_arm(plan, plan.arms[0], _Recorder(codes={"score": 2}))
    assert run.results is None and "exited 2" in run.error


def test_a_sweep_that_wrote_nothing_is_not_a_measurement(tmp_path):
    plan = _plan(tmp_path)
    run = run_arms.execute_arm(plan, plan.arms[0], _Recorder())
    assert run.results is None and "wrote no results" in run.error


def test_a_scored_exit_that_wrote_nothing_is_refused(tmp_path):
    # Exit 5 without the file: the sweep says it recorded a measurement and this
    # arm has none, which is never pairable.
    plan = _plan(tmp_path)
    run = run_arms.execute_arm(plan, plan.arms[0], _Recorder(codes={"score": 5}))
    assert run.results is None and "wrote no results" in run.error


def test_an_arm_whose_results_say_invalid_is_refused(tmp_path):
    # `valid` travels with the numbers; an arm that measured nothing cannot be
    # paired even when the process exited cleanly.
    plan = _plan(tmp_path)
    runner = _Recorder(results=_results({"cap/one": 1.0}, valid=False))
    run = run_arms.execute_arm(plan, plan.arms[0], runner)
    assert run.results is None and "INVALID" in run.error


# --- comparison + report ----------------------------------------------------

def _run(plan, index: int, results) -> run_arms.ArmRun:
    return run_arms.ArmRun(arm=plan.arms[index], results=results)


def test_the_control_is_not_compared_with_itself(tmp_path):
    plan = _plan(tmp_path)
    tasks = {"cap/one": 1.0, "cap/two": 0.0}
    rows = run_arms.compare_runs(plan, [_run(plan, 0, _results(tasks)),
                                        _run(plan, 1, _results(tasks))])
    assert rows[0].uplift is None and not rows[0].problems
    assert rows[1].uplift is not None and rows[1].uplift.n == 2


def test_an_arm_that_ran_other_tasks_is_refused_rather_than_intersected(tmp_path):
    plan = _plan(tmp_path)
    rows = run_arms.compare_runs(plan, [
        _run(plan, 0, _results({"cap/one": 1.0, "cap/two": 1.0})),
        _run(plan, 1, _results({"cap/one": 1.0}))])
    assert rows[1].uplift is None
    assert any("task sets differ" in problem for problem in rows[1].problems)


def test_an_invalid_arm_is_refused(tmp_path):
    plan = _plan(tmp_path)
    rows = run_arms.compare_runs(plan, [
        _run(plan, 0, _results({"cap/one": 1.0})),
        _run(plan, 1, _results({"cap/one": 1.0}, valid=False))])
    assert rows[1].uplift is None
    assert any("INVALID" in problem for problem in rows[1].problems)


def test_a_row_carries_success_latency_and_turn_economy(tmp_path):
    plan = _plan(tmp_path)
    rows = run_arms.compare_runs(plan, [_run(plan, 0, _results({"cap/one": 1.0,
                                                               "cap/two": 0.0}))])
    row = rows[0]
    assert row.success == 0.5
    # Pooled over trials, nearest rank: six samples of 1000/2000/9000.
    assert row.p50_ms == 2000.0 and row.p95_ms == 9000.0
    assert row.main_llm_calls == 4.0


def test_an_arm_without_the_optional_columns_reports_them_as_unrecorded(tmp_path):
    plan = _plan(tmp_path)
    bare = _results({"cap/one": 1.0})
    for task in bare["tasks"].values():
        task.pop("durations_ms")
        task.pop("mean_main_llm_calls")
    rows = run_arms.compare_runs(plan, [_run(plan, 0, bare)])
    assert rows[0].p50_ms is None and rows[0].main_llm_calls is None
    assert uplift.pooled_durations_ms(bare) == []
    assert uplift.mean_main_llm_calls(bare) is None


def test_the_report_names_every_arm_and_its_refusals(tmp_path):
    plan = _plan(tmp_path)
    rows = run_arms.compare_runs(plan, [
        _run(plan, 0, _results({"cap/one": 1.0})),
        _run(plan, 1, None)])
    rows[1].problems = ["this arm produced no measurement"]
    report = run_arms.render_report(plan, rows)
    assert "`control`" in report and "`alternative`" in report
    assert "is not comparable" in report
    assert "p50 ms" in report and "main-model calls/task" in report


def test_percentile_is_nearest_rank_and_none_on_no_samples():
    assert run_arms.percentile([], 95) is None
    assert run_arms.percentile([5.0], 95) == 5.0
    assert run_arms.percentile([1.0, 2.0, 3.0, 4.0], 50) == 2.0


def test_dry_run_plans_every_command_and_starts_nothing(tmp_path, capsys):
    path = _write_arms(tmp_path)
    assert run_arms.main(["--arms", path, "--out", str(tmp_path), "--dry-run"]) == 0
    printed = capsys.readouterr().out
    assert "capability-daemon.sh up" in printed and "run_capability.py" in printed
    assert "nothing was started" in printed
    assert not os.path.exists(os.path.join(str(tmp_path), "arms.md"))


def test_an_invalid_arms_file_exits_usage(tmp_path, capsys):
    path = _write_arms(tmp_path, {**_ARMS_DOC, "arms": [{"name": "only"}]})
    assert run_arms.main(["--arms", path, "--out", str(tmp_path)]) == 2
    assert "arms file invalid" in capsys.readouterr().err


# --- the seeder's --extra-config -------------------------------------------

def _seeded() -> str:
    return seed.render_config("/tmp/x-eval", "openai", {"default_model": "m"}, None)


def test_table_headers_lists_what_a_document_writes():
    headers = seed.table_headers(_seeded())
    assert "sandbox" in headers and "fermix_core.harness" in headers
    assert "fermix_core.providers.openai" in headers


def test_a_fragment_the_seeder_does_not_own_is_accepted():
    assert seed.extra_config_error(
        _seeded(), '[fermix_core.browser]\nallowed_hosts = []\n') is None


def test_a_fragment_redefining_a_seeded_table_is_refused():
    problem = seed.extra_config_error(_seeded(), '[fermix_core.harness]\napproved = false\n')
    assert problem and "fermix_core.harness" in problem


def test_a_fragment_redefining_the_sandbox_is_refused():
    problem = seed.extra_config_error(_seeded(), '[sandbox]\nmode = "open"\n')
    assert problem and "sandbox" in problem


def test_a_fragment_with_a_bare_top_level_key_is_refused():
    # Appended after the seeder's last table, a bare key joins THAT table.
    problem = seed.extra_config_error(_seeded(), 'profile = "other"\n')
    assert problem and "table header" in problem


def test_an_invalid_toml_fragment_is_refused():
    problem = seed.extra_config_error(_seeded(), "[unclosed\n")
    assert problem and "not valid TOML" in problem


def test_an_accepted_fragment_keeps_the_merged_config_parseable(tmp_path):
    import tomllib
    fragment = '[fermix_core.browser]\nallowed_hosts = ["example.com"]\n'
    assert seed.extra_config_error(_seeded(), fragment) is None
    merged = tomllib.loads(_seeded() + "\n" + fragment)
    assert merged["fermix_core"]["browser"]["allowed_hosts"] == ["example.com"]
    assert merged["fermix_core"]["harness"]["approved"] is True


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
