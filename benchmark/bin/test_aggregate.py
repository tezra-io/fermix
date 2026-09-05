#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "certifi"]
# ///
"""Unit tests for the capability aggregation layer (evallib.aggregate).

Covers the pass@1 / pass^k unbiased estimators, safety-gate zeroing, per-task and
per-config aggregation, and cross-config ranking. All pure — no daemon, no Opik.
Run: `uv run bin/test_aggregate.py`.
"""
from __future__ import annotations

import itertools
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

from dataclasses import asdict as dc_asdict  # noqa: E402

from evallib import aggregate as agg  # noqa: E402


def trial(task_id="t", success=1.0, safety_ok=True, cost=0.10, dur=1000.0, tokens=500,
          tools=1, status="ok", trace_id="tr", **pricing):
    return agg.score_trial(task_id, task_success=success, safety_ok=safety_ok, cost=cost,
                           duration_ms=dur, tokens=tokens, tool_calls=tools, status=status,
                           trace_id=trace_id, **pricing)


def priced_trial(**overrides):
    """A trial whose llm spans were priced against the rate card (the stage-(a) shape:
    a full token split plus one PricedUsage rolled up over the trial's spans)."""
    kw = dict(total_input_tokens=1000, total_output_tokens=200,
              total_cached_input_tokens=800, total_cache_write_tokens=0,
              priced_cost_usd=0.05, pricing_basis="cache_aware",
              pricing_card_version="2026-09-05", unpriced_routes=[], spans_without_usage=0)
    kw.update(overrides)
    return trial(**kw)


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
    assert t.safety_violation is True


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


def test_aggregate_task_refuses_k_over_n():
    # Clamping silently published a pass^3 under a "pass^5" label. Refuse instead.
    trials = [trial(success=1.0) for _ in range(3)]
    with pytest.raises(ValueError):
        agg.aggregate_task(trials, k=8, threshold=1.0)


def test_aggregate_task_refuses_k_below_one():
    with pytest.raises(ValueError):
        agg.aggregate_task([trial(success=1.0)], k=0, threshold=1.0)


def test_aggregate_task_keeps_the_requested_k():
    st = agg.aggregate_task([trial(success=1.0) for _ in range(5)], k=5, threshold=1.0)
    assert st.k == 5


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


def _config_tokens(cid, tokens_each):
    trials = [trial(task_id=f"{cid}-t0", success=1.0, tokens=tokens_each) for _ in range(2)]
    return agg.aggregate_config(cid, [agg.aggregate_task(trials, k=2, threshold=1.0)])


# --- efficiency: a DISPLAY column, no longer part of the score ----------------
# These three started life as rank-order tests, back when the composite carried an
# `eff * 1e-6` term and efficiency broke an exact capability tie. The score is now
# capability only, so they are restated against _efficiency_norm's own contract --
# which still matters: the leaderboard renders the column, and an unpriced $0 must
# never read as "maximally efficient".

def test_efficiency_norm_is_the_ratio_to_the_best_and_clamps_at_one():
    assert agg._efficiency_norm(0.5, 0.5) == pytest.approx(1.0)
    assert agg._efficiency_norm(1.0, 0.5) == pytest.approx(0.5)
    assert agg._efficiency_norm(0.25, 0.5) == pytest.approx(1.0)   # beats "best" -> clamped
    assert agg._efficiency_norm(2.0, None) == pytest.approx(1.0)   # nothing to compare against


def _carded_config(cid, *, opik_cost, card_cost, basis="cache_aware", card="2026-09-05",
                   routes=None, n_pass=2, n_total=2):
    """One config carrying BOTH dollar columns, set independently: Opik's per-trial
    auto-cost (`opik_cost`) and the rate card's own per-trial figure (`card_cost`).

    Setting them apart — and, in the tests below, in OPPOSITE directions — is the only
    way to prove which column the cost axis actually read."""
    trials = [trial(task_id=f"{cid}-t0", success=(1.0 if i < n_pass else 0.0),
                    cost=opik_cost, total_input_tokens=1000, total_output_tokens=200,
                    total_cached_input_tokens=0, total_cache_write_tokens=0,
                    priced_cost_usd=card_cost, pricing_basis=basis,
                    pricing_card_version=card, unpriced_routes=routes,
                    spans_without_usage=0)
              for i in range(n_total)]
    return agg.aggregate_config(cid, [agg.aggregate_task(trials, k=n_total, threshold=1.0)])


def test_efficiency_norm_prefers_the_cheaper_config_on_the_cost_axis():
    # Opik says the opposite of the card on purpose: cheap is Opik-expensive and
    # pricey is Opik-cheap, so an eff that followed Opik would invert this assertion.
    cheap = _carded_config("cheap", opik_cost=1.00, card_cost=0.01)
    pricey = _carded_config("pricey", opik_cost=0.01, card_cost=1.00)
    ranked = {r.config.config_id: r for r in agg.rank_configs([pricey, cheap], axis="cost")}
    assert ranked["cheap"].efficiency_norm == pytest.approx(1.0)
    assert ranked["pricey"].efficiency_norm == pytest.approx(0.01)
    # ...and it no longer moves the rank: equal capability -> equal composite.
    assert ranked["cheap"].composite == pytest.approx(ranked["pricey"].composite)


def test_cost_axis_prices_a_row_whose_slug_opik_never_knew():
    # THE original defect. Opik's auto-cost keys on the MODEL SLUG, so a slug absent
    # from its price table reports $0 on every span -- which `_efficiency_norm` reads
    # as no signal, i.e. eff 0.00, for a row the rate card prices perfectly well.
    uncarded_by_opik = _carded_config("sol", opik_cost=0.0, card_cost=0.05)
    known_to_opik = _carded_config("mini", opik_cost=0.30, card_cost=0.10)
    ranked = {r.config.config_id: r
              for r in agg.rank_configs([known_to_opik, uncarded_by_opik], axis="cost")}
    assert ranked["sol"].efficiency_norm == pytest.approx(1.0)      # was 0.00 on Opik
    assert ranked["mini"].efficiency_norm == pytest.approx(0.5)


def test_efficiency_norm_prefers_fewer_tokens_on_the_default_axis():
    lean = _config_tokens("lean", 200)
    heavy = _config_tokens("heavy", 2000)
    ranked = {r.config.config_id: r for r in agg.rank_configs([heavy, lean])}   # default axis
    assert ranked["lean"].efficiency_norm == pytest.approx(1.0)
    assert ranked["heavy"].efficiency_norm == pytest.approx(0.1)


def test_efficiency_norm_treats_an_unpriced_zero_as_no_signal_not_as_free():
    # A $0/success is never "free": on the Opik column it means the MODEL SLUG is
    # missing from its price table. The primitive guards that for every axis.
    assert agg._efficiency_norm(0.0, 0.5) == 0.0
    assert agg._efficiency_norm(math.inf, 0.5) == 0.0        # nothing resolved
    priced = _carded_config("priced", opik_cost=0.5, card_cost=0.50)
    nothing = _carded_config("nothing", opik_cost=0.5, card_cost=0.50, n_pass=0)
    ranked = {r.config.config_id: r for r in agg.rank_configs([nothing, priced], axis="cost")}
    assert ranked["nothing"].efficiency_norm == 0.0          # resolved nothing to divide by
    assert ranked["priced"].efficiency_norm > ranked["nothing"].efficiency_norm


# --- the cost axis refuses to normalize across incomparable accountings -------

def test_cost_axis_withholds_eff_when_a_cohort_mixes_the_card_with_opik_dollars():
    # Today's store does exactly this: gpt-5.5/xhigh carries a real Opik-metered
    # $0.3745/success beside rows the rate card prices. A ratio between the two is a
    # ratio between two different accountings, so the cohort reports no eff at all.
    carded = _carded_config("carded", opik_cost=0.10, card_cost=0.10)
    legacy = _config("legacy", [(2, 2, 0.3745)])             # pricing_basis None
    ranked = agg.rank_configs([legacy, carded], axis="cost")
    assert [r.efficiency_norm for r in ranked] == [None, None]


def test_cost_axis_withholds_eff_across_two_rate_card_versions():
    # The same defect one level down: two `cache_aware` figures priced under different
    # cards are not a ratio either.
    july = _carded_config("july", opik_cost=0.1, card_cost=0.10, card="2026-07-01")
    today = _carded_config("today", opik_cost=0.1, card_cost=0.20, card="2026-09-05")
    ranked = agg.rank_configs([july, today], axis="cost")
    assert [r.efficiency_norm for r in ranked] == [None, None]


def test_cost_axis_withholds_eff_across_a_ceiling_and_a_cache_aware_figure():
    ceiling = _carded_config("ceiling", opik_cost=0.1, card_cost=0.10, basis="ceiling")
    exact = _carded_config("exact", opik_cost=0.1, card_cost=0.20, basis="cache_aware")
    ranked = agg.rank_configs([ceiling, exact], axis="cost")
    assert [r.efficiency_norm for r in ranked] == [None, None]


def test_cost_axis_withholds_eff_when_the_cohort_has_no_dollar_figure_at_all():
    # Uniform basis, but neither row carries dollars: an `unpriced` route has no rate
    # and a local route was never token-billed. Neither is a cheap run.
    local_a = _carded_config("local-a", opik_cost=0.0, card_cost=None,
                             basis="not_token_billed")
    local_b = _carded_config("local-b", opik_cost=0.0, card_cost=None,
                             basis="not_token_billed")
    assert [r.efficiency_norm
            for r in agg.rank_configs([local_a, local_b], axis="cost")] == [None, None]
    gap = _carded_config("gap", opik_cost=0.0, card_cost=None, basis="unpriced",
                         routes=["openai_codex/gpt-6-astra"])
    assert [r.efficiency_norm for r in agg.rank_configs([gap], axis="cost")] == [None]


def test_a_withheld_cost_eff_never_disturbs_the_capability_rank():
    carded = _carded_config("carded", opik_cost=0.10, card_cost=0.10, n_pass=2)
    legacy = _config("legacy", [(1, 2, 0.3745)])             # weaker, and Opik-metered
    ranked = agg.rank_configs([legacy, carded], axis="cost")
    assert [r.config.config_id for r in ranked] == ["carded", "legacy"]
    assert [r.rank for r in ranked] == [1, 2]


def test_the_tokens_axis_is_unaffected_by_mixed_pricing_bases():
    # Tokens are captured for every provider and every auth mode, so a cohort's
    # pricing provenance has nothing to say about the default axis.
    carded = _carded_config("carded", opik_cost=0.10, card_cost=0.10)
    legacy = _config("legacy", [(2, 2, 0.3745)])
    effs = {r.config.config_id: r.efficiency_norm for r in agg.rank_configs([legacy, carded])}
    assert all(v is not None for v in effs.values())
    assert max(effs.values()) == pytest.approx(1.0)


def test_rank_rejects_unknown_axis():
    with pytest.raises(ValueError):
        agg.rank_configs([_config_tokens("x", 100)], axis="dollars")


# --- rank: capability only, and a function of the data alone ------------------

def test_composite_is_capability_only_and_ignores_efficiency():
    lean = _config_tok("lean", [(2, 2), (1, 2)], tokens_each=100)
    heavy = _config_tok("mega", [(2, 2), (1, 2)], tokens_each=100000)
    ranked = agg.rank_configs([lean, heavy])
    assert ranked[0].composite == pytest.approx(ranked[1].composite)   # same capability
    assert ranked[0].efficiency_norm != ranked[1].efficiency_norm      # display column differs


def test_rank_order_is_identical_under_a_permuted_input_list():
    # Dropping the efficiency term exposes exact (success, pass^k) ties to Python's
    # stable sort -- i.e. to whichever config happened to be scored first. Rank must be
    # a function of the DATA, never of the input order.
    tied = [_config_tok(cid, [(2, 2), (1, 2)], tokens_each=tok)
            for cid, tok in (("bravo", 100), ("alpha", 50000), ("charlie", 900))]
    orders = {tuple(r.config.config_id for r in agg.rank_configs(list(perm)))
              for perm in itertools.permutations(tied)}
    assert orders == {("alpha", "bravo", "charlie")}


def test_exact_ties_break_on_config_id_not_insertion_order():
    first = _config_tok("zzz", [(2, 2)], tokens_each=100)
    second = _config_tok("aaa", [(2, 2)], tokens_each=100)
    assert [r.config.config_id for r in agg.rank_configs([first, second])] == ["aaa", "zzz"]


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


# --- run validity: a trial whose evidence is missing is not a scored zero -----

def test_invalid_statuses_are_named_and_flagged():
    assert "no_trace" in agg.INVALID_STATUSES and "opik_error" in agg.INVALID_STATUSES
    assert trial(status="ok").valid is True
    assert trial(status="no_trace").valid is False
    assert trial(status="crashed").valid is False


def test_aggregate_task_counts_invalid_trials():
    trials = [trial(success=1.0), trial(success=0.0, status="no_trace"),
              trial(success=0.0, status="opik_error")]
    st = agg.aggregate_task(trials, k=1, threshold=1.0)
    assert st.n_invalid == 2
    assert st.n_trials == 3                       # still recorded, never dropped silently


# --- safety: "not evaluated" is not a pass -----------------------------------

def test_safety_none_means_not_evaluated_and_never_zeroes():
    t = agg.score_trial("t", task_success=1.0, safety_ok=None, cost=0.1, duration_ms=10.0,
                        tokens=5, tool_calls=0, status="ok")
    assert t.safety_evaluated is False
    assert t.safety_violation is False
    assert t.effective_success == 1.0             # no gate graded -> nothing to zero


def test_safety_false_is_a_violation_and_zeroes():
    t = trial(success=1.0, safety_ok=False)
    assert t.safety_evaluated is True and t.safety_violation is True
    assert t.effective_success == 0.0 and t.raw_success == 1.0


def test_aggregate_task_reports_the_safety_denominator():
    trials = [trial(success=1.0, safety_ok=True), trial(success=1.0, safety_ok=None),
              trial(success=1.0, safety_ok=False)]
    st = agg.aggregate_task(trials, k=1, threshold=1.0)
    assert st.safety_trials_evaluated == 2        # the ungraded trial is NOT in the denominator
    assert st.safety_violations == 1


def test_config_safety_denominator_is_zero_when_nothing_was_graded():
    trials = [trial(success=1.0, safety_ok=None) for _ in range(3)]
    cfg = agg.aggregate_config("c", [agg.aggregate_task(trials, k=3, threshold=1.0)])
    assert cfg.safety_trials_evaluated == 0       # renders "not evaluated", never a checkmark
    assert cfg.safety_violations == 0


# --- cost: unknown is unknown, never $0 --------------------------------------

def test_unknown_cost_is_none_not_zero():
    t = agg.score_trial("t", task_success=1.0, safety_ok=True, cost=0.0, duration_ms=1.0,
                        tokens=1, tool_calls=0, status="ok", cost_known=False)
    assert t.cost is None and t.cost_known is False


def test_task_and_config_cost_known_is_false_when_any_trial_is_unpriced():
    known = trial(success=1.0, cost=0.25)
    unknown = agg.score_trial("t", task_success=1.0, safety_ok=True, cost=0.0,
                              duration_ms=1.0, tokens=1, tool_calls=0, status="ok",
                              cost_known=False)
    st = agg.aggregate_task([known, unknown], k=1, threshold=1.0)
    assert st.cost_known is False
    assert st.total_cost == pytest.approx(0.25)   # only the priced trial contributes
    assert agg.aggregate_config("c", [st]).cost_known is False


# --- per-model pricing: the token split and the rate card's dollar figure -----
# The card is applied by the reporting layer and arrives here ALREADY PRICED; this
# layer only carries the numbers up, tri-state, and never touches the Opik cost
# columns beside them.

def test_score_trial_carries_the_token_split_and_the_priced_cost():
    t = priced_trial()
    assert (t.total_input_tokens, t.total_output_tokens) == (1000, 200)
    assert t.total_cached_input_tokens == 800 and t.total_cache_write_tokens == 0
    assert t.priced_cost_usd == pytest.approx(0.05)
    assert t.pricing_basis == "cache_aware" and t.pricing_card_version == "2026-09-05"


def test_a_trial_without_pricing_reports_unknown_never_zero():
    t = trial()
    assert t.total_input_tokens is None and t.total_output_tokens is None
    assert t.total_cached_input_tokens is None and t.total_cache_write_tokens is None
    assert t.priced_cost_usd is None and t.pricing_basis is None
    assert t.pricing_card_version is None and t.unpriced_routes is None
    assert t.spans_without_usage is None        # 0 would claim we checked and found none


def test_score_trial_rejects_an_unknown_pricing_basis():
    with pytest.raises(ValueError):
        priced_trial(pricing_basis="estimated")


def test_score_trial_refuses_a_dollar_figure_that_contradicts_its_basis():
    with pytest.raises(ValueError):     # "unpriced" has no rate to apply -> no number
        priced_trial(pricing_basis="unpriced", unpriced_routes=["openai/gpt-9"])
    with pytest.raises(ValueError):     # a costed basis must carry the number it computed
        priced_trial(priced_cost_usd=None)
    with pytest.raises(ValueError):     # a local model was never token-billed
        priced_trial(pricing_basis="not_token_billed")


def test_score_trial_refuses_a_cost_or_a_route_with_no_basis():
    with pytest.raises(ValueError):
        trial(priced_cost_usd=0.02)
    with pytest.raises(ValueError):
        trial(unpriced_routes=["openai/gpt-9"])


def test_score_trial_refuses_an_unpriced_basis_that_names_no_route():
    # "unpriced" exists to tell the operator WHAT to add to the card. Naming nothing
    # is the useless-error failure mode.
    with pytest.raises(ValueError):
        priced_trial(pricing_basis="unpriced", priced_cost_usd=None, unpriced_routes=[])


def test_score_trial_refuses_routes_alongside_a_priced_basis():
    with pytest.raises(ValueError):
        priced_trial(unpriced_routes=["openai/gpt-9"])


def test_score_trial_requires_a_card_version_with_any_basis():
    with pytest.raises(ValueError):
        priced_trial(pricing_card_version=None)


def test_score_trial_refuses_a_half_reported_token_split():
    with pytest.raises(ValueError):
        priced_trial(total_output_tokens=None)
    with pytest.raises(ValueError):     # cache detail with no split to subtract it from
        priced_trial(total_input_tokens=None, total_output_tokens=None)


def test_score_trial_refuses_negative_token_counts():
    with pytest.raises(ValueError):
        priced_trial(total_input_tokens=-1)


def test_aggregate_task_sums_the_split_and_the_priced_cost():
    trials = [priced_trial(total_input_tokens=1000, total_output_tokens=200,
                           priced_cost_usd=0.05),
              priced_trial(total_input_tokens=3000, total_output_tokens=400,
                           priced_cost_usd=0.09)]
    st = agg.aggregate_task(trials, k=1, threshold=1.0)
    assert st.total_input_tokens == 4000 and st.total_output_tokens == 600
    assert st.total_cached_input_tokens == 1600 and st.total_cache_write_tokens == 0
    assert st.priced_cost_usd == pytest.approx(0.14)
    assert st.pricing_basis == "cache_aware" and st.pricing_card_version == "2026-09-05"


def test_a_missing_split_makes_the_total_unknown_never_a_partial_sum():
    st = agg.aggregate_task([priced_trial(), trial()], k=1, threshold=1.0)
    assert st.total_input_tokens is None and st.total_output_tokens is None
    assert st.priced_cost_usd is None and st.pricing_basis is None


def test_the_weakest_pricing_basis_wins_the_rollup():
    ceiling = priced_trial(pricing_basis="ceiling", total_cached_input_tokens=None,
                           total_cache_write_tokens=None)
    st = agg.aggregate_task([priced_trial(), ceiling], k=1, threshold=1.0)
    assert st.pricing_basis == "ceiling"          # one span without cache detail degrades it
    assert st.priced_cost_usd == pytest.approx(0.10)
    assert st.total_cached_input_tokens is None   # the cache column is unknown, not 800


def test_an_unpriced_route_beats_every_other_basis_and_is_named():
    unpriced = priced_trial(pricing_basis="unpriced", priced_cost_usd=None,
                            unpriced_routes=["openai_codex/gpt-6-astra"])
    st = agg.aggregate_task([priced_trial(), unpriced], k=1, threshold=1.0)
    cfg = agg.aggregate_config("c", [st])
    assert cfg.pricing_basis == "unpriced" and cfg.priced_cost_usd is None
    assert cfg.unpriced_routes == ["openai_codex/gpt-6-astra"]
    assert cfg.priced_cost_per_success is None


def test_a_local_only_config_reports_no_dollar_figure():
    local = priced_trial(pricing_basis="not_token_billed", priced_cost_usd=None)
    cfg = agg.aggregate_config("c", [agg.aggregate_task([local], k=1, threshold=1.0)])
    assert cfg.pricing_basis == "not_token_billed" and cfg.priced_cost_usd is None
    assert cfg.total_input_tokens == 1000        # tokens are still measured, just not billed


def test_a_local_trial_beside_a_metered_one_keeps_the_metered_figure():
    local = priced_trial(pricing_basis="not_token_billed", priced_cost_usd=None)
    st = agg.aggregate_task([priced_trial(), local], k=1, threshold=1.0)
    assert st.pricing_basis == "cache_aware"
    assert st.priced_cost_usd == pytest.approx(0.05)   # the local half really is $0


def test_rollup_refuses_two_rate_cards_in_one_dollar_figure():
    stale = priced_trial(pricing_card_version="2026-07-01")
    with pytest.raises(ValueError):
        agg.aggregate_task([priced_trial(), stale], k=1, threshold=1.0)


def test_spans_without_usage_are_carried_up_never_silently_zeroed():
    # An errored span carries real, unrecoverable spend; the count is how a reader
    # knows the dollar figure is short.
    errored = priced_trial(spans_without_usage=2)
    st = agg.aggregate_task([priced_trial(), errored], k=1, threshold=1.0)
    assert agg.aggregate_config("c", [st]).spans_without_usage == 2


def test_priced_cost_per_success_is_derived_not_a_stored_column():
    cfg = agg.aggregate_config("c", [agg.aggregate_task([priced_trial(), priced_trial()],
                                                        k=1, threshold=1.0)])
    assert cfg.priced_cost_per_success == pytest.approx(0.10 / 2)
    # Stored, a null-serialized inf would reload as a silent None (leaderboard._sanitize).
    assert "priced_cost_per_success" not in dc_asdict(cfg)


def test_priced_cost_per_success_is_inf_when_nothing_succeeded():
    cfg = agg.aggregate_config("c", [agg.aggregate_task([priced_trial(success=0.0)],
                                                        k=1, threshold=1.0)])
    assert cfg.priced_cost_per_success == math.inf


def test_folding_nothing_refuses_rather_than_reporting_a_zero_total():
    with pytest.raises(ValueError):
        agg._pricing_columns([])


def test_the_rate_card_never_touches_the_opik_cost_columns():
    # Filling Opik's cost in from the card would arm every declared max_cost_usd gate
    # at once, calibrated against list prices nobody was billed.
    st = agg.aggregate_task([priced_trial(cost=0.02)], k=1, threshold=1.0)
    cfg = agg.aggregate_config("c", [st])
    assert cfg.total_cost == pytest.approx(0.02)         # Opik's number, untouched
    assert cfg.cost_per_success == pytest.approx(0.02)
    assert cfg.cost_known is True
    assert cfg.priced_cost_usd == pytest.approx(0.05)    # the card's number, beside it


# --- latency: pooled trial-level p95, labelled ------------------------------

def test_config_p95_is_pooled_over_trials_not_max_of_task_p95():
    fast = [trial(dur=1000.0) for _ in range(10)]
    slow = [trial(dur=1000.0) for _ in range(9)] + [trial(dur=200000.0)]
    stats = [agg.aggregate_task(fast, k=1, threshold=1.0),
             agg.aggregate_task(slow, k=1, threshold=1.0)]
    cfg = agg.aggregate_config("c", stats)
    assert cfg.latency_stat == "pooled_p95"
    # max-of-task-p95 would report the single 200s outlier; the pooled p95 of 20 trials is 1000
    assert cfg.p95_latency_ms == pytest.approx(1000.0)


def test_config_falls_back_to_max_task_p95_for_rows_without_trial_durations():
    st = agg.aggregate_task([trial(dur=5000.0)], k=1, threshold=1.0)
    st.durations_ms = []                          # a legacy TaskStats carries no trial list
    cfg = agg.aggregate_config("c", [st])
    assert cfg.latency_stat == "max_task_p95"
    assert cfg.p95_latency_ms == pytest.approx(5000.0)


# --- strict pass@1 and families ---------------------------------------------

def test_mean_pass_at_1_is_strict_not_partial_credit():
    partial = [trial(success=0.6), trial(success=0.6)]
    st = agg.aggregate_task(partial, k=1, threshold=1.0)
    cfg = agg.aggregate_config("c", [st])
    assert cfg.mean_task_success == pytest.approx(0.6)   # partial credit preserved
    assert cfg.mean_pass_at_1 == pytest.approx(0.0)      # nothing cleared the bar


def _fam_stats(specs):
    """specs: list of (family, mean_success) -> single-trial TaskStats."""
    return [agg.aggregate_task([trial(task_id=f"t{i}", success=v)], k=1, threshold=1.0,
                               family=fam)
            for i, (fam, v) in enumerate(specs)]


def test_bootstrap_resamples_families_when_every_task_declares_one():
    stats = _fam_stats([("alpha", 1.0), ("alpha", 1.0), ("alpha", 1.0),
                        ("beta", 0.0), ("beta", 0.0), ("beta", 0.0)])
    cfg = agg.aggregate_config("c", stats)
    assert cfg.ci_resampled == "families"
    assert cfg.n_families == 2
    # Two independent worlds, not six independent cases: the band must span both.
    assert cfg.mean_task_success_ci_lo == pytest.approx(0.0)
    assert cfg.mean_task_success_ci_hi == pytest.approx(1.0)


def test_bootstrap_resamples_cases_when_a_family_is_missing():
    stats = _fam_stats([("alpha", 1.0), ("alpha", 0.0)])
    stats[1].family = None
    cfg = agg.aggregate_config("c", stats)
    assert cfg.ci_resampled == "cases"
    assert cfg.n_families is None


def test_clustered_bootstrap_is_deterministic_and_rejects_empty():
    clusters = [[1.0, 1.0], [0.0, 0.5]]
    assert agg.bootstrap_ci_clustered(clusters) == agg.bootstrap_ci_clustered(clusters)
    with pytest.raises(ValueError):
        agg.bootstrap_ci_clustered([])


def test_single_family_ci_is_degenerate_not_a_case_bootstrap():
    # One world carries no between-world information: the honest band is (mean, mean).
    # Resampling the correlated paraphrases inside it produced [0, 1] under a label
    # that said the families were resampled.
    stats = _fam_stats([("only", 1.0), ("only", 0.0), ("only", 1.0), ("only", 0.0)])
    cfg = agg.aggregate_config("c", stats)
    assert cfg.ci_resampled == "families" and cfg.n_families == 1
    assert cfg.mean_task_success_ci_lo == pytest.approx(0.5)
    assert cfg.mean_task_success_ci_hi == pytest.approx(0.5)


def test_checker_error_is_an_invalid_measurement_not_a_scored_zero():
    # An evaluator failure is never a model failure: it must not enter pass@1.
    assert "checker_error" in agg.INVALID_STATUSES
    st = agg.aggregate_task([trial(success=0.0, status="checker_error")], k=1, threshold=1.0)
    assert st.n_invalid == 1


def test_score_trial_records_a_normalized_status_detail():
    t = trial(status="no_trace")
    assert t.status_detail == ""
    t = agg.score_trial("t", task_success=0.0, safety_ok=None, cost=0.0, duration_ms=1.0,
                        tokens=0, tool_calls=0, status="no_trace", status_detail="timeout")
    assert t.status == "no_trace" and t.status_detail == "timeout"


def test_trial_result_safety_defaults_to_not_evaluated():
    # A construction that forgot to say must not record a clean bill of health.
    t = agg.TrialResult(task_id="t", effective_success=1.0, raw_success=1.0, cost=0.0,
                        duration_ms=1.0, tokens=1, tool_calls=0, status="ok")
    assert t.safety_ok is None and not t.safety_evaluated and not t.safety_violation


def test_legacy_config_score_loads_without_the_new_fields():
    # A v1 leaderboard row carries none of the v2 columns; they must default, not raise.
    c = agg.ConfigScore(config_id="old", n_tasks=2, n_trials=10, mean_task_success=0.9,
                        mean_pass_hat_k=0.8, total_cost=1.0, total_tokens=10, total_successes=9,
                        cost_per_success=0.11, tokens_per_success=1.1, p95_latency_ms=10.0,
                        safety_violations=0)
    assert c.mean_pass_at_1 is None and c.safety_trials_evaluated is None
    assert c.n_invalid_trials is None and c.cost_known is None and c.n_families is None
    assert c.latency_stat == "max_task_p95" and c.ci_resampled is None
    # ...and none of the per-model-pricing columns either: leaderboard._config_from_dict
    # is ConfigScore(**row), so every column added after a row was stored must default.
    assert c.total_input_tokens is None and c.total_output_tokens is None
    assert c.total_cached_input_tokens is None and c.total_cache_write_tokens is None
    assert c.priced_cost_usd is None and c.pricing_basis is None
    assert c.pricing_card_version is None and c.unpriced_routes is None
    assert c.spans_without_usage is None and c.priced_cost_per_success is None


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
