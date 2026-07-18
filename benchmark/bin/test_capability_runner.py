#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7"]
# ///
"""Tests for the capability runner's pure pieces: the tool-provenance gate and the
`requires_tools` suite validation. No daemon / no Opik. Run: `uv run bin/test_capability_runner.py`."""
from __future__ import annotations

import os
import sys
from datetime import datetime, timezone
from types import SimpleNamespace

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

import run_capability as rc  # noqa: E402
from evallib import grade, safe_rm, suites  # noqa: E402


# --- tool-provenance gate ---------------------------------------------------

def test_provenance_no_requirement_always_passes():
    assert rc._provenance_ok([], []) is True
    assert rc._provenance_ok([], ["file_read"]) is True


def test_provenance_fails_when_no_required_tool_fired():
    # answer reached without any declared tool == parametric recall -> must fail
    assert rc._provenance_ok(["web_search", "web_fetch"], []) is False
    assert rc._provenance_ok(["web_search", "web_fetch"], ["file_read", "memory_recall"]) is False


def test_provenance_passes_when_any_required_tool_fired():
    assert rc._provenance_ok(["web_search", "web_fetch"], ["web_fetch"]) is True
    assert rc._provenance_ok(["web_search"], ["web_search", "file_read"]) is True


def test_safety_grading_uses_the_captured_driver_duration():
    trace = {
        "_eval_trace_complete": True,
        "total_estimated_cost": 0.0,
        "usage": {"total_tokens": 4},
        "metadata": {"iterations": 1},
        "output": "ok",
    }
    assert rc._safety_ok(trace, [], {"tools_none": ["shell"]}, 5.0)


def test_capability_evidence_requires_settled_complete_telemetry():
    complete = grade.TurnView.build({
        "_eval_trace_complete": True,
        "total_estimated_cost": 0.0,
        "usage": {"total_tokens": 4},
        "metadata": {"iterations": 1},
    }, [], elapsed_ms=1.0)
    unsettled = grade.TurnView.build({
        "total_estimated_cost": 0.0,
        "usage": {"total_tokens": 4},
        "metadata": {"iterations": 1},
    }, [], elapsed_ms=1.0)
    assert rc._gradeable(complete)
    assert not rc._gradeable(unsettled)


def test_capability_judge_preflight_delegates_to_the_judge_precondition(monkeypatch):
    cfg = SimpleNamespace(judge=SimpleNamespace(backend="openai", model="gpt-5.4-mini"))
    monkeypatch.setattr(rc.judge, "precondition_error", lambda _cfg: None)
    assert rc._independent_judge_error(cfg, want_judge=True) is None


def test_unevaluated_judge_aborts_instead_of_scoring_candidate_zero(monkeypatch):
    case = SimpleNamespace(
        id="quality", score_spec=None, rubric="Judge quality.",
        turns=[SimpleNamespace(query="q")])
    cfg = SimpleNamespace(judge=SimpleNamespace(backend="openai", model="gpt-5.4-mini"))
    monkeypatch.setattr(
        rc.judge, "judge_case",
        lambda *_args, **_kwargs: SimpleNamespace(
            evaluated=False, score=None, error="judge output truncated"))

    with pytest.raises(rc.JudgeUnavailable) as caught:
        rc._task_success(
            cfg, case, "reply", True, "tag",
            [{"provider": "openai_codex", "model": "candidate"}])

    assert caught.value.case_id == "quality"
    assert "truncated" in caught.value.error


def test_abort_judge_unavailable_exits_incomplete_without_writing(capsys):
    unavailable = rc.JudgeUnavailable("quality", "invalid verdict")
    unavailable.locate("cap_response_quality", "quality", 2)
    assert rc._abort_judge_unavailable(unavailable, done=1, total=3) == 4
    err = capsys.readouterr().err
    assert "cap_response_quality/quality (trial 2)" in err
    assert "invalid verdict" in err
    assert "Leaderboard NOT written" in err


def test_incomplete_trace_still_records_an_observed_safety_violation():
    trace = {
        "_eval_trace_complete": True,
        "total_estimated_cost": 0.0,
        "usage": {},
        "metadata": {"iterations": 1},
    }
    spans = [{"type": "tool", "name": "shell", "input": {"command": "unsafe"}}]
    view = grade.TurnView.build(trace, spans, elapsed_ms=1.0)
    cap = rc._Captured("incomplete", view, trace, spans, 1.0)
    case = SimpleNamespace(id="unsafe", expect={"tools_none": ["shell"]})
    trial, _trace_id, _models = rc._fail_trial(case, cap)
    assert not trial.safety_ok


def test_incomplete_trace_without_forbidden_action_is_not_a_safety_violation():
    trace = {
        "_eval_trace_complete": True,
        "total_estimated_cost": 0.0,
        "usage": {},
        "metadata": {"iterations": 1},
    }
    view = grade.TurnView.build(trace, [], elapsed_ms=1.0)
    cap = rc._Captured("incomplete", view, trace, [], 1.0)
    case = SimpleNamespace(id="safe", expect={"tools_none": ["shell"]})
    trial, _trace_id, _models = rc._fail_trial(case, cap)
    assert trial.safety_ok


# --- dev-default / isolated-mutation execution boundary --------------------

def test_capability_home_uses_dev_for_safe_runs_but_never_production():
    assert rc._capability_home_error("~/.fermix", require_isolated=False) is not None
    assert rc._capability_home_error("~/.fermix-dev", require_isolated=False) is None
    assert rc._capability_home_error("~/.fermix-dev", require_isolated=True) is not None


def test_capability_home_accepts_a_named_eval_home(tmp_path):
    home = str(tmp_path / "fermix-capability-eval")
    assert rc._capability_home_error(home, require_isolated=False) is None
    assert rc._capability_home_error(home, require_isolated=True) is None


def test_capability_project_uses_dev_for_safe_runs_and_eval_for_isolated_runs():
    assert rc._capability_project_error("fermix") is not None
    assert rc._capability_project_error("fermix-dev", require_isolated=False) is None
    assert rc._capability_project_error(
        "fermix-dev", require_isolated=True) is not None
    assert rc._capability_project_error(
        "fermix-capability-eval", require_isolated=True) is None


def test_capability_config_defaults_to_the_dev_daemon(monkeypatch):
    monkeypatch.delenv("FERMIX_EVAL_HOME", raising=False)
    monkeypatch.delenv("OPIK_PROJECT", raising=False)
    cfg = rc.cfgmod.load(os.path.dirname(HERE))
    assert cfg.daemon.fermix_home == os.path.expanduser("~/.fermix-dev")
    assert cfg.opik.project == "fermix-dev"


def test_capability_check_infers_isolation_from_the_configured_target():
    dev = SimpleNamespace(
        daemon=SimpleNamespace(fermix_home="~/.fermix-dev"),
        opik=SimpleNamespace(project="fermix-dev"),
    )
    isolated = SimpleNamespace(
        daemon=SimpleNamespace(fermix_home="~/.fermix-capability-eval"),
        opik=SimpleNamespace(project="fermix-capability-eval"),
    )
    assert not rc._capability_config_requires_isolation(dev)
    assert rc._capability_config_requires_isolation(isolated)


def test_capability_sandbox_requires_strict_home_scoped_repo(tmp_path):
    home = tmp_path / "fermix-capability-eval"
    workspace = home / "workspace"
    (workspace / ".git").mkdir(parents=True)
    (home / "config.toml").write_text(
        f'[sandbox]\nmode = "strict"\nworkspace_root = "{workspace}"\n'
    )
    assert rc._capability_sandbox_error(str(home), require_isolated=True) is None


def test_capability_safe_dev_run_accepts_standard_non_git_workspace(tmp_path):
    home = tmp_path / ".fermix-dev"
    workspace = home / "workspace"
    workspace.mkdir(parents=True)
    (home / "config.toml").write_text(
        f'[sandbox]\nmode = "standard"\nworkspace_root = "{workspace}"\n'
    )
    assert rc._capability_sandbox_error(str(home), require_isolated=False) is None
    assert rc._capability_sandbox_error(str(home), require_isolated=True) is not None


def test_capability_sandbox_rejects_workspace_escape(tmp_path):
    home = tmp_path / "fermix-capability-eval"
    home.mkdir()
    (home / "config.toml").write_text(
        f'[sandbox]\nmode = "strict"\nworkspace_root = "{tmp_path}"\n'
    )
    assert rc._capability_sandbox_error(str(home), require_isolated=True) is not None


def test_capability_sandbox_rejects_nonconventional_workspace_root(tmp_path):
    home = tmp_path / "fermix-capability-eval"
    workspace = home / "repo"
    (workspace / ".git").mkdir(parents=True)
    (home / "config.toml").write_text(
        f'[sandbox]\nmode = "strict"\nworkspace_root = "{workspace}"\n'
    )
    error = rc._capability_sandbox_error(str(home), require_isolated=True)
    assert error is not None and "workspace" in error.lower()


def test_capability_attestation_is_only_required_for_isolated_execution():
    assert rc._execution_attestation_error(
        SimpleNamespace(confirm_daemon_isolated=False), require_isolated=False
    ) is None
    assert rc._execution_attestation_error(
        SimpleNamespace(confirm_daemon_isolated=False), require_isolated=True
    ) is not None
    assert rc._execution_attestation_error(
        SimpleNamespace(confirm_daemon_isolated=True), require_isolated=True
    ) is None


def test_only_mutating_capability_cases_require_an_isolated_home():
    assert not rc._capability_requires_isolated_home(_risk_case("host_readonly"))
    assert not rc._capability_requires_isolated_home(_risk_case("expensive"))
    assert rc._capability_requires_isolated_home(
        _risk_case("expensive", checker_spec={"script": "checker.py"}))
    assert rc._capability_requires_isolated_home(_risk_case("isolated_mutation"))


def _risk_case(risk, checker_spec=None, confirm_cost=False):
    suite = SimpleNamespace(name="cap")
    scenario = SimpleNamespace(id="scenario", risk=risk, confirm_cost=confirm_cost)
    case = SimpleNamespace(id="case", checker_spec=checker_spec)
    return [(suite, scenario, case)]


def test_capability_risk_refuses_unclassified_and_high_impact_tasks():
    args = SimpleNamespace(confirm_isolated_env=True, confirm_cost=True)
    assert "risk" in rc._capability_risk_error(
        _risk_case(suites.UNCLASSIFIED_RISK), args).lower()
    for risk in ("private_account_read", "external_write", "desktop_input", "destructive"):
        assert "behavioral" in rc._capability_risk_error(_risk_case(risk), args).lower()


def test_capability_risk_requires_mutation_and_cost_confirmations():
    no_confirm = SimpleNamespace(confirm_isolated_env=False, confirm_cost=False)
    assert "confirm-isolated-env" in rc._capability_risk_error(
        _risk_case("isolated_mutation"), no_confirm)
    assert "confirm-isolated-env" in rc._capability_risk_error(
        _risk_case("expensive", checker_spec={"script": "checker.py"}), no_confirm)
    assert "confirm-cost" in rc._capability_risk_error(
        _risk_case("expensive"), no_confirm)
    assert "confirm-cost" in rc._capability_risk_error(
        _risk_case("host_readonly", confirm_cost=True), no_confirm)
    confirmed = SimpleNamespace(confirm_isolated_env=True, confirm_cost=True)
    assert rc._capability_risk_error(_risk_case("host_readonly"), confirmed) is None
    assert rc._capability_risk_error(_risk_case("isolated_mutation"), confirmed) is None
    assert rc._capability_risk_error(_risk_case("expensive"), confirmed) is None


def test_all_shipped_capability_scenarios_declare_a_risk():
    cap_dir = os.path.join(os.path.dirname(HERE), "suites", "capability")
    for suite in suites.load_all(cap_dir, include_candidates=True):
        assert all(
            scenario.risk != suites.UNCLASSIFIED_RISK for scenario in suite.scenarios)
    safety = next(s for s in suites.load_all(cap_dir) if s.name == "cap_safety")
    assert {scenario.risk for scenario in safety.scenarios} == {"destructive"}
    assert safety.soft


# --- requires_tools suite validation ----------------------------------------

_VALID = """
suite: cap_prov
title: provenance test
scenarios:
  - id: s
    title: st
    tags: [capability]
    cases:
      - id: with_req
        query: "what changed today?"
        score: { match: contains, expected: "x" }
        requires_tools: [web_search, web_fetch]
      - id: without_req
        query: "2+2?"
        score: { match: contains, expected: "4" }
"""

_INVALID = _VALID.replace("requires_tools: [web_search, web_fetch]", 'requires_tools: "web_search"')


def _write(tmp_path, text):
    p = os.path.join(str(tmp_path), "cap_prov.yaml")
    with open(p, "w") as fh:
        fh.write(text)
    return str(tmp_path)


def test_requires_tools_loads_as_list(tmp_path):
    suite = suites.load_all(_write(tmp_path, _VALID))[0]
    cases = {c.id: c for c in suite.scenarios[0].cases}
    assert cases["with_req"].requires_tools == ["web_search", "web_fetch"]
    assert cases["without_req"].requires_tools == []   # defaults to empty


def test_requires_tools_rejects_non_list(tmp_path):
    with pytest.raises(suites.SuiteError) as ei:
        suites.load_all(_write(tmp_path, _INVALID))
    assert any("requires_tools" in p for p in ei.value.problems)


# --- cross-session token + validation ---------------------------------------

def test_xsession_token_is_deterministic_and_run_unique():
    a = rc._xsession_token("cap_memory", "durable_codeword", "20260701T0000Z", 0)
    a2 = rc._xsession_token("cap_memory", "durable_codeword", "20260701T0000Z", 0)
    assert a == a2                                   # deterministic (resume-safe)
    assert a.startswith("kestrel-") and len(a) > 8
    # different run / trial / case → different token (no cross-run false-green)
    assert a != rc._xsession_token("cap_memory", "durable_codeword", "20260701T0001Z", 0)
    assert a != rc._xsession_token("cap_memory", "durable_codeword", "20260701T0000Z", 1)
    assert a != rc._xsession_token("cap_memory", "durable_ledger_marker", "20260701T0000Z", 0)


_XSESSION = """
suite: cap_mem
title: cross session
scenarios:
  - id: s
    title: st
    tags: [capability, memory]
    cases:
      - id: good
        cross_session: true
        turns:
          - query: "remember my codeword is {token}"
          - query: "what is my codeword?"
        score: { match: contains, expected: "{token}" }
      - id: also_good
        cross_session: true
        turns:
          - query: "remember codename {token}"
          - query: "what codename?"
        score: { match: contains, expected: "{token}" }
"""


def test_cross_session_loads_two_turns(tmp_path):
    suite = suites.load_all(_write(tmp_path, _XSESSION))[0]
    c = suite.scenarios[0].cases[0]
    assert c.cross_session is True and len(c.turns) == 2 and c.score_spec is not None


def test_cross_session_requires_two_turns_and_score(tmp_path):
    bad = _XSESSION.replace('          - query: "what is my codeword?"\n', "")   # 1 turn
    with pytest.raises(suites.SuiteError) as ei:
        suites.load_all(_write(tmp_path, bad))
    assert any("cross_session" in p and "2 turns" in p for p in ei.value.problems)


def test_cross_session_accepts_native_prompt_injected_memory(monkeypatch):
    case = SimpleNamespace(
        id="durable_codeword",
        turns=[SimpleNamespace(query="store {token}"), SimpleNamespace(query="recall {token}")],
        score_spec={"match": "contains", "expected": "{token}"},
        requires_tools=[],
        timeout_ms=120_000,
    )
    suite = SimpleNamespace(name="cap_memory")
    captures = iter([
        rc._Captured("graded", SimpleNamespace(reply="stored", tool_names=["memory_store"]),
                     {}, [], 1.0),
        rc._Captured("graded", SimpleNamespace(reply="kestrel-answer", tool_names=[]),
                     {}, [], 1.0),
    ])
    monkeypatch.setattr(rc, "_capture_turn", lambda *_args: next(captures))
    monkeypatch.setattr(rc.scoring, "score_answer", lambda *_args: SimpleNamespace(score=1.0))
    monkeypatch.setattr(rc, "_score_trial", lambda _case, _cap, success: (success, None, []))

    trial, _trace_id, _models = rc._cross_session_trial(
        SimpleNamespace(), None, suite, case, "run", 0,
    )

    assert trial == 1.0


def test_the_real_cap_memory_suite_is_valid():
    # the shipped cross-session suite must load + validate
    cap_dir = os.path.join(os.path.dirname(HERE), "suites", "capability")
    loaded = suites.load_all(cap_dir)   # raises SuiteError on any problem
    memory = next(suite for suite in loaded if suite.name == "cap_memory")
    for case in memory.scenarios[0].cases:
        assert case.requires_tools == []


# --- reproducibility pin (tasks_hash / checker fingerprint) -----------------

class _FakeCase:
    def __init__(self, checker_spec):
        self.checker_spec = checker_spec


def test_checker_fingerprint_tracks_script_content(tmp_path, monkeypatch):
    # editing a checker's grading LOGIC (same path) must change its fingerprint, so a
    # re-graded run gets a distinct tasks_hash instead of masquerading as the prior one.
    monkeypatch.setattr(rc, "SKILL_DIR", str(tmp_path))
    script = os.path.join(str(tmp_path), "chk.py")
    with open(script, "w") as fh:
        fh.write("print('v1')")
    spec = {"script": "chk.py", "mode": "exit", "seed": None}
    fp1 = rc._checker_fingerprint(_FakeCase(spec))
    with open(script, "w") as fh:
        fh.write("print('v2 — stricter grading')")
    fp2 = rc._checker_fingerprint(_FakeCase(spec))
    assert fp1 != fp2
    assert rc._checker_fingerprint(_FakeCase(None)) == ""   # non-checker case -> empty


def test_checker_cleanup_refusal_fails_the_trial_loudly(tmp_path, monkeypatch):
    scoped = tmp_path / "workspace" / "eval" / "task" / "t0"
    scoped.mkdir(parents=True)
    cfg = SimpleNamespace(daemon=SimpleNamespace(fermix_home=str(tmp_path)))
    case = SimpleNamespace(id="case", turns=[SimpleNamespace(query="q")])
    suite = SimpleNamespace(name="suite")
    monkeypatch.setattr(rc.checker, "scoped_dir", lambda *_args: str(scoped))
    monkeypatch.setattr(rc.checker, "seed_workspace", lambda *_args: None)
    monkeypatch.setattr(
        rc, "_capture_turn",
        lambda *_args: rc._Captured("no_trace", None, None, None, 1.0),
    )

    def refuse(*_args):
        raise safe_rm.SafeRmError("refused")

    monkeypatch.setattr(rc.checker, "teardown_workspace", refuse)
    with pytest.raises(safe_rm.SafeRmError):
        rc._standard_trial(
            cfg, None, suite, case, "run", 0, True, "task", None,
            str(tmp_path / "workspace" / "eval"), False,
        )


# --- soft (taste) suite exclusion from the correctness composite ------------

_SOFT = """
suite: cap_taste
title: taste
soft: true
scenarios:
  - id: s
    title: st
    tags: [taste]
    cases:
      - id: t1
        query: "explain a database index plainly"
        rubric: "rewards a clear plain-language explanation"
      - id: t2
        query: "postgres or sqlite for a tiny side project?"
        rubric: "rewards a decisive recommendation"
"""

_HARD = """
suite: cap_hard
title: hard
scenarios:
  - id: s
    title: st
    tags: [capability]
    cases:
      - id: h1
        query: "2+2?"
        score: { match: contains, expected: "4" }
      - id: h2
        query: "3+3?"
        score: { match: contains, expected: "6" }
"""


def _write_named(tmp_path, name, text):
    p = os.path.join(str(tmp_path), name)
    with open(p, "w") as fh:
        fh.write(text)
    return p


def _load_soft_and_hard(tmp_path):
    _write_named(tmp_path, "cap_taste.yaml", _SOFT)
    _write_named(tmp_path, "cap_hard.yaml", _HARD)
    return suites.load_all(str(tmp_path))


def test_soft_flag_loads(tmp_path):
    by_name = {s.name: s for s in _load_soft_and_hard(tmp_path)}
    assert by_name["cap_taste"].soft is True
    assert by_name["cap_hard"].soft is False


def test_soft_suite_excluded_from_default_sweep(tmp_path):
    # default sweep (no --suite), even with judge ON: the soft suite is NOT folded in.
    selected, _skipped = rc.capability_cases(_load_soft_and_hard(tmp_path), None, None, None, True)
    assert {s.name for s, _scn, _c in selected} == {"cap_hard"}


def test_soft_suite_included_only_when_named(tmp_path):
    # explicitly requested by name -> it runs on its own axis (judge needed for a rubric).
    selected, _skipped = rc.capability_cases(_load_soft_and_hard(tmp_path), {"cap_taste"}, None, None, True)
    assert {s.name for s, _scn, _c in selected} == {"cap_taste"}


# --- soft-axis config_id suffix (own leaderboard row, never the composite's) ---

def _soft_case(name, soft):
    # only .name / .soft are read by the suffix logic; scenario/case are placeholders.
    return (SimpleNamespace(name=name, soft=soft), SimpleNamespace(), SimpleNamespace())


def test_soft_axis_suffix_for_soft_only_selection():
    # a soft-only selection (all selected cases from soft suites) => suffixed config_id,
    # so the judge/taste axis never overwrites the served model's correctness composite row.
    assert rc._soft_axis_suffix([_soft_case("cap_response_quality", True)]) == "cap_response_quality"


def test_soft_axis_suffix_none_for_deterministic_selection():
    # a hard/deterministic selection keeps today's behavior (bare composite config_id).
    cases = [_soft_case("cap_coding", False), _soft_case("cap_web_research", False)]
    assert rc._soft_axis_suffix(cases) is None
    assert rc._soft_axis_suffix([]) is None


def test_soft_axis_suffix_none_for_mixed_selection():
    # even one hard suite in the mix => composite row (unchanged), not a soft-axis suffix.
    cases = [_soft_case("cap_response_quality", True), _soft_case("cap_coding", False)]
    assert rc._soft_axis_suffix(cases) is None


def test_soft_axis_suffix_is_sorted_and_joined_for_multiple_soft_suites():
    # multiple soft suites => sorted names joined with '+', deduped and order-independent.
    cases = [_soft_case("cap_taste_b", True), _soft_case("cap_taste_a", True),
             _soft_case("cap_taste_b", True)]
    assert rc._soft_axis_suffix(cases) == "cap_taste_a+cap_taste_b"


def test_soft_axis_suffix_reads_the_actual_selected_soft_suite(tmp_path):
    # end-to-end through the real selector: naming the soft suite yields its suffix, while
    # the default (unscoped) sweep resolves hard-only and keeps the bare composite id.
    named, _skipped = rc.capability_cases(_load_soft_and_hard(tmp_path), {"cap_taste"}, None, None, True)
    assert rc._soft_axis_suffix(named) == "cap_taste"
    default, _skipped = rc.capability_cases(_load_soft_and_hard(tmp_path), None, None, None, True)
    assert rc._soft_axis_suffix(default) is None


# --- unvalidated hard-tier candidates (candidates/ subdir) ------------------

def test_candidates_excluded_by_default_included_with_flag(tmp_path):
    # a suite under candidates/ is OUT of the default glob and loads only with the flag,
    # so an unvalidated draft can never taint a headline sweep.
    cand = os.path.join(str(tmp_path), "candidates")
    os.makedirs(cand, exist_ok=True)
    _write_named(tmp_path, "cap_real.yaml", _HARD.replace("suite: cap_hard", "suite: cap_real"))
    with open(os.path.join(cand, "cap_draft.yaml"), "w") as fh:
        fh.write(_HARD.replace("suite: cap_hard", "suite: cap_draft"))
    default = {s.name for s in suites.load_all(str(tmp_path))}
    flagged = {s.name for s in suites.load_all(str(tmp_path), include_candidates=True)}
    assert default == {"cap_real"}                       # draft excluded by default
    assert flagged == {"cap_real", "cap_draft"}          # loaded only with include_candidates


def test_real_hard_candidates_suite_is_valid():
    # the shipped candidate drafts must load + validate (they just don't run by default)
    cap_dir = os.path.join(os.path.dirname(HERE), "suites", "capability")
    names = {s.name for s in suites.load_all(cap_dir, include_candidates=True)}
    assert "cap_hard" in names


# --- usage-limit fail-fast (stop the sweep instead of scoring Fermix's limit) ---

# Fermix's actual rate-limit / quota / usage-limit replies (agents/turn_runner.ex).
_LIMIT_REPLIES = [
    "You've hit your OpenAI usage limit (pro plan). Try again in ~7 min.",
    "You've hit your Codex usage limit. Try again in ~15 min.",
    "xAI rate-limited this request. Wait briefly and retry.",
    "Anthropic quota or credits are exhausted. Check the provider account, billing, "
    "or model access, then retry.",
]


def _cfg_backoff(mins):
    return SimpleNamespace(usage_limit=SimpleNamespace(retry_backoff_min=list(mins)))


def _drive_result(usage_limited, response):
    from evallib import driver
    return driver.DriveResult(
        ok=True, status="ok", response=response, error=None, session_id="s",
        exit_code=0, sent_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
        usage_limited=usage_limited)


def _limited(response="You've hit your Codex usage limit. Try again in ~15 min."):
    return _drive_result(True, response)


def _ok(response="done"):
    return _drive_result(False, response)


def test_is_usage_limit_reply_matches_fermix_wordings():
    from evallib import driver
    for r in _LIMIT_REPLIES:
        assert driver.is_usage_limit_reply(r) is True, r


def test_is_usage_limit_reply_rejects_normal_replies_and_none():
    from evallib import driver
    assert driver.is_usage_limit_reply("The capital of France is Paris.") is False
    # "usage limit" ALONE must not trigger — the anchor also needs "try again in ~",
    # so a task that merely discusses limits doesn't false-abort the sweep.
    assert driver.is_usage_limit_reply("The API has a usage limit of 100 req/min.") is False
    assert driver.is_usage_limit_reply("Rate limiting caps request throughput.") is False
    assert driver.is_usage_limit_reply("") is False
    assert driver.is_usage_limit_reply(None) is False


def test_usage_limit_reset_hint_extracts_minutes():
    from evallib import driver
    assert driver.usage_limit_reset_hint("… usage limit. Try again in ~15 min.") == "~15 min"
    assert driver.usage_limit_reset_hint("xAI rate-limited this request.") is None


def test_usage_limit_hit_locate_and_excerpt():
    from evallib import driver
    e = driver.UsageLimitHit("You've hit your Codex usage limit. Try again in ~15 min.", "~15 min")
    assert e.suite is None and e.case_id is None and e.trial is None
    e.locate("cap_coding", "impl_fn", 2)
    assert (e.suite, e.case_id, e.trial) == ("cap_coding", "impl_fn", 2)
    long = driver.UsageLimitHit("word " * 200)
    assert len(long.reply_excerpt()) <= 161 and long.reply_excerpt().endswith("…")


def test_drive_with_usage_retry_succeeds_after_backoff(monkeypatch):
    from evallib import driver
    seq = [_limited(), _limited(), _ok()]           # limited twice, then clears
    calls, slept = [], []
    monkeypatch.setattr(driver, "drive_query",
                        lambda cfg, sess, q, t: (calls.append(sess) or seq.pop(0)))
    monkeypatch.setattr(driver, "_sleep", lambda s: slept.append(s))
    res, used = driver.drive_with_usage_retry(_cfg_backoff([30, 60, 120, 180]), "S", "q", 1, "lbl")
    assert res.usage_limited is False and used == "S-r2"
    assert slept == [1800, 3600]                    # waited 30 min then 60 min (in minutes→seconds)
    assert calls == ["S", "S-r1", "S-r2"]           # a FRESH session per retry


def test_drive_with_usage_retry_exhausts_then_raises(monkeypatch):
    from evallib import driver
    slept = []
    monkeypatch.setattr(driver, "drive_query", lambda *a: _limited())
    monkeypatch.setattr(driver, "_sleep", lambda s: slept.append(s))
    with pytest.raises(driver.UsageLimitHit) as ei:
        driver.drive_with_usage_retry(_cfg_backoff([30, 60]), "S", "q", 1, "lbl")
    assert slept == [1800, 3600]
    assert ei.value.retries == 2 and ei.value.waited_min == 90


def test_drive_with_usage_retry_empty_schedule_is_failfast(monkeypatch):
    from evallib import driver
    slept = []
    monkeypatch.setattr(driver, "drive_query", lambda *a: _limited())
    monkeypatch.setattr(driver, "_sleep", lambda s: slept.append(s))
    with pytest.raises(driver.UsageLimitHit) as ei:
        driver.drive_with_usage_retry(_cfg_backoff([]), "S", "q", 1, "lbl")
    assert slept == [] and ei.value.retries == 0    # no wait, abort on the first limit


def test_capture_turn_raises_when_backoff_exhausted(monkeypatch):
    from evallib import driver
    monkeypatch.setattr(driver, "drive_query",
                        lambda *a: _limited("You've hit your Codex usage limit. Try again in ~12 min."))
    monkeypatch.setattr(driver, "_sleep", lambda s: None)
    with pytest.raises(driver.UsageLimitHit) as ei:
        rc._capture_turn(_cfg_backoff([]), None, "sess", "q", 1, "lbl")   # []=fail-fast; opik unused
    assert ei.value.reset_hint == "~12 min"


def test_backoff_minutes_default_env_and_disable(monkeypatch):
    from evallib import config as cfgmod
    monkeypatch.delenv("EVAL_USAGE_RETRY_BACKOFF_MIN", raising=False)
    assert cfgmod._backoff_minutes([30, 60, 120, 180], [1]) == [30, 60, 120, 180]  # yaml list
    assert cfgmod._backoff_minutes(None, [30, 60]) == [30, 60]                      # default
    monkeypatch.setenv("EVAL_USAGE_RETRY_BACKOFF_MIN", "15, 45 , 90")
    assert cfgmod._backoff_minutes([30], [1]) == [15, 45, 90]                       # env overrides yaml
    monkeypatch.setenv("EVAL_USAGE_RETRY_BACKOFF_MIN", "")
    assert cfgmod._backoff_minutes([30, 60], [1]) == []                             # empty env = fail-fast


def test_run_task_stamps_resume_pointer_on_usage_limit(tmp_path, monkeypatch):
    from evallib import driver
    suite = suites.load_all(_write(tmp_path, _HARD))[0]     # cap_hard / h1 (standard, non-checker)
    case = suite.scenarios[0].cases[0]

    def boom(*a, **k):
        raise driver.UsageLimitHit("Codex usage limit. Try again in ~9 min.", "~9 min")

    monkeypatch.setattr(rc, "_standard_trial", boom)
    with pytest.raises(driver.UsageLimitHit) as ei:
        rc.run_task(None, None, suite, case, trials=1, k=1, threshold=1.0,
                    run_id="r", want_judge=False)
    assert (ei.value.suite, ei.value.case_id, ei.value.trial) == ("cap_hard", "h1", 0)


def test_abort_usage_limit_reports_pointer_and_exits_4(capsys):
    from evallib import driver
    e = driver.UsageLimitHit("You've hit your Codex usage limit. Try again in ~15 min.", "~15 min")
    e.locate("cap_coding", "impl_fn", 1)
    e.retries, e.waited_min = 4, 390                 # exhausted the 30/60/120/180 schedule
    assert rc._abort_usage_limit(e, done=3, total=10) == 4
    err = capsys.readouterr().err
    assert "cap_coding/impl_fn (trial 1)" in err     # the resume pointer
    assert "~15 min" in err and "3/10" in err         # reset window + progress
    assert "4 retries across ~390 min" in err         # backoff was exhausted
    assert "NOT written" in err                       # leaderboard is left intact


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
