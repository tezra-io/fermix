#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8.4", "pyyaml>=6,<7", "certifi", "anthropic>=1.13,<2"]
# ///
"""Specs for starting every attempt of an isolated companion case from the seeded
world: eval_home_state.py (snapshot, restore and the disposable-home guard),
capability-daemon.sh `up`/`reset` against a fake daemon, and run_eval.py
--reset-home. Hermetic: every home is a temp dir, the daemon is a stub `mix` on
PATH that answers the control socket as fermix-shim speaks to it, a "live daemon"
in a refused home is a `sleep`, and nothing reaches ~/.fermix, ~/.fermix-dev or a
real daemon. Run: `uv run bin/test_home_reset.py`."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import eval_home_state as state  # noqa: E402
import run_eval  # noqa: E402
import seed_capability_home as seed  # noqa: E402
from evallib import companion, report, safe_rm, suites  # noqa: E402

DAEMON_SCRIPT = os.path.join(HERE, "capability-daemon.sh")
SCRIPT_TIMEOUT_S = 120

# Stands in for `mix`: `mix compile` succeeds, and `mix fermix.dev` is a daemon that
# records each start with what memory.db held then, writes to memory.db as a real
# daemon would, answers the control socket ({packet, 4} JSON), and exits on SIGTERM.
# Its companion socket comes up only after the control socket answered, as the real
# daemon's does (FermixChannels starts after FermixCore's control socket), and
# FAKE_COMPANION_DELAY_S seconds later; it speaks just enough of the chat for one
# `companion.drive`: the hello, `/new`, a history page, and a message that completes.
MIX_STUB = r'''#!/usr/bin/env python3
import json, os, signal, socket, struct, sys, threading, time
args = sys.argv[1:]
if args[:1] == ["compile"]:
    sys.exit(0)
if args[:1] != ["fermix.dev"]:
    sys.exit(f"mix stub: unexpected {args}")
home = os.environ["FERMIX_HOME"]
db = os.path.join(home, "memory.db")
seen = open(db).read() if os.path.exists(db) else None
with open(os.path.join(home, "fake-daemon.log"), "a") as log:
    log.write(json.dumps({"pid": os.getpid(), "memory_db": seen,
                          "path": os.environ.get("PATH", ""),
                          "fixture_origin": os.environ.get("FERMIX_EVAL_FIXTURE_ORIGIN")}) + "\n")
with open(db, "a") as fh:
    fh.write("+written-by-the-daemon")
path = os.path.join(home, "daemon.sock")
companion_path = os.path.join(home, "companion.sock")
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(4)
answered = threading.Event()
def stop(*_):
    server.close()
    for sock in (path, companion_path):
        if os.path.exists(sock):
            os.remove(sock)
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
def chat(event):
    kind = event["type"]
    if kind == "client_hello":
        return [{"type": "server_hello", "min_version": 1, "max_version": 7}]
    if kind == "command":
        return [{"type": "row", "role": "assistant", "text": "New conversation.",
                 "server_seq": 1}]
    if kind == "history_pull":
        return [{"type": "history_page", "messages": [], "history_head_seq": 1}]
    if kind == "msg":
        cid = event["client_msg_id"]
        return [{"type": "accepted", "client_msg_id": cid},
                {"type": "turn_started", "in_reply_to": cid, "turn_id": "turn-1"},
                {"type": "text_done", "turn_id": "turn-1", "text": "Done.",
                 "server_seq": 2, "blocks": []}]
    return []
def serve_companion():
    answered.wait()
    time.sleep(float(os.environ.get("FAKE_COMPANION_DELAY_S", "0")))
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(companion_path)
    listener.listen(4)
    while True:
        conn, _ = listener.accept()
        with conn, conn.makefile("rb") as lines:
            for line in lines:
                for event in chat(json.loads(line)):
                    conn.sendall(json.dumps(event).encode() + b"\n")
threading.Thread(target=serve_companion, daemon=True).start()
while True:
    conn, _ = server.accept()
    with conn:
        size = struct.unpack(">I", conn.recv(4))[0]
        body = b""
        while len(body) < size:
            body += conn.recv(size - len(body))
        reply = json.dumps({"status": "ok", "pid": os.getpid()}).encode()
        conn.sendall(struct.pack(">I", len(reply)) + reply)
    answered.set()
'''

SEEDED = {"memory.db": "seeded rows", "memory.db-wal": "seeded wal",
          "memory/MEMORY.md": "seeded memory", "skills/tallow/SKILL.md": "seeded skill",
          "config.toml": "# seeded config\n"}


@pytest.fixture
def scratch():
    """A short temp root: a daemon.sock path under it stays inside the AF_UNIX limit."""
    root = tempfile.mkdtemp(prefix="fxr")
    yield Path(root)
    safe_rm.rm_rf(root, tempfile.gettempdir())


@pytest.fixture
def fake_mix(scratch, monkeypatch):
    stub_dir = scratch / "stubbin"
    stub_dir.mkdir()
    stub = stub_dir / "mix"
    stub.write_text(MIX_STUB)
    stub.chmod(0o755)
    monkeypatch.setenv("PATH", f"{stub_dir}{os.pathsep}{os.environ['PATH']}")
    return stub_dir


@pytest.fixture
def stray_daemons():
    """Every pid a test started or recorded; any still alive at the end is killed."""
    pids: list[int] = []
    yield pids
    for pid in pids:
        if _alive(pid):
            os.kill(pid, 9)


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def _write_tree(home: Path, files: dict[str, str]) -> None:
    for name, text in files.items():
        path = home / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


def _seeded_home(root: Path, leaf: str = "cap-eval") -> Path:
    home = root / leaf
    home.mkdir()
    _write_tree(home, SEEDED)
    return home


def _script(command: str, home: Path, **extra) -> subprocess.CompletedProcess:
    env = {**os.environ, "FERMIX_CAP_HOME": str(home), "FERMIX_CAP_OPIK": "0",
           "READY_TIMEOUT": "30", **extra}
    return subprocess.run([DAEMON_SCRIPT, command], env=env, capture_output=True,
                          text=True, timeout=SCRIPT_TIMEOUT_S)


def _starts(home: Path) -> list[dict]:
    log = home / "fake-daemon.log"
    if not log.exists():
        return []
    return [json.loads(line) for line in log.read_text().splitlines()]


def _down(home: Path, stray_daemons: list[int]) -> None:
    stray_daemons.extend(start["pid"] for start in _starts(home))
    assert _script("down", home).returncode == 0


# --- eval_home_state.py ------------------------------------------------------

def test_restore_puts_back_the_seeded_state_and_removes_what_came_after(scratch):
    home = _seeded_home(scratch)
    (home / "auth.json").write_text('{"seeded": true}')
    state.snapshot(str(home))
    # What a case's model and the daemon leave behind: a changed database, a new
    # memory directive, a job run, a new sqlite sidecar, a lost one, a changed config.
    _write_tree(home, {"memory.db": "a watcher a case created",
                       "memory/directive.md": "a review directive",
                       "job_runs/run_1/out.txt": "ran", "memory.db-shm": "shm",
                       "config.toml": "# changed\n"})
    (home / "memory.db-wal").unlink()
    (home / "auth.json").write_text('{"rotated": true}')
    state.restore(str(home))
    for name, text in SEEDED.items():
        assert (home / name).read_text() == text, name
    for gone in ("memory/directive.md", "job_runs", "memory.db-shm"):
        assert not (home / gone).exists(), gone
    # A rotated OAuth refresh token stays: the old one would sign the home out.
    assert (home / "auth.json").read_text() == '{"rotated": true}'


def test_restore_removes_a_sign_in_mark_written_after_the_snapshot(scratch):
    # M98 D10: each attempt starts without the marks an earlier attempt's run left
    # in this machine's coding store; the computers' records beside it stay.
    home = _seeded_home(scratch)
    _write_tree(home, {"device/computers/b47e0d93.json": '{"v": 1}'})
    state.snapshot(str(home))
    store = ("device/coding.db", "device/coding.db-wal", "device/coding.db-shm")
    _write_tree(home, {name: "claude signed out" for name in store})

    state.restore(str(home))

    assert not any((home / name).exists() for name in store)
    assert (home / "device/computers/b47e0d93.json").read_text() == '{"v": 1}'


def test_a_snapshot_taken_with_the_coding_store_present_puts_it_back(scratch):
    # `capability-daemon.sh snapshot` may run after a daemon made device/coding.db.
    home = _seeded_home(scratch)
    _write_tree(home, {"device/coding.db": "seeded store"})
    state.snapshot(str(home))
    (home / "device/coding.db").write_text("a mark from the attempt")

    state.restore(str(home))

    assert (home / "device/coding.db").read_text() == "seeded store"


def test_snapshot_keeps_what_reset_state_clears_and_the_config():
    # The seeded sandbox is the machine's own setting (M97 §4), which a grant changes.
    assert set(state.KEPT) == {*seed.STATE_DIRS, *seed.STATE_FILES, "config.toml",
                               seed.MACHINE_FILE}
    assert "auth.json" not in state.KEPT


def test_snapshot_and_restore_refuse_a_home_that_is_not_an_eval_home(scratch):
    home = _seeded_home(scratch, leaf="vela-home")
    for step in (state.snapshot, state.restore, state.snapshot_path):
        with pytest.raises(SystemExit):
            step(str(home))
    assert not (home / state.SNAPSHOT_DIR).exists()
    assert (home / "memory.db").read_text() == "seeded rows"


def test_restore_refuses_a_symlinked_home(scratch):
    real = _seeded_home(scratch, leaf="vela-home")
    link = scratch / "linked-eval"
    link.symlink_to(real)
    with pytest.raises(SystemExit):
        state.restore(str(link))
    assert (real / "memory.db").read_text() == "seeded rows"


def test_snapshot_and_restore_refuse_while_a_daemon_answers(scratch, monkeypatch):
    home = _seeded_home(scratch)
    state.snapshot(str(home))
    (home / "memory.db").write_text("live rows")
    monkeypatch.setattr(seed, "daemon_answers", lambda _home: True)
    for step in (state.snapshot, state.restore):
        with pytest.raises(SystemExit):
            step(str(home))
    assert (home / "memory.db").read_text() == "live rows"


def test_restore_refuses_a_home_with_no_snapshot(scratch):
    home = _seeded_home(scratch)
    with pytest.raises(SystemExit):
        state.restore(str(home))
    assert (home / "memory.db").read_text() == "seeded rows"


def test_snapshot_refuses_a_home_the_seeder_never_seeded(scratch):
    home = scratch / "cap-eval"
    home.mkdir()
    with pytest.raises(SystemExit):
        state.snapshot(str(home))


# --- capability-daemon.sh ------------------------------------------------------

def test_up_snapshots_the_seed_before_the_daemon_starts(scratch, fake_mix, stray_daemons):
    home = scratch / "cap-eval"
    up = _script("up", home, FERMIX_CAP_SEED_ARGS="--provider ollama --model brindle-7b")
    try:
        assert up.returncode == 0, up.stderr
        saved = home / state.SNAPSHOT_DIR
        assert (saved / "config.toml").read_text() == (home / "config.toml").read_text()
        assert (saved / "skills").is_dir()
        # The daemon wrote memory.db once it started; the snapshot was taken before.
        assert (home / "memory.db").exists() and not (saved / "memory.db").exists()
    finally:
        _down(home, stray_daemons)


@pytest.mark.parametrize("flag, leads", [("--coding-signed-out", True), ("", False)])
def test_up_puts_the_eval_bin_first_on_the_daemons_path_only_for_a_stub(
        scratch, fake_mix, stray_daemons, flag, leads):
    # The signed-out stub `claude` is the Claude Code the daemon finds at boot only
    # when its folder leads the daemon's PATH, as the cue suites' stub codex does.
    home = scratch / "cap-eval"
    up = _script("up", home, FERMIX_CAP_SEED_ARGS=f"--provider ollama --model brindle-7b {flag}")
    try:
        assert up.returncode == 0, up.stderr
        [start] = _starts(home)
        eval_bin = str(home / seed.CUE_BIN_DIR)
        assert (start["path"].split(os.pathsep)[0] == eval_bin) is leads
    finally:
        _down(home, stray_daemons)


def test_up_hands_the_daemon_the_fixture_origin_its_seed_recorded(
        scratch, fake_mix, stray_daemons):
    # The one origin the daemon's web_fetch may read is the port the runners bind,
    # whatever the caller's own environment says.
    home = scratch / "cap-eval"
    up = _script("up", home, FERMIX_CAP_SEED_ARGS="--provider ollama --model brindle-7b",
                 FERMIX_EVAL_FIXTURE_ORIGIN="http://127.0.0.1:1")
    try:
        assert up.returncode == 0, up.stderr
        port = json.loads((home / seed.FIXTURE_MANIFEST).read_text())["port"]
        [start] = _starts(home)
        assert start["fixture_origin"] == f"http://127.0.0.1:{port}"
    finally:
        _down(home, stray_daemons)


def test_a_home_without_the_fixture_manifest_starts_the_daemon_without_the_origin(
        scratch, fake_mix, stray_daemons):
    # A home seeded before the manifest existed: its daemon's web_fetch refuses
    # loopback as every Fermix does, even when the caller's environment carries
    # the variable.
    home = _seeded_home(scratch)
    assert not (home / seed.FIXTURE_MANIFEST).exists()
    assert _script("snapshot", home).returncode == 0
    try:
        reset = _script("reset", home, FERMIX_EVAL_FIXTURE_ORIGIN="http://127.0.0.1:4173")
        assert reset.returncode == 0, reset.stderr
        [start] = _starts(home)
        assert start["fixture_origin"] is None
    finally:
        _down(home, stray_daemons)


def test_a_fixture_manifest_it_cannot_read_stops_the_start(scratch, fake_mix, stray_daemons):
    home = _seeded_home(scratch)
    _write_tree(home, {seed.FIXTURE_MANIFEST: '{"port": "4173"}'})
    assert _script("snapshot", home).returncode == 0
    try:
        reset = _script("reset", home)
        assert reset.returncode != 0
        assert "fixture manifest" in reset.stderr
        assert _starts(home) == []
    finally:
        _down(home, stray_daemons)


def test_reset_restores_the_snapshot_and_restarts_the_daemon(
        scratch, fake_mix, stray_daemons):
    home = _seeded_home(scratch)
    assert _script("snapshot", home).returncode == 0
    try:
        for _attempt in range(2):
            reset = _script("reset", home)
            assert reset.returncode == 0, reset.stderr
        first, second = _starts(home)
        # Each start found the seeded database, never the previous daemon's writes.
        assert first["memory_db"] == second["memory_db"] == "seeded rows"
        assert not _alive(first["pid"]) and _alive(second["pid"])
        assert (home / "daemon.pid").read_text().strip() == str(second["pid"])
    finally:
        _down(home, stray_daemons)


def test_reset_refuses_a_home_that_is_not_an_eval_home_before_stopping_it(
        scratch, fake_mix, stray_daemons):
    home = _seeded_home(scratch, leaf="vela-home")
    live = subprocess.Popen(["sleep", "300"])
    stray_daemons.append(live.pid)
    (home / "daemon.pid").write_text(f"{live.pid}\n")
    reset = _script("reset", home)
    assert reset.returncode != 0
    assert "outside an eval home" in reset.stderr
    assert live.poll() is None, "the daemon of a refused home was stopped"
    assert (home / "daemon.pid").exists()
    assert (home / "memory.db").read_text() == "seeded rows"
    assert _starts(home) == []
    live.kill()
    live.wait()


def test_reset_refuses_an_eval_home_with_no_snapshot_before_stopping_it(
        scratch, fake_mix, stray_daemons):
    home = _seeded_home(scratch)
    live = subprocess.Popen(["sleep", "300"])
    stray_daemons.append(live.pid)
    (home / "daemon.pid").write_text(f"{live.pid}\n")
    reset = _script("reset", home)
    assert reset.returncode != 0
    assert "no seeded-state snapshot" in reset.stderr
    assert live.poll() is None, "the daemon of a home with no snapshot was stopped"
    assert _starts(home) == []
    live.kill()
    live.wait()


# --- run_eval.py --reset-home -------------------------------------------------

def _companion_case(case_id: str) -> str:
    return (f"      - id: {case_id}\n        drive: companion\n        query: {case_id}\n"
            "        expect:\n          wire:\n            events_all: [accepted]\n")


def _reset_suite(tmp_path):
    """An isolated companion scenario, a read-only companion one and an isolated
    `ask` one: only the first starts each attempt from the snapshot."""
    path = tmp_path / "brindle.yaml"
    path.write_text(
        "suite: brindle\ntitle: Brindle\nrisk: isolated_mutation\nscenarios:\n"
        "  - id: makes_a_watcher\n    title: Makes a watcher\n    cases:\n"
        + _companion_case("one") + _companion_case("two")
        + "  - id: reads_the_watchers\n    title: Reads\n    risk: host_readonly\n"
          "    cases:\n" + _companion_case("three") + _companion_case("four")
        + "  - id: asked\n    title: Asked\n    cases:\n"
          "      - id: five\n        query: five\n      - id: six\n        query: six\n")
    return suites.load_all(str(tmp_path))[0]


def _scripted(monkeypatch, events: list[str], outcomes: dict[str, list[str]]):
    """Each case's attempt outcomes in order; every attempt driven joins `events`."""

    def scripted(_cfg, _client, _suite, _scn, case, _run_id, trial, *_rest):
        events.append(case.id)
        outcome = outcomes.get(case.id, ["pass"]).pop(0)
        return {"id": case.id, "trial": trial, "outcome": outcome,
                "passed": outcome == "pass", "incomplete": False,
                "gate_passed": True, "turns": [], "rubric": None}

    monkeypatch.setattr(run_eval, "run_companion_case", scripted)
    monkeypatch.setattr(run_eval, "run_case", scripted)


def _reset(events: list[str], error: str | None = None):
    def reset() -> str | None:
        events.append("reset")
        return error

    return reset


def test_every_attempt_of_an_isolated_companion_case_starts_from_the_snapshot(
        tmp_path, monkeypatch):
    suite = _reset_suite(tmp_path)
    jobs = run_eval.case_jobs([(suite, suite.scenarios)], repeat=1)
    events: list[str] = []
    _scripted(monkeypatch, events, {"one": ["fail", "pass"]})
    _results, _skipped, aborted = run_eval._execute_jobs(
        SimpleNamespace(), object(), jobs, "20261103T010000Z01234567", False, False,
        fail_retries=1, reset_home=_reset(events))
    assert aborted is None
    # The retry of `one` starts from the snapshot too; read-only and `ask` cases never.
    assert events == ["reset", "one", "reset", "one", "reset", "two",
                      "three", "four", "five", "six"]


def test_a_failed_reset_stops_the_run_before_the_case_is_driven(tmp_path, monkeypatch):
    suite = _reset_suite(tmp_path)
    jobs = run_eval.case_jobs([(suite, suite.scenarios)], repeat=1)
    events: list[str] = []
    _scripted(monkeypatch, events, {})
    results, _skipped, aborted = run_eval._execute_jobs(
        SimpleNamespace(), object(), jobs, "20261103T010000Z01234567", False, False,
        reset_home=_reset(events, error="daemon did not become ready within 90s"))
    assert events == ["reset"], "no case may be driven after a reset failed"
    cases = results[0]["scenarios"][0]["cases"]
    assert [c["id"] for c in cases] == ["one"]
    assert cases[0]["outcome"] == "incomplete"
    assert aborted["unrun"] == 5
    assert "daemon did not become ready" in aborted["message"]
    # The report says what stopped the run: the harness, never an exhausted account.
    banner = report._abort_text(run_eval._persistable_abort(dict(aborted)))
    assert "the harness, not a product failure" in banner
    assert "external account" not in banner


def test_the_runner_resets_through_the_daemon_script(scratch, fake_mix, stray_daemons):
    home = _seeded_home(scratch)
    assert _script("snapshot", home).returncode == 0
    (home / "memory.db").write_text("a watcher the last case created")
    cfg = SimpleNamespace(daemon=SimpleNamespace(fermix_home=str(home)),
                          opik=SimpleNamespace(project="fermix-capability-eval"))
    try:
        assert run_eval.home_resetter(cfg)() is None
        assert [start["memory_db"] for start in _starts(home)] == ["seeded rows"]
    finally:
        _down(home, stray_daemons)


def test_a_companion_socket_that_comes_up_after_the_control_socket_fails_no_drive(
        scratch, fake_mix, stray_daemons, monkeypatch):
    # The live cues run lost five attempts this way: the reset returned once the
    # control socket answered, and the drive's connect beat the companion socket.
    home = _seeded_home(scratch)
    assert _script("snapshot", home).returncode == 0
    monkeypatch.setenv("FAKE_COMPANION_DELAY_S", "2")
    cfg = SimpleNamespace(daemon=SimpleNamespace(fermix_home=str(home)),
                          opik=SimpleNamespace(project="fermix-capability-eval"))
    try:
        assert run_eval.home_resetter(cfg)() is None
        evidence = companion.drive(str(home), {}, "Brindle status", "e2e-mark-brindle",
                                   timeout_s=10)
        assert evidence.ok, evidence.error
        assert evidence.target.reply() == "Done."
    finally:
        _down(home, stray_daemons)


def test_a_companion_socket_that_never_answers_fails_the_reset_loudly(
        scratch, fake_mix, stray_daemons, monkeypatch):
    # A reset error stops the run as the harness's (test_a_failed_reset_stops_the_run…).
    home = _seeded_home(scratch)
    assert _script("snapshot", home).returncode == 0
    monkeypatch.setenv("FAKE_COMPANION_DELAY_S", "600")
    monkeypatch.setattr(run_eval, "_COMPANION_READY_S", 0.5)
    cfg = SimpleNamespace(daemon=SimpleNamespace(fermix_home=str(home)),
                          opik=SimpleNamespace(project="fermix-capability-eval"))
    try:
        error = run_eval.home_resetter(cfg)()
        assert error is not None
        assert "answered its control socket" in error
        assert "did not answer a hello within 0.5s" in error
        assert f"{home / companion.SOCKET_NAME}: [Errno 2]" in error
    finally:
        _down(home, stray_daemons)


def test_the_runner_reports_a_reset_the_script_refused(scratch, fake_mix):
    home = _seeded_home(scratch)
    cfg = SimpleNamespace(daemon=SimpleNamespace(fermix_home=str(home)),
                          opik=SimpleNamespace(project="fermix-capability-eval"))
    error = run_eval.home_resetter(cfg)()
    assert "no seeded-state snapshot" in error
    assert _starts(home) == []


def test_reset_home_precondition_needs_the_snapshot(scratch):
    home = _seeded_home(scratch)
    assert "capability-daemon.sh up" in run_eval.reset_home_precondition_error(str(home))
    state.snapshot(str(home))
    assert run_eval.reset_home_precondition_error(str(home)) is None


def test_reset_home_is_refused_without_the_isolated_mutation_profile(capsys):
    code = run_eval.main(["--suite", "cues", "--judge", "--dry-run", "--reset-home"])
    assert code == 2
    assert "--reset-home" in capsys.readouterr().err


def test_dry_run_counts_the_attempts_that_start_from_the_snapshot(capsys):
    code = run_eval.main(["--suite", "cues", "--profile", "isolated_mutation", "--judge",
                          "--dry-run", "--reset-home"])
    out = capsys.readouterr().out
    assert code == 0
    jobs = run_eval.case_jobs(
        [(s, s.scenarios) for s in suites.load_all(os.path.join(run_eval.SKILL_DIR, "suites"))
         if s.name == "cues"], repeat=1)
    resets = sum(1 for _suite, scenario, case, _trial in jobs
                 if run_eval.resets_home(scenario, case))
    assert resets > 0
    assert f"home reset: {resets} case trial(s)" in out


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "--disable-plugin-autoload"]))
