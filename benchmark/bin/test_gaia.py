#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7"]
# ///
"""Tests for the GAIA runner's pure core (bin/run_gaia.py): final-answer
extraction, GAIA-style quasi-exact-match scoring, dataset parsing, and the HF
submission format. Driving Fermix + the gated dataset are operator-gated.
Run: `uv run bin/test_gaia.py`."""
from __future__ import annotations

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

import run_gaia  # noqa: E402


# --- final-answer extraction ------------------------------------------------

def test_extract_after_marker():
    assert run_gaia.extract_final_answer("reasoning...\nFINAL ANSWER: Paris") == "Paris"
    assert run_gaia.extract_final_answer("FINAL ANSWER:  42  ") == "42"


def test_extract_case_insensitive():
    assert run_gaia.extract_final_answer("final answer: Canberra") == "Canberra"


def test_extract_no_marker_returns_whole():
    assert run_gaia.extract_final_answer("just Paris") == "just Paris"


# --- GAIA scoring -----------------------------------------------------------

def test_score_number():
    assert run_gaia.gaia_score("FINAL ANSWER: 42", "42")
    assert run_gaia.gaia_score("FINAL ANSWER: 1,234", "1234")
    assert not run_gaia.gaia_score("FINAL ANSWER: 43", "42")


def test_score_string_normalized():
    assert run_gaia.gaia_score("FINAL ANSWER: Paris.", "paris")
    assert not run_gaia.gaia_score("FINAL ANSWER: London", "Paris")


def test_score_list_ordered():
    assert run_gaia.gaia_score("FINAL ANSWER: apple, banana, cherry", "apple, banana, cherry")
    assert not run_gaia.gaia_score("FINAL ANSWER: banana, apple, cherry", "apple, banana, cherry")


def test_score_parity_with_official_gating():
    # A comma in the gold forces the LIST path even for "1,234": "1234" must FAIL.
    assert run_gaia.gaia_score("FINAL ANSWER: 1,234", "1,234")
    assert not run_gaia.gaia_score("FINAL ANSWER: 1234", "1,234")
    # "1,2,3" is a 3-element list, not the scalar 123.
    assert run_gaia.gaia_score("FINAL ANSWER: 1, 2, 3", "1,2,3")
    assert not run_gaia.gaia_score("FINAL ANSWER: 123", "1,2,3")
    # "$5" / "50%" are strings (bare float() raises) -> punctuation-stripped compare.
    assert run_gaia.gaia_score("FINAL ANSWER: 5", "$5")
    assert run_gaia.gaia_score("FINAL ANSWER: 50", "50%")


def test_score_string_removes_all_whitespace():
    # GAIA's documented "seagull" == "sea gull" (all whitespace removed, not collapsed).
    assert run_gaia.gaia_score("FINAL ANSWER: seagull", "sea gull")


def test_score_plain_number_still_works():
    assert run_gaia.gaia_score("FINAL ANSWER: 3.14", "3.14")
    assert not run_gaia.gaia_score("FINAL ANSWER: 3.15", "3.14")


# --- dataset parsing --------------------------------------------------------

def test_load_gaia_tolerates_field_variants(tmp_path):
    p = tmp_path / "gaia.jsonl"
    p.write_text(
        json.dumps({"task_id": "1", "Question": "Q1?", "Final answer": "A1", "Level": 1}) + "\n"
        + json.dumps({"task_id": "2", "question": "Q2?", "answer": "A2", "level": 2}) + "\n",
        encoding="utf-8",
    )
    items = run_gaia.load_gaia(str(p))
    assert len(items) == 2
    assert items[0]["question"] == "Q1?" and items[0]["answer"] == "A1" and items[0]["level"] == 1
    assert items[1]["question"] == "Q2?" and items[1]["answer"] == "A2"


def test_load_gaia_handles_missing_gold(tmp_path):
    p = tmp_path / "test.jsonl"
    p.write_text(json.dumps({"task_id": "9", "Question": "Q?", "Level": 3}) + "\n", encoding="utf-8")
    items = run_gaia.load_gaia(str(p))
    assert items[0]["answer"] is None        # test split has no gold


# --- submission format ------------------------------------------------------

def test_submission_row_shape():
    row = run_gaia.submission_row("task-7", "FINAL ANSWER: 42", "my reasoning")
    assert row == {"task_id": "task-7", "model_answer": "42", "reasoning_trace": "my reasoning"}


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
