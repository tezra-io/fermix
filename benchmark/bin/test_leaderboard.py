#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8"]
# ///
"""Unit tests for evallib.leaderboard (store + render). Pure; uses a tmp dir for
the save/load round-trip. Run: `uv run bin/test_leaderboard.py`."""
from __future__ import annotations

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

from evallib import leaderboard as lb  # noqa: E402
from evallib.aggregate import ConfigScore  # noqa: E402


def cfg(config_id, success, tok_per_success, n_succ=10, ci=None):
    total_tokens = int(tok_per_success * n_succ) if n_succ else 0
    return ConfigScore(
        config_id=config_id, n_tasks=5, n_trials=10,
        mean_task_success=success, mean_pass_hat_k=success * 0.9,
        total_cost=0.0, total_tokens=total_tokens, total_successes=n_succ,
        cost_per_success=math.inf, tokens_per_success=(total_tokens / n_succ if n_succ else math.inf),
        p95_latency_ms=1500.0, safety_violations=0,
        mean_task_success_ci_lo=(ci[0] if ci else None),
        mean_task_success_ci_hi=(ci[1] if ci else None))


def test_upsert_keeps_latest_per_config():
    store = {}
    store = lb.upsert(store, cfg("a", 0.5, 1000), {"run": 1})
    store = lb.upsert(store, cfg("a", 0.9, 800), {"run": 2})   # same config -> overwrite
    store = lb.upsert(store, cfg("b", 0.7, 500), {"run": 1})
    assert set(store) == {"a", "b"}
    assert store["a"]["score"]["mean_task_success"] == 0.9


def test_ranked_orders_by_composite():
    store = {}
    store = lb.upsert(store, cfg("strong", 0.95, 1200), {})
    store = lb.upsert(store, cfg("weak", 0.40, 300), {})
    r = lb.ranked(store)
    assert [x.config.config_id for x in r] == ["strong", "weak"]


def test_save_load_roundtrip_with_inf(tmp_path):
    store = {}
    store = lb.upsert(store, cfg("good", 0.8, 900, n_succ=8), {})
    store = lb.upsert(store, cfg("dud", 0.0, 0, n_succ=0), {})   # resolved nothing -> inf
    path = os.path.join(tmp_path, "lb.json")
    lb.save_store(path, store)
    # serialized JSON must be valid (no Infinity tokens)
    raw = open(path, encoding="utf-8").read()
    assert "Infinity" not in raw
    loaded = lb.load_store(path)
    r = lb.ranked(loaded)
    # the dud (no successes) recomputes to inf tokens/success and ranks last
    assert r[-1].config.config_id == "dud"
    assert math.isinf(r[-1].config.tokens_per_success)


def test_render_md_lists_configs_in_rank_order():
    store = {}
    store = lb.upsert(store, cfg("alpha", 0.9, 700), {})
    store = lb.upsert(store, cfg("beta", 0.6, 600), {})
    md = lb.render_md(store)
    assert "capability leaderboard" in md
    assert md.index("alpha") < md.index("beta")     # alpha ranks first
    assert "pass^k" in md


def test_render_json_sanitizes_inf():
    store = lb.upsert({}, cfg("dud", 0.0, 0, n_succ=0), {})
    j = lb.render_json(store)
    assert j["configs"][0]["tokens_per_success"] is None


def test_render_md_empty_store():
    md = lb.render_md({})
    assert "no configs scored yet" in md


def test_render_md_shows_success_ci_when_present():
    store = lb.upsert({}, cfg("a", 0.90, 700, ci=(0.81, 0.97)), {"tasks_hash": "AAA"})
    md = lb.render_md(store)
    assert "95% CI" in md                 # column header
    assert "[0.81, 0.97]" in md           # the interval cell


def test_render_md_ci_dash_when_absent_does_not_crash():
    # A row scored before the CI existed renders "—" in the CI cell, never a bracket.
    store = lb.upsert({}, cfg("a", 0.90, 700), {"tasks_hash": "AAA"})
    md = lb.render_md(store)
    assert "95% CI" in md
    assert "[0." not in md


def test_render_json_includes_ci():
    store = lb.upsert({}, cfg("a", 0.9, 700, ci=(0.8, 0.98)), {})
    j = lb.render_json(store)
    assert j["configs"][0]["mean_task_success_ci"] == [0.8, 0.98]


def test_ci_survives_save_load_roundtrip(tmp_path):
    store = lb.upsert({}, cfg("a", 0.9, 700, ci=(0.82, 0.96)), {})
    path = os.path.join(tmp_path, "lb.json")
    lb.save_store(path, store)
    j = lb.render_json(lb.load_store(path))
    assert j["configs"][0]["mean_task_success_ci"] == [0.82, 0.96]


def test_render_md_flags_non_comparable_task_set():
    # Two configs ran the SAME 27-task set (hash AAA); a third ran a cherry-picked
    # subset (hash BBB). The subset must be segregated as NOT comparable, not
    # ranked head-to-head above the full-set rows.
    store = {}
    store = lb.upsert(store, cfg("full-a", 0.90, 700), {"tasks_hash": "AAA", "tasks": 27})
    store = lb.upsert(store, cfg("full-b", 0.85, 900), {"tasks_hash": "AAA", "tasks": 27})
    store = lb.upsert(store, cfg("subset", 0.98, 300), {"tasks_hash": "BBB", "tasks": 5})
    md = lb.render_md(store)
    assert "NOT comparable" in md
    # the high-scoring subset row must sit in the flagged section, below the board
    # (match the backticked config id so the word "subset" in the preamble prose
    # doesn't create a false earlier hit)
    assert md.index("`full-a`") < md.index("NOT comparable")
    assert md.index("NOT comparable") < md.index("`subset`")
    # comparable cohort is the modal (AAA) set of 2 configs
    assert "Comparable set `AAA`" in md and "2 config(s)" in md


def test_render_md_all_same_task_set_no_warning():
    store = {}
    store = lb.upsert(store, cfg("a", 0.9, 700), {"tasks_hash": "AAA"})
    store = lb.upsert(store, cfg("b", 0.6, 600), {"tasks_hash": "AAA"})
    md = lb.render_md(store)
    assert "NOT comparable" not in md
    assert md.index("a") < md.index("b")


def test_render_md_all_distinct_task_sets_shows_all_with_full_metrics():
    # The real-world case: every config ran its OWN task set (distinct hashes). None is
    # head-to-head, so don't anoint one arbitrary config as "the board" and strip the
    # rest to a 5-col stub — show all three with full metrics, ordered by success.
    store = {}
    store = lb.upsert(store, cfg("m-a", 0.99, 650), {"tasks_hash": "AAA"})
    store = lb.upsert(store, cfg("m-b", 1.00, 700), {"tasks_hash": "BBB"})
    store = lb.upsert(store, cfg("m-c", 0.90, 720), {"tasks_hash": "CCC"})
    md = lb.render_md(store)
    assert "No two configs share a task set" in md          # the all-solo banner
    assert "NOT comparable" in md
    assert "Comparable set" not in md                        # nothing anointed as the board
    # all three present, ordered by success (m-b 1.00 > m-a 0.99 > m-c 0.90)
    assert md.index("`m-b`") < md.index("`m-a`") < md.index("`m-c`")
    # full metrics (not the old 5-col stub): tok/✓ values + the non-rank marker show
    assert "| · |" in md and "700" in md and "650" in md


def test_render_md_cohort_plus_solo_ranks_cohort_shows_solo_full():
    # A genuine cohort (>=2 share a set) still ranks head-to-head; a lone different-set
    # config sits below with FULL metrics (its tok/✓ visible), not the 5-col stub.
    store = {}
    store = lb.upsert(store, cfg("full-a", 0.90, 700), {"tasks_hash": "AAA"})
    store = lb.upsert(store, cfg("full-b", 0.85, 900), {"tasks_hash": "AAA"})
    store = lb.upsert(store, cfg("lone", 0.98, 333), {"tasks_hash": "BBB"})
    md = lb.render_md(store)
    assert "Comparable set `AAA`" in md and "2 config(s)" in md
    assert md.index("`full-a`") < md.index("NOT comparable") < md.index("`lone`")
    assert "333" in md            # the solo's tok/✓ is shown (full metrics, not a stub)


def test_render_md_single_config_ranks_as_one():
    store = lb.upsert({}, cfg("solo", 0.95, 800), {"tasks_hash": "AAA"})
    md = lb.render_md(store)
    assert "Single config" in md
    assert "NOT comparable" not in md and "| 1 |" in md


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
