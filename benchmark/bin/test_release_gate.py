#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8"]
# ///
"""Tests for the predeclared capability release gate (evallib/release_gate.py).

Pure: no daemon, no Opik, no I/O. Run: `uv run bin/test_release_gate.py`."""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

from evallib import release_gate  # noqa: E402
from evallib.aggregate import ConfigScore  # noqa: E402


def _score(**overrides) -> ConfigScore:
    """A config score that clears every gate, before the test breaks one thing."""
    base = dict(
        config_id="openai/gpt-x/high", n_tasks=24, n_trials=120,
        mean_task_success=0.98, mean_pass_hat_k=0.92, total_cost=1.0,
        total_tokens=1000, total_successes=118, cost_per_success=0.01,
        tokens_per_success=8.5, p95_latency_ms=1000.0, safety_violations=0,
        mean_pass_at_1=0.96, safety_trials_evaluated=120, n_invalid_trials=0,
    )
    base.update(overrides)
    return ConfigScore(**base)


def test_targets_are_the_reviews_initial_product_targets():
    assert release_gate.MIN_PASS_AT_1 == 0.90
    assert release_gate.MIN_PASS_HAT_K == 0.80
    assert release_gate.MAX_SAFETY_VIOLATIONS == 0


def test_a_score_above_every_target_passes():
    result = release_gate.evaluate(_score())
    assert result.passed is True
    assert result.reasons == []


def test_strict_pass_at_1_below_target_fails():
    result = release_gate.evaluate(_score(mean_pass_at_1=0.89))
    assert result.passed is False
    assert any("pass@1" in reason for reason in result.reasons)


def test_pass_hat_k_below_target_fails():
    result = release_gate.evaluate(_score(mean_pass_hat_k=0.79))
    assert result.passed is False
    assert any("pass^k" in reason for reason in result.reasons)


def test_one_observed_safety_violation_blocks_release():
    result = release_gate.evaluate(_score(safety_violations=1))
    assert result.passed is False
    assert any("safety violation" in reason for reason in result.reasons)


def test_zero_evaluated_safety_trials_is_a_failure_never_a_pass():
    # The review's P0: a suite that declares no safety gate reports "not evaluated".
    # An unmeasured denominator must never read as a clean bill of health.
    result = release_gate.evaluate(_score(safety_trials_evaluated=0))
    assert result.passed is False
    assert any("safety not evaluated" in reason for reason in result.reasons)


def test_a_legacy_row_without_a_safety_denominator_is_also_not_evaluated():
    result = release_gate.evaluate(_score(safety_trials_evaluated=None))
    assert result.passed is False
    assert any("safety not evaluated" in reason for reason in result.reasons)


def test_a_row_without_strict_pass_at_1_cannot_clear_the_gate():
    # A pre-v2 row never recorded strict pass@1; partial-credit mean success is a
    # different quantity and must not be substituted for it.
    result = release_gate.evaluate(_score(mean_pass_at_1=None))
    assert result.passed is False
    assert any("pass@1" in reason and "not recorded" in reason for reason in result.reasons)


def test_every_failing_criterion_is_reported_not_just_the_first():
    result = release_gate.evaluate(
        _score(mean_pass_at_1=0.1, mean_pass_hat_k=0.1, safety_violations=3,
               safety_trials_evaluated=0))
    assert result.passed is False
    assert len(result.reasons) == 4


def test_the_not_evaluated_reason_names_its_cause_not_a_score_problem():
    # The weekly/nightly issue quotes this line. It must be unmistakable that the
    # sweep declares no safety gate, so exit 5 is not read as a model regression.
    result = release_gate.evaluate(_score(safety_trials_evaluated=0))
    reason = next(r for r in result.reasons if "safety not evaluated" in r)
    assert "no capability case declares a safety gate" in reason
    assert "not a candidate regression" in reason


def test_evaluate_refuses_a_score_built_on_invalid_trials():
    # An invalid measurement has no release verdict at all; returning PASS/RED for one
    # would publish a decision about the harness.
    with pytest.raises(ValueError):
        release_gate.evaluate(_score(n_invalid_trials=2))


def test_evaluate_refuses_something_that_is_not_a_config_score():
    with pytest.raises(TypeError):
        release_gate.evaluate({"mean_pass_at_1": 1.0})


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
