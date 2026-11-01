#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7"]
# ///
"""Tests for the desktop corpus runner (`bin/run_desktop.py`, `bin/desktoplib`).

Hermetic: no daemon, no display, no accessibility bus, and nothing under
`~/.fermix*` is read or written. A "fixture" here is a tiny Python script written
into the test's own temporary directory that keeps the real fixtures' state-file
contract (`{"version": 1, "events": [...]}`, rewritten through a rename), so the
launch / ready / stop path is exercised without a toolkit. Trace rows carry the
fields `FermixCore.Trace` writes (`trace.ex` `build_entry/3`, `Tools.Telemetry.exec/5`,
`Providers.Telemetry.emit_call/3`). Run: `uv run bin/test_desktop.py`.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import textwrap
import threading
from datetime import datetime, timezone
from types import SimpleNamespace

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402
import yaml  # noqa: E402

import run_desktop  # noqa: E402
from desktoplib import corpus, cu_trace, fixture, oracle  # noqa: E402
from evallib import driver  # noqa: E402

CORPUS = os.path.join(os.path.dirname(HERE), "suites", "desktop", "corpus.yaml")
BASE_MS = 1_790_000_000_000
TURN = "main-41"


def iso(ms: float) -> str:
    return datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc).isoformat()


def event(seq, control, action, value=None, length=None):
    out = {"seq": seq, "control": control, "action": action}
    if value is not None:
        out["value"] = value
    if length is not None:
        out["length"] = length
    return out


def clause(**raw):
    return oracle.parse_clause(raw, "test")


# --- the corpus file ----------------------------------------------------------

def test_the_corpus_loads_with_every_required_verb_on_every_fixture():
    loaded = corpus.load(CORPUS)
    assert len(loaded.tasks) >= corpus.MIN_TASKS
    assert {task.verb for task in loaded.tasks} >= corpus.REQUIRED_VERBS
    assert set(loaded.fixtures) == {"gtk3", "gtk4", "qt", "macos"}
    assert all(task.risk == "desktop_input" for task in loaded.tasks)
    rendered = corpus.render_all(loaded, sorted(loaded.fixtures))
    assert len(rendered) == len(loaded.tasks) * 4


def test_a_rendered_task_names_the_fixtures_own_labels_and_controls():
    loaded = corpus.load(CORPUS)
    task = next(t for t in loaded.tasks if t.id == "press_button")
    gtk3 = corpus.render(loaded, task, "gtk3")
    macos = corpus.render(loaded, task, "macos")
    assert gtk3.query == "Press the GTK3 button in the Compux Fixture GTK3 window."
    assert macos.query == "Press the AppKit button in the Compux Fixture window."
    assert gtk3.clauses[0].control == "gtk3.button"
    assert macos.clauses[0].control == "appkit.button"


def test_the_disabled_button_task_expects_a_refusal():
    loaded = corpus.load(CORPUS)
    refusals = [t for t in loaded.tasks if t.expect_refusal]
    assert [(t.id, t.expect_refusal) for t in refusals] == [("press_disabled_button",
                                                            "element_disabled")]


def _write_corpus(tmp_path, mutate) -> str:
    with open(CORPUS, encoding="utf-8") as handle:
        raw = yaml.safe_load(handle)
    mutate(raw)
    path = tmp_path / "corpus.yaml"
    path.write_text(yaml.safe_dump(raw, sort_keys=False), encoding="utf-8")
    return str(path)


def _disabled_task(raw) -> dict:
    return next(t for t in raw["tasks"] if t["id"] == "press_disabled_button")


@pytest.mark.parametrize("mutate,needle", [
    (lambda raw: raw.pop("risk"), "risk"),
    # the refusal a task expects is a typed code the classifier recognises on a row
    (lambda raw: _disabled_task(raw).update(expect_refusal=True), "expect_refusal"),
    (lambda raw: _disabled_task(raw).update(expect_refusal="element_disabld"), "element_disabld"),
    (lambda raw: raw.update(risk="host_readonly"), "desktop_input"),
    (lambda raw: raw["tasks"][0].update(risk="isolated_mutation"), "desktop_input"),
    (lambda raw: raw["tasks"][0].update(verb="hover"), "verb"),
    (lambda raw: raw["tasks"][1].update(id=raw["tasks"][0]["id"]), "duplicate"),
    (lambda raw: raw["tasks"][0]["oracle"][0].update(absent=True), "exactly one"),
    (lambda raw: raw["tasks"][0]["oracle"][0].pop("count"), "exactly one"),
    (lambda raw: raw["tasks"][0].update(query="Press {it}."), "placeholder"),
    (lambda raw: raw["tasks"][0]["oracle"][0].update(control="{tk}.knob"), "knob"),
    (lambda raw: raw["tasks"][0].update(oracle=[]), "oracle"),
    (lambda raw: raw.update(tasks=raw["tasks"][:5]), "at least"),
    (lambda raw: raw.update(tasks=[t for t in raw["tasks"] if t["verb"] != "focus"]), "focus"),
    (lambda raw: raw["fixtures"]["gtk3"].update(platform="windows"), "platform"),
    (lambda raw: raw["tasks"][0]["oracle"][0].update(count=-1), "count"),
    (lambda raw: raw["tasks"][0]["oracle"][0].update(value=80), "text"),
    (lambda raw: raw["tasks"][0].update(timeout_ms=0), "timeout_ms"),
    (lambda raw: raw["tasks"][0].update(timeout_ms="soon"), "timeout_ms"),
])
def test_a_broken_corpus_is_refused_at_load(tmp_path, mutate, needle):
    path = _write_corpus(tmp_path, mutate)
    with pytest.raises(corpus.CorpusError) as caught:
        corpus.load(path)
    assert needle in str(caught.value)


def test_launch_argv_fills_the_fixture_paths():
    loaded = corpus.load(CORPUS)
    argv = corpus.launch_argv(loaded.fixtures["qt"], fixture_dir="/src/compux/fixtures",
                              fixture_app="/tmp/FixtureApp", state_file="/run/s.json")
    assert argv == ["python3", "/src/compux/fixtures/linux/fixture_qt.py",
                    "--state-file", "/run/s.json"]
    mac = corpus.launch_argv(loaded.fixtures["macos"], fixture_dir="/x",
                             fixture_app="/tmp/FixtureApp", state_file="/run/s.json")
    assert mac == ["/tmp/FixtureApp", "--state-file", "/run/s.json"]


# --- the oracle ---------------------------------------------------------------

def test_present_absent_and_count_read_matching_events():
    events = [event(1, "gtk3.button", "press"), event(2, "gtk3.button", "press"),
              event(3, "gtk3.list", "select", "Cherry")]
    results = oracle.evaluate(events, [
        clause(control="gtk3.button", action="press", count=2),
        clause(control="gtk3.list", action="select", value="Cherry", present=True),
        clause(control="gtk3.list", action="select", value="Apple", absent=True),
        clause(control="sidebar.save", absent=True),
    ])
    assert [r.passed for r in results] == [True, True, True, True]
    assert oracle.passed(results)


def test_count_is_exact():
    events = [event(1, "document.save", "press"), event(2, "document.save", "press")]
    [result] = oracle.evaluate(events, [clause(control="document.save", action="press", count=1)])
    assert not result.passed
    assert "2" in result.detail


def test_count_zero_is_a_usable_verdict():
    none = clause(control="qt.button", action="press", count=0)
    assert none.verdict == "count" and none.count == 0
    assert oracle.passed(oracle.evaluate([], [none]))
    assert not oracle.passed(oracle.evaluate([event(1, "qt.button", "press")], [none]))


def test_last_reads_the_final_event_of_that_control_and_action():
    events = [event(1, "qt.text_field", "set_value", "draft"),
              event(2, "qt.text_field", "set_value", "final")]
    good = clause(control="qt.text_field", action="set_value", value="final", last=True)
    stale = clause(control="qt.text_field", action="set_value", value="draft", last=True)
    results = oracle.evaluate(events, [good, stale])
    assert [r.passed for r in results] == [True, False]


def test_last_with_no_event_fails_rather_than_passes():
    [result] = oracle.evaluate([], [clause(control="gtk4.slider", action="set_value",
                                           value="80", last=True)])
    assert not result.passed
    assert "no gtk4.slider set_value event" in result.detail


def test_last_needs_an_action():
    with pytest.raises(ValueError, match="action"):
        clause(control="gtk4.slider", value="80", last=True)


def test_a_length_clause_reads_the_secure_field_length():
    events = [event(1, "gtk3.secure_field", "set_value", length=4),
              event(2, "gtk3.secure_field", "set_value", length=13)]
    [result] = oracle.evaluate(events, [clause(control="gtk3.secure_field", action="set_value",
                                               length=13, last=True)])
    assert result.passed


def _state(tmp_path, document) -> str:
    path = tmp_path / "state.json"
    path.write_text(json.dumps(document), encoding="utf-8")
    return str(path)


def test_read_state_takes_the_fixture_contract(tmp_path):
    path = _state(tmp_path, {"version": 1, "events": [event(1, "qt.button", "press")]})
    assert oracle.read_state(path) == [event(1, "qt.button", "press")]


@pytest.mark.parametrize("document,needle", [
    ({"version": 2, "events": []}, "version"),
    ({"version": 1}, "events"),
    ({"version": 1, "events": [{"seq": 1, "control": "qt.button"}]}, "action"),
    ({"version": 1, "events": [event(2, "qt.button", "press")]}, "seq"),
    ({"version": 1, "events": [event(1, "qt.secure_field", "set_value", value="x", length=1)]},
     "secure"),
])
def test_read_state_refuses_a_broken_file_as_an_evaluator_error(tmp_path, document, needle):
    with pytest.raises(oracle.OracleError, match=needle):
        oracle.read_state(_state(tmp_path, document))


def test_a_missing_state_file_is_an_evaluator_error(tmp_path):
    with pytest.raises(oracle.OracleError, match="cannot read"):
        oracle.read_state(str(tmp_path / "absent.json"))


# --- counting one task's turn from its trace rows ------------------------------

SHOT = ("Image 7c1e-{n}, {w}x{h} (display 0). Coordinates are pixels in this exact image: "
        'pass observation_id "7c1e-{n}" with any click, move, drag, scroll or inspect.')


def cu_row(at_ms, action, *, success=True, output="", args=None, session=TURN, duration=150):
    row = {"ts": iso(at_ms), "type": "tool_exec", "agent": "main", "tool": "computer_use",
           "action": action, "success": success, "duration_ms": duration,
           "session_id": session, "output": output}
    if args is not None:
        row["input"] = args
    return row


def llm_row(at_ms, *, duration=3000, session=TURN):
    return {"ts": iso(at_ms), "type": "llm_call", "agent": "main", "session_id": session,
            "provider": "anthropic", "model": "claude-opus-5-5", "duration_ms": duration}


def test_turn_counts_model_calls_images_failures_and_replayed_image_tokens():
    shot = SHOT.format(n=1, w=1500, h=1000)
    rows = [
        llm_row(BASE_MS + 3000),                                   # call 1: no image yet
        cu_row(BASE_MS + 3500, "screenshot", output=shot),         # 2000 tokens
        llm_row(BASE_MS + 7000, duration=3000),                    # call 2 carries image 1
        cu_row(BASE_MS + 7500, "left_click", success=False,
               output="this action was not sent: it names no `observation_id`, so ..."),
        llm_row(BASE_MS + 11000, duration=3000),                   # call 3 still carries it
    ]
    counts = cu_trace.turn_counts(rows, retained=3)
    assert counts["model_calls"] == 3
    assert counts["cu_calls"] == 2
    assert counts["cu_failures"] == 1
    assert counts["failure_classes"]["refusal"] == 1
    assert counts["images"] == 1
    assert counts["image_tokens"] == 2000
    assert counts["image_tokens_sent"] == 4000


def test_replayed_image_tokens_keep_only_the_retained_images():
    rows = []
    for n in range(1, 5):   # four screenshots, each followed by a model call
        rows.append(cu_row(BASE_MS + n * 10_000, "screenshot",
                           output=SHOT.format(n=n, w=750, h=1000)))   # 1000 tokens each
        rows.append(llm_row(BASE_MS + n * 10_000 + 5000, duration=2000))
    counts = cu_trace.turn_counts(rows, retained=2)
    # calls see 1, 2, 2, 2 images under a retention of two
    assert counts["image_tokens_sent"] == 7000


def test_select_turn_takes_the_one_main_turn_inside_the_window():
    rows = [cu_row(BASE_MS + 100, "screenshot"), llm_row(BASE_MS + 500),
            cu_row(BASE_MS - 60_000, "screenshot", session="main-40"),   # before the window
            {"ts": iso(BASE_MS + 200), "type": "tool_exec", "agent": "heartbeat",
             "tool": "memory_search", "session_id": "hb-1", "success": True}]
    session, turn = cu_trace.select_turn(rows, BASE_MS, BASE_MS + 10_000)
    assert session == TURN
    assert len(turn) == 2


def test_select_turn_refuses_two_main_turns_in_one_window():
    rows = [cu_row(BASE_MS + 100, "screenshot"),
            cu_row(BASE_MS + 200, "screenshot", session="main-42")]
    with pytest.raises(cu_trace.TraceError, match="main-41, main-42"):
        cu_trace.select_turn(rows, BASE_MS, BASE_MS + 10_000)


def test_select_turn_with_no_rows_says_so():
    with pytest.raises(cu_trace.TraceError, match="no main-agent"):
        cu_trace.select_turn([], BASE_MS, BASE_MS + 10_000)


def test_a_half_written_last_line_is_left_for_the_next_read(tmp_path):
    path = tmp_path / "tool_exec.jsonl"
    whole = cu_row(BASE_MS, "screenshot")
    path.write_text(json.dumps(whole) + "\n" + '{"ts": "2026-10-31T00:00:0', encoding="utf-8")
    assert list(cu_trace.iter_rows(str(path))) == [whole]


def test_rows_between_parses_only_the_lines_inside_the_window(tmp_path, monkeypatch):
    day = tmp_path / iso(BASE_MS)[:10]
    day.mkdir()
    with open(day / "tool_exec.jsonl", "w", encoding="utf-8") as handle:
        for at in (BASE_MS - 60_000, BASE_MS + 1000, BASE_MS + 60_000):
            handle.write(json.dumps(cu_row(at, "screenshot", output="x" * 5000)) + "\n")
    parsed = []
    real_loads = cu_trace.json.loads
    monkeypatch.setattr(cu_trace.json, "loads", lambda text: parsed.append(1) or real_loads(text))
    inside = cu_trace.rows_between(str(tmp_path), BASE_MS, BASE_MS + 10_000)
    assert [row["ts"] for row in inside] == [iso(BASE_MS + 1000)]
    assert len(parsed) == 1


def test_rows_between_reads_every_day_the_window_touches_and_nothing_outside_it(tmp_path):
    midnight = datetime(2026, 10, 31, tzinfo=timezone.utc).timestamp() * 1000.0
    rows = {"before": cu_row(midnight - 60_000, "screenshot"),
            "late_evening": cu_row(midnight - 5_000, "screenshot"),
            "early_morning": cu_row(midnight + 5_000, "screenshot"),
            "after": cu_row(midnight + 30_000, "screenshot")}
    for row in rows.values():
        day = tmp_path / row["ts"][:10]
        day.mkdir(exist_ok=True)
        with open(day / "tool_exec.jsonl", "a", encoding="utf-8") as handle:
            handle.write(json.dumps(row) + "\n")
    inside = cu_trace.rows_between(str(tmp_path), midnight - 10_000, midnight + 10_000)
    assert inside == [rows["late_evening"], rows["early_morning"]]


# --- the fixture process --------------------------------------------------------

FAKE_FIXTURE = textwrap.dedent('''
    import json, os, sys, time
    args = sys.argv[1:]
    path = args[args.index("--state-file") + 1]
    def write(events):
        scratch = path + ".writing"
        with open(scratch, "w") as handle:
            json.dump({"version": 1, "events": events}, handle)
        os.replace(scratch, path)
    if "--self-test" in args:
        names = os.environ["FAKE_CONTROLS"].split(",")
        write([{"seq": i + 1, "control": n, "action": "press"} for i, n in enumerate(names)])
        sys.exit(0)
    if os.environ.get("FAKE_NEVER_READY"):
        time.sleep(60)
    if os.environ.get("FAKE_STALE"):
        write([{"seq": 1, "control": "qt.button", "action": "press"}])
        time.sleep(60)
    write([])
    time.sleep(60)
''')


@pytest.fixture
def fake_fixture(tmp_path):
    script = tmp_path / "fake_fixture.py"
    script.write_text(FAKE_FIXTURE, encoding="utf-8")
    return script


def test_a_fixture_starts_ready_and_stops(tmp_path, fake_fixture):
    state = tmp_path / "state.json"
    process = fixture.FixtureProcess(
        [sys.executable, str(fake_fixture), "--state-file", str(state)], env={},
        state_file=str(state), log_path=str(tmp_path / "fixture.log"), settle_s=0.0)
    with process:
        assert process.alive()
        assert oracle.read_state(str(state)) == []
    assert not process.alive()


def test_a_fixture_that_never_writes_its_state_fails_typed(tmp_path, fake_fixture):
    state = tmp_path / "state.json"
    process = fixture.FixtureProcess(
        [sys.executable, str(fake_fixture), "--state-file", str(state)],
        env={"FAKE_NEVER_READY": "1"}, state_file=str(state),
        log_path=str(tmp_path / "fixture.log"), settle_s=0.0, ready_tries=5)
    with pytest.raises(fixture.FixtureError) as caught:
        with process:
            pass
    assert caught.value.kind == "fixture_not_ready"
    assert not process.alive()


def test_a_fixture_that_cannot_be_spawned_fails_typed_and_closes_its_log(tmp_path):
    state = tmp_path / "state.json"
    process = fixture.FixtureProcess(
        [str(tmp_path / "no-such-fixture"), "--state-file", str(state)], env={},
        state_file=str(state), log_path=str(tmp_path / "fixture.log"), settle_s=0.0)
    with pytest.raises(fixture.FixtureError) as caught:
        with process:
            pass
    assert caught.value.kind == "launch_failed"
    assert process._log is None


def test_a_fixture_refuses_a_state_file_that_already_exists(tmp_path, fake_fixture):
    state = tmp_path / "state.json"
    state.write_text('{"version": 1, "events": []}', encoding="utf-8")
    process = fixture.FixtureProcess(
        [sys.executable, str(fake_fixture), "--state-file", str(state)], env={},
        state_file=str(state), log_path=str(tmp_path / "fixture.log"), settle_s=0.0)
    with pytest.raises(fixture.FixtureError, match="already exists"):
        with process:
            pass


def test_a_fixture_that_starts_with_events_already_recorded_is_refused(tmp_path, fake_fixture):
    state = tmp_path / "state.json"
    process = fixture.FixtureProcess(
        [sys.executable, str(fake_fixture), "--state-file", str(state)],
        env={"FAKE_STALE": "1"}, state_file=str(state),
        log_path=str(tmp_path / "fixture.log"), settle_s=0.0)
    with pytest.raises(fixture.FixtureError) as caught:
        with process:
            pass
    assert caught.value.kind == "fixture_not_fresh"
    assert not process.alive()


def test_the_settled_state_includes_an_event_recorded_after_the_reply(tmp_path):
    state = tmp_path / "state.json"

    def write(events):
        scratch = tmp_path / ".state.writing"
        scratch.write_text(json.dumps({"version": 1, "events": events}), encoding="utf-8")
        os.replace(scratch, state)

    write([])
    late = threading.Timer(0.2, write, args=[[event(1, "qt.slider", "set_value", "80")]])
    late.start()
    try:
        events, settled = fixture.wait_for_settled_state(str(state), quiet_s=0.5, max_s=5.0)
    finally:
        late.join()
    assert settled is True
    assert events == [event(1, "qt.slider", "set_value", "80")]


def test_the_self_test_preflight_compares_recorded_controls(tmp_path, fake_fixture):
    argv = [sys.executable, str(fake_fixture), "--state-file", str(tmp_path / "self.json")]
    recorded = fixture.self_test_controls(argv, env={"FAKE_CONTROLS": "qt.button,qt.list"},
                                          state_file=str(tmp_path / "self.json"))
    assert recorded == {"qt.button", "qt.list"}


# --- the runner -----------------------------------------------------------------

def _forbid(monkeypatch, *targets):
    def refuse(*_args, **_kwargs):
        raise AssertionError("this path must launch, send and contact nothing")
    for owner, name in targets:
        monkeypatch.setattr(owner, name, refuse)


NOTHING_SPAWNED = [(subprocess, "Popen"), (subprocess, "run"), (os, "system"),
                   (os, "posix_spawn"), (os, "fork"), (driver, "drive_query"),
                   (driver, "drive_with_usage_retry"), (driver, "daemon_reachable"),
                   (fixture, "self_test_controls"), (fixture.FixtureProcess, "start")]


def test_dry_run_validates_and_plans_without_launching_anything(monkeypatch, capsys):
    _forbid(monkeypatch, *NOTHING_SPAWNED)
    assert run_desktop.main(["--dry-run", "--repeat", "2"]) == run_desktop.EXIT_OK
    out = capsys.readouterr().out
    assert "desktop_input" in out
    assert "--disposable-desktop" in out
    for name in ("gtk3", "gtk4", "qt", "macos"):
        assert name in out


# Every refusal test forbids what lies past its guard: with the guard removed (a
# planted regression), the run must fail here, never reach a daemon or a display.
def test_a_live_run_is_refused_without_the_disposable_desktop_attestation(monkeypatch, capsys):
    _forbid(monkeypatch, *NOTHING_SPAWNED)
    assert run_desktop.main(["--fixture", "gtk3"]) == run_desktop.EXIT_USAGE
    assert "--disposable-desktop" in capsys.readouterr().err


def test_a_live_run_needs_one_fixture(monkeypatch, capsys):
    _forbid(monkeypatch, *NOTHING_SPAWNED)
    assert run_desktop.main(["--disposable-desktop"]) == run_desktop.EXIT_USAGE
    assert "--fixture" in capsys.readouterr().err


def test_a_live_run_refuses_the_production_home(monkeypatch, capsys):
    monkeypatch.setenv("FERMIX_EVAL_HOME", "~/.fermix")
    _forbid(monkeypatch, *NOTHING_SPAWNED)
    code = run_desktop.main(["--disposable-desktop", "--fixture", "gtk3"])
    assert code == run_desktop.EXIT_PRECONDITION
    assert "production" in capsys.readouterr().err


def test_a_misspelt_expected_refusal_fails_the_dry_run(tmp_path, monkeypatch, capsys):
    path = _write_corpus(tmp_path, lambda raw: _disabled_task(raw).update(
        expect_refusal="disabled_element"))
    _forbid(monkeypatch, *NOTHING_SPAWNED)
    assert run_desktop.main(["--dry-run", "--suite", path]) == run_desktop.EXIT_USAGE
    assert "disabled_element" in capsys.readouterr().err


@pytest.mark.parametrize("value", [None, ""])
def test_a_live_run_refuses_an_eval_home_left_to_the_default(monkeypatch, capsys, value):
    if value is None:
        monkeypatch.delenv("FERMIX_EVAL_HOME", raising=False)
    else:
        monkeypatch.setenv("FERMIX_EVAL_HOME", value)
    _forbid(monkeypatch, *NOTHING_SPAWNED)
    code = run_desktop.main(["--disposable-desktop", "--fixture", "gtk3"])
    assert code == run_desktop.EXIT_PRECONDITION
    assert "FERMIX_EVAL_HOME" in capsys.readouterr().err


def test_repeat_must_be_positive(monkeypatch, capsys):
    _forbid(monkeypatch, *NOTHING_SPAWNED)
    assert run_desktop.main(["--dry-run", "--repeat", "0"]) == run_desktop.EXIT_USAGE


@pytest.mark.parametrize("attempt, waits", [
    ({"status": "invalid", "invalid_reason": "turn_timeout"}, 1),
    ({"status": "invalid", "invalid_reason": "no_trace"}, 0),
    ({"status": "scored", "success": True}, 0),
])
def test_only_a_turn_the_cli_gave_up_on_holds_the_next_attempt(monkeypatch, attempt, waits):
    waited = []
    monkeypatch.setattr(run_desktop, "run_attempt", lambda *_a: dict(attempt))
    monkeypatch.setattr(run_desktop, "wait_for_quiet", lambda ctx, since: waited.append(since))
    task = corpus.Task(id="t", verb="press", query="q", oracle=(), expect_refusal=False,
                       timeout_ms=1, risk=corpus.RISK)
    rendered = corpus.RenderedTask(task=task, fixture="gtk3", query="q", clauses=())
    attempts: list[dict] = []
    run_desktop.drive_one(None, rendered, 1, "desktop-test", attempts)
    assert attempts == [attempt]
    assert len(waited) == waits


def test_a_daemon_still_busy_after_an_abandoned_turn_stops_the_run(tmp_path, monkeypatch):
    now = datetime.now(timezone.utc).timestamp() * 1000.0
    day = tmp_path / iso(now)[:10]
    day.mkdir()
    with open(day / "llm_call.jsonl", "w", encoding="utf-8") as handle:
        handle.write(json.dumps(llm_row(now, duration=10)) + "\n")
    monkeypatch.setattr(run_desktop, "QUIET_MAX_WAIT_S", 0.3)
    monkeypatch.setattr(run_desktop, "QUIET_POLL_S", 0.1)
    ctx = SimpleNamespace(traces_root=str(tmp_path))
    with pytest.raises(run_desktop.RunAbort) as caught:
        run_desktop.wait_for_quiet(ctx, now - 1000)
    assert caught.value.kind == "daemon_busy"


def test_a_daemon_quiet_since_the_abandoned_turn_lets_the_run_go_on(tmp_path):
    now = datetime.now(timezone.utc).timestamp() * 1000.0
    long_ago = now - (run_desktop.QUIET_WINDOW_S + 5) * 1000.0
    day = tmp_path / iso(long_ago)[:10]
    day.mkdir()
    with open(day / "llm_call.jsonl", "w", encoding="utf-8") as handle:
        handle.write(json.dumps(llm_row(long_ago, duration=10)) + "\n")
    run_desktop.wait_for_quiet(SimpleNamespace(traces_root=str(tmp_path)), long_ago - 1000)


def _attempt_world(tmp_path, fake_fixture, monkeypatch, events, rows, task_id="save_document"):
    """A fake fixture, a fake `fermix ask` that 'does' the task by writing the
    fixture's state file and the turn's trace rows, and a traces directory."""
    traces = tmp_path / "home" / "traces"
    loaded = corpus.load(CORPUS)
    task = corpus.render(loaded, next(t for t in loaded.tasks if t.id == task_id), "gtk3")
    fixture_def = loaded.fixtures["gtk3"]
    monkeypatch.setattr(corpus, "launch_argv", lambda _f, **kw: [
        sys.executable, str(fake_fixture), "--state-file", kw["state_file"]])

    def fake_drive(session, query, timeout_ms):
        sent_at = datetime.now(timezone.utc)
        state = next(p for p in (tmp_path / "out" / "state").iterdir())
        state.write_text(json.dumps({"version": 1, "events": events}), encoding="utf-8")
        now = sent_at.timestamp() * 1000 + 50
        day = traces / sent_at.date().isoformat()
        day.mkdir(parents=True, exist_ok=True)
        for row in rows(now):
            kind = row["type"]
            with open(day / f"{kind}.jsonl", "a", encoding="utf-8") as handle:
                handle.write(json.dumps(row) + "\n")
        return driver.DriveResult(ok=True, status="ok", response="Done.", error=None,
                                  session_id=session, exit_code=0, sent_at=sent_at,
                                  elapsed_ms=1234.0)

    ctx = run_desktop.Context(
        drive=fake_drive, traces_root=str(traces), out_dir=str(tmp_path / "out"),
        fixture_def=fixture_def, fixture_dir="/unused", fixture_app="/unused",
        retained=3, settle_s=0.0, trace_settle_s=0.2, state_quiet_s=0.05)
    return ctx, task


def test_an_attempt_is_driven_scored_and_counted_end_to_end(tmp_path, fake_fixture, monkeypatch):
    events = [event(1, "document.save", "press")]
    rows = lambda now: [  # noqa: E731
        llm_row(now + 10, duration=5),
        cu_row(now + 20, "screenshot", output=SHOT.format(n=1, w=750, h=750)),
        llm_row(now + 40, duration=10), cu_row(now + 50, "press"), llm_row(now + 70, duration=5)]
    ctx, task = _attempt_world(tmp_path, fake_fixture, monkeypatch, events, rows)
    attempt = run_desktop.run_attempt(ctx, task, repeat_index=1, run_id="desktop-test")
    assert attempt["status"] == "scored", attempt
    assert attempt["success"] is True
    assert attempt["turn"] == TURN
    assert attempt["counts"]["model_calls"] == 3
    assert attempt["counts"]["images"] == 1
    assert attempt["counts"]["image_tokens"] == 750
    assert attempt["elapsed_ms"] == 1234.0


def test_an_attempt_that_pressed_the_wrong_save_fails(tmp_path, fake_fixture, monkeypatch):
    events = [event(1, "sidebar.save", "press")]
    rows = lambda now: [llm_row(now + 10), cu_row(now + 20, "press")]  # noqa: E731
    ctx, task = _attempt_world(tmp_path, fake_fixture, monkeypatch, events, rows)
    attempt = run_desktop.run_attempt(ctx, task, repeat_index=1, run_id="desktop-test")
    assert attempt["status"] == "scored"
    assert attempt["success"] is False
    assert [c["passed"] for c in attempt["clauses"]] == [False, False]


def test_an_attempt_with_no_trace_is_invalid_not_a_failure(tmp_path, fake_fixture, monkeypatch):
    rows = lambda now: []  # noqa: E731
    ctx, task = _attempt_world(tmp_path, fake_fixture, monkeypatch,
                               [event(1, "document.save", "press")], rows)
    attempt = run_desktop.run_attempt(ctx, task, repeat_index=1, run_id="desktop-test")
    assert attempt["status"] == "invalid"
    assert attempt["invalid_reason"] == "no_trace"
    assert "success" not in attempt


@pytest.mark.parametrize("task_id", ["leave_checkbox_unticked", "press_disabled_button"])
def test_a_turn_that_made_no_computer_use_call_is_invalid_not_a_pass(
        tmp_path, fake_fixture, monkeypatch, task_id):
    rows = lambda now: [llm_row(now + 10, duration=5)]  # noqa: E731
    ctx, task = _attempt_world(tmp_path, fake_fixture, monkeypatch, [], rows, task_id)
    attempt = run_desktop.run_attempt(ctx, task, repeat_index=1, run_id="desktop-test")
    assert attempt["status"] == "invalid", attempt
    assert attempt["invalid_reason"] == "no_computer_use"


# The engine's own sentences (`tools/computer_use.ex`): the one rendered for the
# typed code `element_disabled`, and three refusals that are not about the control.
DISABLED = ("this action was not sent: that control is DISABLED right now, so it would do "
            "nothing however it were reached — clicking its pixels included. Do not retry it.")
PAUSED = ("computer use is paused — the user took the machine back with /pause. Do not retry; "
          "stop and tell them you'll continue when they run /resume.")
USER_ACTIVE = ("the user is actively using the machine right now, so this action was held back "
               "to avoid taking the cursor from them.")
INPUT_BUSY = ("another conversation is driving this machine's cursor and keyboard right now, "
              "so this action was not sent.")


@pytest.mark.parametrize("refusal, passes", [
    (None, False), (DISABLED, True), (PAUSED, False), (USER_ACTIVE, False), (INPUT_BUSY, False)])
def test_an_expected_refusal_passes_only_with_that_code_in_the_turn(
        tmp_path, fake_fixture, monkeypatch, refusal, passes):
    def rows(now):
        out = [llm_row(now + 10, duration=5), cu_row(now + 20, "elements", output="2 windows")]
        if refusal:
            out.append(cu_row(now + 30, "press", success=False, output=refusal))
        return out + [llm_row(now + 60, duration=5)]
    ctx, task = _attempt_world(tmp_path, fake_fixture, monkeypatch, [], rows,
                               "press_disabled_button")
    attempt = run_desktop.run_attempt(ctx, task, repeat_index=1, run_id="desktop-test")
    assert attempt["status"] == "scored", attempt
    assert all(c["passed"] for c in attempt["clauses"])
    assert attempt["expected_refusal_seen"] is passes
    assert attempt["success"] is passes


def test_an_attempt_traced_without_content_capture_is_invalid(tmp_path, fake_fixture,
                                                               monkeypatch):
    def rows(now):
        bare = cu_row(now + 20, "press")
        del bare["output"]
        return [llm_row(now + 10, duration=5), bare]
    ctx, task = _attempt_world(tmp_path, fake_fixture, monkeypatch,
                               [event(1, "document.save", "press")], rows)
    attempt = run_desktop.run_attempt(ctx, task, repeat_index=1, run_id="desktop-test")
    assert attempt["status"] == "invalid", attempt
    assert attempt["invalid_reason"] == "content_capture_off"


def test_an_attempt_whose_fixture_cannot_start_is_invalid_and_the_run_goes_on(
        tmp_path, fake_fixture, monkeypatch):
    ctx, task = _attempt_world(tmp_path, fake_fixture, monkeypatch, [], lambda now: [])
    monkeypatch.setattr(corpus, "launch_argv", lambda _f, **kw: [
        str(tmp_path / "no-such-fixture"), "--state-file", kw["state_file"]])
    attempt = run_desktop.run_attempt(ctx, task, repeat_index=1, run_id="desktop-test")
    assert attempt["status"] == "invalid"
    assert attempt["invalid_reason"] == "launch_failed"


def test_the_summary_counts_scored_attempts_only():
    attempts = [
        {"task": "a", "status": "scored", "success": True,
         "counts": {"model_calls": 4, "image_tokens": 100, "image_tokens_sent": 300,
                    "cu_calls": 3, "cu_failures": 0}, "elapsed_ms": 10.0},
        {"task": "a", "status": "scored", "success": False,
         "counts": {"model_calls": 6, "image_tokens": 300, "image_tokens_sent": 900,
                    "cu_calls": 5, "cu_failures": 2}, "elapsed_ms": 30.0},
        {"task": "a", "status": "invalid", "invalid_reason": "no_trace"},
    ]
    summary = run_desktop.summarize(attempts)
    assert summary["attempts"] == 3
    assert summary["scored"] == 2
    assert summary["invalid"] == 1
    assert summary["successes"] == 1
    assert summary["cu_failure_rate"] == pytest.approx(2 / 8)
    assert summary["median_model_calls"] == 5


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
