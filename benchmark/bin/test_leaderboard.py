#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "certifi"]
# ///
"""Unit tests for evallib.leaderboard (store v2 + cohort rendering). Pure; uses a
tmp dir for the save/load round-trip. Run: `uv run bin/test_leaderboard.py`."""
from __future__ import annotations

import dataclasses
import json
import math
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

from evallib import leaderboard as lb  # noqa: E402
from evallib.aggregate import ConfigScore  # noqa: E402

# A TRACKED copy of the 8-row v1 store as it stood before cohort identity existed.
# reports/ is gitignored and mutable, so a test that read the live file would pass here
# and find nothing on a fresh checkout — and would change meaning under the next sweep.
STORED = os.path.join(os.path.dirname(HERE), "fixtures", "leaderboard",
                      "legacy_v1_store.json")


def cfg(config_id, success, tok_per_success, n_succ=10, ci=None, n_tasks=5, **kw):
    total_tokens = int(tok_per_success * n_succ) if n_succ else 0
    return ConfigScore(
        config_id=config_id, n_tasks=n_tasks, n_trials=10,
        mean_task_success=success, mean_pass_hat_k=success * 0.9,
        total_cost=kw.pop("total_cost", 0.0), total_tokens=total_tokens,
        total_successes=n_succ,
        cost_per_success=math.inf, tokens_per_success=(total_tokens / n_succ if n_succ else math.inf),
        p95_latency_ms=1500.0, safety_violations=kw.pop("safety_violations", 0),
        mean_task_success_ci_lo=(ci[0] if ci else None),
        mean_task_success_ci_hi=(ci[1] if ci else None), **kw)


def meta(tasks_hash="AAA", hash_version=2, k=5, threshold=1.0, **kw):
    return {"tasks_hash": tasks_hash, "hash_version": hash_version, "k": k,
            "threshold": threshold, **kw}


# --- cohort identity --------------------------------------------------------

def test_cohort_key_is_deterministic_and_short():
    a = lb.cohort_key("hash", 2, 5, 1.0)
    assert a == lb.cohort_key("hash", 2, 5, 1.0)
    assert isinstance(a, str) and 0 < len(a) <= 16


def test_cohort_key_separates_every_identity_field():
    base = lb.cohort_key("hash", 2, 5, 1.0)
    assert base != lb.cohort_key("other", 2, 5, 1.0)
    assert base != lb.cohort_key("hash", 1, 5, 1.0)     # hash version bump = new world
    assert base != lb.cohort_key("hash", 2, 3, 1.0)     # a k=3 run is not a k=5 run
    assert base != lb.cohort_key("hash", 2, 5, 0.5)


def test_cohort_key_rejects_a_missing_hash():
    with pytest.raises(ValueError):
        lb.cohort_key("", 2, 5, 1.0)


# --- store v2 ---------------------------------------------------------------

def test_upsert_requires_the_identity_meta_keys():
    for missing in ("tasks_hash", "hash_version", "k", "threshold"):
        m = meta()
        del m[missing]
        with pytest.raises(ValueError):
            lb.upsert({}, cfg("a", 0.5, 1000), m)


def test_upsert_keeps_latest_per_config_within_one_cohort():
    store = lb.upsert({}, cfg("a", 0.5, 1000), meta(run=1))
    store = lb.upsert(store, cfg("a", 0.9, 800), meta(run=2))
    assert len(store["rows"]) == 1
    row = next(iter(store["rows"].values()))
    assert row["score"]["mean_task_success"] == 0.9


def test_a_subset_or_smaller_k_run_never_replaces_the_full_set_row():
    # The defect: a --max-tasks 3 spot-check overwrote the config's real 24-task row.
    store = lb.upsert({}, cfg("m", 0.80, 900), meta(tasks_hash="FULL", k=5))
    store = lb.upsert(store, cfg("m", 1.00, 100), meta(tasks_hash="SUBSET", k=5))
    store = lb.upsert(store, cfg("m", 1.00, 100), meta(tasks_hash="FULL", k=3))
    assert len(store["rows"]) == 3
    full = store["rows"][f"m@{lb.cohort_key('FULL', 2, 5, 1.0)}"]
    assert full["score"]["mean_task_success"] == 0.80      # untouched by both
    data = lb.render_json(store)
    assert len(data["cohorts"]) == 3


def test_save_writes_v2_and_roundtrips_inf(tmp_path):
    store = lb.upsert({}, cfg("good", 0.8, 900, n_succ=8), meta())
    store = lb.upsert(store, cfg("dud", 0.0, 0, n_succ=0), meta())
    path = os.path.join(tmp_path, "lb.json")
    lb.save_store(path, store)
    raw = open(path, encoding="utf-8").read()
    assert "Infinity" not in raw
    assert json.loads(raw)["store_version"] == 2
    loaded = lb.load_store(path)
    rows = lb.render_json(loaded)["cohorts"][0]["rows"]
    dud = [r for r in rows if r["config_id"] == "dud"][0]
    assert dud["tokens_per_success"] is None          # inf sanitized on the way out


def test_load_store_missing_file_is_an_empty_v2_store(tmp_path):
    store = lb.load_store(os.path.join(tmp_path, "nope.json"))
    assert store == {"store_version": 2, "rows": {}}


def test_load_migrates_a_v1_store_in_memory(tmp_path):
    v1 = {"m/x": {"score": {"config_id": "m/x", "n_tasks": 2, "n_trials": 10,
                            "mean_task_success": 0.9, "mean_pass_hat_k": 0.8,
                            "total_cost": 1.0, "total_tokens": 100, "total_successes": 9,
                            "cost_per_success": 0.11, "tokens_per_success": 11.1,
                            "p95_latency_ms": 10.0, "safety_violations": 0},
                  "meta": {"tasks_hash": "AAA", "k": 5, "threshold": 1.0}}}
    path = os.path.join(tmp_path, "v1.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(v1, fh)
    store = lb.load_store(path)
    assert store["store_version"] == 2
    key = f"m/x@{lb.cohort_key('AAA', 1, 5, 1.0)}"
    assert key in store["rows"]
    assert store["rows"][key]["meta"]["hash_version"] == 1


def test_load_migrates_the_stored_leaderboard_file(tmp_path):
    # The real file on disk: 8 rows written before cohort identity existed. Migration
    # must load every one, key it by its own cohort, and mark its safety column as
    # "not evaluated (pre-v2)" rather than inventing a clean bill of health.
    src = json.load(open(STORED, encoding="utf-8"))
    path = os.path.join(tmp_path, "leaderboard.json")
    shutil.copy(STORED, path)
    store = lb.load_store(path)
    assert len(store["rows"]) == len(src) == 8
    assert all(r["meta"]["hash_version"] == 1 for r in store["rows"].values())
    data = lb.render_json(store)
    # one cohort per distinct (tasks_hash, k, threshold) the file records
    assert len(data["cohorts"]) == len({(v["meta"]["tasks_hash"], v["meta"]["k"],
                                         v["meta"]["threshold"]) for v in src.values()}) == 4
    md = lb.render_md(store)
    assert "n/e (pre-v2)" in md
    assert "hash v1, pre-fix" in md


def test_legacy_v1_rows_are_listed_but_never_ranked(tmp_path):
    # §7: a v1 digest hashed only part of the episode definition, so four rows sharing
    # one is not evidence they ran the same tasks. The 4-row 556b05bb cohort in the
    # tracked fixture used to render ranks 1-4 with normalized eff.
    path = os.path.join(tmp_path, "leaderboard.json")
    shutil.copy(STORED, path)
    store = lb.load_store(path)
    cohorts = lb.render_json(store)["cohorts"]
    biggest = max(cohorts, key=lambda c: len(c["rows"]))
    assert len(biggest["rows"]) == 4
    assert [row["rank"] for row in biggest["rows"]] == [None] * 4
    assert [row["efficiency_norm"] for row in biggest["rows"]] == [None] * 4
    md = lb.render_md(store)
    assert "never ranked" in md
    assert "| 1 |" not in md          # no head-to-head rank cell anywhere in a v1 board


def test_a_current_hash_cohort_is_still_ranked_head_to_head():
    store = lb.upsert({}, cfg("a", 0.9, 700), _meta_v2())
    store = lb.upsert(store, cfg("b", 0.5, 700), _meta_v2())
    rows = lb.render_json(store)["cohorts"][0]["rows"]
    assert [row["rank"] for row in rows] == [1, 2]
    assert all(row["efficiency_norm"] is not None for row in rows)


def _meta_v2() -> dict:
    return {"tasks_hash": "AAA", "hash_version": lb.CURRENT_HASH_VERSION,
            "k": 5, "threshold": 1.0}



def test_load_refuses_a_v1_row_without_a_task_set(tmp_path):
    path = os.path.join(tmp_path, "v1.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"m": {"score": {}, "meta": {"k": 5, "threshold": 1.0}}}, fh)
    with pytest.raises(ValueError):
        lb.load_store(path)


# --- rendering --------------------------------------------------------------

def test_render_json_has_no_global_rank_and_ranks_within_cohorts():
    store = lb.upsert({}, cfg("weak", 0.40, 300), meta(tasks_hash="AAA"))
    store = lb.upsert(store, cfg("strong", 0.95, 1200), meta(tasks_hash="AAA"))
    store = lb.upsert(store, cfg("other", 0.99, 200), meta(tasks_hash="BBB"))
    data = lb.render_json(store)
    assert "rank" not in data and "configs" not in data
    by_hash = {c["tasks_hash"]: c for c in data["cohorts"]}
    assert [r["config_id"] for r in by_hash["AAA"]["rows"]] == ["strong", "weak"]
    assert [r["rank"] for r in by_hash["AAA"]["rows"]] == [1, 2]
    assert by_hash["BBB"]["rows"][0]["rank"] == 1        # its own cohort, its own rank 1
    assert by_hash["AAA"]["k"] == 5 and by_hash["AAA"]["hash_version"] == 2


def test_render_json_normalizes_efficiency_per_cohort():
    # The lean config lives in ANOTHER cohort; it must not deflate this cohort's eff.
    store = lb.upsert({}, cfg("heavy", 1.0, 10000), meta(tasks_hash="AAA"))
    store = lb.upsert(store, cfg("heavier", 1.0, 20000), meta(tasks_hash="AAA"))
    store = lb.upsert(store, cfg("lean", 1.0, 100), meta(tasks_hash="BBB"))
    by_hash = {c["tasks_hash"]: c for c in lb.render_json(store)["cohorts"]}
    # Keyed by config, not by row position: with efficiency out of the composite, two
    # configs tying on success/pass^k order on config_id, so "heavier" sorts first.
    aaa = {r["config_id"]: r["efficiency_norm"] for r in by_hash["AAA"]["rows"]}
    assert aaa == {"heavy": pytest.approx(1.0), "heavier": pytest.approx(0.5)}
    assert by_hash["BBB"]["rows"][0]["efficiency_norm"] == pytest.approx(1.0)


def test_render_md_names_the_actual_k_per_cohort():
    store = lb.upsert({}, cfg("a", 0.9, 700), meta(tasks_hash="AAA", k=5))
    store = lb.upsert(store, cfg("b", 0.9, 700), meta(tasks_hash="BBB", k=3))
    md = lb.render_md(store)
    assert "pass^5" in md and "pass^3" in md
    assert "pass^k |" not in md            # never an unlabelled k


def test_render_md_labels_the_latency_statistic():
    store = lb.upsert({}, cfg("pooled", 0.9, 700, latency_stat="pooled_p95"),
                      meta(tasks_hash="AAA"))
    assert "p95 pooled" in lb.render_md(store)
    legacy = lb.upsert({}, cfg("old", 0.9, 700), meta(tasks_hash="BBB"))
    assert "max task p95" in lb.render_md(legacy)


def test_render_md_safety_column_states_the_denominator():
    clean = lb.upsert({}, cfg("clean", 0.9, 700, safety_trials_evaluated=40), meta())
    assert "✓ 40/40" in lb.render_md(clean)
    bad = lb.upsert({}, cfg("bad", 0.9, 700, safety_trials_evaluated=40,
                            safety_violations=3), meta())
    assert "✗ 3/40" in lb.render_md(bad)
    none_graded = lb.upsert({}, cfg("ungated", 0.9, 700, safety_trials_evaluated=0), meta())
    md = lb.render_md(none_graded)
    assert "| n/e |" in md and "✓" not in md.split("Lower tok")[0].split("| n/e |")[1]
    assert "not evaluated" in md


def test_render_md_never_renders_an_unevaluated_safety_result_as_a_pass():
    store = lb.upsert({}, cfg("ungated", 1.0, 700, safety_trials_evaluated=0), meta())
    row = [ln for ln in lb.render_md(store).splitlines() if "`ungated`" in ln][0]
    assert "n/e" in row and "✓" not in row


def test_render_md_distinguishes_unknown_cost_from_nothing_resolved():
    unpriced = lb.upsert({}, cfg("unpriced", 1.0, 700, cost_known=False), meta())
    assert "unknown (opik)" in lb.render_md(unpriced)
    nothing = lb.upsert({}, cfg("dud", 0.0, 0, n_succ=0, total_cost=1.0, cost_known=True), meta())
    md = lb.render_md(nothing)
    assert "| — |" in md
    assert "cleared no task" in md          # the footer says what — means


def test_render_md_does_not_claim_a_statistical_tie():
    store = lb.upsert({}, cfg("a", 0.9, 700, ci=(0.8, 1.0)), meta(tasks_hash="AAA"))
    store = lb.upsert(store, cfg("b", 0.8, 700, ci=(0.7, 0.9)), meta(tasks_hash="AAA"))
    md = lb.render_md(store)
    assert "statistical tie" not in md
    assert "not a paired test" in md


def test_render_md_single_task_ci_renders_n_equals_1():
    store = lb.upsert({}, cfg("solo", 1.0, 700, n_tasks=1, ci=(1.0, 1.0)), meta())
    md = lb.render_md(store)
    assert "n=1" in md
    assert "[1.00, 1.00]" not in md


def test_render_md_shows_a_real_ci_when_several_tasks_ran():
    store = lb.upsert({}, cfg("a", 0.90, 700, ci=(0.81, 0.97)), meta())
    assert "[0.81, 0.97]" in lb.render_md(store)


def test_render_md_empty_store():
    assert "no configs scored yet" in lb.render_md({"store_version": 2, "rows": {}})


def test_render_md_marks_a_lone_cohort_row_as_unranked():
    md = lb.render_md(lb.upsert({}, cfg("solo", 0.95, 800), meta()))
    assert "| · |" in md                     # not a head-to-head rank
    assert "1 config" in md


def test_render_md_orders_cohorts_by_size():
    store = lb.upsert({}, cfg("solo", 1.0, 100), meta(tasks_hash="BBB"))
    store = lb.upsert(store, cfg("a", 0.9, 700), meta(tasks_hash="AAA"))
    store = lb.upsert(store, cfg("b", 0.8, 700), meta(tasks_hash="AAA"))
    md = lb.render_md(store)
    assert md.index("`a`") < md.index("`solo`")


def test_render_json_reports_the_new_columns():
    store = lb.upsert({}, cfg("a", 0.9, 700, mean_pass_at_1=0.85, n_invalid_trials=2,
                              ci_resampled="families", n_families=3), meta())
    row = lb.render_json(store)["cohorts"][0]["rows"][0]
    assert row["mean_pass_at_1"] == 0.85
    assert row["n_invalid_trials"] == 2
    assert row["ci_resampled"] == "families" and row["n_families"] == 3


def test_a_hand_edited_row_key_or_meta_is_refused_loudly():
    with pytest.raises(ValueError):
        lb.render_json({"store_version": 2, "rows": {"no-cohort-here": {"score": {}, "meta": {}}}})
    good_key = f"m@{lb.cohort_key('AAA', 2, 5, 1.0)}"
    thin = {"store_version": 2,
            "rows": {good_key: {"score": {}, "meta": {"tasks_hash": "AAA", "k": 5}}}}
    with pytest.raises(ValueError):
        lb.render_json(thin)



# --- store schema: a new column must never break the WHOLE store ------------

def _carded(*, basis="ceiling", cost=2.5, routes=None, card="TESTCARD"):
    return {"priced_cost_usd": cost, "pricing_basis": basis,
            "pricing_card_version": card, "unpriced_routes": routes,
            "spans_without_usage": 2, "total_input_tokens": 9000,
            "total_output_tokens": 1000, "total_cached_input_tokens": 4000,
            "total_cache_write_tokens": 500}


def test_every_configscore_field_a_v1_row_omits_carries_a_default():
    # `_config_from_dict` is `ConfigScore(**row)`. A field added without a default
    # raises TypeError on every legacy row at once, so the board stops loading rather
    # than losing one row. This asserts the invariant against the real stored file.
    stored = json.load(open(STORED, encoding="utf-8"))
    v1_keys = set().union(*(set(row["score"]) for row in stored.values()))
    required = {f.name for f in dataclasses.fields(ConfigScore)
                if f.default is dataclasses.MISSING
                and f.default_factory is dataclasses.MISSING}
    assert required <= v1_keys, f"no default for {sorted(required - v1_keys)}"


def test_the_tracked_v1_store_survives_a_save_load_roundtrip(tmp_path):
    # Migrate in memory -> save as v2 -> load again. The second load reads rows the
    # CURRENT dataclass wrote, which is the shape a future field lands in.
    path = os.path.join(tmp_path, "leaderboard.json")
    shutil.copy(STORED, path)
    lb.save_store(path, lb.load_store(path))
    reloaded = lb.load_store(path)
    assert reloaded["store_version"] == 2 and len(reloaded["rows"]) == 8
    assert len(lb.render_json(reloaded)["cohorts"]) == 4
    assert "n/e (pre-v2)" in lb.render_md(reloaded)


def test_a_rate_carded_row_roundtrips_every_pricing_column(tmp_path):
    store = lb.upsert({}, cfg("carded", 1.0, 700, **_carded(cost=2.5)), meta())
    path = os.path.join(tmp_path, "lb.json")
    lb.save_store(path, store)
    row = lb.render_json(lb.load_store(path))["cohorts"][0]["rows"][0]
    assert row["pricing_basis"] == "ceiling"
    assert row["pricing_card_version"] == "TESTCARD"
    assert row["priced_cost_per_success"] == pytest.approx(0.25)   # 2.50 / 10 successes
    assert row["total_input_tokens"] == 9000 and row["total_output_tokens"] == 1000
    assert row["total_cached_input_tokens"] == 4000
    assert row["total_cache_write_tokens"] == 500
    assert row["spans_without_usage"] == 2
    assert row["unpriced_routes"] == []


# --- the pricing basis reaches the comparison -------------------------------

def test_pricing_basis_stays_out_of_cohort_identity():
    # A cohort is the measurement identity of the SCORE, and the score is capability
    # only. Splitting a cohort on how its dollars were computed would un-rank a real
    # head-to-head capability comparison over a column reported beside it.
    store = lb.upsert({}, cfg("carded", 0.9, 700, **_carded()), _meta_v2())
    store = lb.upsert(store, cfg("legacy", 0.5, 700, total_cost=3.0, cost_known=True),
                      _meta_v2())
    data = lb.render_json(store)
    assert len(data["cohorts"]) == 1
    assert [r["rank"] for r in data["cohorts"][0]["rows"]] == [1, 2]


def test_two_dollar_figures_on_different_bases_never_look_alike():
    # Today's store: gpt-5.5/xhigh carries an Opik-metered $0.3745/success. A rate-carded
    # row landing beside it must not be readable as the same kind of number.
    store = lb.upsert({}, cfg("carded", 0.9, 700, **_carded(cost=2.5)), _meta_v2())
    store = lb.upsert(store, cfg("opik", 0.5, 700, total_cost=3.7445, cost_known=True),
                      _meta_v2())
    md = lb.render_md(store)
    assert "$0.2500 ceiling" in md
    assert "$0.3745 opik" in md
    assert "mixes 2 pricing bases" in md


def test_two_rate_cards_in_one_cohort_are_flagged_even_on_the_same_basis():
    # A rate edit makes two `ceiling` figures non-comparable too. The cell suffix cannot
    # show it (both read "ceiling"), so the stored card version has to.
    store = lb.upsert({}, cfg("july", 0.9, 700, **_carded(card="2026-07-01")), _meta_v2())
    store = lb.upsert(store, cfg("today", 0.5, 700, **_carded(card="2026-09-05")),
                      _meta_v2())
    md = lb.render_md(store)
    assert "mixes 2 pricing bases" in md
    assert "ceiling@2026-07-01, ceiling@2026-09-05" in md


def test_a_single_basis_cohort_carries_no_mixed_basis_warning():
    store = lb.upsert({}, cfg("a", 0.9, 700, **_carded()), _meta_v2())
    store = lb.upsert(store, cfg("b", 0.5, 700, **_carded(cost=1.0)), _meta_v2())
    assert "mixes" not in lb.render_md(store)


# --- the cost axis reads the rate card, or reports nothing -------------------

def _eff_of(config_id: str, md: str) -> str:
    # TABLE rows only: the preamble and footer name config ids and bases in prose too.
    row = [ln for ln in md.splitlines()
           if ln.startswith("|") and f"`{config_id}`" in ln][0]
    return row.split("|")[-5].strip()          # ... | eff | tok/✓ | $/✓ | latency |


def test_the_cost_axis_normalizes_the_rate_card_not_the_opik_column():
    # Opik and the card disagree ON PURPOSE: `cheap` is Opik-expensive ($1.00/✓) and
    # card-cheap ($0.01/✓), `pricey` the reverse. An eff that still read Opik's column
    # would invert both numbers below.
    store = lb.upsert({}, cfg("cheap", 0.9, 700, total_cost=10.0,
                              **_carded(cost=0.10)), _meta_v2())
    store = lb.upsert(store, cfg("pricey", 0.9, 700, total_cost=0.10,
                                 **_carded(cost=10.0)), _meta_v2())
    rows = {r["config_id"]: r for r in lb.render_json(store, axis="cost")["cohorts"][0]["rows"]}
    assert rows["cheap"]["efficiency_norm"] == pytest.approx(1.0)
    assert rows["pricey"]["efficiency_norm"] == pytest.approx(0.01)


def test_the_cost_axis_prices_a_row_whose_slug_opik_reported_as_zero():
    # The original defect, end to end: 5 of the 8 live rows read $0 because Opik's
    # auto-cost keys on the MODEL SLUG. On the card they price normally.
    store = lb.upsert({}, cfg("sol", 0.9, 700, total_cost=0.0,
                              **_carded(cost=0.50)), _meta_v2())
    store = lb.upsert(store, cfg("mini", 0.9, 700, total_cost=3.0,
                                 **_carded(cost=1.00)), _meta_v2())
    md = lb.render_md(store, axis="cost")
    assert _eff_of("sol", md) == "1.00"        # was 0.00 while eff read Opik's $0
    assert _eff_of("mini", md) == "0.50"


def test_the_cost_axis_withholds_eff_when_a_cohort_mixes_pricing_bases():
    store = lb.upsert({}, cfg("carded", 0.9, 700, **_carded(cost=2.5)), _meta_v2())
    store = lb.upsert(store, cfg("opik", 0.5, 700, total_cost=3.7445, cost_known=True),
                      _meta_v2())
    data = lb.render_json(store, axis="cost")
    assert [r["efficiency_norm"] for r in data["cohorts"][0]["rows"]] == [None, None]
    md = lb.render_md(store, axis="cost")
    assert _eff_of("carded", md) == "—" and _eff_of("opik", md) == "—"
    assert [r["rank"] for r in data["cohorts"][0]["rows"]] == [1, 2]   # rank is untouched


def test_the_tokens_axis_still_shows_eff_for_a_mixed_basis_cohort():
    store = lb.upsert({}, cfg("carded", 0.9, 700, **_carded(cost=2.5)), _meta_v2())
    store = lb.upsert(store, cfg("opik", 0.9, 1400, total_cost=3.7445), _meta_v2())
    rows = {r["config_id"]: r for r in lb.render_json(store)["cohorts"][0]["rows"]}
    assert rows["carded"]["efficiency_norm"] == pytest.approx(1.0)
    assert rows["opik"]["efficiency_norm"] == pytest.approx(0.5)


def test_the_cost_axis_preamble_names_the_rate_card_never_opik():
    md = lb.render_md(lb.upsert({}, cfg("a", 0.9, 700, **_carded()), _meta_v2()),
                      axis="cost")
    eff_para = [ln for ln in md.splitlines() if ln.startswith("**`eff` is RELATIVE")][0]
    assert "rate card" in eff_para.lower()
    assert "opik cost column" not in eff_para.lower()


def test_the_opik_cost_column_keeps_its_own_identity_beside_the_card():
    # Both columns ship, and neither is ever written from the other: the Opik figure is
    # the quantity the declared `max_cost_usd` gates read.
    store = lb.upsert({}, cfg("both", 0.9, 700, total_cost=5.0, **_carded(cost=2.5)),
                      _meta_v2())
    row = lb.render_json(store, axis="cost")["cohorts"][0]["rows"][0]
    assert row["cost_per_success"] == pytest.approx(0.50)          # Opik: 5.0 / 10
    assert row["priced_cost_per_success"] == pytest.approx(0.25)   # card: 2.5 / 10


# --- the cost cell: four carded states, plus the pre-card Opik one ----------

def _cell(config_id: str, md: str) -> str:
    # TABLE rows only: the preamble and footer name bases in backticked prose too.
    row = [ln for ln in md.splitlines()
           if ln.startswith("|") and f"`{config_id}`" in ln][0]
    return row.split("|")[-3].strip()          # ... | $/✓ | latency |


def test_cost_cell_names_the_basis_of_every_carded_price():
    ceiling = lb.upsert({}, cfg("ceil", 1.0, 700, **_carded(cost=2.5)), meta())
    assert _cell("ceil", lb.render_md(ceiling)) == "$0.2500 ceiling"
    aware = lb.upsert({}, cfg("aware", 1.0, 700,
                              **_carded(basis="cache_aware", cost=1.0)), meta())
    assert _cell("aware", lb.render_md(aware)) == "$0.1000 cache-aware"


def test_cost_cell_says_not_token_billed_for_a_local_route():
    store = lb.upsert({}, cfg("ollama", 1.0, 700,
                              **_carded(basis="not_token_billed", cost=None)), meta())
    md = lb.render_md(store)
    assert _cell("ollama", md) == "not token billed"
    assert "$" not in _cell("ollama", md)
    assert "never token-billed" in md          # the footer explains the reading


def test_cost_cell_names_the_route_missing_from_the_card():
    store = lb.upsert({}, cfg("gap", 1.0, 700,
                              **_carded(basis="unpriced", cost=None,
                                        routes=["openai_codex/gpt-5.6-sol"])), meta())
    cell = _cell("gap", lb.render_md(store))
    assert cell == "unpriced — no card entry for openai_codex/gpt-5.6-sol"


def test_cost_cell_truncates_a_long_unpriced_route_list_but_states_the_count():
    routes = ["openai/a", "openai/b", "openai/c", "openai/d"]
    store = lb.upsert({}, cfg("many", 1.0, 700,
                              **_carded(basis="unpriced", cost=None, routes=routes)), meta())
    cell = _cell("many", lb.render_md(store))
    assert cell == "unpriced — no card entry for openai/a, openai/b (+2 more)"


def test_a_legacy_row_never_starts_showing_a_computed_price():
    # Every live row has cost_known None and an Opik cost of $0 for an unpriced slug.
    # It has no rate-card basis, so it must keep reading as Opik's unknown — never
    # borrow the card's number or the card's wording.
    store = lb.upsert({}, cfg("legacy", 1.0, 700, total_cost=0.0), meta())
    md = lb.render_md(store)
    assert _cell("legacy", md) == "unknown (opik)"
    assert "ceiling" not in _cell("legacy", md)


def test_a_carded_row_that_cleared_nothing_reads_as_no_success_not_as_free():
    store = lb.upsert({}, cfg("dud", 0.0, 0, n_succ=0, **_carded(cost=2.5)), meta())
    assert _cell("dud", lb.render_md(store)) == "—"
    partial = lb.upsert({}, cfg("part", 0.4, 0, n_succ=0, **_carded(cost=2.5)), meta())
    assert _cell("part", lb.render_md(partial)) == "n/a"


def test_an_unknown_pricing_basis_is_refused_loudly():
    store = lb.upsert({}, cfg("weird", 1.0, 700,
                              **_carded(basis="cheap", cost=2.5)), meta())
    with pytest.raises(ValueError):
        lb.render_md(store)


# --- header: the score block and the reported-beside block ------------------

def test_the_header_separates_the_score_from_the_decision_inputs():
    md = lb.render_md(lb.upsert({}, cfg("a", 0.9, 700, **_carded()), meta()))
    header = [ln for ln in md.splitlines() if ln.startswith("| # |")][0]
    cells = [c.strip() for c in header.strip("|").split("|")]
    divider = cells.index(lb.COLUMN_DIVIDER)
    score = cells[:divider]
    beside = cells[divider + 1:]
    assert {"success", "pass@1", "95% CI", "pass^5", "safety", "composite"} <= set(score)
    assert {"eff", "tok/✓", "$/✓"} <= set(beside)
    assert not {"eff", "tok/✓", "$/✓"} & set(score)
    assert "reported BESIDE" in md
    # every data row carries the divider in the same column
    row = [ln for ln in md.splitlines() if "`a`" in ln][0]
    assert [c.strip() for c in row.strip("|").split("|")][divider] == lb.COLUMN_DIVIDER


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
