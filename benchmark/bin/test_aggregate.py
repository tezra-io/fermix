#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8"]
# ///
"""Unit tests for the capability aggregation layer (evallib.aggregate).

Covers the pass@1 / pass^k unbiased estimators, safety-gate zeroing, per-task and
per-config aggregation, and cross-config ranking. All pure — no daemon, no Opik.
Run: `uv run bin/test_aggregate.py`.
"""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

from evallib import aggregate as agg  # noqa: E402


def trial(task_id="t", success=1.0, safety_ok=True, cost=0.10, dur=1000.0, tokens=500,
          tools=1, status="ok", trace_id="tr"):
    return agg.score_trial(task_id, task_success=success, safety_ok=safety_ok, cost=cost,
                           duration_ms=dur, tokens=tokens, tool_calls=tools, status=status,
                           trace_id=trace_id)


# --- estimators -------------------------------------------------------------

def test_pass_at_1_equals_success_rate():
    assert agg.pass_at_k(5, 2, 1) == pytest.approx(0.4)


def test_pass_at_k_unbiased():
    # 1 - C(3,2)/C(5,2) = 1 - 3/10
    assert agg.pass_at_k(5, 2, 2) == pytest.approx(0.7)


def test_pass_hat_k_all_pass():
    assert agg.pass_hat_k(5, 5, 3) == pytest.approx(1.0)


def test_pass_hat_k_impossible_is_zero():
    # cannot draw 3 successes from only 2
    assert agg.pass_hat_k(5, 2, 3) == 0.0


def test_pass_hat_k_partial():
    # C(3,2)/C(4,2) = 3/6
    assert agg.pass_hat_k(4, 3, 2) == pytest.approx(0.5)


def test_estimators_reject_bad_args():
    with pytest.raises(ValueError):
        agg.pass_hat_k(3, 4, 1)          # c > n
    with pytest.raises(ValueError):
        agg.pass_at_k(3, 1, 4)           # k > n


# --- safety zeroing ---------------------------------------------------------

def test_safety_violation_zeroes_success():
    t = trial(success=1.0, safety_ok=False)
    assert t.effective_success == 0.0
    assert t.raw_success == 1.0
    assert t.safety_ok is False


def test_safe_run_keeps_success():
    assert trial(success=1.0, safety_ok=True).effective_success == 1.0


# --- per-task aggregation ---------------------------------------------------

def test_aggregate_task_all_pass():
    trials = [trial(success=1.0) for _ in range(5)]
    st = agg.aggregate_task(trials, k=3, threshold=1.0)
    assert st.n_trials == 5
    assert st.successes == 5
    assert st.pass_at_1 == pytest.approx(1.0)
    assert st.pass_hat_k == pytest.approx(1.0)
    assert st.mean_success == pytest.approx(1.0)


def test_aggregate_task_flaky_reliability_drops():
    # 3 of 5 pass -> pass@1 0.6 but pass^3 well under 1 (unreliable)
    trials = [trial(success=1.0), trial(success=1.0), trial(success=1.0),
              trial(success=0.0), trial(success=0.0)]
    st = agg.aggregate_task(trials, k=3, threshold=1.0)
    assert st.successes == 3
    assert st.pass_at_1 == pytest.approx(0.6)
    assert st.pass_hat_k == pytest.approx(agg.pass_hat_k(5, 3, 3))
    assert st.pass_hat_k < st.pass_at_1   # the reliability gap


def test_aggregate_task_counts_safety_violations():
    trials = [trial(success=1.0, safety_ok=False), trial(success=1.0)]
    st = agg.aggregate_task(trials, k=1, threshold=1.0)
    assert st.safety_violations == 1
    assert st.successes == 1                       # the unsafe trial scored 0


def test_aggregate_task_clamps_k_to_n():
    trials = [trial(success=1.0) for _ in range(3)]
    st = agg.aggregate_task(trials, k=8, threshold=1.0)
    assert st.k == 3                               # clamped to n_trials


def test_partial_credit_threshold_binarizes_for_passk():
    trials = [trial(success=0.8), trial(success=0.3)]
    st = agg.aggregate_task(trials, k=1, threshold=0.5)
    assert st.successes == 1                        # only the 0.8 clears 0.5
    assert st.mean_success == pytest.approx(0.55)   # mean keeps partial credit


# --- per-config aggregation + ranking ---------------------------------------

def _config(cid, task_specs):
    """task_specs: list of (n_pass, n_total, cost_each) -> TaskStats list."""
    stats = []
    for i, (npass, ntot, cost) in enumerate(task_specs):
        trials = [trial(task_id=f"{cid}-t{i}", success=1.0, cost=cost) for _ in range(npass)]
        trials += [trial(task_id=f"{cid}-t{i}", success=0.0, cost=cost) for _ in range(ntot - npass)]
        stats.append(agg.aggregate_task(trials, k=ntot, threshold=1.0))
    return agg.aggregate_config(cid, stats)


def test_aggregate_config_cost_and_tokens_per_success():
    cfg = _config("a", [(2, 2, 0.10), (1, 2, 0.10)])  # 3 successes / 6 trials, $0.10 each
    assert cfg.n_tasks == 2
    assert cfg.n_trials == 4
    assert cfg.total_cost == pytest.approx(0.40)
    assert cfg.cost_per_success == pytest.approx(0.40 / 3)
    # tokens default 500/trial * 4 trials = 2000, over 3 successes
    assert cfg.tokens_per_success == pytest.approx(2000 / 3)


def test_rank_orders_by_composite_success_dominant():
    strong = _config("strong", [(2, 2, 0.50), (2, 2, 0.50)])   # perfect
    weak = _config("weak", [(1, 2, 0.01), (0, 2, 0.01)])       # mostly wrong
    ranked = agg.rank_configs([weak, strong])
    assert [r.config.config_id for r in ranked] == ["strong", "weak"]
    assert ranked[0].rank == 1
    assert ranked[0].composite > ranked[1].composite


def _config_tok(cid, task_specs, tokens_each):
    """Like _config but pins each trial's token count so efficiency differs."""
    stats = []
    for i, (npass, ntot) in enumerate(task_specs):
        trials = [trial(task_id=f"{cid}-t{i}", success=1.0, tokens=tokens_each) for _ in range(npass)]
        trials += [trial(task_id=f"{cid}-t{i}", success=0.0, tokens=tokens_each) for _ in range(ntot - npass)]
        stats.append(agg.aggregate_task(trials, k=ntot, threshold=1.0))
    return agg.aggregate_config(cid, stats)


def test_efficiency_cannot_override_a_real_capability_gap():
    # The core ranking bug: a LESS capable model that is maximally token-lean must
    # NOT out-rank a MORE capable but chattier one. capable=0.75 success (heavy
    # tokens) vs lean=0.50 success (tiny tokens). Under the old 0.7/0.3 blend the
    # lean model won on efficiency; capability-first ranking puts capable first.
    capable = _config_tok("capable", [(2, 2), (1, 2)], tokens_each=10000)   # mean success 0.75
    lean = _config_tok("lean", [(2, 2), (0, 2)], tokens_each=100)           # mean success 0.50
    ranked = agg.rank_configs([lean, capable])   # default tokens axis; lean is far more efficient
    assert [r.config.config_id for r in ranked] == ["capable", "lean"]
    assert ranked[0].efficiency_norm < ranked[1].efficiency_norm  # winner is the LESS efficient one


def test_rank_breaks_tie_on_cost_axis():
    cheap = _config("cheap", [(2, 2, 0.01), (2, 2, 0.01)])
    pricey = _config("pricey", [(2, 2, 1.00), (2, 2, 1.00)])
    ranked = agg.rank_configs([pricey, cheap], axis="cost")
    # equal (perfect) success -> the cheaper config wins on the $/success term
    assert ranked[0].config.config_id == "cheap"


def _config_tokens(cid, tokens_each):
    trials = [trial(task_id=f"{cid}-t0", success=1.0, tokens=tokens_each) for _ in range(2)]
    return agg.aggregate_config(cid, [agg.aggregate_task(trials, k=2, threshold=1.0)])


def test_rank_tokens_axis_is_default_and_prefers_fewer_tokens():
    lean = _config_tokens("lean", 200)
    heavy = _config_tokens("heavy", 2000)
    ranked = agg.rank_configs([heavy, lean])   # default axis == tokens
    assert ranked[0].config.config_id == "lean"


def test_rank_rejects_unknown_axis():
    with pytest.raises(ValueError):
        agg.rank_configs([_config_tokens("x", 100)], axis="dollars")


def test_cost_axis_does_not_reward_unpriced_zero():
    # $0/success means Opik never priced the trace (Anthropic/xAI/...), NOT "free".
    # It must not out-rank a genuinely cheap PRICED config on the cost axis.
    priced = _config("priced", [(2, 2, 0.50)])
    unpriced = _config("unpriced", [(2, 2, 0.0)])
    ranked = agg.rank_configs([unpriced, priced], axis="cost")
    assert ranked[0].config.config_id == "priced"
    assert ranked[0].efficiency_norm > ranked[1].efficiency_norm


def test_aggregate_task_rejects_nonpositive_or_oversized_threshold():
    trials = [trial(success=1.0)]
    with pytest.raises(ValueError):
        agg.aggregate_task(trials, k=1, threshold=0)     # would count safety-zeroed trials as passes
    with pytest.raises(ValueError):
        agg.aggregate_task(trials, k=1, threshold=1.5)


# --- bootstrap CI on mean_task_success --------------------------------------

def test_bootstrap_ci_is_deterministic():
    vals = [1.0, 0.0, 1.0, 0.5, 0.8, 0.2, 1.0]
    assert agg.bootstrap_ci(vals) == agg.bootstrap_ci(vals)   # fixed seed -> reproducible


def test_bootstrap_ci_single_value_is_point_interval():
    assert agg.bootstrap_ci([0.7]) == (0.7, 0.7)


def test_bootstrap_ci_all_equal_collapses_to_the_value():
    lo, hi = agg.bootstrap_ci([0.4, 0.4, 0.4, 0.4])
    assert lo == pytest.approx(0.4) and hi == pytest.approx(0.4)


def test_bootstrap_ci_brackets_mean_within_unit():
    vals = [1.0, 1.0, 1.0, 0.0, 0.0, 0.5]
    lo, hi = agg.bootstrap_ci(vals)
    mean = sum(vals) / len(vals)
    assert 0.0 <= lo <= mean <= hi <= 1.0
    assert lo < hi                                   # heterogeneous tasks -> a real band


def test_bootstrap_ci_rejects_empty():
    with pytest.raises(ValueError):
        agg.bootstrap_ci([])


def test_aggregate_config_populates_success_ci():
    # Heterogeneous per-task success -> a non-degenerate CI bracketing the mean.
    mixed = _config("mixed", [(2, 2, 0.1), (0, 2, 0.1), (1, 2, 0.1), (2, 2, 0.1)])
    assert mixed.mean_task_success_ci_lo is not None
    assert mixed.mean_task_success_ci_lo <= mixed.mean_task_success <= mixed.mean_task_success_ci_hi
    assert mixed.mean_task_success_ci_lo < mixed.mean_task_success_ci_hi
    # A uniformly-perfect config -> the CI collapses onto 1.0 (no uncertainty).
    perfect = _config("perfect", [(2, 2, 0.1), (2, 2, 0.1)])
    assert perfect.mean_task_success_ci_lo == pytest.approx(1.0)
    assert perfect.mean_task_success_ci_hi == pytest.approx(1.0)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
