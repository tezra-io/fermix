#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8"]
# ///
"""Tests for the TLA+ runner: config and header parsing, check validation
(mechanism pairing, deadlock and symmetry rules), TLC output classification,
verdict judging, source pins, and the tool/Java preflight. Hermetic: temp dirs,
an injected cache dir and a fake `java`; no real Java, no TLC, no network.
Run: `uv run tla/bin/test_check.py`."""
from __future__ import annotations

import os
import stat
import subprocess
import sys
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

import check  # noqa: E402
import trace_report  # noqa: E402

HOLDS_OUTPUT = """
Model checking completed. No error has been found.
595 states generated, 595 distinct states found, 0 states left on queue.
"""

INVARIANT_OUTPUT = """
Error: Invariant SingleFlight is violated.
Error: The behavior up to this point is:
State 1: <Initial predicate>
State 2: <Send line 104, col 5 to line 111, col 50 of module TurnQueue>
State 3: <QueueCrash line 131, col 5 to line 138, col 50 of module TurnQueue>
State 4: <Send line 104, col 5 to line 111, col 50 of module TurnQueue>
15 states generated, 15 distinct states found, 3 states left on queue.
"""

TEMPORAL_OUTPUT = """
Error: Temporal properties were violated.
Error: The following behavior constitutes a counter-example:
State 1: <Initial predicate>
State 2: <Send line 104, col 5 to line 111, col 50 of module TurnQueue>
State 3: Stuttering
1794 states generated, 1,794 distinct states found, 0 states left on queue.
"""

PARSE_ERROR_OUTPUT = """
***Parse Error***
Encountered "Beginning of definition" at line 12, column 1 in module Foo
"""

BASE_CFG = """\\* EXPECT: holds
\\* CHECKS: base
SPECIFICATION Spec
CONSTANTS Msgs = {m1, m2}  None = None
          CanCrash = TRUE  Guard = TRUE
INVARIANT TypeOK Safe
"""


def make_check(kind="holds", finding=None, length=None, invariants=("TypeOK",), properties=()):
    return check.Check(
        spec="s",
        name="c",
        cfg=Path("c.cfg"),
        expect=check.Expectation(kind, finding=finding, length=length),
        summary="s",
        invariants=tuple(invariants),
        properties=tuple(properties),
        constants={},
        deadlock_off=False,
        symmetry=False,
    )


def write_cfg(directory: Path, name: str, text: str) -> Path:
    path = directory / f"{name}.cfg"
    path.write_text(text)
    return path


# --- config parsing ---------------------------------------------------------


def test_parse_cfg_reads_sections_and_constants():
    text = BASE_CFG + "INVARIANTS\n  A\n  B\nPROPERTIES Live\n"
    sections, constants = check.parse_cfg(text)
    assert sections["INVARIANT"] == ("TypeOK", "Safe", "A", "B")
    assert sections["PROPERTY"] == ("Live",)
    assert constants == {"Msgs": "{m1, m2}", "None": "None", "CanCrash": "TRUE", "Guard": "TRUE"}


def test_parse_cfg_ignores_comments():
    text = "\\* INVARIANT Hidden\n(* INVARIANT AlsoHidden *)\nINVARIANT Real\n"
    assert check.parse_cfg(text)[0]["INVARIANT"] == ("Real",)


@pytest.mark.parametrize(
    "line, expected",
    [
        ("holds", check.Expectation("holds")),
        ("reachable", check.Expectation("reachable")),
        ("violated QUEUE-1 len=4", check.Expectation("violated", finding="QUEUE-1", length=4)),
        ("violated QUEUE-1", check.Expectation("violated", finding="QUEUE-1")),
        ("mechanism Guard covers 01_base", check.Expectation("mechanism", mechanism="Guard", covers="01_base")),
    ],
)
def test_parse_expectation_accepts_the_four_kinds(line, expected):
    assert check.parse_expectation(line, "x") == expected


@pytest.mark.parametrize(
    "line",
    ["maybe", "violated", "violated len=4", "violated queue-1", "violated QUEUE-1 4", "holds QUEUE-1",
     "mechanism Guard", "mechanism Guard of 01"],
)
def test_parse_expectation_rejects_malformed_lines(line):
    with pytest.raises(check.CheckError):
        check.parse_expectation(line, "x")


def test_missing_header_is_rejected(tmp_path):
    cfg = write_cfg(tmp_path, "01_x", "\\* CHECKS: no expectation\nINVARIANT TypeOK Safe\n")
    with pytest.raises(check.CheckError, match="header"):
        check.parse_check("s", cfg)


def test_deadlock_checking_may_not_be_switched_off(tmp_path):
    cfg = write_cfg(tmp_path, "01_x", BASE_CFG + "CHECK_DEADLOCK FALSE\n")
    with pytest.raises(check.CheckError, match="Done"):
        check.parse_check("s", cfg)


def test_symmetry_with_a_temporal_property_is_rejected(tmp_path):
    cfg = write_cfg(tmp_path, "01_x", BASE_CFG + "SYMMETRY Perms\nPROPERTY Live\n")
    with pytest.raises(check.CheckError, match="SYMMETRY"):
        check.parse_check("s", cfg)


def test_a_violated_check_names_exactly_one_target(tmp_path):
    text = BASE_CFG.replace("holds", "violated X-1 len=3") + "INVARIANT Other\n"
    with pytest.raises(check.CheckError, match="exactly one"):
        check.parse_check("s", write_cfg(tmp_path, "01_x", text))


def test_an_invariant_violation_must_pin_its_length(tmp_path):
    text = BASE_CFG.replace("holds", "violated X-1")
    with pytest.raises(check.CheckError, match="pin len="):
        check.parse_check("s", write_cfg(tmp_path, "01_x", text))


def test_a_temporal_violation_may_not_pin_a_length(tmp_path):
    text = BASE_CFG.replace("holds", "violated X-1 len=5").replace("INVARIANT TypeOK Safe", "INVARIANT TypeOK\nPROPERTY Live")
    with pytest.raises(check.CheckError, match="do not pin"):
        check.parse_check("s", write_cfg(tmp_path, "01_x", text))
    unpinned = text.replace("violated X-1 len=5", "violated X-1")
    assert check.parse_check("s", write_cfg(tmp_path, "02_x", unpinned)).expect.length is None


# --- mechanism pairing ------------------------------------------------------


def mechanism_cfg(guard="FALSE", can_crash="TRUE", covers="01_base", target="Safe"):
    return (
        f"\\* EXPECT: mechanism Guard covers {covers}\n\\* CHECKS: needs the guard\n"
        f"SPECIFICATION Spec\nCONSTANTS Msgs = {{m1, m2}}  None = None\n"
        f"          CanCrash = {can_crash}  Guard = {guard}\nINVARIANT TypeOK {target}\n"
    )


def load_checks(tmp_path, *cfgs):
    return tuple(check.parse_check("s", write_cfg(tmp_path, name, text)) for name, text in cfgs)


def test_a_correct_mechanism_pairing_validates(tmp_path):
    checks = load_checks(tmp_path, ("01_base", BASE_CFG), ("02_needs_guard", mechanism_cfg()))
    check.validate_mechanisms("s", checks)


def test_a_holds_property_without_a_mechanism_check_is_rejected(tmp_path):
    checks = load_checks(tmp_path, ("01_base", BASE_CFG))
    with pytest.raises(check.CheckError, match="no mechanism check covers Safe"):
        check.validate_mechanisms("s", checks)


@pytest.mark.parametrize(
    "cfg, message",
    [
        (mechanism_cfg(guard="TRUE"), "must set Guard = FALSE"),
        (mechanism_cfg(can_crash="FALSE"), "constants other than Guard"),
        (mechanism_cfg(covers="09_missing"), "not a holds check"),
        (mechanism_cfg(target="Other"), "not a property of 01_base"),
    ],
)
def test_a_mechanism_check_must_differ_only_in_its_switch(tmp_path, cfg, message):
    checks = load_checks(tmp_path, ("01_base", BASE_CFG), ("02_needs_guard", cfg))
    with pytest.raises(check.CheckError, match=message):
        check.validate_mechanisms("s", checks)


# --- TLC output -------------------------------------------------------------


def test_parse_holds():
    assert check.parse_tlc_output(HOLDS_OUTPUT) == check.Verdict("holds", "", "595")


def test_the_state_count_is_the_final_total_not_a_progress_line():
    output = (
        "Progress(12) at 2026-09-24 05:20:26: 41,178 states generated, 19,446 distinct states found, 9 left.\n"
        + HOLDS_OUTPUT.replace("595 states generated, 595 distinct", "663,647 states generated, 663,647 distinct")
    )
    assert check.parse_tlc_output(output).states == "663,647"


def test_parse_invariant_violation_names_the_invariant_and_counts_states():
    verdict = check.parse_tlc_output(INVARIANT_OUTPUT)
    assert (verdict.kind, verdict.detail, verdict.states, verdict.length) == ("invariant", "SingleFlight", "15", 4)


def test_parse_temporal_violation():
    verdict = check.parse_tlc_output(TEMPORAL_OUTPUT)
    assert (verdict.kind, verdict.length) == ("temporal", 3)


def test_parse_error_is_an_error():
    verdict = check.parse_tlc_output(PARSE_ERROR_OUTPUT)
    assert verdict.kind == "error" and "Parse Error" in verdict.detail


def test_no_verdict_is_an_error():
    assert check.parse_tlc_output("").kind == "error"


# --- judging ----------------------------------------------------------------


def test_holds_expectation():
    assert check.judge(make_check(invariants=("Safe",)), check.Verdict("holds"))[0]
    ok, message = check.judge(make_check(invariants=("Safe",)), check.Verdict("invariant", "Safe"))
    assert not ok and "Safe" in message


def test_violated_expectation_needs_its_target_and_length():
    c = make_check("violated", "Q-1", 4, invariants=("TypeOK", "Safe"))
    assert check.judge(c, check.Verdict("invariant", "Safe", length=4)) == (True, "Q-1")
    ok, message = check.judge(c, check.Verdict("invariant", "Safe", length=6))
    assert not ok and "6-state" in message
    ok, message = check.judge(c, check.Verdict("invariant", "TypeOK", length=4))
    assert not ok and "spec is wrong" in message


def test_violated_expectation_that_now_holds_asks_to_flip():
    ok, message = check.judge(make_check("violated", "Q-1", 4, invariants=("Safe",)), check.Verdict("holds"))
    assert not ok and "Q-1 fixed" in message


def test_temporal_violation_matches_only_a_property_target():
    prop = make_check("violated", "Q-1", None, properties=("Live",))
    assert check.judge(prop, check.Verdict("temporal", length=12))[0]
    assert check.judge(prop, check.Verdict("temporal", length=15))[0]
    inv = make_check("violated", "Q-1", 2, invariants=("Safe",))
    assert not check.judge(inv, check.Verdict("temporal", length=2))[0]


def test_a_mechanism_check_that_holds_fails():
    c = check.Check("s", "c", Path("c.cfg"), check.Expectation("mechanism", mechanism="Guard", covers="01"),
                    "s", ("Safe",), (), {}, False, False)
    assert check.judge(c, check.Verdict("invariant", "Safe", length=3))[0]
    ok, message = check.judge(c, check.Verdict("holds"))
    assert not ok and "without Guard" in message


def test_unreachable_witness_fails():
    ok, message = check.judge(make_check("reachable", invariants=("Witness_A",)), check.Verdict("holds"))
    assert not ok and "unreachable" in message


@pytest.mark.parametrize("kind", ["error", "timeout", "deadlock"])
def test_errors_timeouts_and_deadlocks_always_fail(kind):
    for c in (make_check(invariants=("Safe",)), make_check("violated", "Q-1", 3, invariants=("Safe",))):
        assert not check.judge(c, check.Verdict(kind, "x"))[0]


# --- source pins ------------------------------------------------------------


def write_spec(root: Path, name: str, sources: list[str]) -> Path:
    spec_dir = root / "specs" / name
    (spec_dir / "checks").mkdir(parents=True)
    lines = "".join(f"\\* SOURCE: {s}\n" for s in sources)
    (spec_dir / "M.tla").write_text(f"---- MODULE M ----\n{lines}====\n")
    base = BASE_CFG.replace("CanCrash = TRUE  Guard = TRUE", "CanCrash = TRUE  Guard = TRUE")
    write_cfg(spec_dir / "checks", "01_base", base)
    write_cfg(spec_dir / "checks", "02_needs_guard", mechanism_cfg())
    return spec_dir


def test_load_spec_rejects_a_source_that_no_longer_exists(tmp_path, monkeypatch):
    monkeypatch.setattr(check, "REPO_ROOT", tmp_path)
    with pytest.raises(check.CheckError, match="no longer exist"):
        check.load_spec(write_spec(tmp_path, "s", ["apps/gone.ex"]))


def git_repo(root: Path) -> None:
    for args in (["init", "-q"], ["config", "user.email", "t@example.com"], ["config", "user.name", "t"]):
        subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)


def git_commit_all(root: Path) -> None:
    subprocess.run(["git", "add", "-A"], cwd=root, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-q", "-m", "c"], cwd=root, check=True, capture_output=True)


def test_an_unpinned_or_edited_source_is_stale_until_repinned(tmp_path, monkeypatch):
    monkeypatch.setattr(check, "REPO_ROOT", tmp_path)
    git_repo(tmp_path)
    (tmp_path / "apps").mkdir()
    source = tmp_path / "apps" / "a.ex"
    source.write_text("defmodule A do end\n")
    spec_dir = write_spec(tmp_path, "s", ["apps/a.ex"])
    git_commit_all(tmp_path)
    assert check.load_spec(spec_dir).stale() == ["apps/a.ex"]

    check.repin([check.load_spec(spec_dir)])
    assert check.load_spec(spec_dir).stale() == []

    source.write_text("defmodule A do def b, do: 1 end\n")
    assert check.load_spec(spec_dir).stale() == ["apps/a.ex"]


def test_repin_refuses_uncommitted_source_changes(tmp_path, monkeypatch):
    monkeypatch.setattr(check, "REPO_ROOT", tmp_path)
    git_repo(tmp_path)
    (tmp_path / "apps").mkdir()
    source = tmp_path / "apps" / "a.ex"
    source.write_text("defmodule A do end\n")
    spec_dir = write_spec(tmp_path, "s", ["apps/a.ex"])
    git_commit_all(tmp_path)
    source.write_text("defmodule A do def b, do: 1 end\n")
    with pytest.raises(check.CheckError, match="commit these first"):
        check.repin([check.load_spec(spec_dir)])
    git_commit_all(tmp_path)
    assert check.repin([check.load_spec(spec_dir)]) == 0


def test_repin_text_rewrites_only_source_lines():
    text = "\\* SOURCE: apps/a.ex @ 000000000000\n\\* keep me\n\\* SOURCE: apps/b.ex\n"
    pins = {"apps/a.ex": "aaaaaaaaaaaa", "apps/b.ex": "bbbbbbbbbbbb"}
    assert check.repin_text(text, pins) == (
        "\\* SOURCE: apps/a.ex @ aaaaaaaaaaaa\n\\* keep me\n\\* SOURCE: apps/b.ex @ bbbbbbbbbbbb\n"
    )


# --- function-level pins ----------------------------------------------------

ELIXIR = '''defmodule M do
  @max_attempts 3

  def claim(a) do
    GenServer.call(a, :claim)
  catch
    :exit, _reason -> nil
  end

  def claim(a, b), do: {a, b}

  defp helper(
         x,
         y
       ) do
    x + y
  end

  defp short(x),
    do: x * 2

  def other, do: :other

  @schema_sql """
  CREATE TABLE runs (
    delivery_status TEXT NOT NULL DEFAULT 'pending'
  );
  """

  defp query(conn) do
    run(conn, """
    SELECT *
    FROM runs
    """)
  end
end
'''


def test_elixir_definition_takes_every_clause_through_its_end():
    text = check.elixir_definition(ELIXIR, "claim")
    assert "GenServer.call(a, :claim)" in text
    assert ":exit, _reason -> nil" in text  # catch at def indentation continues the block
    assert "def claim(a, b), do: {a, b}" in text
    assert "helper" not in text and "other" not in text


def test_elixir_definition_handles_multiline_heads_one_liners_and_attributes():
    assert "x + y" in check.elixir_definition(ELIXIR, "helper")
    assert "do: x * 2" in check.elixir_definition(ELIXIR, "short")
    assert check.elixir_definition(ELIXIR, "@max_attempts").strip() == "@max_attempts 3"
    assert check.elixir_definition(ELIXIR, "missing") == ""


def test_elixir_definition_follows_heredocs_at_any_indentation():
    schema = check.elixir_definition(ELIXIR, "@schema_sql")
    assert "DEFAULT 'pending'" in schema and schema.rstrip().endswith('"""')
    query = check.elixir_definition(ELIXIR, "query")
    assert "FROM runs" in query and query.rstrip().endswith("end")


def test_a_function_pin_ignores_edits_elsewhere_in_the_file(tmp_path, monkeypatch):
    monkeypatch.setattr(check, "REPO_ROOT", tmp_path)
    (tmp_path / "m.ex").write_text(ELIXIR)
    source = check.Source("m.ex", ("claim", "@max_attempts"), None)
    before = check.source_pin(source)
    (tmp_path / "m.ex").write_text(ELIXIR.replace(":other", ":changed"))
    assert check.source_pin(source) == before
    (tmp_path / "m.ex").write_text(ELIXIR.replace(":claim)", ":claim_now)"))
    assert check.source_pin(source) != before


def test_a_function_pin_fails_loud_when_the_function_is_gone(tmp_path, monkeypatch):
    monkeypatch.setattr(check, "REPO_ROOT", tmp_path)
    (tmp_path / "m.ex").write_text(ELIXIR)
    with pytest.raises(check.CheckError, match="no longer defines renamed"):
        check.source_pin(check.Source("m.ex", ("renamed",), None))


def test_source_lines_carry_function_lists_through_a_repin():
    text = "\\* SOURCE: apps/r.ex#claim,@max @ 000000000000\n"
    [source] = check.parse_sources(text)
    assert (source.path, source.functions, source.label) == ("apps/r.ex", ("claim", "@max"), "apps/r.ex#claim,@max")
    assert check.repin_text(text, {"apps/r.ex#claim,@max": "abcdefabcdef"}) == (
        "\\* SOURCE: apps/r.ex#claim,@max @ abcdefabcdef\n"
    )


def test_a_finding_without_a_readme_section_is_rejected(tmp_path):
    spec_dir = tmp_path / "s"
    (spec_dir / "checks").mkdir(parents=True)
    (spec_dir / "README.md").write_text("### Q-2: another finding\n")
    violated = check.parse_check("s", write_cfg(spec_dir / "checks", "01_x", BASE_CFG.replace("holds", "violated Q-1 len=3")))
    with pytest.raises(check.CheckError, match="no '### <ID>:' section for Q-1"):
        check.validate_findings_documented(spec_dir, (violated,))


# --- report --------------------------------------------------------------------

TRACE_OUTPUT = """Error: Invariant Safe is violated.
Error: The behavior up to this point is:
State 1: <Initial predicate>
/\\ pc = "idle"
/\\ outcomes = <<>>

State 2: <Send line 10, col 5 to line 12, col 9 of module M>
/\\ pc = "start"
/\\ outcomes = <<>>

State 3: <Stop line 20, col 5 to line 22, col 9 of module M>
/\\ pc = "gone"
/\\ outcomes = << "cancelled",
   "cancelled" >>

Back to state 2: <Send line 10, col 5 to line 12, col 9 of module M>

State 4: Stuttering
"""

SPEC_TEXT = """---- MODULE M ----
\\* handle_cast({:enqueue, msg}) (queue.ex:151): enqueue, start if idle.
Send == TRUE

Stop ==
    TRUE
====
"""


def test_parse_trace_reads_actions_variables_loops_and_stuttering():
    steps = trace_report.parse_trace(TRACE_OUTPUT)
    assert [s.action for s in steps] == ["Initial", "Send", "Stop", "Send", "Stuttering"]
    assert steps[2].variables["outcomes"] == '<< "cancelled", "cancelled" >>'
    assert steps[3].back_to == 2 and steps[3].variables["pc"] == '"start"'


def test_trace_steps_link_each_action_to_its_code_and_changes():
    steps = trace_report.trace_steps(TRACE_OUTPUT, trace_report.action_comments(SPEC_TEXT))
    send = steps[1]
    assert send["code_refs"] == ["queue.ex:151"]
    assert "enqueue, start if idle" in send["mirrors"]
    assert send["changed"] == {"pc": '"start"'}
    assert steps[2]["mirrors"] == ""  # an action with no comment above it


def test_finding_sections_split_on_finding_headings():
    readme = "# spec\n\n## Findings\n\n### Q-1: first\nbody one\n\n### Q-2: second\nbody two\n\n## After\nx\n"
    sections = trace_report.finding_sections(readme)
    assert sections["Q-1"] == "### Q-1: first\nbody one"
    assert sections["Q-2"] == "### Q-2: second\nbody two"


def test_render_markdown_puts_the_trace_under_its_finding():
    comments = trace_report.action_comments(SPEC_TEXT)
    check_entry = {
        "name": "07_x", "expectation": "violated Q-1", "finding": "Q-1", "summary": "a stop loses it",
        "ok": True, "message": "Q-1", "states": "12",
        "trace": trace_report.trace_steps(TRACE_OUTPUT, comments),
    }
    report = {
        "generated_at": "now", "totals": {"checks": 1, "ok": 1, "fail": 0, "stale": 0},
        "specs": [{"name": "s", "stale": [], "checks": [check_entry],
                   "findings": {"Q-1": {"readme": "### Q-1: first\nbody", "checks": [check_entry]}}}],
    }
    text = trace_report.render_markdown(report)
    assert "### Q-1: first" in text
    assert "**Send**: handle_cast({:enqueue, msg}) (queue.ex:151)" in text
    assert "(loops back to state 2)" in text
    assert "How to use this report" in text


# --- tools preflight --------------------------------------------------------


def fake_java(directory: Path, stderr: str, exit_code: int = 0) -> None:
    java = directory / "java"
    java.write_text(f"#!/bin/sh\nprintf '%s\\n' '{stderr}' >&2\nexit {exit_code}\n")
    java.chmod(java.stat().st_mode | stat.S_IEXEC)


@pytest.mark.parametrize(
    "stderr, exit_code, expected",
    [
        ('openjdk version "25.0.2" 2026-01-20', 0, None),
        ('java version "1.8.0_292"', 0, "Java 8 found"),
        ("The operation couldn't be completed. Unable to locate a Java Runtime.", 1, "not a working Java"),
    ],
)
def test_require_java(tmp_path, monkeypatch, stderr, exit_code, expected):
    fake_java(tmp_path, stderr, exit_code)
    monkeypatch.setenv("PATH", str(tmp_path))
    if expected is None:
        assert check.require_java() == str(tmp_path / "java")
    else:
        with pytest.raises(check.CheckError, match=expected):
            check.require_java()


def test_a_tampered_jar_is_refused_before_java_runs(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path))
    jar = tmp_path / "fermix" / f"tla2tools-{check.TOOLS_VERSION}.jar"
    jar.parent.mkdir(parents=True)
    jar.write_bytes(b"not the pinned jar")

    def java_must_not_run():
        raise AssertionError("require_java ran before the jar was verified")

    monkeypatch.setattr(check, "require_java", java_must_not_run)
    with pytest.raises(check.CheckError, match="sha256"):
        check.run_specs([], timeout_s=1)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
