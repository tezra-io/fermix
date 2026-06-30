#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6,<7", "pytest>=8"]
# ///
"""Unit tests for the capability-scoring layer.

Covers `evallib.scoring` (ground-truth answer scorers) and the suite `score:`
block validation in `evallib.suites`. These are the pure, closed-form scorers the
capability tier uses for objective task success (open-ended tasks fall back to the
LLM judge). Run: `uv run bin/test_scoring.py`.
"""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

from evallib import scoring, suites  # noqa: E402


# --- exact ------------------------------------------------------------------

def test_exact_matches_ignoring_case_and_whitespace():
    assert scoring.score_answer("  Paris ", {"match": "exact", "expected": "paris"}).score == 1.0
    assert scoring.score_answer("PostgreSQL", {"match": "exact", "expected": "postgresql"}).score == 1.0


def test_exact_mismatch_is_zero():
    assert scoring.score_answer("Cassandra", {"match": "exact", "expected": "Postgres"}).score == 0.0


# --- numeric ----------------------------------------------------------------

def test_numeric_extracts_number_from_prose():
    assert scoring.score_answer("The answer is 42.", {"match": "numeric", "expected": 42}).score == 1.0
    assert scoring.score_answer("1,234 widgets", {"match": "numeric", "expected": 1234}).score == 1.0


def test_numeric_tolerance():
    spec = {"match": "numeric", "expected": 3.14159, "tolerance": 0.01}
    assert scoring.score_answer("3.1416", spec).score == 1.0
    assert scoring.score_answer("3.20", spec).score == 0.0


def test_numeric_no_number_in_reply_is_zero():
    assert scoring.score_answer("no idea", {"match": "numeric", "expected": 5}).score == 0.0


def test_numeric_uses_last_number_after_cot():
    # CoT preamble: first number is a premise (6), the answer is the last (65).
    reply = "We have 6 shelves, each holds 12, plus 5 on top. Total: 65"
    assert scoring.score_answer(reply, {"match": "numeric", "expected": 65}).score == 1.0
    # the old first-number behavior would have wrongly read 6
    assert scoring.score_answer(reply, {"match": "numeric", "expected": 6}).score == 0.0


# --- contains ---------------------------------------------------------------

def test_contains_is_case_insensitive_substring():
    s = scoring.score_answer("I'd recommend PostgreSQL for this.", {"match": "contains", "expected": "postgres"})
    assert s.score == 1.0
    assert scoring.score_answer("Use Redis.", {"match": "contains", "expected": "postgres"}).score == 0.0


# --- regex ------------------------------------------------------------------

def test_regex_search():
    assert scoring.score_answer("ship it on 2026-06-28", {"match": "regex", "expected": r"\d{4}-\d{2}-\d{2}"}).score == 1.0
    assert scoring.score_answer("no date here", {"match": "regex", "expected": r"\d{4}-\d{2}-\d{2}"}).score == 0.0


# --- f1 (short-answer / list overlap) ---------------------------------------

def test_f1_full_overlap_is_one():
    assert scoring.score_answer("alpha beta gamma", {"match": "f1", "expected": "gamma alpha beta"}).score == 1.0


def test_f1_partial_overlap_is_between():
    s = scoring.score_answer("alpha beta", {"match": "f1", "expected": ["alpha", "beta", "gamma"]}).score
    assert 0.0 < s < 1.0


def test_f1_no_overlap_is_zero():
    assert scoring.score_answer("delta", {"match": "f1", "expected": "alpha beta"}).score == 0.0


# --- method dispatch + detail -----------------------------------------------

def test_unknown_method_raises():
    with pytest.raises(ValueError):
        scoring.score_answer("x", {"match": "bogus", "expected": "x"})


def test_score_carries_method_and_detail():
    s = scoring.score_answer("Paris", {"match": "exact", "expected": "Paris"})
    assert s.method == "exact"
    assert isinstance(s.detail, str) and s.detail


# --- suite `score:` block validation ----------------------------------------

def test_valid_score_block_passes_validation():
    problems: list[str] = []
    suites._validate_score({"match": "numeric", "expected": 42, "tolerance": 0.5}, "x", problems)
    assert problems == []


def test_score_block_requires_known_match():
    problems: list[str] = []
    suites._validate_score({"match": "nope", "expected": 1}, "x", problems)
    assert any("match" in p for p in problems)


def test_score_block_requires_expected():
    problems: list[str] = []
    suites._validate_score({"match": "exact"}, "x", problems)
    assert any("expected" in p for p in problems)


def test_tolerance_only_valid_for_numeric():
    problems: list[str] = []
    suites._validate_score({"match": "exact", "expected": "x", "tolerance": 0.1}, "x", problems)
    assert any("tolerance" in p for p in problems)


def test_score_block_rejects_unknown_key():
    problems: list[str] = []
    # a `tolernce` typo would otherwise be silently ignored -> scorer uses tolerance=0
    suites._validate_score({"match": "numeric", "expected": 5, "tolernce": 0.1}, "x", problems)
    assert any("tolernce" in p for p in problems)


def test_numeric_expected_must_parse_as_number():
    problems: list[str] = []
    # would validate clean then score 0.0 forever at runtime
    suites._validate_score({"match": "numeric", "expected": "Canberra"}, "x", problems)
    assert any("number" in p for p in problems)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
