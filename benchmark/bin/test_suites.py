#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8.4", "pyyaml>=6,<7", "certifi", "anthropic>=1.13,<2"]
# ///
"""Specs for the suite schema keys that make a measurement trustworthy: sticky
safety gates, the all-of tool-provenance key, the per-trial checker reset list,
single-number scoring, multi-turn capability cases, and numbered rubrics.
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
from evallib import rubric, session_ids, suites  # noqa: E402

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


def test_always_sticky_gates_are_the_prohibitions_and_recorded_state():
    """The gates whose failure no retry can clear, none of which a scenario has to
    declare. `fixture_state` is here on the same evidence as the two tool bans: a
    violated `absent:` clause is the PAGE's own record that the action happened,
    and its other failure kind grades inconclusive (grade.py), so a positive
    clause stays as retryable as any other quality assertion."""
    assert suites.ALWAYS_STICKY_GATES == (
        "tools_none", "tools_none_succeeded", "fixture_state", "workspace_paths_absent")
    assert set(suites.ALWAYS_STICKY_GATES) <= set(suites.STICKY_GATE_KEYS)
    assert set(suites.STICKY_GATE_KEYS) <= set(suites.EXPECT_SPEC)


# --- platforms (scenario level) ---------------------------------------------

def test_a_scenario_without_platforms_runs_on_every_host(tmp_path):
    assert _load_one_scenario(tmp_path).platforms == ()


def test_platforms_accepts_known_hosts(tmp_path):
    assert _load_one_scenario(tmp_path, {"platforms": ["linux"]}).platforms == ("linux",)
    both = _load_one_scenario(tmp_path, {"platforms": ["linux", "macos"]})
    assert both.platforms == ("linux", "macos")


@pytest.mark.parametrize("value", [["windows"], ["Linux"], ["linux", "darwin"],
                                   [], "linux", None])
def test_platforms_refuses_an_unknown_host_an_empty_list_or_a_non_list(tmp_path, value):
    problems = _problems(tmp_path, {"platforms": value})
    assert any("`platforms` must be a non-empty list" in p for p in problems), problems


def test_a_capability_suite_cannot_declare_platforms(tmp_path):
    """run_capability.py does not read it, so the case would run on every host."""
    doc = {"suite": "cap_spec", "title": "Cap spec", "risk": "isolated_mutation",
           "scenarios": [{"id": "scn", "title": "Scenario", "platforms": ["linux"],
                          "cases": [{"id": "only", "query": "q",
                                     "score": {"match": "exact", "expected": "x"}}]}]}
    with open(os.path.join(str(tmp_path), "cap_spec.yaml"), "w", encoding="utf-8") as fh:
        yaml.safe_dump(doc, fh)
    with pytest.raises(suites.SuiteError) as exc:
        suites.load_all(str(tmp_path))
    assert any("read by run_eval.py only" in p for p in exc.value.problems)


@pytest.mark.parametrize("sys_platform, name", [
    ("linux", "linux"), ("linux2", "linux"), ("darwin", "macos"),
    ("win32", "win32"), ("freebsd14", "freebsd14")])
def test_the_host_is_named_in_the_platforms_vocabulary(sys_platform, name):
    # Another host keeps its own name, which no scenario can declare.
    assert suites.platform_of(sys_platform) == name


# --- workspace_paths_absent (expect) -----------------------------------------

def test_workspace_paths_absent_loads_on_an_ask_case(tmp_path):
    cases = [dict(BASE_CASE, expect={"workspace_paths_absent": ["kiosk/kernel.txt"]}),
             dict(FILLER_CASE)]
    scn = _load_one_scenario(tmp_path, cases=cases)
    assert scn.cases[0].turns[0].expect["workspace_paths_absent"] == ["kiosk/kernel.txt"]


@pytest.mark.parametrize("value", [[], ["/etc/passwd"], ["../outside.txt"],
                                   ["kiosk/../../outside.txt"], ["."], [""], [3],
                                   "kiosk/kernel.txt"])
def test_workspace_paths_absent_refuses_traversal_absolute_or_empty_paths(tmp_path, value):
    cases = [dict(BASE_CASE, expect={"workspace_paths_absent": value}), dict(FILLER_CASE)]
    problems = _problems(tmp_path, cases=cases)
    assert any("workspace_paths_absent" in p for p in problems), problems


def test_workspace_paths_absent_needs_the_ask_drive(tmp_path):
    case = {"id": "case_a", "drive": "telegram_operator", "query": "q",
            "expect": {"workspace_paths_absent": ["kiosk/kernel.txt"]}}
    problems = _problems(tmp_path, cases=[case, dict(FILLER_CASE)])
    assert any("needs `drive: ask`" in p for p in problems), problems


def test_a_capability_case_cannot_declare_workspace_paths_absent(tmp_path):
    doc = {"suite": "cap_spec", "title": "Cap spec", "risk": "isolated_mutation",
           "scenarios": [{"id": "scn", "title": "Scenario",
                          "cases": [{"id": "only", "query": "q",
                                     "score": {"match": "exact", "expected": "x"},
                                     "expect": {"workspace_paths_absent": ["k.txt"]}}]}]}
    with open(os.path.join(str(tmp_path), "cap_spec.yaml"), "w", encoding="utf-8") as fh:
        yaml.safe_dump(doc, fh)
    with pytest.raises(suites.SuiteError) as exc:
        suites.load_all(str(tmp_path))
    assert any("graded by run_eval.py only" in p for p in exc.value.problems)


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


# --- multi-turn capability cases are driven, one session per trial ----------

def test_multi_turn_scored_case_loads(tmp_path):
    case = {"id": "case_a",
            "turns": [{"query": "set it up"}, {"query": "now answer"}],
            "score": {"match": "numeric", "expected": 42}}
    scn = _load_one_scenario(tmp_path, cases=[case, dict(FILLER_CASE)])
    assert len(scn.cases[0].turns) == 2


def test_checker_expect_must_be_a_non_empty_map(tmp_path):
    for bad in ({}, ["C"], "C"):
        case = {"id": "case_a", "query": "q",
                "checker": {"script": "checkers/thing.py", "mode": "json", "expect": bad}}
        problems = _problems(tmp_path, cases=[case, dict(FILLER_CASE)])
        assert any("checker.expect" in p for p in problems), (bad, problems)
    case = {"id": "case_a", "query": "q",
            "checker": {"script": "checkers/thing.py", "mode": "json",
                        "expect": {"hotel": "C"}}}
    scn = _load_one_scenario(tmp_path, cases=[case, dict(FILLER_CASE)])
    assert scn.cases[0].checker_spec["expect"] == {"hotel": "C"}


def test_checker_state_is_a_relative_json_path(tmp_path):
    for bad in ("../state/w.json", "/abs/w.json", "fixtures/state/w.yaml", ""):
        case = {"id": "case_a", "query": "q",
                "checker": {"script": "checkers/thing.py", "mode": "json", "state": bad}}
        problems = _problems(tmp_path, cases=[case, dict(FILLER_CASE)])
        assert any("checker.state" in p for p in problems), (bad, problems)
    case = {"id": "case_a", "query": "q",
            "checker": {"script": "checkers/thing.py", "mode": "json",
                        "state": "fixtures/state/w.json"}}
    scn = _load_one_scenario(tmp_path, cases=[case, dict(FILLER_CASE)])
    assert scn.cases[0].checker_spec["state"] == "fixtures/state/w.json"


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


def test_the_hand_coding_cases_grade_their_instruction_as_capability_not_safety():
    # "Do this yourself" is a task instruction. Declared as `tools_none`, which is
    # safety vocabulary, fifteen delegations were reported as fifteen safety violations
    # and turned the release gate red for a reason that was not safety. A delegated
    # trial fails the checker instead: the capability failure it is.
    import run_capability
    doc = yaml.safe_load(open(os.path.join(CAP_DIR, "coding.yaml"), encoding="utf-8"))
    cases = [c for scn in doc["scenarios"] for c in scn["cases"]]
    hand = [c for c in cases
            if "do not delegate" in " ".join(c["query"].split()).lower()]
    assert hand, "the coding suite no longer asks for a case to be done by hand"
    for case in hand:
        gates = set(case.get("expect") or {}) & set(run_capability.SAFETY_GATES)
        assert not gates, f"{case['id']} grades a task instruction as safety: {gates}"
        assert case.get("checker"), f"{case['id']} has no checker to grade the fix"


def test_shipped_suites_still_load():
    assert suites.load_all(SUITES_DIR, include_dangerous=True)
    assert suites.load_all(CAP_DIR, include_candidates=True)


_ONE_CASE = ("suite: {name}\nrisk: host_readonly\ntitle: t\nscenarios:\n"
             "  - id: s\n    title: t\n    cases:\n      - id: c\n        query: q\n"
             "        score: {{match: contains, expected: x}}\n")


def test_a_behavioral_scenario_still_needs_two_phrasings(tmp_path):
    (tmp_path / "one.yaml").write_text(_ONE_CASE.format(name="one"))
    with pytest.raises(suites.SuiteError) as raised:
        suites.load_all(str(tmp_path))
    assert any("needs at least 2 case" in p for p in raised.value.problems)


def test_a_capability_scenario_may_hold_one_task(tmp_path):
    (tmp_path / "one.yaml").write_text(_ONE_CASE.format(name="cap_one"))
    assert suites.load_all(str(tmp_path))[0].name == "cap_one"


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


# --- numbered rubrics ---------------------------------------------------------
#
# A rubric that numbers its requirements gets one verdict per requirement, and
# the harness computes pass and score from them; any other rubric is prose and
# keeps the whole-verdict path. The numbering is checked at load, so a list the
# harness would miscount fails `--dry-run` instead of grading as prose.

NUMBERED = """It passes only when every numbered requirement holds:
1. The reply names the deadline.
2. It keeps the level settled. It fails if it
   reopens the level in any form.
3. It invents nothing.
Not required: any particular wording.
"""


def test_a_rubric_without_a_numbered_list_is_prose():
    assert rubric.numbered_requirements("Grounds the brief in all four files.") == (None, None)
    assert rubric.numbered_requirements("Line one.\nLine two.\n") == (None, None)


def test_a_numbered_rubric_yields_each_requirement_with_its_continuation():
    texts, error = rubric.numbered_requirements(NUMBERED)
    assert error is None
    assert texts == ["The reply names the deadline.",
                     "It keeps the level settled. It fails if it reopens the level in any form.",
                     "It invents nothing."]


def test_the_not_required_line_is_never_a_requirement():
    texts, _error = rubric.numbered_requirements(NUMBERED)
    assert not any("Not required" in text for text in texts)


def test_blank_lines_may_separate_numbered_requirements():
    texts, error = rubric.numbered_requirements("1. First.\n\n2. Second.\n")
    assert (texts, error) == (["First.", "Second."], None)


@pytest.mark.parametrize(("text", "found"), [
    ("2. First.\n3. Second.\n", "2, 3"),
    ("1. First.\n3. Second.\n", "1, 3"),
    ("1. First.\n2. Second.\n2. Again.\n", "1, 2, 2"),
    ("2. Second.\n1. First.\n", "2, 1"),
])
def test_a_numbering_that_is_not_one_to_n_in_order_is_refused(text, found):
    texts, error = rubric.numbered_requirements(text)
    assert texts is None
    assert f"numbers its requirements {found}" in error
    assert "1..N" in error


def test_a_numbered_requirement_with_no_text_is_refused():
    texts, error = rubric.numbered_requirements("1. First.\n2.   \n")
    assert texts is None and "requirement 2 has no text" in error


def test_an_unindented_line_inside_the_list_is_refused():
    # The harness would cut requirement 1 short and the judge would read a
    # sentence the report never shows, so the line must be indented under it.
    texts, error = rubric.numbered_requirements("1. The reply uses facts\nfrom all files.\n"
                                                "2. Second.\n")
    assert texts is None
    assert "line 2" in error and "requirement 1" in error


def test_a_numbered_rubric_loads(tmp_path):
    scn = _load_one_scenario(tmp_path, cases=[dict(BASE_CASE, rubric=NUMBERED),
                                              dict(FILLER_CASE)])
    assert scn.cases[0].rubric == NUMBERED


def test_a_malformed_numbering_is_a_suite_validation_error(tmp_path):
    problems = _problems(tmp_path, cases=[dict(BASE_CASE, rubric="1. First.\n3. Third.\n"),
                                          dict(FILLER_CASE)])
    assert len(problems) == 1
    assert "case_a" in problems[0] and "`rubric`" in problems[0]
    assert "numbers its requirements 1, 3" in problems[0]


def test_a_watch_on_a_numbered_rubric_loads(tmp_path):
    watch = [{"n": 2, "reason": " The candidate misses it 2 of 12. "}]
    scn = _load_one_scenario(tmp_path, cases=[dict(BASE_CASE, rubric=NUMBERED, watch=watch),
                                              dict(FILLER_CASE)])
    assert scn.cases[0].watch == ((2, "The candidate misses it 2 of 12."),)
    assert scn.cases[1].watch == ()


@pytest.mark.parametrize("rubric_text, watch, defect", [
    ("Prose.", [{"n": 1, "reason": "r"}], "only a numbered rubric"),
    (None, [{"n": 1, "reason": "r"}], "only a numbered rubric"),
    (NUMBERED, [], "non-empty list"),
    (NUMBERED, [{"n": 4, "reason": "r"}], "n must be a requirement number 1..3"),
    (NUMBERED, [{"n": True, "reason": "r"}], "n must be a requirement number 1..3"),
    (NUMBERED, [{"n": 2, "reason": "  "}], "reason must say why requirement 2"),
    (NUMBERED, [{"n": 2}], "exactly the keys n and reason"),
    (NUMBERED, [{"n": 2, "reason": "r", "until": "x"}], "exactly the keys n and reason"),
    (NUMBERED, [{"n": 2, "reason": "r"}, {"n": 2, "reason": "s"}], "watched more than once"),
    (NUMBERED, [{"n": n, "reason": "r"} for n in (1, 2, 3)], "none would decide the verdict"),
])
def test_an_impossible_watch_is_a_suite_validation_error(tmp_path, rubric_text, watch, defect):
    case = dict(BASE_CASE, watch=watch)
    if rubric_text is not None:
        case["rubric"] = rubric_text
    problems = _problems(tmp_path, cases=[case, dict(FILLER_CASE)])
    assert any("case_a" in problem and "watch" in problem and defect in problem
               for problem in problems), problems


def test_the_shipped_watches_each_name_one_requirement_and_a_reason():
    watches = {case.id: case.watch
               for suite in suites.load_all(SUITES_DIR, include_dangerous=True)
               for scenario in suite.scenarios for case in scenario.cases if case.watch}
    assert {case_id: [n for n, _reason in watch] for case_id, watch in watches.items()} == \
        {"people_and_customer_update": [4], "hiring_decision": [2]}
    assert all("Revisit when the candidate model changes." in reason
               for watch in watches.values() for _n, reason in watch)


def test_the_shipped_numbered_rubrics_parse():
    counts = {}
    for suite in suites.load_all(SUITES_DIR, include_dangerous=True):
        for scenario in suite.scenarios:
            for case in scenario.cases:
                texts, error = rubric.numbered_requirements(case.rubric or "")
                assert error is None, (case.id, error)
                if texts:
                    counts[case.id] = len(texts)
    assert counts == {"launch_day_update": 5, "people_and_customer_update": 4,
                      "hiring_decision": 5,
                      # grok_voice.yaml
                      "intake_on_the_thirteenth": 2, "van_on_the_twentieth": 2,
                      "curry_question_while_stocktake_runs": 3,
                      "rice_question_while_stocktake_runs": 3,
                      "never_mind_cancel": 2, "stop_the_stocktake": 2,
                      "thirteenth_corrected_to_twentieth": 3,
                      "twentieth_corrected_to_thirteenth": 3,
                      # home_move.yaml
                      "move_to_vm_sanity": 4, "device_role_after_the_move": 3,
                      "what_stops_after_an_always_on_move": 5,
                      "new_fermix_release_on_the_server": 3,
                      "security_patches_and_reboots_on_the_server": 3,
                      "hetzner_server_from_a_token": 5,
                      "deleting_the_server_the_home_moved_to": 3,
                      # open_loops.yaml
                      "grant_overhead": 3, "contractor_choice": 3,
                      "fence_paint_route_sanity": 3,
                      "permit_forms_tomorrow_route_sanity": 3, "deadline_question": 2,
                      "colleague_visa": 2, "hypothetical_race": 2,
                      "forwarded_school_notice": 2,
                      "reminder_listed_back": 3, "fetched_notice": 2,
                      "consent_form_after_reading": 3, "own_engineer_after_reading": 3,
                      "settle_while_reading": 3, "bulletin_summary": 2,
                      "bulletin_anything_to_do": 2,
                      "allotment_application": 2,
                      "insurance_renewal": 2, "invoices_sent": 3,
                      "volunteer_form_submitted": 3, "venue_booking_plan": 5,
                      "lease_signing_plan": 5, "onboarding_course_not_started": 5,
                      "photos_not_sorted": 5, "storage_unit_stop": 4,
                      "gym_decision_stop": 4,
                      "curious_draft": 4, "asked_to_check": 3,
                      "earlier_lookup_then_work": 4,
                      "pasted_deadline_own_application": 4,
                      "date_said_earlier_then_work": 3, "moved_date": 2,
                      "ignored_question": 2, "unsure_no_lookup": 1,
                      "no_deadline_answer": 1, "asking_only": 2, "considering_only": 2,
                      "earlier_lookup_then_asking": 2, "someone_elses": 2,
                      "lookup_for_someone_else": 2, "already_dated": 2,
                      "pressed_for_time": 2, "final_interview": 2,
                      "planning_decision_route_sanity": 2,
                      # cues.yaml
                      "releases_and_outages": 3, "security_fixes_only": 3,
                      "sanity_watcher_tool_reached": 2,
                      "firehose_failover_news": 4, "flooded_source_replication_lag": 4,
                      "ignore_conference_talks": 3, "skip_vendor_webinars": 3,
                      "funding_story_not_useful": 3, "meetup_item_useless": 3,
                      "alerts_to_dana_on_signal": 2, "alerts_to_sister_on_signal": 2,
                      "sources_and_anything_broken": 4, "anything_waiting_on_me": 4,
                      "sanity_sources_read": 2, "broker_news_websocket": 3,
                      "market_headlines_wss": 3, "x_account_new_posts": 4,
                      "x_handle_through_webhooks": 4, "github_repo_events": 4,
                      "github_secret_to_invent": 3, "words_miss_reworded_posts": 4,
                      "screen_on_a_fallback_provider": 3, "mandates_and_approval": 3,
                      "mandates_needing_approval": 3, "codex_review_on_release": 4,
                      "status_script_on_outage": 3, "claude_code_changelog_on_release": 3,
                      "claude_code_issue_triage_on_report": 3, "codex_quotes_the_post": 3,
                      "summarise_each_post_into_notes": 3, "automatic_with_a_cap": 3,
                      "automatic_without_a_cap": 3}


if __name__ == "__main__":
    # No third-party pytest plugins: the anthropic SDK imports anyio first, and its
    # autoloaded plugin would only warn that it could not be rewritten.
    sys.exit(pytest.main([__file__, "-q", "--disable-plugin-autoload"]))
