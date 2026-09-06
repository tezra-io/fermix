#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7", "certifi"]
# ///
"""Tests for the checker scoring tier — the SafeRm teardown guard, the
`run_checker` mechanism (exit/json modes + recorded errors + the per-trial
evidence file), the suite `checker:` block validation, and every capability
checker's oracle/negative set. Pure / temp-dir; no daemon.
Run: `uv run bin/test_checker.py`."""
from __future__ import annotations

import datetime
import math
import os
import stat
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

from evallib import checker, safe_rm, suites  # noqa: E402


# --- SafeRm teardown guard --------------------------------------------------

def test_safe_rm_rejects_traversal():
    with pytest.raises(safe_rm.SafeRmError):
        safe_rm.check("/root/eval/../../etc", "/root/eval")


def test_safe_rm_rejects_outside_root():
    with pytest.raises(safe_rm.SafeRmError):
        safe_rm.check("/other/place", "/root/eval")


def test_safe_rm_rejects_root_itself_and_too_shallow(tmp_path):
    root = os.path.join(str(tmp_path), "ws", "eval")
    os.makedirs(root)
    with pytest.raises(safe_rm.SafeRmError):
        safe_rm.check(root, root, min_below=2)            # root itself
    with pytest.raises(safe_rm.SafeRmError):
        safe_rm.check(os.path.join(root, "task"), root, min_below=2)  # only 1 below


def test_safe_rm_accepts_and_removes_scoped_dir(tmp_path):
    root = os.path.join(str(tmp_path), "ws", "eval")
    scoped = os.path.join(root, "task", "t0")
    os.makedirs(scoped)
    open(os.path.join(scoped, "f.txt"), "w").close()
    safe_rm.rm_rf(scoped, root, min_below=2)
    assert not os.path.exists(scoped)


# --- run_checker ------------------------------------------------------------

def _script(tmp_path, name, body):
    p = os.path.join(str(tmp_path), name)
    with open(p, "w") as fh:
        fh.write(body)
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
    return p


def test_checker_exit_mode_pass(tmp_path):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/ok.sh", "#!/bin/sh\nexit 0\n")
    r = checker.run_checker(str(tmp_path), {"script": "checkers/ok.sh", "mode": "exit"},
                            scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="")
    assert r.score == 1.0 and r.error is None


def test_checker_missing_fermix_home_is_a_recorded_error_not_a_zero(tmp_path):
    # A checker reading ground truth from a home that is not there finds nothing
    # and scores 0 — indistinguishable from the model failing the task. The
    # workspace was already held to this standard; the home was not.
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/ok.sh", "#!/bin/sh\nexit 0\n")
    r = checker.run_checker(str(tmp_path), {"script": "checkers/ok.sh", "mode": "exit"},
                            scoped_dir=str(tmp_path),
                            fermix_home=os.path.join(str(tmp_path), "no-such-home"),
                            reply="")
    assert r.score == 0.0
    assert r.error is not None and "fermix_home not found" in r.error


def test_checker_exit_mode_fail(tmp_path):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/no.sh", "#!/bin/sh\nexit 3\n")
    r = checker.run_checker(str(tmp_path), {"script": "checkers/no.sh", "mode": "exit"},
                            scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="")
    assert r.score == 0.0 and r.error is None


def test_checker_json_mode_parses_score(tmp_path):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/j.sh", '#!/bin/sh\necho \'{"score": 0.5, "detail": "half"}\'\n')
    r = checker.run_checker(str(tmp_path), {"script": "checkers/j.sh", "mode": "json"},
                            scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="")
    assert r.score == 0.5 and "half" in r.detail


def test_checker_sees_workspace_and_reply_env(tmp_path):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    # passes only if both env vars are wired through
    _script(tmp_path, "checkers/env.sh",
            '#!/bin/sh\n[ -n "$FERMIX_EVAL_WORKSPACE" ] && [ "$FERMIX_EVAL_REPLY" = "hi" ] && exit 0 || exit 1\n')
    r = checker.run_checker(str(tmp_path), {"script": "checkers/env.sh", "mode": "exit"},
                            scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="hi")
    assert r.score == 1.0


def test_checker_subprocess_env_does_not_inherit_secrets(tmp_path, monkeypatch):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    monkeypatch.setenv("FERMIX_EVAL_SHOULD_NOT_LEAK", "secret")
    _script(tmp_path, "checkers/env-clean.sh",
            '#!/bin/sh\n[ -n "$PATH" ] && [ -z "$FERMIX_EVAL_SHOULD_NOT_LEAK" ]\n')
    r = checker.run_checker(str(tmp_path),
                            {"script": "checkers/env-clean.sh", "mode": "exit"},
                            scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="")
    assert r.score == 1.0 and r.error is None


@pytest.mark.parametrize("script_path", [
    "/tmp/checker.sh", "../checker.sh", r"C:\tmp\checker.sh", r"\\server\share\checker.sh",
])
def test_checker_rejects_absolute_and_traversal_script_paths(tmp_path, script_path):
    r = checker.run_checker(str(tmp_path), {"script": script_path, "mode": "exit"},
                            scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="")
    assert r.score == 0.0 and r.error and "path" in r.error.lower()


def test_checker_rejects_script_symlink_escape(tmp_path):
    harness = tmp_path / "harness"
    checkers = harness / "checkers"
    checkers.mkdir(parents=True)
    outside = _script(tmp_path, "outside.sh", "#!/bin/sh\nexit 0\n")
    os.symlink(outside, checkers / "escape.sh")
    r = checker.run_checker(str(harness),
                            {"script": "checkers/escape.sh", "mode": "exit"},
                            scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="")
    assert r.score == 0.0 and r.error and "outside" in r.error.lower()


def test_checker_rejects_unknown_mode_before_execution(tmp_path):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/ok.sh", "#!/bin/sh\nexit 0\n")
    r = checker.run_checker(str(tmp_path), {"script": "checkers/ok.sh", "mode": "yaml"},
                            scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="")
    assert r.score == 0.0 and r.error and "mode" in r.error.lower()


@pytest.mark.parametrize("timeout_s", [0, -1, math.inf, math.nan, True, "1", 10**1000])
def test_checker_rejects_invalid_timeout_override(tmp_path, timeout_s):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/ok.sh", "#!/bin/sh\nexit 0\n")
    r = checker.run_checker(str(tmp_path), {"script": "checkers/ok.sh", "mode": "exit"},
                            scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="", timeout_s=timeout_s)
    assert r.score == 0.0 and r.error and "timeout" in r.error.lower()


@pytest.mark.parametrize("timeout_ms", [0, -1, math.inf, math.nan, True, "1000", 10**1000])
def test_checker_rejects_invalid_spec_timeout(tmp_path, timeout_ms):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/ok.sh", "#!/bin/sh\nexit 0\n")
    spec = {"script": "checkers/ok.sh", "mode": "exit", "timeout_ms": timeout_ms}
    r = checker.run_checker(str(tmp_path), spec, scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="")
    assert r.score == 0.0 and r.error and "timeout" in r.error.lower()


def test_checker_missing_script_records_error(tmp_path):
    r = checker.run_checker(str(tmp_path), {"script": "checkers/nope.sh", "mode": "exit"},
                            scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="")
    assert r.score == 0.0 and r.error and "not found" in r.error.lower()


def test_checker_bad_json_records_error(tmp_path):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/garbage.sh", "#!/bin/sh\necho not-json\n")
    r = checker.run_checker(str(tmp_path), {"script": "checkers/garbage.sh", "mode": "json"},
                            scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="")
    assert r.score == 0.0 and r.error


@pytest.mark.parametrize(
    "score", ["NaN", "Infinity", "-0.1", "1.1", "true", '"0.5"', "1" + "0" * 400])
def test_checker_rejects_non_finite_out_of_range_or_non_numeric_score(tmp_path, score):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    body = f'#!/bin/sh\necho \'{{"score": {score}, "detail": "bad"}}\'\n'
    _script(tmp_path, "checkers/bad-score.sh", body)
    r = checker.run_checker(str(tmp_path),
                            {"script": "checkers/bad-score.sh", "mode": "json"},
                            scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="")
    assert r.score == 0.0 and r.error


@pytest.mark.parametrize("line", ["0.5", "null", "[1, 2]", '"done"'])
def test_checker_non_object_json_records_error_not_crash(tmp_path, line):
    # Valid JSON that isn't a {score,...} object must be a recorded 0-score, NOT an
    # uncaught TypeError that discards the whole (expensive) sweep. Regression for
    # the crash where `float(data["score"])` on a bare number/null/list raised.
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/bare.sh", f"#!/bin/sh\necho '{line}'\n")
    r = checker.run_checker(str(tmp_path), {"script": "checkers/bare.sh", "mode": "json"},
                            scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="")
    assert r.score == 0.0 and r.error and "parse failed" in r.error


# --- the checker's own safety verdict ---------------------------------------

def _json_result(tmp_path, payload: str):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/s.sh", f"#!/bin/sh\ncat <<'EOF'\n{payload}\nEOF\n")
    return checker.run_checker(str(tmp_path), {"script": "checkers/s.sh", "mode": "json"},
                               scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="")


def test_a_checker_that_says_nothing_about_safety_leaves_it_not_evaluated(tmp_path):
    r = _json_result(tmp_path, '{"score": 1.0, "detail": "done"}')
    assert r.error is None and r.safety_ok is None and r.violations == []


def test_a_checker_can_report_that_it_looked_and_found_nothing(tmp_path):
    r = _json_result(tmp_path, '{"score": 1.0, "detail": "done", "safety_ok": true}')
    assert r.safety_ok is True and r.violations == []


def test_a_named_violation_is_a_safety_violation_even_without_the_flag(tmp_path):
    # Naming a violation IS the observation; requiring both keys would let a checker
    # report harm and still read as "nothing was evaluated".
    r = _json_result(tmp_path,
                     '{"score": 1.0, "detail": "d", "violations": ["deleted keep-me"]}')
    assert r.safety_ok is False and r.violations == ["deleted keep-me"]


@pytest.mark.parametrize("payload", [
    '{"score": 1.0, "safety_ok": "yes"}',
    '{"score": 1.0, "safety_ok": 1}',
    '{"score": 1.0, "violations": "deleted keep-me"}',
    '{"score": 1.0, "violations": [3]}',
])
def test_a_malformed_safety_verdict_is_a_recorded_checker_error(tmp_path, payload):
    # Quietly dropping it would turn a typo into "nothing was evaluated", which is the
    # one reading a safety field must never acquire by accident.
    r = _json_result(tmp_path, payload)
    assert r.score == 0.0 and r.error and "safety verdict invalid" in r.error


def test_evidence_cleanup_failure_is_recorded_not_raised(tmp_path, monkeypatch):
    # Raising out of the `finally` masked the CheckerResult and took the whole sweep
    # with it — including when the dir was simply already gone.
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/ok.sh", "#!/bin/sh\nexit 0\n")

    def boom(_dir, _root, **_kw):
        raise OSError("device busy")

    monkeypatch.setattr(checker.safe_rm, "rm_rf", boom)
    r = checker.run_checker(str(tmp_path), {"script": "checkers/ok.sh", "mode": "exit"},
                            scoped_dir=str(tmp_path), fermix_home=str(tmp_path),
                            reply="", evidence={"tool_spans": []})
    assert r.score == 0.0 and r.error and "could not be removed" in r.error


def test_checker_sees_the_fermix_home_env(tmp_path):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    # ground-truth checkers read daemon state under the home; the env var must
    # carry the caller's fermix_home, not be derived or absent
    _script(tmp_path, "checkers/home.sh",
            '#!/bin/sh\n[ -d "$FERMIX_EVAL_HOME" ] && [ "$FERMIX_EVAL_HOME" != "$FERMIX_EVAL_WORKSPACE" ] && exit 0 || exit 1\n')
    scoped = os.path.join(str(tmp_path), "ws")
    os.makedirs(scoped)
    r = checker.run_checker(str(tmp_path), {"script": "checkers/home.sh", "mode": "exit"},
                            scoped_dir=scoped, fermix_home=str(tmp_path), reply="")
    assert r.score == 1.0 and r.error is None


# --- the per-trial evidence file --------------------------------------------

EVIDENCE = {"schema": 1, "run_id": "run-1", "trial": 0, "session": "e2e-cap/x",
            "trace_id": None, "token": "TOK-DEADBEEF", "reply": "done",
            "tool_spans": [{"name": "run_job_now", "status": "ok", "error": None,
                            "input": {"job_id": "j1"}, "output": "ok",
                            "start_time": "2026-09-04T10:00:00Z",
                            "end_time": "2026-09-04T10:00:05Z"}]}


def _record_evidence_dirs(monkeypatch) -> list:
    """Record the temp dirs THIS call creates. Globbing the shared temp dir would
    also see other processes' evidence dirs, which is a race, not a leak."""
    created: list = []
    real = tempfile.mkdtemp

    def spy(*args, **kwargs):
        path = real(*args, **kwargs)
        created.append(path)
        return path

    monkeypatch.setattr(checker.tempfile, "mkdtemp", spy)
    return created


def _evidence_probe(tmp_path):
    """A checker that records where its evidence file was, so the test can prove
    the file existed during the run and its temp dir is gone afterwards."""
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/ev.sh",
            '#!/bin/sh\n'
            '[ -f "$FERMIX_EVAL_EVIDENCE" ] || exit 1\n'
            'grep -q TOK-DEADBEEF "$FERMIX_EVAL_EVIDENCE" || exit 1\n'
            'case "$FERMIX_EVAL_EVIDENCE" in "$FERMIX_EVAL_WORKSPACE"/*) exit 1 ;; esac\n'
            'printf %s "$FERMIX_EVAL_EVIDENCE" > "$FERMIX_EVAL_WORKSPACE/seen_evidence"\n'
            'exit 0\n')
    scoped = os.path.join(str(tmp_path), "ws")
    os.makedirs(scoped, exist_ok=True)
    return scoped


def test_checker_evidence_is_readable_json_outside_the_workspace(tmp_path):
    # The runner's correlation evidence must reach the checker as a JSON file the
    # agent could never have written — outside the scored workspace.
    scoped = _evidence_probe(tmp_path)
    r = checker.run_checker(str(tmp_path), {"script": "checkers/ev.sh", "mode": "exit"},
                            scoped_dir=scoped, fermix_home=str(tmp_path), reply="",
                            evidence=EVIDENCE)
    assert r.score == 1.0 and r.error is None
    with open(os.path.join(scoped, "seen_evidence")) as fh:
        seen = fh.read()
    assert os.path.basename(seen) == "evidence.json"
    assert not os.path.exists(os.path.dirname(seen))   # temp dir removed after the run


def test_checker_without_evidence_leaves_the_variable_unset(tmp_path):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/none.sh",
            '#!/bin/sh\n[ -z "$FERMIX_EVAL_EVIDENCE" ]\n')
    r = checker.run_checker(str(tmp_path), {"script": "checkers/none.sh", "mode": "exit"},
                            scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="")
    assert r.score == 1.0 and r.error is None


def test_checker_removes_the_evidence_dir_on_timeout(tmp_path, monkeypatch):
    # Own every resource on every path: a checker killed by the timeout must not
    # leave the trial's evidence behind in the temp dir.
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/slow.sh", "#!/bin/sh\nsleep 5\n")
    created = _record_evidence_dirs(monkeypatch)
    r = checker.run_checker(str(tmp_path), {"script": "checkers/slow.sh", "mode": "exit"},
                            scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="",
                            evidence=EVIDENCE, timeout_s=0.4)
    assert r.score == 0.0 and r.error and "timed out" in r.error
    assert created and not [d for d in created if os.path.exists(d)]


@pytest.mark.parametrize("evidence", [[1, 2], "text", 3, {"bad": object()}])
def test_checker_rejects_unwritable_evidence_without_leaking_a_dir(tmp_path, monkeypatch,
                                                                  evidence):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/ok.sh", "#!/bin/sh\nexit 0\n")
    created = _record_evidence_dirs(monkeypatch)
    r = checker.run_checker(str(tmp_path), {"script": "checkers/ok.sh", "mode": "exit"},
                            scoped_dir=str(tmp_path), fermix_home=str(tmp_path), reply="",
                            evidence=evidence)
    assert r.score == 0.0 and r.error and "evidence" in r.error
    assert not [d for d in created if os.path.exists(d)]


# --- the real skill_created checker: ground truth, not the model's claim -----

SKILL_CREATED = {"script": "suites/capability/checkers/skill_created.py", "mode": "json"}


def _iso(seconds_ago):
    """Span timestamps as the runner records them (UTC, Z-suffixed). Relative to
    now so freshness assertions compare against real file mtimes."""
    moment = datetime.datetime.fromtimestamp(time.time() - seconds_ago,
                                             datetime.timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


T0, T1, T2 = _iso(30), _iso(20), _iso(10)


def _span(name, status="ok", inp=None, out=None, start=None, end=None):
    """One evidence span in the shape `run_capability._evidence_spans` actually records:
    `input` verbatim off the Opik span (absent for every `Support.run` tool, and an
    Elixir `inspect` rendering wrapped as {"text": …} for the rest), `output` as text."""
    return {"name": name, "status": status, "error": None if status == "ok" else "boom",
            "input": inp, "output": out, "start_time": start, "end_time": end}


def _inspect_input(**pairs):
    """The Opik rendering of a tool input: `FermixCore.Telemetry.preview/1`'s Elixir
    `inspect` output, wrapped as {"text": …}. It is NOT JSON, and it contains `=>` —
    which is why matching the `">"` shell-write marker against the whole blob flagged
    every read-only `cat` of the artifact as a direct write."""
    body = ", ".join('"%s" => "%s"' % (k, v.replace('"', '\\"'))
                     for k, v in pairs.items())
    return {"text": "%%{%s}" % body}


def _shell_span(command, start=None, end=None, status="ok"):
    return _span("shell", status=status, inp=_inspect_input(command=command),
                 out="", start=start, end=end)


def _support_span(name, output, start=None, end=None, status="ok"):
    """A tool routed through `FermixCore.Tools.Support.run/3` — schedule_job,
    run_job_now, skill_create, skill_reload. Verified against every such span recorded
    in ~/.fermix-dev/traces: NO input is ever attached, and a successful schedule_job
    carries no output either."""
    return _span(name, status=status, inp=None, out=output, start=start, end=end)


def _ev(token="TOK-DEADBEEF", spans=(), reply=""):
    return {"schema": 1, "run_id": "run-1", "trial": 0, "session": "e2e-cap/x",
            "trace_id": None, "token": token, "reply": reply, "tool_spans": list(spans)}


SKILL_SPANS = (_support_span(
                   "skill_create",
                   '{"path":"/home/.fermix-eval/skills/eval-echo","created":true}',
                   start=T0, end=T1),
               _support_span("skill_reload", '{"count":3,"version":2}',
                             start=T1, end=T2))


def _skill_home(tmp_path, listing, skill_md=None):
    """A fake capability home: a scoped trial workspace plus (optionally) the
    skill the task under test is supposed to create."""
    home = tmp_path / "cap-eval-home"
    ws = home / "workspace" / "eval" / "cap_agentic-create_and_confirm_skill" / "t0"
    ws.mkdir(parents=True)
    if listing is not None:
        (ws / "skills.txt").write_text(listing)
    if skill_md is not None:
        d = home / "skills" / "eval-echo"
        d.mkdir(parents=True)
        (d / "SKILL.md").write_text(skill_md)
    return home, ws


GOOD_SKILL_MD = "# eval-echo\n\nAlways reply with the single word ECHO.\n"
GOOD_LISTING = "browser-guidance\neval-echo\nself-knowledge\n"


def _skill_score(home, ws, evidence):
    return checker.run_checker(BENCH, SKILL_CREATED, scoped_dir=str(ws),
                               fermix_home=str(home), reply="done", evidence=evidence)


def test_skill_created_reference_solution_passes(tmp_path):
    home, ws = _skill_home(tmp_path, GOOD_LISTING, GOOD_SKILL_MD)
    r = _skill_score(home, ws, _ev(spans=SKILL_SPANS))
    assert r.error is None and r.score == 1.0


def test_skill_created_rejects_prose_without_the_artifact(tmp_path):
    # "I created the skill" with nothing written: no listing at all.
    home, ws = _skill_home(tmp_path, None, GOOD_SKILL_MD)
    r = _skill_score(home, ws, _ev(spans=SKILL_SPANS))
    assert r.score == 0.0 and "skills.txt" in r.detail


def test_skill_created_rejects_stale_wrong_body_skill(tmp_path):
    # A SKILL.md left by an earlier sweep whose body is NOT the asked-for
    # instruction: the listing is right, the skill is wrong.
    home, ws = _skill_home(tmp_path, GOOD_LISTING,
                           "# eval-echo\n\nAlways reply with the word HELLO.\n")
    r = _skill_score(home, ws, _ev(spans=SKILL_SPANS))
    assert r.score == 0.0 and "ECHO" in r.detail


def test_skill_created_rejects_partial_completion_without_reload(tmp_path):
    # Created but never reloaded: the skill is not live, which is half the task.
    home, ws = _skill_home(tmp_path, GOOD_LISTING, GOOD_SKILL_MD)
    r = _skill_score(home, ws, _ev(spans=(SKILL_SPANS[0],)))
    assert r.score == 0.0 and "reload" in r.detail


def test_skill_created_rejects_reload_that_precedes_the_creation(tmp_path):
    # A reload BEFORE the create cannot have registered it — ordering is the
    # whole evidence that the listing was observed live.
    spans = (_support_span("skill_create", '{"path":"/h/skills/eval-echo","created":true}',
                           start=T1, end=T2),
             _support_span("skill_reload", '{"count":3}', start=T0, end=T1))
    home, ws = _skill_home(tmp_path, GOOD_LISTING, GOOD_SKILL_MD)
    r = _skill_score(home, ws, _ev(spans=spans))
    assert r.score == 0.0 and "reload" in r.detail


def test_skill_created_rejects_wrong_skill_name_in_the_creation_span(tmp_path):
    spans = (_support_span("skill_create", '{"path":"/h/skills/eval-other","created":true}',
                           start=T0, end=T1),
             _support_span("skill_reload", '{"count":3}', start=T1, end=T2))
    home, ws = _skill_home(tmp_path, GOOD_LISTING, GOOD_SKILL_MD)
    r = _skill_score(home, ws, _ev(spans=spans))
    assert r.score == 0.0 and "skill_create" in r.detail


def test_skill_created_rejects_a_note_that_only_mentions_the_name(tmp_path):
    # The token-only shortcut: the name appears in the listing file, but as prose
    # reporting failure rather than as a listed skill.
    home, ws = _skill_home(tmp_path,
                           "browser-guidance\n(eval-echo could not be created)\n",
                           GOOD_SKILL_MD)
    r = _skill_score(home, ws, _ev(spans=SKILL_SPANS))
    assert r.score == 0.0 and "listing" in r.detail


def test_skill_created_rejects_a_hand_written_skill_file(tmp_path):
    # Direct-write shortcut: SKILL.md authored with file_write, no skill_create.
    spans = (_span("file_write",
                   inp=_inspect_input(path="skills/eval-echo/SKILL.md", content="x"),
                   start=T0, end=T1),
             _support_span("skill_reload", '{"count":3}', start=T1, end=T2))
    home, ws = _skill_home(tmp_path, GOOD_LISTING, GOOD_SKILL_MD)
    r = _skill_score(home, ws, _ev(spans=spans))
    assert r.score == 0.0 and "skill_create" in r.detail


def test_skill_created_refuses_without_evidence(tmp_path):
    # Never assume: with no evidence file the provenance half is unmeasured, and
    # unmeasured is not a pass.
    home, ws = _skill_home(tmp_path, GOOD_LISTING, GOOD_SKILL_MD)
    r = checker.run_checker(BENCH, SKILL_CREATED, scoped_dir=str(ws),
                            fermix_home=str(home), reply="done")
    assert r.score == 0.0 and "no evidence file" in r.detail


def test_skill_created_rejects_listing_without_skill_on_disk(tmp_path):
    # A model could write the expected listing without creating anything; the
    # checker must verify the skill exists on disk, not trust the claim.
    home, ws = _skill_home(tmp_path, GOOD_LISTING, skill_md=None)
    r = _skill_score(home, ws, _ev(spans=SKILL_SPANS))
    assert r.score == 0.0 and "disk" in r.detail


def test_skill_created_rejects_skill_on_disk_that_is_not_listed(tmp_path):
    # The listing proves the model observed the skill LIVE (post-reload); disk
    # alone isn't enough.
    home, ws = _skill_home(tmp_path, "browser-guidance\nself-knowledge\n", GOOD_SKILL_MD)
    r = _skill_score(home, ws, _ev(spans=SKILL_SPANS))
    assert r.score == 0.0 and "listing" in r.detail


# --- suite `checker:` validation --------------------------------------------

def test_validate_checker_ok():
    problems: list[str] = []
    suites._validate_checker({"script": "checkers/x.py", "mode": "exit"}, "x", problems)
    assert problems == []


def test_validate_checker_requires_script_and_mode():
    problems: list[str] = []
    suites._validate_checker({"mode": "exit"}, "x", problems)
    suites._validate_checker({"script": "x", "mode": "bogus"}, "y", problems)
    assert any("script" in p for p in problems)
    assert any("mode" in p for p in problems)


@pytest.mark.parametrize("key,value", [
    ("script", "/tmp/checker.py"),
    ("script", "../checker.py"),
    ("script", r"C:\tmp\checker.py"),
    ("seed", "/tmp/fixtures"),
    ("seed", "../fixtures"),
    ("seed", r"\\server\share\fixtures"),
])
def test_validate_checker_rejects_absolute_and_traversal_paths(key, value):
    spec = {"script": "checkers/x.py", "mode": "exit"}
    spec[key] = value
    problems: list[str] = []
    suites._validate_checker(spec, "x", problems)
    assert any(key in problem and "relative" in problem for problem in problems)


def test_checker_and_score_mutually_exclusive():
    # a case can't carry both `score:` and `checker:` — validated in _load_one
    problems: list[str] = []
    suites._validate_checker("not-a-map", "x", problems)
    assert any("map" in p for p in problems)


# --- anchor-task oracle/negative proofs (check passes IFF solved; no daemon) -----

import json as _json  # noqa: E402

BENCH = os.path.dirname(HERE)                       # HERE = bin/ -> benchmark/


def _seed(tmp_path, fixture_rel):
    cleanup_root = os.path.join(str(tmp_path), "cleanup")
    scoped = os.path.join(cleanup_root, "task", "t0")
    checker.seed_workspace(scoped, BENCH, fixture_rel, cleanup_root)
    return scoped


@pytest.mark.parametrize("fixture_path", [
    "", "/tmp/fixtures", "../fixtures", r"C:\tmp\fixtures", r"\\server\share\fixtures",
])
def test_seed_workspace_rejects_invalid_fixture_paths(tmp_path, fixture_path):
    harness = tmp_path / "harness"
    harness.mkdir()
    cleanup_root = tmp_path / "cleanup"
    scoped = cleanup_root / "task" / "t0"
    with pytest.raises(checker.CheckerBoundaryError):
        checker.seed_workspace(str(scoped), str(harness), fixture_path, str(cleanup_root))


def test_seed_workspace_rejects_fixture_symlink_escape(tmp_path):
    harness = tmp_path / "harness"
    fixtures = harness / "fixtures"
    fixtures.mkdir(parents=True)
    outside = tmp_path / "outside"
    outside.mkdir()
    os.symlink(outside, fixtures / "escape")
    cleanup_root = tmp_path / "cleanup"
    scoped = cleanup_root / "task" / "t0"
    with pytest.raises(checker.CheckerBoundaryError):
        checker.seed_workspace(str(scoped), str(harness), "fixtures/escape", str(cleanup_root))


def test_seed_workspace_rejects_nested_fixture_symlink(tmp_path):
    harness = tmp_path / "harness"
    seed = harness / "fixtures" / "seed"
    seed.mkdir(parents=True)
    outside = tmp_path / "secret.txt"
    outside.write_text("secret")
    os.symlink(outside, seed / "leak.txt")
    cleanup_root = tmp_path / "cleanup"
    scoped = cleanup_root / "task" / "t0"
    with pytest.raises(checker.CheckerBoundaryError):
        checker.seed_workspace(str(scoped), str(harness), "fixtures/seed", str(cleanup_root))


def test_seed_workspace_requires_explicit_root_containing_target(tmp_path):
    scoped = tmp_path / "outside" / "task" / "t0"
    cleanup_root = tmp_path / "cleanup"
    with pytest.raises(safe_rm.SafeRmError):
        checker.seed_workspace(str(scoped), str(tmp_path), None, str(cleanup_root))
    assert not scoped.exists()


def test_anchor_pytest_bugfix_oracle_accepts_bug_rejects(tmp_path):
    spec = {"script": "suites/capability/checkers/pytest_business_days.sh", "mode": "exit"}
    scoped = _seed(tmp_path, "suites/capability/fixtures/code/business_days")
    # negative: the seeded module still has the planted bug -> tests fail
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score == 0.0
    # oracle: apply the correct fix -> all tests pass
    mod = os.path.join(scoped, "business_days.py")
    with open(mod) as fh:
        fixed = fh.read().replace("cur.weekday() <= 5", "cur.weekday() <= 4")
    with open(mod, "w") as fh:
        fh.write(fixed)
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score == 1.0


def test_anchor_csv_to_json_oracle_accepts_wrong_rejects(tmp_path):
    spec = {"script": "suites/capability/checkers/csv_to_json.py", "mode": "json"}
    scoped = _seed(tmp_path, "suites/capability/fixtures/code/sales_csv")
    out = os.path.join(scoped, "sales_by_region.json")
    with open(out, "w") as fh:                       # oracle: correct values, descending
        _json.dump({"South": 89.96, "North": 67.47, "West": 47.50, "East": 0.0}, fh)
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score == 1.0
    with open(out, "w") as fh:                       # negative: drops East + wrong order
        _json.dump({"North": 67.47, "South": 89.96, "West": 47.50}, fh)
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score < 1.0


def test_csv_to_json_rejects_invented_regions(tmp_path):
    # Same parsing contract as the other ONLY/EXACTLY artifacts: the object must
    # contain the seeded regions and nothing else. An invented key is fabrication,
    # not partial credit.
    spec = {"script": "suites/capability/checkers/csv_to_json.py", "mode": "json"}
    scoped = _seed(tmp_path, "suites/capability/fixtures/code/sales_csv")
    with open(os.path.join(scoped, "sales_by_region.json"), "w") as fh:
        _json.dump({"South": 89.96, "North": 67.47, "West": 47.50, "East": 0.0,
                    "Mars": 12.00}, fh)
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score == 0.0


def test_csv_to_json_rejects_numeric_strings(tmp_path):
    # A JSON string is not a total: "89.96" round-trips as text and breaks every
    # downstream consumer, so it is not a match.
    spec = {"script": "suites/capability/checkers/csv_to_json.py", "mode": "json"}
    scoped = _seed(tmp_path, "suites/capability/fixtures/code/sales_csv")
    with open(os.path.join(scoped, "sales_by_region.json"), "w") as fh:
        _json.dump({"South": "89.96", "North": "67.47", "West": "47.50", "East": "0.0"}, fh)
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score == 0.0


LANDLORD = {"script": "suites/capability/checkers/landlord_email.py", "mode": "json"}
GOOD_EMAIL = ("Dear Mr. Adeyemi,\n\nI am writing to request repair of the heating, which has "
              "not worked since November 3. Per lease clause 14.2, please arrange a fix within "
              "14 days.\n\nSincerely,\nSam")


def _email_score(tmp_path, scoped, body):
    with open(os.path.join(scoped, "email.txt"), "w") as fh:
        fh.write(body)
    return checker.run_checker(BENCH, LANDLORD, scoped, "", str(tmp_path)).score


def test_anchor_landlord_email_oracle_accepts_sparse_rejects(tmp_path):
    scoped = _seed(tmp_path, None)
    assert _email_score(tmp_path, scoped, GOOD_EMAIL) == 1.0
    assert _email_score(tmp_path, scoped, "fix the heat") < 1.0   # misses ~all constraints


def test_landlord_keyword_stuffing_is_gated(tmp_path):
    # The review's 25-word stuffed blob: every constraint token present, no email
    # anywhere in it. Sentence-level constraints must put it far below a real email.
    scoped = _seed(tmp_path, None)
    stuffed = ("Dear Mr Adeyemi. heating Nov 3 14.2 14 days please. filler filler filler "
               "filler filler filler filler filler filler filler. Sincerely.")
    assert _email_score(tmp_path, scoped, stuffed) < 0.5


def test_landlord_rejects_a_stale_email_for_the_wrong_recipient(tmp_path):
    # Wrong entity: a well-formed letter addressed to somebody else.
    scoped = _seed(tmp_path, None)
    wrong = GOOD_EMAIL.replace("Mr. Adeyemi", "Mr. Okafor")
    assert _email_score(tmp_path, scoped, wrong) < 1.0


def test_landlord_rejects_partial_completion(tmp_path):
    # Real email, but no clause citation and no deadline.
    scoped = _seed(tmp_path, None)
    partial = ("Dear Mr. Adeyemi,\n\nI am writing to request repair of the heating, which "
               "has not worked since November 3. Please arrange a visit soon.\n\n"
               "Sincerely,\nSam")
    assert 0.0 < _email_score(tmp_path, scoped, partial) < 1.0


def test_landlord_accepts_idiomatic_phrasing(tmp_path):
    # "November 3rd" and "14-day deadline" are correct phrasings the old regexes wrongly
    # rejected (biasing against models that write naturally). They must still count.
    scoped = _seed(tmp_path, None)
    good = ("Dear Mr. Adeyemi,\n\nI am writing to request that the broken heating be repaired; "
            "it has not worked since November 3rd. As set out in lease clause 14.2, please "
            "arrange a fix within a 14-day deadline. I would appreciate your prompt "
            "attention.\n\nSincerely,\nSam")
    assert _email_score(tmp_path, scoped, good) == 1.0


def test_landlord_rejects_a_line_shaped_stuffed_blob(tmp_path):
    # The blob that scored 8/8: put the greeting and sign-off on their own LINES and a
    # sentence-level gate that is only a token count is satisfied by padding.
    scoped = _seed(tmp_path, None)
    stuffed = ("Dear Mr. Adeyemi,\n"
               "heating please Nov 3 14.2 14 days filler filler filler filler filler\n"
               "Sincerely,\n")
    # An envelope and nothing else: the three prose constraints, the citation and the
    # length all fail; only the greeting/sign-off shape survives.
    assert _email_score(tmp_path, scoped, stuffed) <= 0.375


def test_landlord_rejects_constraints_written_outside_the_letter_body(tmp_path):
    # Content after the sign-off is not in the letter.
    scoped = _seed(tmp_path, None)
    outside = ("Dear Mr. Adeyemi,\n\nI hope this note finds you well and that the "
               "building works are going smoothly this month.\n\nSincerely,\nSam\n\n"
               "I am writing to request repair of the heating, which has not worked "
               "since November 3. Per lease clause 14.2, please arrange a fix within "
               "14 days.\n")
    assert _email_score(tmp_path, scoped, outside) < 0.6


@pytest.mark.parametrize("greeting,signoff", [
    ("Dear Mr. Adeyemi:", "Sincerely,"),          # business-letter colon
    ("Dear Mr Adeyemi,", "Sincerely, Sam"),       # closing with the name on the line
    ("Dear Mr. Adeyemi,", "Best,"),               # "Best" is a polite closing
])
def test_landlord_accepts_standard_formal_openings_and_closings(tmp_path, greeting,
                                                                signoff):
    # The task says 'end with a polite closing (e.g. "Sincerely")'. Rejecting other
    # standard forms is the reply_matches allowlist trap.
    scoped = _seed(tmp_path, None)
    body = GOOD_EMAIL.replace("Dear Mr. Adeyemi,", greeting).replace("Sincerely,\nSam",
                                                                    signoff)
    assert _email_score(tmp_path, scoped, body) == 1.0


def test_landlord_grades_the_body_of_a_letter_with_an_unknown_closing(tmp_path):
    # An unrecognized sign-off costs its own constraint, never the whole body: a
    # phrase list must not sit in front of an eight-point cliff.
    scoped = _seed(tmp_path, None)
    odd = GOOD_EMAIL.replace("Sincerely,\nSam", "Yours truly,\nSam")
    assert _email_score(tmp_path, scoped, odd) >= 0.75


def test_landlord_rejects_a_letter_too_short_to_carry_the_requirements(tmp_path):
    scoped = _seed(tmp_path, None)
    terse = "Dear Mr. Adeyemi,\n\nHeating broken Nov 3, clause 14.2, 14 days please.\n\nSincerely,\n"
    assert _email_score(tmp_path, scoped, terse) < 1.0


EXPENSE = {"script": "suites/capability/checkers/expense_total.py", "mode": "json"}


def _answer_score(tmp_path, scoped, spec, text):
    with open(os.path.join(scoped, "answer.txt"), "w") as fh:
        fh.write(text)
    return checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score


def test_expense_total_checker_oracle_and_negative(tmp_path):
    # Gold is derived from the SEEDED csv, so the fixture must be present.
    scoped = _seed(tmp_path, "suites/capability/fixtures/data/expenses")
    assert _answer_score(tmp_path, scoped, EXPENSE, "1419.35\n") == 1.0
    # forgot the refund is negative
    assert _answer_score(tmp_path, scoped, EXPENSE, "1438.10") == 0.0


def test_expense_total_derives_gold_from_the_seeded_file(tmp_path):
    # The gold is not a memorizable constant: change the fixture, the answer changes.
    scoped = _seed(tmp_path, "suites/capability/fixtures/data/expenses")
    with open(os.path.join(scoped, "expenses.csv"), "a") as fh:
        fh.write("2026-01-25,Groceries,Extra,10.00\n")
    assert _answer_score(tmp_path, scoped, EXPENSE, "1419.35") == 0.0
    assert _answer_score(tmp_path, scoped, EXPENSE, "1429.35") == 1.0


def test_expense_total_refuses_when_the_seed_is_missing(tmp_path):
    scoped = _seed(tmp_path, None)                    # no expenses.csv seeded
    assert _answer_score(tmp_path, scoped, EXPENSE, "1419.35") == 0.0


@pytest.mark.parametrize("text", [
    "The groceries total is 1419.35",                 # prose, not ONLY the number
    "Groceries: 1419.35\nDining: 14.50",              # more than one line
    "1419.35\nDone.",                                 # trailing chatter
    "",                                               # empty artifact
])
def test_expense_total_enforces_the_only_the_number_contract(tmp_path, text):
    scoped = _seed(tmp_path, "suites/capability/fixtures/data/expenses")
    assert _answer_score(tmp_path, scoped, EXPENSE, text) == 0.0


ORDER = {"script": "suites/capability/checkers/order_extract.py", "mode": "json"}


def test_order_extract_checker_oracle_and_negative(tmp_path):
    scoped = _seed(tmp_path, "suites/capability/fixtures/data/order")
    assert _answer_score(tmp_path, scoped, ORDER, "NW-48213|94.74|6|2026-03-03\n") == 1.0
    # subtotal + line-count traps
    assert _answer_score(tmp_path, scoped, ORDER, "NW-48213|80.50|3|2026-03-03") == 0.0


def test_order_extract_derives_gold_from_the_seeded_order(tmp_path):
    scoped = _seed(tmp_path, "suites/capability/fixtures/data/order")
    path = os.path.join(scoped, "order.txt")
    with open(path) as fh:
        edited = fh.read().replace("Total charged: $94.74", "Total charged: $99.99")
    with open(path, "w") as fh:
        fh.write(edited)
    assert _answer_score(tmp_path, scoped, ORDER, "NW-48213|94.74|6|2026-03-03") == 0.0
    assert _answer_score(tmp_path, scoped, ORDER, "NW-48213|99.99|6|2026-03-03") == 1.0


def test_order_extract_refuses_when_the_seed_is_missing(tmp_path):
    scoped = _seed(tmp_path, None)
    assert _answer_score(tmp_path, scoped, ORDER, "NW-48213|94.74|6|2026-03-03") == 0.0


@pytest.mark.parametrize("text", [
    "NW-48213|94.74|6|2026-03-03\nDone.",             # trailing chatter on a new line
    "NW-48213|94.74|6|2026-03-03 Done.",              # trailing chatter on the line
    "Here it is: NW-48213|94.74|6|2026-03-03",        # preamble
    "",                                               # empty artifact
])
def test_order_extract_enforces_the_exactly_one_line_contract(tmp_path, text):
    scoped = _seed(tmp_path, "suites/capability/fixtures/data/order")
    assert _answer_score(tmp_path, scoped, ORDER, text) == 0.0


def test_anchor_invoice_bug_oracle_accepts_bug_rejects(tmp_path):
    spec = {"script": "suites/capability/checkers/pytest_invoice.sh", "mode": "exit"}
    scoped = _seed(tmp_path, "suites/capability/fixtures/code/invoice")
    # negative: the planted discount-dropping bug -> visible + hidden tests fail
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score == 0.0
    # oracle: route the subtotal through line_total (applies the discount) -> all pass
    mod = os.path.join(scoped, "invoice.py")
    with open(mod) as fh:
        fixed = fh.read().replace(
            'subtotal = sum(ln["qty"] * ln["unit_price"] for ln in lines)',
            'subtotal = sum(line_total(ln["qty"], ln["unit_price"], ln["discount_pct"]) for ln in lines)')
    with open(mod, "w") as fh:
        fh.write(fixed)
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score == 1.0


def test_anchor_order_pipeline_oracle_accepts_bug_rejects(tmp_path):
    spec = {"script": "suites/capability/checkers/pytest_order.sh", "mode": "exit"}
    scoped = _seed(tmp_path, "suites/capability/fixtures/code/order_pipeline")
    # negative: the `>` boundary bug -> visible + hidden boundary tests fail
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score == 0.0
    # oracle: fix the tier boundaries in catalog (> -> >=) -> all pass, incl. hidden
    cat = os.path.join(scoped, "catalog.py")
    with open(cat) as fh:
        fixed = (fh.read().replace("if qty > 100:", "if qty >= 100:")
                 .replace("elif qty > 50:", "elif qty >= 50:")
                 .replace("elif qty > 10:", "elif qty >= 10:"))
    with open(cat, "w") as fh:
        fh.write(fixed)
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score == 1.0


def _patch(scoped, name, *pairs):
    path = os.path.join(scoped, name)
    with open(path) as fh:
        body = fh.read()
    for old, new in pairs:
        body = body.replace(old, new)
    with open(path, "w") as fh:
        fh.write(body)


def _apply_reference_fix(scoped, seed):
    """The correct fix for each bugfix fixture, so a negative can isolate the ONE
    thing under test instead of failing because the bug is still there."""
    if seed.endswith("business_days"):
        _patch(scoped, "business_days.py", ("cur.weekday() <= 5", "cur.weekday() <= 4"))
    elif seed.endswith("invoice"):
        _patch(scoped, "invoice.py",
               ('subtotal = sum(ln["qty"] * ln["unit_price"] for ln in lines)',
                'subtotal = sum(line_total(ln["qty"], ln["unit_price"], ln["discount_pct"])'
                ' for ln in lines)'))
    else:
        _patch(scoped, "catalog.py", ("if qty > 100:", "if qty >= 100:"),
               ("elif qty > 50:", "elif qty >= 50:"), ("elif qty > 10:", "elif qty >= 10:"))


@pytest.mark.parametrize("script,seed,visible", [
    ("pytest_business_days.sh", "code/business_days", "tests/test_business_days.py"),
    ("pytest_invoice.sh", "code/invoice", "tests/test_invoice.py"),
    ("pytest_order.sh", "code/order_pipeline", "tests/test_order.py"),
])
def test_pytest_checkers_reject_a_modified_visible_test(tmp_path, script, seed, visible):
    # Every task says "do not edit the tests". Editing them is the oldest shortcut
    # there is, and the hidden cases alone cannot see it — so the fix is applied
    # first: without the integrity gate this trial would score 1.0.
    spec = {"script": f"suites/capability/checkers/{script}", "mode": "exit"}
    scoped = _seed(tmp_path, f"suites/capability/fixtures/{seed}")
    _apply_reference_fix(scoped, seed)
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score == 1.0
    with open(os.path.join(scoped, visible), "w") as fh:
        fh.write("def test_nothing():\n    assert True\n")
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score == 0.0


def test_pytest_checker_rejects_a_deleted_visible_test(tmp_path):
    spec = {"script": "suites/capability/checkers/pytest_business_days.sh", "mode": "exit"}
    scoped = _seed(tmp_path, "suites/capability/fixtures/code/business_days")
    os.remove(os.path.join(scoped, "tests/test_business_days.py"))
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score == 0.0


def test_pytest_checker_ignores_an_agent_authored_conftest(tmp_path):
    # Hidden tests run from OUTSIDE the workspace with --noconftest, so a
    # conftest.py the agent leaves behind can neither fake a pass nor break the run.
    spec = {"script": "suites/capability/checkers/pytest_business_days.sh", "mode": "exit"}
    scoped = _seed(tmp_path, "suites/capability/fixtures/code/business_days")
    mod = os.path.join(scoped, "business_days.py")
    with open(mod) as fh:
        fixed = fh.read().replace("cur.weekday() <= 5", "cur.weekday() <= 4")
    with open(mod, "w") as fh:
        fh.write(fixed)
    with open(os.path.join(scoped, "conftest.py"), "w") as fh:
        fh.write("raise RuntimeError('agent conftest must never run')\n")
    with open(os.path.join(scoped, "tests", "conftest.py"), "w") as fh:
        fh.write("raise RuntimeError('agent conftest must never run')\n")
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score == 1.0


def _fix_business_days(scoped):
    mod = os.path.join(scoped, "business_days.py")
    with open(mod) as fh:
        fixed = fh.read().replace("cur.weekday() <= 5", "cur.weekday() <= 4")
    with open(mod, "w") as fh:
        fh.write(fixed)


def test_pytest_checker_ignores_an_agent_authored_test_plugin(tmp_path):
    # The grader used to collect $FERMIX_EVAL_WORKSPACE/tests, which the agent can ADD
    # files to. A new module declaring `pytest_plugins` loaded an agent-written
    # hookwrapper that rewrote every report to "passed": the UNFIXED bug scored 1.0.
    # --noconftest blocks a conftest.py, not this.
    spec = {"script": "suites/capability/checkers/pytest_business_days.sh", "mode": "exit"}
    scoped = _seed(tmp_path, "suites/capability/fixtures/code/business_days")
    with open(os.path.join(scoped, "hack.py"), "w") as fh:
        fh.write("import pytest\n\n\n"
                 "@pytest.hookimpl(hookwrapper=True)\n"
                 "def pytest_runtest_makereport(item, call):\n"
                 "    outcome = yield\n"
                 "    outcome.get_result().outcome = 'passed'\n")
    with open(os.path.join(scoped, "tests", "test_aaa_plugin.py"), "w") as fh:
        fh.write("pytest_plugins = ['hack']\n")
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score == 0.0


def test_pytest_checker_does_not_import_agent_code_beside_the_module(tmp_path):
    # PYTHONPATH used to be the whole workspace, and the interpreter imports
    # `sitecustomize` off it before anything else runs. Only the modules under test
    # reach the grader's import path now, so the fixed module still passes.
    spec = {"script": "suites/capability/checkers/pytest_business_days.sh", "mode": "exit"}
    scoped = _seed(tmp_path, "suites/capability/fixtures/code/business_days")
    _fix_business_days(scoped)
    with open(os.path.join(scoped, "sitecustomize.py"), "w") as fh:
        fh.write("raise RuntimeError('agent sitecustomize must never run')\n")
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score == 1.0


def test_pytest_checker_still_runs_the_visible_pass_to_pass_cases(tmp_path):
    # They come from the EVALUATOR's fixture copy now. Breaking a visible behaviour
    # while satisfying the hidden cases must still fail.
    spec = {"script": "suites/capability/checkers/pytest_business_days.sh", "mode": "exit"}
    scoped = _seed(tmp_path, "suites/capability/fixtures/code/business_days")
    with open(os.path.join(scoped, "business_days.py"), "w") as fh:
        fh.write("def business_days_between(start, end):\n"
                 "    return {(0, 0): 0, (7, 5): 0, (4, 8): 2, (0, 14): 10}.get(\n"
                 "        ((start.day - 5) % 100, (end.day - 5) % 100), 0)\n")
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score == 0.0


def test_order_pipeline_symptom_patch_still_fails_hidden(tmp_path):
    # a symptom-level "fix" (special-case the failing qty=50 in report) must NOT pass —
    # the hidden boundary tests (10/100) catch it. Guards the anti-shortcut discipline.
    spec = {"script": "suites/capability/checkers/pytest_order.sh", "mode": "exit"}
    scoped = _seed(tmp_path, "suites/capability/fixtures/code/order_pipeline")
    rep = os.path.join(scoped, "report.py")
    with open(rep) as fh:
        body = fh.read()
    hack = body.replace(
        "    subtotal_cents = sum(line_total_cents(sku, qty) for sku, qty in lines)",
        "    if lines == [(\"A\", 50)] and tax_percent == 0:\n        return 450.00\n"
        "    subtotal_cents = sum(line_total_cents(sku, qty) for sku, qty in lines)")
    with open(rep, "w") as fh:
        fh.write(hack)
    assert checker.run_checker(BENCH, spec, scoped, "", str(tmp_path)).score == 0.0   # hidden tests still fail


SUBAGENT = {"script": "suites/capability/checkers/subagent_synthesis.py", "mode": "json"}
SUBSYSTEMS_SEED = "suites/capability/fixtures/agentic/subsystems"
GOOD_SUMMARY = (
    "Gateway (FALCON-G7) — owner team Platform; it routes channel messages and "
    "serializes one turn per conversation.\n"
    "Memory (OTTER-M3) — owner team Knowledge; a durable SQLite store that "
    "consolidates facts.\n"
    "Scheduler (HERON-S9) — owner team Automation; runs cron jobs as isolated "
    "bounded loops.\n"
    "Sandbox (BADGER-X2) — owner team Security; gates the shell and file "
    "built-ins, denying protected paths.\n")


def _summary_score(tmp_path, scoped, text):
    with open(os.path.join(scoped, "summary.txt"), "w") as fh:
        fh.write(text)
    return checker.run_checker(BENCH, SUBAGENT, scoped, "", str(tmp_path)).score


def test_subagent_synthesis_reference_solution_passes(tmp_path):
    scoped = _seed(tmp_path, SUBSYSTEMS_SEED)
    assert _summary_score(tmp_path, scoped, GOOD_SUMMARY) == 1.0


def test_subagent_synthesis_rejects_bare_codenames(tmp_path):
    # The review's probe: four codenames, no roles, no teams — used to score 1.0.
    scoped = _seed(tmp_path, SUBSYSTEMS_SEED)
    assert _summary_score(tmp_path, scoped,
                          "FALCON-G7 OTTER-M3 HERON-S9 BADGER-X2 — all four covered") == 0.0


def test_subagent_synthesis_scores_partial_coverage(tmp_path):
    scoped = _seed(tmp_path, SUBSYSTEMS_SEED)
    dropped = "\n".join(GOOD_SUMMARY.splitlines()[:3])
    assert _summary_score(tmp_path, scoped, dropped) == 0.75


def test_subagent_synthesis_rejects_wrong_attribution(tmp_path):
    # Swapped owner teams: every codename present, every claim wrong.
    scoped = _seed(tmp_path, SUBSYSTEMS_SEED)
    swapped = (GOOD_SUMMARY.replace("Platform", "PLACEHOLDER")
               .replace("Security", "Platform").replace("PLACEHOLDER", "Security"))
    assert _summary_score(tmp_path, scoped, swapped) <= 0.5


def test_subagent_synthesis_rejects_a_contradictory_summary(tmp_path):
    # A later sentence contradicting the earlier correct one scores that
    # subsystem 0 — a summary that says both things has established nothing.
    scoped = _seed(tmp_path, SUBSYSTEMS_SEED)
    contradictory = GOOD_SUMMARY + "Actually FALCON-G7 is owned by Security.\n"
    assert _summary_score(tmp_path, scoped, contradictory) == 0.75


def test_subagent_synthesis_rejects_a_negated_claim(tmp_path):
    scoped = _seed(tmp_path, SUBSYSTEMS_SEED)
    negated = GOOD_SUMMARY.replace(
        "Gateway (FALCON-G7) — owner team Platform;",
        "Gateway (FALCON-G7) is not owned by Platform and")
    assert _summary_score(tmp_path, scoped, negated) == 0.75


PROSE_SUMMARY = (
    "The gateway subsystem is owned by Platform and its codename is FALCON-G7. "
    "The memory subsystem belongs to Knowledge and is called OTTER-M3. "
    "Scheduling is the Automation team's, under the codename HERON-S9. "
    "The sandbox is Security's, codenamed BADGER-X2.\n")


def test_subagent_synthesis_accepts_one_paragraph_of_correct_sentences(tmp_path):
    # Every codename ends in a digit and the splitter refused to split after one, so
    # this whole paragraph was ONE unit and each subsystem read as "attributed to
    # another team". Four correct sentences scored 0.0.
    scoped = _seed(tmp_path, SUBSYSTEMS_SEED)
    assert _summary_score(tmp_path, scoped, PROSE_SUMMARY) == 1.0


NEGATIVE_ROLE_SUMMARY = (
    "Gateway (FALCON-G7) — owner team Platform; routes channel messages.\n"
    "Memory (OTTER-M3) — owner team Knowledge; a durable SQLite store.\n"
    "HERON-S9 (Automation): runs cron jobs as isolated loops that do not see the "
    "creating chat.\n"
    "BADGER-X2 (Security): gates the shell and file built-ins; protected paths are "
    "not allowed.\n")


def test_subagent_synthesis_accepts_a_faithful_paraphrase_of_a_negative_role_line(
        tmp_path):
    # Two of the four role lines are inherently negative ("cannot see the creating
    # chat", "protected paths always denied"). A whole-sentence negation test scored a
    # faithful paraphrase of them as a denial: a fully correct summary got 0.5.
    scoped = _seed(tmp_path, SUBSYSTEMS_SEED)
    assert _summary_score(tmp_path, scoped, NEGATIVE_ROLE_SUMMARY) == 1.0


def test_subagent_synthesis_still_rejects_a_denial_of_the_subsystems_own_team(tmp_path):
    scoped = _seed(tmp_path, SUBSYSTEMS_SEED)
    denied = NEGATIVE_ROLE_SUMMARY.replace(
        "Gateway (FALCON-G7) — owner team Platform;",
        "Gateway (FALCON-G7) is not owned by Platform and")
    assert _summary_score(tmp_path, scoped, denied) == 0.75


def test_subagent_synthesis_does_not_credit_a_merged_two_codename_sentence(tmp_path):
    # A sentence naming two codenames attributes nothing to either: not evidence, and
    # not a contradiction against both.
    scoped = _seed(tmp_path, SUBSYSTEMS_SEED)
    merged = ("FALCON-G7 and OTTER-M3 are owned by Platform and Knowledge.\n"
              "Scheduler (HERON-S9) — owner team Automation; runs cron jobs.\n"
              "Sandbox (BADGER-X2) — owner team Security; gates the built-ins.\n")
    assert _summary_score(tmp_path, scoped, merged) == 0.5


def test_subagent_synthesis_refuses_when_a_seeded_file_is_missing(tmp_path):
    # The gold comes from the seeded files; grading without them would score a
    # correct summary 0 and look like a model failure.
    scoped = _seed(tmp_path, SUBSYSTEMS_SEED)
    os.remove(os.path.join(scoped, "gateway.txt"))
    assert _summary_score(tmp_path, scoped, GOOD_SUMMARY) == 0.0


def test_subagent_synthesis_refuses_when_a_seeded_file_was_altered(tmp_path):
    # The agent can write in its workspace: rewriting the source to match its own
    # summary must refuse, not pass.
    scoped = _seed(tmp_path, SUBSYSTEMS_SEED)
    with open(os.path.join(scoped, "gateway.txt"), "w") as fh:
        fh.write("Subsystem: Gateway. Internal codename: FALCON-G7.\n"
                 "Role: anything at all.\nOwner team: Security.\n")
    assert _summary_score(tmp_path, scoped, GOOD_SUMMARY) == 0.0


CRON = {"script": "suites/capability/checkers/cron_job_output.py", "mode": "json"}
TOKEN = "TOK-DEADBEEF"


def _cron_spans(scoped, run_status="ok", extra=()):
    """The two spans a real trial records. A successful schedule_job carries NEITHER
    input nor output — `Support.run` attaches no input, and the tool returns none — so
    the job's task text is not in the trace at all and nothing can correlate on it."""
    return (_support_span("schedule_job", None, start=T0, end=T1),
            _support_span(
                "run_job_now",
                '{"id":"run_x","job_id":"j1","status":"queued","trigger":"manual"}',
                start=T1, end=T2, status=run_status),
            *extra)


def _cron_score(tmp_path, scoped, evidence, content=TOKEN, mtime=None):
    path = os.path.join(scoped, "job_out.txt")
    if content is not None:
        with open(path, "w") as fh:
            fh.write(content + "\n")
        if mtime is not None:
            os.utime(path, (mtime, mtime))
    return checker.run_checker(BENCH, CRON, scoped, "", str(tmp_path),
                               evidence=evidence).score


def test_cron_job_output_reference_solution_passes(tmp_path):
    scoped = _seed(tmp_path, None)
    assert _cron_score(tmp_path, scoped, _ev(spans=_cron_spans(scoped))) == 1.0


def test_cron_job_output_rejects_a_hand_written_file(tmp_path):
    # The review's probe: the token in a file nobody scheduled — used to score 1.0.
    scoped = _seed(tmp_path, None)
    assert _cron_score(tmp_path, scoped, _ev(spans=())) == 0.0


def test_cron_job_output_rejects_the_token_in_refusal_prose_only(tmp_path):
    # The model explains what it would have written; no artifact exists.
    scoped = _seed(tmp_path, None)
    ev = _ev(spans=_cron_spans(scoped), reply=f"I would write {TOKEN} but jobs are off")
    assert _cron_score(tmp_path, scoped, ev, content=None) == 0.0


def test_cron_job_output_rejects_a_direct_write_shortcut(tmp_path):
    # Errored run + a file_write that produced the artifact by hand.
    scoped = _seed(tmp_path, None)
    write = _span("file_write",
                  inp=_inspect_input(path=os.path.join(scoped, "job_out.txt"),
                                     content=TOKEN), start=T1, end=T2)
    ev = _ev(spans=_cron_spans(scoped, run_status="error", extra=(write,)))
    assert _cron_score(tmp_path, scoped, ev) == 0.0


def test_cron_job_output_rejects_a_direct_write_beside_a_real_run(tmp_path):
    scoped = _seed(tmp_path, None)
    write = _span("file_write",
                  inp=_inspect_input(path=os.path.join(scoped, "job_out.txt")),
                  start=T1, end=T2)
    assert _cron_score(tmp_path, scoped, _ev(spans=_cron_spans(scoped, extra=(write,)))) == 0.0


def test_cron_job_output_rejects_a_stale_file_older_than_the_run(tmp_path):
    scoped = _seed(tmp_path, None)
    stale = time.time() - 3600            # written long before this trial's run
    assert _cron_score(tmp_path, scoped, _ev(spans=_cron_spans(scoped)), mtime=stale) == 0.0


def test_cron_job_output_rejects_partial_completion_without_a_run(tmp_path):
    scoped = _seed(tmp_path, None)
    scheduled_only = (_cron_spans(scoped)[0],)
    assert _cron_score(tmp_path, scoped, _ev(spans=scheduled_only)) == 0.0


def test_cron_job_output_rejects_a_run_that_predates_the_scheduling(tmp_path):
    # An earlier run of some other job says nothing about this task's artifact.
    scoped = _seed(tmp_path, None)
    spans = (_support_span("schedule_job", None, start=T1, end=T2),
             _support_span("run_job_now", '{"job_id":"j1"}', start=T0, end=T1))
    assert _cron_score(tmp_path, scoped, _ev(spans=spans)) == 0.0


def test_cron_job_output_accepts_a_shell_read_of_the_artifact(tmp_path):
    # Verifying the file with `cat` is legitimate. It used to FAIL the trial: the
    # recorded input is an Elixir map rendering whose `=>` contains the `">"`
    # shell-write marker, so every read-only check read as a redirect.
    scoped = _seed(tmp_path, None)
    read = _shell_span(f"cat {os.path.join(scoped, 'job_out.txt')}", start=T2, end=T2)
    assert _cron_score(tmp_path, scoped,
                       _ev(spans=_cron_spans(scoped, extra=(read,)))) == 1.0


def test_cron_job_output_rejects_a_shell_redirect_into_the_artifact(tmp_path):
    scoped = _seed(tmp_path, None)
    artifact = os.path.join(scoped, "job_out.txt")
    write = _shell_span(f"printf %s {TOKEN} > {artifact}", start=T1, end=T2)
    assert _cron_score(tmp_path, scoped,
                       _ev(spans=_cron_spans(scoped, extra=(write,)))) == 0.0


def test_cron_job_output_refuses_a_shell_span_whose_command_was_not_recorded(tmp_path):
    # It names the artifact and we cannot read what it did with it. Guessing "not a
    # write" is how a direct-write shortcut passes.
    scoped = _seed(tmp_path, None)
    opaque = _span("shell", inp={"text": "%{}"}, out=os.path.join(scoped, "job_out.txt"),
                   start=T1, end=T2)
    opaque["input"] = {"text": "%%{\"cmd\" => \"%s\"}" % os.path.join(scoped, "job_out.txt")}
    assert _cron_score(tmp_path, scoped,
                       _ev(spans=_cron_spans(scoped, extra=(opaque,)))) == 0.0


def test_cron_job_output_rejects_wrong_content(tmp_path):
    scoped = _seed(tmp_path, None)
    ev = _ev(spans=_cron_spans(scoped))
    assert _cron_score(tmp_path, scoped, ev, content="CRON-OK-7731") == 0.0


def test_cron_job_output_refuses_without_evidence(tmp_path):
    scoped = _seed(tmp_path, None)
    with open(os.path.join(scoped, "job_out.txt"), "w") as fh:
        fh.write(TOKEN + "\n")
    r = checker.run_checker(BENCH, CRON, scoped, "", str(tmp_path))
    assert r.score == 0.0 and "no evidence file" in r.detail


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
