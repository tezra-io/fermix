#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7"]
# ///
"""Tests for bin/tier_exit_code.sh — which tier step's exit code the eval-box
job publishes — and for the workflow wiring that feeds it.

The script is pure argv-in / code-out: no daemon, no network, no spend, and the
environment is built here rather than inherited. The last group parses
`.github/workflows/eval-box.yml`, because the defect these tests exist for lived
in the workflow and not in any script: the job output was a `||` chain over the
tier steps' outputs, `||` yields the first TRUTHY operand, and the string "0" is
truthy — so in a capability run the green deterministic axis published "0" and
the judged axis's 5 (release gate RED) never left the job. The callers then
classified a recorded, explained result as a plain failure.

Run: `uv run bin/test_tier_exit_code.py`."""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys

import pytest
import yaml

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "tier_exit_code.sh"
BENCH = HERE.parent
WORKFLOW = BENCH.parent / ".github" / "workflows" / "eval-box.yml"

# Nothing the script reads may come from the ambient environment: it takes its
# whole input on the command line, and these tests prove that by giving it only
# a PATH to find bash's own utilities.
ENV = {"PATH": os.environ.get("PATH", "")}

# The four tier steps, in the order eval-box.yml runs them. `<outcome>:<code>`
# per step, exactly as the workflow renders it.
NOT_RUN = "skipped:"


def select(*args):
    return subprocess.run([str(SCRIPT), *args], env=ENV, capture_output=True,
                          text=True, timeout=10)


def selected(*args):
    """The published code for one set of step results."""
    p = select(*args)
    assert p.returncode == 0, p.stderr
    return p.stdout.strip()


# --- what the job publishes -------------------------------------------------

def test_a_red_judged_axis_survives_a_green_deterministic_axis():
    # The regression under repair: both capability steps run, the deterministic
    # axis is green and the judged axis exits 5 (valid, recorded, release gate
    # RED). Publishing "0" here told the callers a red gate was a pass.
    assert selected("capability_deterministic=success:0",
                    "capability_judged=failure:5") == "5"


def test_a_lone_failing_step_publishes_its_own_code():
    # The regression tier: one step ran, the others never existed.
    assert selected("regression=failure:1",
                    f"capability_deterministic={NOT_RUN}",
                    f"capability_judged={NOT_RUN}", f"dangerous={NOT_RUN}") == "1"


def test_every_step_that_ran_green_publishes_zero():
    assert selected(f"regression={NOT_RUN}", "capability_deterministic=success:0",
                    "capability_judged=success:0", f"dangerous={NOT_RUN}") == "0"
    assert selected("regression=success:0") == "0"


@pytest.mark.parametrize("code", ["1", "2", "3", "4", "5"])
def test_each_runner_code_is_published_unchanged(code):
    # Every code carries its own meaning (2 refused selection, 3 preconditions,
    # 4 measurement invalid, 5 release gate red). None may be collapsed or
    # remapped on the way out.
    assert selected(f"capability_deterministic=failure:{code}") == code


# --- precedence -------------------------------------------------------------

def test_the_first_failing_step_in_run_order_decides():
    # Both axes red: 4 (no valid measurement) came first and is what the run
    # hit first, so it decides. 4 and 5 are different kinds, not degrees.
    assert selected("capability_deterministic=failure:4",
                    "capability_judged=failure:5") == "4"


def test_precedence_follows_the_order_given_not_the_size_of_the_code():
    # Same two codes, steps listed in the other order: the answer changes,
    # which proves the rule is run order and not a ranking of the codes.
    assert selected("capability_judged=failure:5",
                    "capability_deterministic=failure:4") == "5"


def test_the_code_that_lost_stays_in_the_log():
    p = select("capability_deterministic=failure:4", "capability_judged=failure:5")
    assert p.returncode == 0, p.stderr
    assert "capability_deterministic=failure:4" in p.stderr
    assert "capability_judged=failure:5" in p.stderr


def test_a_green_step_before_a_red_one_does_not_decide():
    assert selected("capability_deterministic=success:0",
                    "capability_judged=failure:4") == "4"


def test_a_later_codeless_failure_does_not_erase_the_deciding_code():
    # The deciding step published 4; a second axis that died before its runner
    # did adds nothing, and must not take 4 away from the callers.
    assert selected("capability_deterministic=failure:4",
                    "capability_judged=failure:") == "4"


# --- absence of evidence ----------------------------------------------------

def test_no_step_ran_is_refused_rather_than_called_green():
    # Nothing ran at all. That is the absence of a measurement, and it must
    # never leave the job as "0".
    p = select(f"regression={NOT_RUN}", f"capability_deterministic={NOT_RUN}",
               f"capability_judged={NOT_RUN}", f"dangerous={NOT_RUN}")
    assert p.returncode == 3
    assert p.stdout == ""
    assert "no tier step ran" in p.stderr


def test_a_step_that_failed_before_publishing_is_not_spoken_for_by_a_later_one():
    # The deterministic axis died in `make check`, so it published nothing; the
    # judged axis still ran and exited 5, which is its EXPECTED code today.
    # Publishing that 5 would tell the humans "the sweep was valid and
    # recorded" about a sweep that never happened.
    p = select("capability_deterministic=failure:", "capability_judged=failure:5")
    assert p.returncode == 3
    assert p.stdout == ""
    assert "capability_deterministic" in p.stderr
    assert "before publishing" in p.stderr


def test_a_lone_step_that_failed_before_publishing_publishes_nothing():
    p = select("dangerous=failure:")
    assert p.returncode == 3
    assert p.stdout == ""


# --- contradictions ---------------------------------------------------------

def test_a_step_that_succeeded_without_publishing_is_a_wiring_bug():
    p = select("regression=success:")
    assert p.returncode == 2
    assert "regression" in p.stderr
    assert p.stdout == ""


def test_a_step_that_succeeded_with_a_red_code_is_refused():
    p = select("regression=success:5")
    assert p.returncode == 2
    assert p.stdout == ""


def test_a_step_that_failed_with_a_green_code_is_refused():
    p = select("regression=failure:0")
    assert p.returncode == 2
    assert p.stdout == ""


@pytest.mark.parametrize("outcome", ["skipped", "cancelled", ""])
def test_a_step_that_did_not_run_cannot_carry_a_code(outcome):
    p = select(f"capability_judged={outcome}:5")
    assert p.returncode == 2
    assert "capability_judged" in p.stderr
    assert p.stdout == ""


@pytest.mark.parametrize("absent", ["skipped:", "cancelled:", ":"])
def test_every_shape_of_did_not_run_reads_the_same(absent):
    # A step the run never reached renders as `skipped`, and an empty outcome
    # if the steps context omits it entirely. Neither is evidence, so neither
    # may decide the run or keep a later failure from deciding it.
    assert selected(f"regression={absent}", "capability_deterministic=failure:1") == "1"
    p = select(f"regression={absent}")
    assert p.returncode == 3
    assert p.stdout == ""


def test_an_unknown_outcome_word_is_refused():
    p = select("capability_judged=green:0")
    assert p.returncode == 2
    assert "green" in p.stderr
    assert p.stdout == ""


# --- refusals ---------------------------------------------------------------

def test_no_arguments_exits_2_with_a_usage_line():
    p = select()
    assert p.returncode == 2
    assert "usage:" in p.stderr
    assert p.stdout == ""


def test_an_argument_without_a_step_name_is_refused():
    p = select("=failure:5")
    assert p.returncode == 2
    assert p.stdout == ""


def test_an_argument_that_is_not_a_pair_is_refused():
    p = select("capability_judged")
    assert p.returncode == 2
    assert "capability_judged" in p.stderr
    assert p.stdout == ""


def test_an_argument_without_an_outcome_is_refused():
    # `<step>=<code>` was the earlier grammar; it must not be read as an
    # outcome-less code, because then a step that never ran and a step that
    # died before publishing would look the same again.
    p = select("capability_judged=5")
    assert p.returncode == 2
    assert "capability_judged" in p.stderr
    assert p.stdout == ""


@pytest.mark.parametrize("code", ["red", "5 ", "-1", "0x5", "256", "1000"])
def test_an_uninterpretable_code_is_refused_rather_than_guessed(code):
    p = select(f"capability_judged=failure:{code}")
    assert p.returncode == 2
    assert "capability_judged" in p.stderr
    assert p.stdout == ""


@pytest.mark.parametrize("code", ["05", "00", "007"])
def test_a_padded_code_is_refused_because_the_callers_compare_strings(code):
    # eval-weekly/eval-nightly test `exit === "5"`; "05" would be classified as
    # a plain failure, which is the mislabel this script exists to prevent.
    p = select(f"capability_judged=failure:{code}")
    assert p.returncode == 2
    assert p.stdout == ""


@pytest.mark.parametrize("step", ["capability judged", "capability.judged", "$step"])
def test_a_name_that_is_not_a_step_id_is_refused(step):
    # A mangled name would also slip past the named-twice check, which matches
    # on a space-separated list of the names already seen.
    p = select(f"{step}=failure:5")
    assert p.returncode == 2
    assert "not a step id" in p.stderr
    assert p.stdout == ""


def test_the_same_step_twice_is_a_wiring_bug_and_is_refused():
    p = select("capability_judged=success:0", "capability_judged=failure:5")
    assert p.returncode == 2
    assert "capability_judged" in p.stderr
    assert p.stdout == ""


# --- the workflow wiring ----------------------------------------------------
# The expression this script replaced was untestable, which is how it stayed
# wrong. These read the workflow itself so it cannot rot back into one.

@pytest.fixture(scope="module")
def box_job():
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["box"]


@pytest.fixture(scope="module")
def publishing_step(box_job):
    """The one step that calls the script."""
    steps = [s for s in box_job["steps"] if SCRIPT.name in s.get("run", "")]
    assert len(steps) == 1, f"expected exactly one caller of {SCRIPT.name}, got {steps}"
    return steps[0]


def test_the_workflow_decides_the_exit_code_with_this_script(publishing_step):
    assert publishing_step.get("id"), "the calling step needs an id to publish from"


def test_the_job_output_is_the_scripts_answer_and_nothing_else(box_job, publishing_step):
    value = " ".join(str(box_job["outputs"]["exit_code"]).split())
    assert value == "${{ steps.%s.outputs.exit_code }}" % publishing_step["id"]
    # A `||` chain is the defect itself: "0" is truthy, so the first step that
    # ran would mask every later one again.
    assert "||" not in value


def test_every_step_that_publishes_a_code_is_handed_to_the_script(box_job, publishing_step):
    # Derived from the workflow, not from a list kept by hand: a fifth tier step
    # added later is covered the day it lands.
    publishers = [s for s in box_job["steps"]
                  if s is not publishing_step
                  and "exit_code=" in s.get("run", "")
                  and "GITHUB_OUTPUT" in s.get("run", "")]
    assert len(publishers) >= 4, "expected the four tier steps to publish a code"
    wiring = " ".join(publishing_step["env"].values())
    for step in publishers:
        step_id = step["id"]
        assert "steps.%s.outputs.exit_code" % step_id in wiring, \
            f"{step_id} publishes a code the deciding step never reads"
        # Its outcome too: a step that died before publishing must not read as
        # one that never ran.
        assert "steps.%s.outcome" % step_id in wiring, \
            f"{step_id}'s outcome never reaches the deciding step"
        assert "%s=" % step_id in publishing_step["run"], \
            f"{step_id} is not named in the call, so its result arrives anonymous"

    # ...and in the order they run. The script's rule is "the FIRST step that
    # failed decides", so alphabetizing the arguments would make a capability
    # run with deterministic=4 and judged=5 publish 5 — a valid, recorded sweep
    # reported for a run that had no valid measurement.
    call = publishing_step["run"]
    positions = [call.index("%s=" % s["id"]) for s in publishers]
    assert positions == sorted(positions), (
        "the deciding step lists the tier steps out of run order, so the first "
        "failure no longer decides: "
        + ", ".join(s["id"] for s in publishers))


def test_the_deciding_step_still_runs_after_a_tier_step_failed(publishing_step):
    # Its whole job is to report a failing tier's code; an `if:` without a
    # status function implicitly ANDs success() and would skip exactly then.
    condition = str(publishing_step["if"])
    assert "!cancelled()" in condition or "always()" in condition


def run_the_publishing_step(publishing_step, tmp_path, results):
    """Execute the workflow step's own shell with each tier step's result, the
    way the runner would, and return (status, stderr, what it published)."""
    # The env var names come from the step, so renaming one cannot slip past.
    env = {"PATH": os.environ.get("PATH", ""),
           "GITHUB_OUTPUT": str(tmp_path / "github_output")}
    for name, expression in publishing_step["env"].items():
        step_id = expression.split("steps.", 1)[1].split(".", 1)[0]
        env[name] = results[step_id]
    Path(env["GITHUB_OUTPUT"]).write_text("")
    # The step calls `bin/tier_exit_code.sh` relatively, so its
    # `working-directory:` is part of the wiring under test — take the cwd from
    # the step rather than hardcoding the one that happens to work.
    cwd = BENCH.parent / publishing_step["working-directory"]
    p = subprocess.run(["bash", "-c", publishing_step["run"]], cwd=str(cwd),
                       env=env, capture_output=True, text=True, timeout=10)
    return p.returncode, p.stderr, Path(env["GITHUB_OUTPUT"]).read_text()


def test_the_step_publishes_the_red_judged_axis_of_a_capability_run(publishing_step, tmp_path):
    # End to end through the workflow's own shell: the run that filed the wrong
    # issue (deterministic green, judged 5) now leaves the job carrying 5.
    status, _stderr, published = run_the_publishing_step(
        publishing_step, tmp_path,
        {"regression": NOT_RUN, "capability_deterministic": "success:0",
         "capability_judged": "failure:5", "dangerous": NOT_RUN})
    assert status == 0
    assert published.strip() == "exit_code=5"


def test_the_step_publishes_nothing_when_no_tier_step_ran(publishing_step, tmp_path):
    # A tier that never started: the step fails loudly and the job output stays
    # empty — "failed with no code", not "passed".
    status, stderr, published = run_the_publishing_step(
        publishing_step, tmp_path,
        {"regression": NOT_RUN, "capability_deterministic": NOT_RUN,
         "capability_judged": NOT_RUN, "dangerous": NOT_RUN})
    assert status != 0
    assert "no tier step ran" in stderr
    assert published == ""


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
