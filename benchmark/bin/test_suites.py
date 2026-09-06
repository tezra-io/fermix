#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7", "certifi"]
# ///
"""Specs for the suite schema keys that make a measurement trustworthy: sticky
safety gates, the all-of tool-provenance key, the per-trial checker reset list,
single-number scoring, and the refusal of undriven multi-turn capability cases.
Also covers the shared session-id helper. Pure: no daemon, no Opik, no spend.
Run: `uv run bin/test_suites.py`."""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402
import yaml  # noqa: E402

import run_eval  # noqa: E402
from evallib import session_ids, suites  # noqa: E402

SUITES_DIR = os.path.join(os.path.dirname(HERE), "suites")
CAP_DIR = os.path.join(SUITES_DIR, "capability")

BASE_CASE = {"id": "case_a", "query": "first phrasing"}
FILLER_CASE = {"id": "case_b", "query": "second phrasing"}


def _write_suite(tmp_path, scenario: dict | None = None, cases: list | None = None) -> str:
    """Write one minimal valid suite into `tmp_path` and return the directory."""
    doc = {
        "suite": "spec_suite",
        "title": "Spec suite",
        "risk": "host_readonly",
        "scenarios": [{
            "id": "scn",
            "title": "Scenario",
            "cases": cases if cases is not None else [dict(BASE_CASE), dict(FILLER_CASE)],
            **(scenario or {}),
        }],
    }
    path = os.path.join(str(tmp_path), "spec.yaml")
    with open(path, "w", encoding="utf-8") as fh:
        yaml.safe_dump(doc, fh)
    return str(tmp_path)


def _load_one_scenario(tmp_path, scenario=None, cases=None):
    loaded = suites.load_all(_write_suite(tmp_path, scenario, cases))
    return loaded[0].scenarios[0]


def _problems(tmp_path, scenario=None, cases=None) -> list[str]:
    with pytest.raises(suites.SuiteError) as exc:
        suites.load_all(_write_suite(tmp_path, scenario, cases))
    return exc.value.problems


def _checker_case(**extra) -> dict:
    case = {"id": "case_a", "query": "do the thing",
            "checker": {"script": "checkers/thing.py", "mode": "exit"}}
    case.update(extra)
    return case


# --- sticky_gates (scenario level) ------------------------------------------

def test_sticky_gates_default_to_empty(tmp_path):
    assert _load_one_scenario(tmp_path).sticky_gates == ()


def test_sticky_gates_accepts_negative_gate_keys(tmp_path):
    scn = _load_one_scenario(tmp_path, {"sticky_gates": ["reply_not_matches", "tools_none"]})
    assert scn.sticky_gates == ("reply_not_matches", "tools_none")


def test_sticky_gates_rejects_a_positive_gate_key(tmp_path):
    problems = _problems(tmp_path, {"sticky_gates": ["reply_matches"]})
    assert any("sticky_gates" in p and "reply_matches" in p for p in problems), problems


def test_sticky_gates_rejects_an_unknown_key(tmp_path):
    problems = _problems(tmp_path, {"sticky_gates": ["no_such_gate"]})
    assert any("sticky_gates" in p for p in problems), problems


def test_sticky_gates_rejects_a_non_list(tmp_path):
    problems = _problems(tmp_path, {"sticky_gates": "tools_none"})
    assert any("sticky_gates" in p for p in problems), problems


def test_always_sticky_gates_are_the_prohibition_keys():
    assert suites.ALWAYS_STICKY_GATES == ("tools_none", "tools_none_succeeded")
    assert set(suites.ALWAYS_STICKY_GATES) <= set(suites.STICKY_GATE_KEYS)
    assert set(suites.STICKY_GATE_KEYS) <= set(suites.EXPECT_SPEC)


# --- requires_tools_all (case level) ----------------------------------------

def test_requires_tools_all_defaults_to_empty(tmp_path):
    scn = _load_one_scenario(tmp_path)
    assert scn.cases[0].requires_tools_all == ()


def test_requires_tools_all_parses_and_coexists_with_requires_tools(tmp_path):
    cases = [dict(BASE_CASE, requires_tools=["skill_create", "skill_reload"],
                  requires_tools_all=["skill_create", "skill_reload"]),
             dict(FILLER_CASE)]
    scn = _load_one_scenario(tmp_path, cases=cases)
    assert scn.cases[0].requires_tools_all == ("skill_create", "skill_reload")
    assert scn.cases[0].requires_tools == ["skill_create", "skill_reload"]


def test_requires_tools_all_rejects_non_string_entries(tmp_path):
    problems = _problems(tmp_path, cases=[dict(BASE_CASE, requires_tools_all=[3]),
                                          dict(FILLER_CASE)])
    assert any("requires_tools_all" in p for p in problems), problems


def test_requires_tools_all_rejects_a_non_list(tmp_path):
    problems = _problems(tmp_path, cases=[dict(BASE_CASE, requires_tools_all="skill_create"),
                                          dict(FILLER_CASE)])
    assert any("requires_tools_all" in p for p in problems), problems


# --- checker.reset ----------------------------------------------------------

def test_checker_reset_defaults_to_an_empty_list(tmp_path):
    scn = _load_one_scenario(tmp_path, cases=[_checker_case(), dict(FILLER_CASE)])
    assert scn.cases[0].checker_spec["reset"] == []


def test_checker_reset_accepts_skills_and_workspace_paths(tmp_path):
    case = _checker_case(checker={"script": "checkers/thing.py", "mode": "exit",
                                  "reset": ["skills/eval-echo", "workspace/scratch"]})
    scn = _load_one_scenario(tmp_path, cases=[case, dict(FILLER_CASE)])
    assert scn.cases[0].checker_spec["reset"] == ["skills/eval-echo", "workspace/scratch"]


@pytest.mark.parametrize("bad", ["../skills/eval-echo", "/skills/eval-echo",
                                 "memory/facts.db", "skills/../../etc", "", "skills"])
def test_checker_reset_rejects_paths_outside_the_reset_roots(tmp_path, bad):
    case = _checker_case(checker={"script": "checkers/thing.py", "mode": "exit",
                                  "reset": [bad]})
    problems = _problems(tmp_path, cases=[case, dict(FILLER_CASE)])
    assert any("checker.reset" in p for p in problems), (bad, problems)


@pytest.mark.parametrize("bare", ["skills/", "skills/.", "skills//", "workspace/",
                                  "workspace/./"])
def test_checker_reset_rejects_a_bare_root(tmp_path, bare):
    # These collapse under realpath to <home>/skills or <home>/workspace, which the
    # runtime SafeRm guard refuses MID-SWEEP — after loading, --estimate, seeding and
    # possibly earlier tasks' spend, and the exception aborts the run. SCHEMA.md
    # promises a load error.
    case = _checker_case(checker={"script": "checkers/thing.py", "mode": "exit",
                                  "reset": [bare]})
    problems = _problems(tmp_path, cases=[case, dict(FILLER_CASE)])
    assert any("checker.reset" in p for p in problems), (bare, problems)


def test_checker_reset_rejects_a_non_list(tmp_path):
    case = _checker_case(checker={"script": "checkers/thing.py", "mode": "exit",
                                  "reset": "skills/eval-echo"})
    problems = _problems(tmp_path, cases=[case, dict(FILLER_CASE)])
    assert any("checker.reset" in p for p in problems), problems


# --- score.single -----------------------------------------------------------

def test_score_single_accepted_for_numeric_match(tmp_path):
    case = dict(BASE_CASE, score={"match": "numeric", "expected": 42, "single": True})
    scn = _load_one_scenario(tmp_path, cases=[case, dict(FILLER_CASE)])
    assert scn.cases[0].score_spec["single"] is True


def test_score_single_rejected_for_a_non_numeric_match(tmp_path):
    case = dict(BASE_CASE, score={"match": "contains", "expected": "teal", "single": True})
    problems = _problems(tmp_path, cases=[case, dict(FILLER_CASE)])
    assert any("score.single" in p or "`single`" in p for p in problems), problems


def test_score_single_must_be_a_boolean(tmp_path):
    case = dict(BASE_CASE, score={"match": "numeric", "expected": 42, "single": "yes"})
    problems = _problems(tmp_path, cases=[case, dict(FILLER_CASE)])
    assert any("single" in p for p in problems), problems


# --- multi-turn capability cases are refused at load time -------------------

MULTI_TURN_REFUSAL = ("multi-turn capability cases are not driven; "
                      "use cross_session or a single turn")


def test_multi_turn_scored_case_is_rejected(tmp_path):
    case = {"id": "case_a",
            "turns": [{"query": "set it up"}, {"query": "now answer"}],
            "score": {"match": "numeric", "expected": 42}}
    problems = _problems(tmp_path, cases=[case, dict(FILLER_CASE)])
    assert any(MULTI_TURN_REFUSAL in p for p in problems), problems
    assert any("case_a" in p and MULTI_TURN_REFUSAL in p for p in problems), problems


def test_multi_turn_checker_case_is_rejected(tmp_path):
    case = {"id": "case_a",
            "turns": [{"query": "set it up"}, {"query": "now do it"}],
            "checker": {"script": "checkers/thing.py", "mode": "exit"}}
    problems = _problems(tmp_path, cases=[case, dict(FILLER_CASE)])
    assert any(MULTI_TURN_REFUSAL in p for p in problems), problems


def test_cross_session_two_turn_case_is_allowed(tmp_path):
    case = {"id": "case_a", "cross_session": True,
            "turns": [{"query": "remember 42"}, {"query": "what was it?"}],
            "score": {"match": "numeric", "expected": 42}}
    scn = _load_one_scenario(tmp_path, cases=[case, dict(FILLER_CASE)])
    assert scn.cases[0].cross_session is True


def test_multi_turn_behavioral_case_is_allowed(tmp_path):
    case = {"id": "case_a", "turns": [{"query": "one"}, {"query": "two"}]}
    scn = _load_one_scenario(tmp_path, cases=[case, dict(FILLER_CASE)])
    assert len(scn.cases[0].turns) == 2


def test_shipped_suites_still_load():
    assert suites.load_all(SUITES_DIR, include_dangerous=True)
    assert suites.load_all(CAP_DIR, include_candidates=True)


# --- session_ids.sess -------------------------------------------------------

def test_sess_leaves_a_short_id_unchanged():
    assert session_ids.sess("eval", "memory", "case", "t1") == "eval-memory-case-t1"


def test_sess_sanitizes_non_id_characters():
    assert session_ids.sess("eval run", "case/one") == "eval-run-case-one"


def test_sess_over_the_limit_keeps_its_trailing_part():
    long_case = "x" * 200
    got = session_ids.sess("eval", long_case, "trial3")
    assert len(got) <= 90
    assert got.endswith("-trial3")
    assert got.startswith("eval-xxx")


def test_sess_is_unique_per_suffix_when_the_head_collides():
    long_case = "y" * 200
    ids = {session_ids.sess("eval", long_case, f"trial{n}") for n in range(1, 6)}
    assert len(ids) == 5


def test_sess_distinguishes_different_middles_with_the_same_tail():
    a = session_ids.sess("eval", "a" * 200, "trial1")
    b = session_ids.sess("eval", "b" * 200, "trial1")
    assert a != b


def test_every_runner_uses_the_shared_session_id_helper():
    # The point of the move was ONE implementation. Comparing two calls to the same
    # object proved nothing; what must hold is that no runner grew its own copy —
    # a divergent one is how a retry re-entered the daemon conversation it exists to
    # independently confirm.
    import run_baseline  # noqa: F401  (imported for the module-list assertion below)
    import run_capability
    assert run_eval.sess is session_ids.sess
    assert run_capability.sess is session_ids.sess
    assert not hasattr(run_baseline, "sess")   # the raw arm has no session at all


def test_sess_honours_a_smaller_limit():
    got = session_ids.sess("eval", "w" * 60, "t4", limit=40)
    assert len(got) <= 40
    assert got.endswith("-t4")


def test_sess_refuses_an_untruncatable_tail():
    with pytest.raises(ValueError):
        session_ids.sess("eval", "w" * 60, "t" * 95)


def test_sess_refuses_no_parts():
    with pytest.raises(ValueError):
        session_ids.sess()


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
