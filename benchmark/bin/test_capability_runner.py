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

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

import run_capability as rc  # noqa: E402
from evallib import suites  # noqa: E402


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
    assert a != rc._xsession_token("cap_memory", "durable_project_codename", "20260701T0000Z", 0)


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


def test_the_real_cap_memory_suite_is_valid():
    # the shipped cross-session suite must load + validate
    cap_dir = os.path.join(os.path.dirname(HERE), "suites", "capability")
    suites.load_all(cap_dir)   # raises SuiteError on any problem


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


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
