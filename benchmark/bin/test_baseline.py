#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7"]
# ///
"""Unit tests for the raw-model baseline runner core (bin/run_baseline.py).

The HTTP call is injected (chat_fn), so the per-task scoring/aggregation is tested
without a key or network. Run: `uv run bin/test_baseline.py`."""
from __future__ import annotations

import os
import sys
from types import SimpleNamespace

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

import run_baseline  # noqa: E402


def _case(cid, query, spec):
    return SimpleNamespace(id=cid, turns=[SimpleNamespace(query=query)], score_spec=spec)


def test_score_case_correct_answer():
    case = _case("add", "What is 2+2? Reply with only the number.", {"match": "numeric", "expected": 4})
    st = run_baseline.score_case(case, trials=2, k=2, threshold=1.0, chat=lambda q: ("The answer is 4.", 50))
    assert st.mean_success == 1.0
    assert st.pass_hat_k == 1.0
    assert st.mean_tokens == 50


def test_score_case_wrong_answer():
    case = _case("cap", "Capital of France?", {"match": "contains", "expected": "Paris"})
    st = run_baseline.score_case(case, trials=2, k=2, threshold=1.0, chat=lambda q: ("London", 10))
    assert st.mean_success == 0.0


def test_score_case_api_error_scores_zero():
    def boom(q):
        raise run_baseline.BaselineError("503")
    case = _case("x", "q", {"match": "exact", "expected": "y"})
    st = run_baseline.score_case(case, trials=2, k=2, threshold=1.0, chat=boom)
    assert st.mean_success == 0.0
    assert st.n_trials == 2


def test_score_case_drives_trials_not_k():
    # With --trials 5 --k 3 the baseline must make 5 calls (sample size = trials),
    # matching the Fermix arm; k is only the pass^k bar. (The old bug looped on k.)
    case = _case("x", "q", {"match": "exact", "expected": "y"})
    calls = {"n": 0}

    def counting_chat(q):
        calls["n"] += 1
        return "y", 1
    st = run_baseline.score_case(case, trials=5, k=3, threshold=1.0, chat=counting_chat)
    assert calls["n"] == 5
    assert st.n_trials == 5
    assert st.k == 3


def test_baseline_cases_only_closed_form():
    scored = SimpleNamespace(id="s", score_spec={"match": "exact", "expected": "a"}, rubric=None)
    rubric_only = SimpleNamespace(id="r", score_spec=None, rubric="judge me")
    scn = SimpleNamespace(id="scn", tags=["capability"], cases=[scored, rubric_only])
    suite = SimpleNamespace(name="cap", scenarios=[scn])
    out = run_baseline.baseline_cases([suite], None, None, None)
    assert [c.id for _s, _scn, c in out] == ["s"]   # rubric-only excluded (no judge in baseline)


def test_make_chat_builds_callable():
    chat = run_baseline.make_chat("http://x/v1", "k", "m")
    assert callable(chat)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
