#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8"]
# ///
"""Tests for bin/tier.sh — the one definition of what each live eval tier runs.

Every assertion goes through `tier.sh --print`, which renders the argv the tier
would exec instead of execing it: no daemon, no network, no spend. The judge-key
resolution is exercised with EVAL_JUDGE_API_KEY exported, and with a stub
`security` first on PATH for the unset case, so no test ever reads the real
keychain. Run: `uv run bin/test_tier.py`."""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
TIER_SH = os.path.join(HERE, "tier.sh")
BENCH = os.path.dirname(HERE)

# Anything the script reads must be established by the test, never inherited.
CONTROLLED = ("EVAL_JUDGE_API_KEY", "CONFIRM_DAEMON_ISOLATED",
              "CONFIRM_ISOLATED_ENV", "CONFIRM_COST")


@pytest.fixture(scope="module")
def stub_path(tmp_path_factory):
    """A PATH prefix whose `security` answers nothing, like a missing keychain
    entry — the real keychain is never consulted by these tests."""
    d = tmp_path_factory.mktemp("stubbin")
    stub = d / "security"
    stub.write_text("#!/bin/sh\nexit 44\n")
    stub.chmod(0o755)
    return str(d)


def run_print(tier, stub_path, *, args=None, **env_overrides):
    env = {k: v for k, v in os.environ.items() if k not in CONTROLLED}
    env["PATH"] = stub_path + os.pathsep + env.get("PATH", "")
    env.update({k: v for k, v in env_overrides.items() if v is not None})
    argv = [TIER_SH] + (args if args is not None else ["--print", tier])
    return subprocess.run(argv, cwd=BENCH, env=env, capture_output=True, text=True)


def plan(tier, stub_path, **env_overrides):
    """(judge-key marker or None, argv list) for one tier."""
    p = run_print(tier, stub_path, **env_overrides)
    assert p.returncode == 0, p.stderr
    lines = p.stdout.strip().split("\n")
    judge = None
    if lines and lines[0].startswith("EVAL_JUDGE_API_KEY="):
        judge = lines[0].split("=", 1)[1]
        lines = lines[1:]
    return judge, lines


# --- the five tier commands -------------------------------------------------
# Each expectation is the Makefile recipe this script replaced, verbatim. A
# silent drift here is a tier that stops measuring what its name claims.

def test_regression_runs_the_host_safe_core_judged_suite(stub_path):
    judge, argv = plan("regression", stub_path, EVAL_JUDGE_API_KEY="sk-test-judge")
    assert argv == ["uv", "run", "bin/run_eval.py", "--tag", "host-safe-core",
                    "--judge", "--fail-retries", "2"]
    assert judge == "<set>"


def test_behavioral_isolated_carries_both_attestations(stub_path):
    _judge, argv = plan("behavioral-isolated", stub_path, EVAL_JUDGE_API_KEY="sk-test-judge")
    assert argv == ["uv", "run", "bin/run_eval.py", "--profile", "isolated_mutation",
                    "--all", "--judge", "--fail-retries", "2",
                    "--confirm-daemon-isolated", "--confirm-isolated-env"]


def test_capability_is_bare_without_the_confirm_vars(stub_path):
    judge, argv = plan("capability", stub_path)
    assert argv == ["uv", "run", "bin/run_capability.py", "--trials", "5"]
    # Not a judged tier: it must not even mention the judge key.
    assert judge is None


def test_capability_adds_each_attestation_its_var_grants(stub_path):
    _judge, argv = plan("capability", stub_path, CONFIRM_DAEMON_ISOLATED="1",
                        CONFIRM_ISOLATED_ENV="true", CONFIRM_COST="yes")
    assert argv == ["uv", "run", "bin/run_capability.py", "--trials", "5",
                    "--confirm-daemon-isolated", "--confirm-isolated-env",
                    "--confirm-cost"]


@pytest.mark.parametrize("value", ["0", "no", "", "TRUE", "maybe"])
def test_capability_attestation_needs_an_exact_grant_word(stub_path, value):
    _judge, argv = plan("capability", stub_path, CONFIRM_COST=value)
    assert "--confirm-cost" not in argv


def test_capability_grants_are_independent(stub_path):
    _judge, argv = plan("capability", stub_path, CONFIRM_ISOLATED_ENV="1")
    assert argv == ["uv", "run", "bin/run_capability.py", "--trials", "5",
                    "--confirm-isolated-env"]


def test_capability_judged_binarizes_the_taste_axis_at_half(stub_path):
    judge, argv = plan("capability-judged", stub_path, EVAL_JUDGE_API_KEY="sk-test-judge")
    assert argv == ["uv", "run", "bin/run_capability.py", "--suite",
                    "cap_response_quality", "--trials", "5", "--judge",
                    "--threshold", "0.5"]
    assert judge == "<set>"


def test_capability_readonly_selects_only_the_read_only_suites(stub_path):
    judge, argv = plan("capability-readonly", stub_path)
    assert argv == ["uv", "run", "bin/run_capability.py", "--trials", "5",
                    "--suite", "cap_web_research", "--suite", "cap_web_app"]
    assert judge is None


# --- the judge key ----------------------------------------------------------

def test_the_judge_key_value_is_never_printed(stub_path):
    p = run_print("regression", stub_path, EVAL_JUDGE_API_KEY="sk-secret-value")
    assert p.returncode == 0, p.stderr
    assert "sk-secret-value" not in p.stdout
    assert "sk-secret-value" not in p.stderr
    assert "EVAL_JUDGE_API_KEY=<set>" in p.stdout


def test_an_unanswered_keychain_leaves_the_judge_key_unset(stub_path):
    # The stub `security` exits nonzero with no output; that is not fatal — the
    # runner refuses the judged run itself, with a message about the key.
    judge, argv = plan("regression", stub_path)
    assert judge == "<unset>"
    assert argv[:3] == ["uv", "run", "bin/run_eval.py"]


# --- refusals ---------------------------------------------------------------

def test_an_unknown_tier_exits_2_with_a_usage_line(stub_path):
    p = run_print(None, stub_path, args=["--print", "capability-everything"])
    assert p.returncode == 2
    assert "usage:" in p.stderr
    assert p.stdout == ""


def test_a_missing_tier_exits_2_with_a_usage_line(stub_path):
    p = run_print(None, stub_path, args=[])
    assert p.returncode == 2
    assert "usage:" in p.stderr


def test_print_only_refuses_extra_arguments(stub_path):
    p = run_print(None, stub_path, args=["--print", "capability", "--trials", "9"])
    assert p.returncode == 2
    assert "usage:" in p.stderr


@pytest.mark.parametrize("check_exit,run_exit", [(0, 0), (0, 2), (0, 4), (0, 5), (3, 0)])
def test_auto_run_preserves_exit_code_and_always_cleans_up(tmp_path, check_exit, run_exit):
    # Exercise the real run function with startup/teardown stubbed: no daemon or home.
    source = Path(HERE, "capability-daemon.sh").read_text()
    body = source.split("\nrun() {\n", 1)[1].split("\n}\n", 1)[0]
    uv = tmp_path / "uv"
    uv.write_text('#!/bin/sh\ncase " $* " in\n'
                  f'  *" --check "*) exit {check_exit} ;;\n'
                  f'  *) exit {run_exit} ;;\nesac\n')
    uv.chmod(0o755)
    script = ('set -euo pipefail\n'
              'log() { printf "%s\\n" "$*" >&2; }\n'
              'up() { :; }\n'
              'down() { printf "cleaned\\n"; }\n'
              'run() {\n' + body + '\n}\nrun\n')
    env = {**os.environ, "BENCH": BENCH, "BIN_DIR": HERE,
           "HOME_DIR": str(tmp_path / "disposable-eval"), "PROJECT": "test-eval",
           "PATH": str(tmp_path) + os.pathsep + os.environ["PATH"]}
    result = subprocess.run(["bash", "-c", script], env=env,
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == (check_exit or run_exit), result.stderr
    assert result.stdout.splitlines().count("cleaned") == 1


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
