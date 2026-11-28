#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8.4", "pyyaml>=6,<7", "certifi", "anthropic>=1.13,<2"]
# ///
"""Specs for starting every attempt of an isolated companion case, and every trial or
attempt of a seeded (`checker.state`, `state:`) case, from the seeded world:
eval_home_state.py (snapshot, restore and the disposable-home guard),
capability-daemon.sh `up`/`reset` against a fake daemon, run_eval.py --reset-home and
the capability runner's restore before each seeded trial. Hermetic: every home is a temp
dir, the daemon is a stub `mix` on PATH that answers the control socket as the engine
does (its replies are the engine's own management goldens, read from the repo when the
tests start), a "live daemon" in a refused home is a `sleep`, and nothing reaches
~/.fermix, ~/.fermix-dev or a real daemon. Run: `uv run bin/test_home_reset.py`."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import eval_daemon_keeper as keeper_mod  # noqa: E402
import eval_home_state as state  # noqa: E402
import run_capability as rc  # noqa: E402
import run_eval  # noqa: E402
import seed_capability_home as seed  # noqa: E402
from evallib import companion, grade, report, safe_rm, suites  # noqa: E402

DAEMON_SCRIPT = os.path.join(HERE, "capability-daemon.sh")
SCRIPT_TIMEOUT_S = 120

# Stands in for `mix` (MIX_WRAPPER, which runs MIX_STUB): `mix compile` succeeds, and
# `mix fermix.dev` is a daemon that records each start with what memory.db held then and
# the parts of its environment the specs ask about (and, from the wrapper, before any
# interpreter touches it, its whole environment as names and a digest of each value, never
# a value, in <home>/daemon-env.<pid>), writes to
# memory.db as a real daemon would (unless FAKE_DAEMON_WRITES=0, for a memory.db that is
# a real SQLite file), says it booted on its stdout (the daemon log), answers the
# control socket as the engine does (below), and exits on SIGTERM. <home>/fail-boot
# makes it exit during boot, <home>/slow-boot holds seconds it waits before it listens,
# and <home>/unready-answers a number of `hello`s it first answers as an engine whose
# identity is not ready yet (the golden `unavailable`, for `engine_identity`).
# On the control socket ({packet, 4} JSON) it answers the one request the harness sends
# there, the management `hello`, with the engine's golden reply (its own request id, and
# its own pid as the string `engine.pid` is), a method the engine does not know as the
# engine does (v0: `unknown method`; v1: the golden `method_not_found`), and dies, saying
# why in the log, on anything the engine would answer that it does not model: a method
# of the engine's, or a v1 frame the engine would refuse.
# Its companion socket comes up only after the control socket answered, as the real
# daemon's does (FermixChannels starts after FermixCore's control socket), and
# FAKE_COMPANION_DELAY_S seconds later; it speaks just enough of the chat for one
# `companion.drive`: the hello, `/new`, a history page, and a message that completes.
MIX_WRAPPER = r'''#!/bin/sh
if [ "$1" = fermix.dev ]; then
  env -0 | python3 -c 'import hashlib, json, sys
entries = [e.partition(b"=") for e in sys.stdin.buffer.read().split(b"\0") if e]
print(json.dumps({k.decode(): hashlib.sha256(v).hexdigest()[:16] for k, _, v in entries}))' \
    > "$FERMIX_HOME/daemon-env.$$"
fi
exec python3 "$(dirname "$0")/mix.py" "$@"
'''
MIX_STUB = r'''#!/usr/bin/env python3
import json, os, signal, socket, struct, sys, threading, time
args = sys.argv[1:]
if args[:1] == ["compile"]:
    sys.exit(0)
if args[:1] != ["fermix.dev"]:
    sys.exit(f"mix stub: unexpected {args}")
home = os.environ["FERMIX_HOME"]
if os.path.exists(os.path.join(home, "fail-boot")):
    sys.exit("mix stub: failing at boot, as <home>/fail-boot asks")
if os.path.exists(os.path.join(home, "slow-boot")):
    time.sleep(float(open(os.path.join(home, "slow-boot")).read()))
db = os.path.join(home, "memory.db")
seen = open(db, "rb").read().decode("utf-8", "replace") if os.path.exists(db) else None
with open(os.path.join(home, "fake-daemon.log"), "a") as log:
    log.write(json.dumps({"pid": os.getpid(), "memory_db": seen,
                          "path": os.environ.get("PATH", ""),
                          "fixture_origin": os.environ.get("FERMIX_EVAL_FIXTURE_ORIGIN"),
                          "openai_key_set": "OPENAI_API_KEY" in os.environ,
                          "anthropic_key_set": "ANTHROPIC_API_KEY" in os.environ,
                          "probe": os.environ.get("EVAL_PROBE_ENV")}) + "\n")
if os.environ.get("FAKE_DAEMON_WRITES", "1") == "1":
    with open(db, "a") as fh:
        fh.write("+written-by-the-daemon")
print(f"fake daemon {os.getpid()} booted", flush=True)
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
ENGINE = json.loads(__ENGINE__)
unready = os.path.join(home, "unready-answers")
UNREADY = [int(open(unready).read())] if os.path.exists(unready) else [0]
PROTOCOL = ENGINE["hello"]["result"]["protocol"]
VERSIONS = range(PROTOCOL["minimum_version"], PROTOCOL["maximum_version"] + 1)
V1_FIELDS = {"request_id", "protocol_version", "method", "params"}
def unmodelled(what):
    sys.exit(f"mix stub: {what}: the engine answers it and this stub does not model it")
def control_reply(request):
    # The engine's own split (Management.Protocol.decode_request): a frame with either
    # marker is v1, any other object with a string method v0.
    method = request.get("method")
    if "request_id" not in request and "protocol_version" not in request:
        if method in ENGINE["v0_methods"]:
            unmodelled(f"v0 {method!r}")
        return {"status": "error", "reason": "unknown method", "method": method}
    if (set(request) - V1_FIELDS or not isinstance(request.get("request_id"), str)
            or request.get("protocol_version") not in VERSIONS
            or not isinstance(request.get("params", {}), dict)):
        unmodelled(f"a v1 frame the engine refuses ({request})")
    if method == "hello" and UNREADY[0] > 0:
        UNREADY[0] -= 1
        reply = json.loads(json.dumps(ENGINE["unavailable"]))
        reply["request_id"] = request["request_id"]
        reply["error"]["details"] = {"capability": "engine_identity"}
        return reply
    if method == "hello":
        reply = json.loads(json.dumps(ENGINE["hello"]))
        reply["request_id"] = request["request_id"]
        reply["result"]["engine"]["pid"] = str(os.getpid())
        return reply
    if method in ENGINE["hello"]["result"]["capabilities"]["methods"]:
        unmodelled(f"v1 {method!r}")
    reply = json.loads(json.dumps(ENGINE["not_found"]))
    reply["request_id"] = request["request_id"]
    reply["error"]["details"] = {"method": method}
    return reply
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
    if os.path.exists(companion_path):
        os.remove(companion_path)         # a killed daemon's, as a real server drops it
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
        try:
            size = struct.unpack(">I", conn.recv(4))[0]
            body = b""
            while len(body) < size:
                body += conn.recv(size - len(body))
        except (OSError, struct.error):
            continue                      # a probe that only connected
        reply = json.dumps(control_reply(json.loads(body))).encode()
        try:
            conn.sendall(struct.pack(">I", len(reply)) + reply)
        except OSError:
            continue                      # a client that went away first
    answered.set()
'''

# The engine's control socket, read from the repo when the tests start: the management
# goldens `protocol_contract_test.exs` holds the engine's code to, and the v0 methods
# `Fermix.CLI.Daemon` answers.
REPO = Path(HERE).parents[1]
MANAGEMENT = REPO / "apps" / "fermix_core" / "priv" / "management"
DAEMON_EX = REPO / "apps" / "fermix_core" / "lib" / "fermix" / "cli" / "daemon.ex"


def _golden(file: str, name: str) -> dict:
    for line in (MANAGEMENT / "fixtures" / file).read_text().splitlines():
        entry = json.loads(line)
        if entry.get("name") == name:
            return entry
    raise LookupError(f"{file} holds no golden named {name!r}")


def _engine_v0_methods() -> list[str]:
    source = DAEMON_EX.read_text()
    return sorted(set(re.findall(r'defp handle_method\("([a-z_]+)"', source)
                      + re.findall(r'dispatch_served_request\(%\{"method" => "([a-z_]+)"\}',
                                   source)))


ENGINE = {"hello": _golden("success.jsonl", "hello")["response"],
          "not_found": _golden("errors.jsonl", "method_not_found")["response"],
          "unavailable": _golden("errors.jsonl", "unavailable")["response"],
          "v0_methods": _engine_v0_methods()}

SEEDED = {"memory.db": "seeded rows", "memory.db-wal": "seeded wal",
          "memory/MEMORY.md": "seeded memory", "skills/tallow/SKILL.md": "seeded skill",
          "config.toml": "# seeded config\n"}


@pytest.fixture
def scratch():
    """A short temp root: a daemon.sock path under it stays inside the AF_UNIX limit."""
    root = tempfile.mkdtemp(prefix="fxr")
    yield Path(root)
    safe_rm.rm_rf(root, tempfile.gettempdir())


def _install_stub(stub_dir: Path) -> Path:
    stub_dir.mkdir()
    stub = MIX_STUB.replace("__ENGINE__", repr(json.dumps(ENGINE)))
    for name, body in (("mix", MIX_WRAPPER), ("mix.py", stub)):
        (stub_dir / name).write_text(body)
        (stub_dir / name).chmod(0o755)
    return stub_dir


@pytest.fixture
def fake_mix(scratch, monkeypatch):
    stub_dir = _install_stub(scratch / "stubbin")
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


def _script_env(home: Path, drop: tuple = (), **extra) -> dict[str, str]:
    env = {**os.environ, "FERMIX_CAP_HOME": str(home), "FERMIX_CAP_OPIK": "0",
           "READY_TIMEOUT": "30", **extra}
    for name in drop:
        env.pop(name, None)
    return env


def _script(command: str, home: Path, drop: tuple = (), **extra) -> subprocess.CompletedProcess:
    return subprocess.run([DAEMON_SCRIPT, command], env=_script_env(home, drop, **extra),
                          capture_output=True, text=True, timeout=SCRIPT_TIMEOUT_S)


def _starts(home: Path) -> list[dict]:
    log = home / "fake-daemon.log"
    if not log.exists():
        return []
    return [json.loads(line) for line in log.read_text().splitlines()]


def _down(home: Path, stray_daemons: list[int]) -> None:
    stray_daemons.extend(start["pid"] for start in _starts(home))
    keeper = home / "keeper.pid"
    if keeper.exists():
        stray_daemons.append(int(keeper.read_text()))
    assert _script("down", home).returncode == 0


EXPLICIT = "--provider ollama --model brindle-7b"


def _up(home: Path, seed_args: str = "", **extra) -> subprocess.CompletedProcess:
    """`up` in the seeder's explicit mode: hermetic, no dev home read."""
    return _script("up", home, FERMIX_CAP_SEED_ARGS=f"{EXPLICIT} {seed_args}".strip(), **extra)


PROJECT = "fermix-capability-eval"
# A home whose daemon exports to the runners' project, as `up` starts it by default.
EXPORTING = {"FERMIX_CAP_OPIK": "1", "FERMIX_CAP_PROJECT": PROJECT}
# The caller's locale, which the shared home's `up` runs without (CPython then coerces
# its own: the daemon must not inherit what the keeper's interpreter added).
LOCALE = ("LANG", "LC_ALL", "LC_CTYPE")


def _cfg(home: Path, project: str = PROJECT) -> SimpleNamespace:
    return SimpleNamespace(daemon=SimpleNamespace(fermix_home=str(home)),
                           opik=SimpleNamespace(project=project))


def _check(home: Path, **extra) -> subprocess.CompletedProcess:
    return _script("check", home, **extra)


def _wait_for(predicate, seconds: float = 10.0) -> bool:
    deadline = time.monotonic() + seconds
    while not predicate():
        if time.monotonic() > deadline:
            return False
        time.sleep(0.05)
    return True


def _daemon_env(home: Path, pid: int) -> dict[str, str]:
    """The environment the daemon `pid` was started with, as its wrapper recorded it:
    each name with a digest of its value (`_digest`), never the value."""
    return json.loads((home / f"daemon-env.{pid}").read_text())


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8", "surrogateescape")).hexdigest()[:16]


def _by_hand(home: Path, fake_mix: Path, stray_daemons: list[int]) -> subprocess.Popen:
    """A daemon started by hand on `home`, as README §4 once started one: no keeper."""
    env = {**os.environ, "FERMIX_HOME": str(home), "FAKE_DAEMON_WRITES": "0"}
    daemon = subprocess.Popen([str(fake_mix / "mix"), "fermix.dev", "--no-web"], env=env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    stray_daemons.append(daemon.pid)
    assert _wait_for(lambda: (home / "daemon.sock").exists()), \
        "the hand-started daemon never made its control socket"
    return daemon


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


# --- the control socket, as the engine speaks it ---------------------------------------
#
# The tie between the harness and the engine is the engine's own management goldens
# (apps/fermix_core/priv/management), which protocol_contract_test.exs holds the
# engine's code to: what the keeper sends, what it reads, and what the stub daemon
# answers are each checked against them here. A change to `hello`'s request or reply,
# to the field and type of `engine.pid`, to the version window, or to the engine's v0
# reply for a method it does not know fails these before any test drives the stub.

def _frame(conn: socket.socket, request: dict) -> dict:
    body = json.dumps(request).encode()
    conn.sendall(len(body).to_bytes(4, "big") + body)
    size = int.from_bytes(keeper_mod._read(conn, 4), "big")
    return json.loads(keeper_mod._read(conn, size))


def _ask_socket(home: Path, request: dict) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(10)
        conn.connect(str(home / "daemon.sock"))
        return _frame(conn, request)


def test_the_keeper_asks_the_engines_hello_as_the_engine_publishes_it():
    frame = keeper_mod.hello_frame()
    golden = _golden("requests.jsonl", "hello")["frame"]
    assert set(frame) == set(golden) and frame["method"] == golden["method"] == "hello"
    assert frame["params"] == golden["params"] == {}
    protocol = ENGINE["hello"]["result"]["protocol"]
    minimums = ENGINE["hello"]["result"]["capabilities"]["minimum_versions"]
    assert protocol["minimum_version"] <= frame["protocol_version"] <= protocol["maximum_version"]
    assert minimums["hello"] <= frame["protocol_version"]
    pattern = json.loads((MANAGEMENT / "protocol.schema.json").read_text())["$defs"]["requestId"]
    assert re.fullmatch(pattern["pattern"], frame["request_id"])


def test_the_keeper_reads_the_pid_from_the_engines_own_hello_reply():
    request_id = keeper_mod.hello_frame()["request_id"]
    reply = {**ENGINE["hello"], "request_id": request_id}
    published = ENGINE["hello"]["result"]["engine"]["pid"]
    assert isinstance(published, str)                       # System.pid(), a string
    assert keeper_mod.hello_pid(reply, request_id) == int(published)
    # What the engine answers when hello cannot say who it is, and what it answers the
    # deleted unversioned `status` the keeper used to ask: neither names a process.
    unavailable = {**_golden("errors.jsonl", "unavailable")["response"], "request_id": request_id}
    v0_unknown = {"status": "error", "reason": "unknown method", "method": "status"}
    for refused, why in ((unavailable, "unavailable"), (v0_unknown, "not a reply to"),
                         ({**reply, "request_id": "another"}, "not a reply to"),
                         ({**reply, "result": {**reply["result"], "engine": {}}}, "engine.pid")):
        with pytest.raises(ValueError, match=why):
            keeper_mod.hello_pid(refused, request_id)


def test_the_stub_daemon_answers_the_control_socket_as_the_engine_does(scratch, fake_mix):
    # Its v0 reply for a method the engine does not know is the engine's own clause.
    assert 'defp handle_method(method, _request, _state) do\n    %{status: "error", ' \
           'reason: "unknown method", method: method}' in DAEMON_EX.read_text()
    assert {"health", "capabilities", "agent_message", "shutdown"} <= set(ENGINE["v0_methods"])
    assert "status" not in ENGINE["v0_methods"]               # deleted (PROTOCOL.md, v0)
    home = _seeded_home(scratch)
    daemon = subprocess.Popen(["mix", "fermix.dev"], env={**os.environ,
                              "FERMIX_HOME": str(home), "FAKE_DAEMON_WRITES": "0"},
                              stdout=subprocess.DEVNULL)
    try:
        assert _wait_for(lambda: (home / "daemon.sock").exists())
        hello = keeper_mod.hello_frame()
        reply = _ask_socket(home, hello)
        golden = json.loads(json.dumps(ENGINE["hello"]))
        golden["request_id"], golden["result"]["engine"]["pid"] = hello["request_id"], \
            str(daemon.pid)
        assert reply == golden
        assert keeper_mod.control_pid(str(home)) == daemon.pid
        assert _ask_socket(home, {"method": "status"}) == {
            "status": "error", "reason": "unknown method", "method": "status"}
        missing = _ask_socket(home, {**hello, "method": "eval.nothing"})
        golden = json.loads(json.dumps(ENGINE["not_found"]))
        golden["request_id"], golden["error"]["details"] = hello["request_id"], \
            {"method": "eval.nothing"}
        assert missing == golden
        # A method of the engine's it does not model is never given an invented answer.
        with pytest.raises((OSError, ValueError)):
            _ask_socket(home, {**hello, "method": "overview.get"})
        assert daemon.wait(10) != 0
    finally:
        if daemon.poll() is None:
            daemon.kill()
            daemon.wait()


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


@pytest.mark.parametrize("flag, keeps_key", [("--phone-calls", False), ("", True)])
def test_a_phone_calls_home_starts_its_daemon_without_the_callers_openai_key(
        scratch, fake_mix, stray_daemons, flag, keeps_key):
    # M94: the phone engine reuses the openai provider's key, which the seed made
    # an invented one; a real key in the caller's environment would overlay it at
    # boot. Every other home keeps the caller's environment as it was.
    home = scratch / "cap-eval"
    up = _script("up", home, FERMIX_CAP_SEED_ARGS=f"--provider ollama --model brindle-7b {flag}",
                 OPENAI_API_KEY="sk-from-the-callers-shell-invented")
    try:
        assert up.returncode == 0, up.stderr
        [start] = _starts(home)
        assert start["openai_key_set"] is keeps_key
        port = json.loads((home / seed.FIXTURE_MANIFEST).read_text())["port"]
        assert start["fixture_origin"] == f"http://127.0.0.1:{port}"
    finally:
        _down(home, stray_daemons)


def test_every_reset_of_a_phone_calls_home_boots_its_daemon_with_the_simulators_origin(
        scratch, fake_mix, stray_daemons):
    # M94: a development build fixes where its calls go once, at boot, from the
    # variable and the home's manifest, so every start must find both in place. The
    # restore leaves eval-fixtures/ alone, and each reset's start (what --reset-home
    # runs before every attempt) gets the origin the seed recorded, never the
    # caller's, and never the caller's OpenAI key.
    home = scratch / "cap-eval"
    callers = {"OPENAI_API_KEY": "sk-from-the-callers-shell-invented",
               "FERMIX_EVAL_FIXTURE_ORIGIN": "http://127.0.0.1:1"}
    up = _script("up", home,
                 FERMIX_CAP_SEED_ARGS="--provider ollama --model brindle-7b --phone-calls",
                 **callers)
    try:
        assert up.returncode == 0, up.stderr
        for _attempt in range(2):
            reset = _script("reset", home, **callers)
            assert reset.returncode == 0, reset.stderr
        port = json.loads((home / seed.FIXTURE_MANIFEST).read_text())["port"]
        starts = _starts(home)
        assert len(starts) == 3
        assert {start["fixture_origin"] for start in starts} == {f"http://127.0.0.1:{port}"}
        assert not any(start["openai_key_set"] for start in starts)
        assert (home / seed.PHONE_CALLS_MANIFEST).is_file()
    finally:
        _down(home, stray_daemons)


# --- one started home, shared by the specs that need nothing of their own ------------

class _SharedHome:
    """One home `up` started for the module (a seed, a snapshot and a boot each time,
    so the specs that only need a working home share it). `up` runs with no locale (the
    keeper's interpreter then coerces its own), a fixture origin and a probe in its
    caller's environment, so every spec on it also checks what reaches the daemon. Each
    spec starts from a home whose keeper answers `check` for the runners' project; one
    that leaves it otherwise (following a refusal's advice to `down` and `up`, say) is
    repaired before the next."""

    def __init__(self, root: Path):
        self.root = root
        self.stubs = _install_stub(root / "stubbin")
        self.home = root / "cap-eval"
        self.caller: dict[str, str] = {}

    def up(self, **extra) -> subprocess.CompletedProcess:
        given = {"PATH": f"{self.stubs}{os.pathsep}{os.environ['PATH']}",
                 "FAKE_DAEMON_WRITES": "0", "EVAL_PROBE_ENV": "from-up",
                 "FERMIX_EVAL_FIXTURE_ORIGIN": "http://127.0.0.1:1", **EXPORTING, **extra}
        self.caller = _script_env(self.home, LOCALE, FERMIX_CAP_SEED_ARGS=EXPLICIT, **given)
        return _up(self.home, drop=LOCALE, **given)

    def pids(self) -> list[int]:
        keeper = self.home / "keeper.pid"
        return [start["pid"] for start in _starts(self.home)] + (
            [int(keeper.read_text())] if keeper.exists() else [])

    def healthy(self) -> None:
        if _check(self.home, FERMIX_CAP_PROJECT=PROJECT).returncode == 0:
            return
        _script("down", self.home)
        up = self.up()
        assert up.returncode == 0, up.stderr


@pytest.fixture(scope="module")
def shared_world():
    world = _SharedHome(Path(tempfile.mkdtemp(prefix="fxs")))
    try:
        up = world.up()
        assert up.returncode == 0, up.stderr
        yield world
    finally:
        started = world.pids()
        _script("down", world.home)
        for pid in started:
            if _alive(pid):
                os.kill(pid, 9)
        safe_rm.rm_rf(str(world.root), tempfile.gettempdir())


@pytest.fixture
def shared(shared_world):
    shared_world.healthy()
    return shared_world


def _keeper_pid(home: Path) -> int:
    return int((home / "keeper.pid").read_text())


def _log(home: Path) -> str:
    return (home / "daemon.log").read_text()


def _files(home: Path) -> set[str]:
    return {name for name in ("keeper.pid", "daemon.pid", keeper_mod.SOCKET_NAME, "daemon.sock")
            if (home / name).exists()}


def test_reset_restores_the_snapshot_and_restarts_the_daemon(shared):
    home = shared.home
    old = _starts(home)[-1]
    (home / "memory.db").write_text("what the trial's turn left behind")
    reset = _script("reset", home)
    assert reset.returncode == 0, reset.stderr
    new = _starts(home)[-1]
    # The snapshot `up` took held no memory.db, and the restarted daemon found none:
    # never what the trial before it wrote.
    assert new["pid"] != old["pid"] and new["memory_db"] is None
    assert not _alive(old["pid"]) and _alive(new["pid"])
    assert (home / "daemon.pid").read_text().strip() == str(new["pid"])


# Variables every shell between the script and the daemon keeps for itself (the real
# `mix` is a shell script too): its working directory, its depth and its last command.
_SHELL_KEPT = {"PWD", "OLDPWD", "SHLVL", "_"}


def test_a_daemon_has_exactly_the_environment_the_script_built_at_every_start(shared):
    # The whole environment. `up` ran with no locale, so the keeper's own interpreter
    # coerced one into ITS environment (LC_CTYPE=C.UTF-8), with a fixture origin the
    # manifest overrides and a probe; this reset runs from a caller with another probe
    # and a judge's key. On the eval box the boot step holds the provider key and the
    # Opik settings, which the later steps do not.
    home = shared.home
    reset = _script("reset", home, EVAL_PROBE_ENV="from-the-caller",
                    ANTHROPIC_API_KEY="sk-ant-invented-judge-key")
    assert reset.returncode == 0, reset.stderr
    port = json.loads((home / seed.FIXTURE_MANIFEST).read_text())["port"]
    built = {**shared.caller, "FERMIX_HOME": str(home), "FERMIX_OPIK_ENABLED": "1",
             "FERMIX_OPIK_PROJECT": PROJECT, "FERMIX_BROWSER_HEADLESS": "1",
             "FERMIX_EVAL_FIXTURE_ORIGIN": f"http://127.0.0.1:{port}"}
    for start in _starts(home)[-2:]:
        env = _daemon_env(home, start["pid"])
        assert {k: v for k, v in env.items() if k not in _SHELL_KEPT} == \
            {k: _digest(v) for k, v in built.items() if k not in _SHELL_KEPT}
        assert "LC_CTYPE" not in env and env["EVAL_PROBE_ENV"] == _digest("from-up")
        assert "ANTHROPIC_API_KEY" not in env and "EVAL_KEEPER_ENV_END" not in env


def test_the_runner_resets_through_the_daemon_script(shared):
    home = shared.home
    (home / "memory.db").write_text("a watcher the last case created")
    assert rc.home_resetter(_cfg(home))() is None
    assert _starts(home)[-1]["memory_db"] is None


def test_a_reset_appends_to_the_daemon_log_and_a_fresh_up_starts_a_new_one(shared):
    # A reset between two passes used to start the log again, so the first pass's daemon
    # log was gone when anyone read it; a log no `up` ever restarted grows without bound.
    home = shared.home
    assert _script("reset", home).returncode == 0
    old, new = _starts(home)[-2:]
    assert f"fake daemon {old['pid']} booted" in _log(home)
    assert f"fake daemon {new['pid']} booted" in _log(home)
    assert "capability-daemon reset: starting the daemon" in _log(home)
    assert _script("down", home).returncode == 0
    assert shared.up().returncode == 0
    log = _log(home)
    assert f"fake daemon {new['pid']} booted" not in log
    assert log.count("capability-daemon up: starting the daemon") == 1
    assert "capability-daemon reset" not in log


# --- the keeper survives anything one client does; only a signal ends it --------------

def _client(home: Path) -> socket.socket:
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.connect(str(home / keeper_mod.SOCKET_NAME))
    return conn


def test_a_client_that_goes_away_before_its_reply_leaves_the_keeper_serving(shared):
    # Ctrl-C of a runner during a reset, `ask` giving up at its bound, a second keeper
    # probing the socket: the reply's write failed and the keeper, then its daemon, died.
    home = shared.home
    keeper = _keeper_pid(home)
    before = _log(home).count("a client went away")
    _client(home).close()                                   # connects, says nothing, goes
    assert _wait_for(lambda: _log(home).count("a client went away") >= before + 1)
    starts = len(_starts(home))
    conn = _client(home)                                    # asks a reset, goes at once
    conn.sendall(json.dumps({"op": "reset", "project": None}).encode() + b"\n")
    conn.close()
    assert _wait_for(lambda: _log(home).count("a client went away") >= before + 2, 30)
    assert len(_starts(home)) == starts + 1
    assert _alive(keeper) and _alive(_starts(home)[-1]["pid"])
    check = _check(home)
    assert check.returncode == 0, check.stderr


class _Answers:
    """A keeper that answers every request at once: the loop is what is under test."""

    def answer(self, request):
        return {"ok": True, "op": request.get("op")}

    def watch(self):
        pass


def test_a_client_that_says_nothing_holds_no_other_longer_than_its_request_bound(
        scratch, monkeypatch, capsys):
    # The keeper's own loop, with a short request bound: a client that connects and
    # says nothing used to hold every other client for as long as it stayed.
    import threading
    monkeypatch.setattr(keeper_mod, "REQUEST_TIMEOUT_S", 0.3)
    home = scratch / "x-eval"
    home.mkdir()
    listener = keeper_mod._listen(str(home))
    ended = []

    def loop():
        try:
            keeper_mod._loop(_Answers(), listener)
        except OSError as exc:                      # the listener closed: the test's end
            ended.append(exc)

    # Both clients are queued, the asking one's line already sent, before the loop
    # accepts the first: only the silent client's bound decides when the second is
    # read, and it always runs out, since that client never says anything.
    silent = _client(home)
    asking = _client(home)
    asking.sendall(b'{"op": "check"}\n')
    server = threading.Thread(target=loop)
    server.start()
    try:
        # Answered while the silent client still holds its connection open: without the
        # bound this read waits on it, and fails at its own 10 s.
        asking.settimeout(10)
        reply = json.loads(asking.makefile("rb").readline())
    finally:
        asking.close()
        silent.close()
        listener.close()
        server.join(10)
    assert reply == {"ok": True, "op": "check"}
    assert "said nothing in 0.3s" in capsys.readouterr().out
    assert ended and not server.is_alive()


@pytest.mark.parametrize("signum", [signal.SIGHUP, signal.SIGINT])
def test_a_hangup_or_an_interrupt_ends_the_keeper_as_down_does(shared, signum):
    # Not only SIGTERM: a keeper a hangup killed left its daemon running without one.
    home = shared.home
    keeper, daemon = _keeper_pid(home), _starts(home)[-1]["pid"]
    os.kill(keeper, signum)
    assert _wait_for(lambda: not _alive(keeper) and not _alive(daemon), 30)
    assert _files(home) == set()


class _FakeDaemon:
    pid = 424242
    returncode = None

    def poll(self):
        return None


def test_a_termination_signal_while_the_daemon_is_spawned_waits_for_its_pidfile(
        tmp_path, monkeypatch):
    # The window between spawning the daemon and recording it: a signal there left a
    # daemon no pidfile and no keeper named. Now it is held until both are done.
    home = tmp_path / "x-eval"
    home.mkdir()
    kept = keeper_mod.Keeper(str(home), str(tmp_path), ["mix"], 1.0, {"PATH": "/usr/bin"})

    def popen(*_args, **_kwargs):
        keeper_mod.SIGNALS(signal.SIGTERM, None)            # lands mid-spawn
        return _FakeDaemon()

    monkeypatch.setattr(keeper_mod.subprocess, "Popen", popen)
    with pytest.raises(SystemExit):
        kept.start("up")
    assert (home / "daemon.pid").read_text().strip() == str(_FakeDaemon.pid)
    assert kept.child.pid == _FakeDaemon.pid               # what `serve`'s finally stops
    assert not keeper_mod.SIGNALS.holding and not keeper_mod.SIGNALS.held


def _serve(home: Path, ready: float, given: bytes, cwd: Path) -> subprocess.CompletedProcess:
    """The keeper as `up` runs it, handed `given` on stdin."""
    return subprocess.run([os.path.join(HERE, "eval_daemon_keeper.py"), "serve", str(home),
                           "--cwd", str(cwd), "--ready-timeout", f"{ready:g}", "--", "mix",
                           "fermix.dev"], input=given, capture_output=True,
                          timeout=SCRIPT_TIMEOUT_S)


def _hand_over(env: dict[str, str]) -> bytes:
    return b"".join(f"{k}={v}".encode() + b"\0" for k, v in env.items()) + \
        keeper_mod.ENV_END.encode() + b"\0"


def test_a_boot_bound_the_client_could_not_outwait_is_refused(scratch, fake_mix):
    home = _seeded_home(scratch)
    state.snapshot(str(home))
    whole = _hand_over({"FERMIX_HOME": str(home), "PATH": os.environ["PATH"]})
    over = _serve(home, keeper_mod.MAX_READY_S + 1, whole, scratch)
    assert over.returncode == 2 and b"--ready-timeout" in over.stderr
    assert _starts(home) == [] and not (home / "keeper.pid").exists()


def test_the_runners_wait_for_the_script_past_the_keepers_own_bound(monkeypatch, tmp_path):
    # What each runner passes as its bound, at the call: past what the keeper's client
    # waits, so the client's own timeout and refusal are what a runner reads.
    bounds = []

    def run(argv, **kwargs):
        bounds.append(kwargs["timeout"])
        return subprocess.CompletedProcess(argv, 3, "", "refused, as the keeper would")

    monkeypatch.setattr(rc.subprocess, "run", run)
    assert "refused" in rc.reset_precondition_error(_cfg(tmp_path / "x-eval"))
    assert "refused" in rc.home_resetter(_cfg(tmp_path / "x-eval"))()
    assert len(bounds) == 2 and min(bounds) > keeper_mod.ANSWER_TIMEOUT_S


@pytest.mark.parametrize("given, why", [
    (b"", f"does not end in {keeper_mod.ENV_END}"),
    # cut inside a value: the key's tail, and everything after it, never arrived
    (b"PATH=/usr/bin\0ANTHROPIC_API_KEY=sk-ant-inv", "it was cut short"),
    # cut before FERMIX_HOME, at an entry's end
    (b"PATH=/usr/bin\0", "it was cut short"),
    # a newline-separated block (`env`, not `env -0`)
    (b"PATH=/usr/bin\nFERMIX_HOME=x\n", "not the `env -0` output"),
    (b"PATH=/usr/bin\0\0" + keeper_mod.ENV_END.encode() + b"\0", "not an environment entry"),
    (b"NOEQUALS\0" + keeper_mod.ENV_END.encode() + b"\0", "not an environment entry"),
])
def test_a_hand_over_cut_short_or_malformed_is_refused(given, why):
    import io
    with pytest.raises(ValueError, match=re.escape(why)):
        keeper_mod.read_environment(io.BytesIO(given), "/h/x-eval")


def test_a_hand_over_names_the_home_it_is_for():
    import io
    whole = {"PATH": "/usr/bin", "B": "x=y \u00e9", "EMPTY": ""}
    got = keeper_mod.read_environment(
        io.BytesIO(_hand_over({**whole, "FERMIX_HOME": "/h/x-eval"})), "/h/x-eval")
    assert got == {**whole, "FERMIX_HOME": "/h/x-eval"}
    for home in (None, "/h/other-eval"):
        given = _hand_over({**whole, **({"FERMIX_HOME": home} if home else {})})
        with pytest.raises(ValueError, match="FERMIX_HOME"):
            keeper_mod.read_environment(io.BytesIO(given), "/h/x-eval")
    twice = _hand_over(whole) + _hand_over({"FERMIX_HOME": "/h/x-eval"})
    with pytest.raises(ValueError, match="cut short"):
        keeper_mod.read_environment(io.BytesIO(twice), "/h/x-eval")


def test_a_keeper_handed_an_environment_cut_inside_a_value_starts_nothing(
        scratch, fake_mix):
    # Fed by hand, the keeper started the daemon with FERMIX_HOME cut off and a key cut
    # mid-value. Now the cut is a refusal before anything starts.
    home = _seeded_home(scratch)
    state.snapshot(str(home))
    whole = _hand_over({"PATH": os.environ["PATH"], "FERMIX_HOME": str(home),
                        "ANTHROPIC_API_KEY": "sk-ant-invented-0123456789"})
    cut = whole[:whole.index(b"sk-ant-invented") + 9]
    served = _serve(home, 30, cut, scratch)
    assert served.returncode == 2 and b"cut short" in served.stderr
    assert b"nothing was started" in served.stderr and b"sk-ant" not in served.stderr
    assert _starts(home) == [] and _files(home) == set()


# --- a boot the keeper started is waited for until its bound -------------------------

def test_a_daemon_not_ready_at_its_first_answers_is_waited_for_by_reset_and_up(shared):
    # A daemon that listens at once and first answers `unavailable` (the engine's own
    # reply while its identity is not ready) failed the reset at its first probe, saying
    # "nothing was stopped or replaced" when the old daemon was stopped, the snapshot
    # restored and the new one left running. Only the boot bound ends the wait.
    home = shared.home
    (home / "unready-answers").write_text("3")
    try:
        reset = _script("reset", home)
        assert reset.returncode == 0, reset.stderr
        assert _check(home).returncode == 0
        assert _script("down", home).returncode == 0
        up = shared.up()
        assert up.returncode == 0, up.stderr
    finally:
        (home / "unready-answers").unlink()
    assert _check(home).returncode == 0


def test_a_daemon_that_never_answers_as_itself_is_stopped_at_the_bound_and_said(
        scratch, fake_mix, monkeypatch):
    # The keeper's own reset, in process, against the stub: the new daemon answers only
    # `unavailable`. The boot bound's expiry is delivered by hand once it has, three
    # times; the restore before it is the real one.
    home = _seeded_home(scratch)
    state.snapshot(str(home))
    env = {"PATH": os.environ["PATH"], "FERMIX_HOME": str(home), "FAKE_DAEMON_WRITES": "0"}
    kept = keeper_mod.Keeper(str(home), str(scratch), ["mix", "fermix.dev"], 30.0, env)
    try:
        kept.start("up")
        was = kept.child.pid
        (home / "unready-answers").write_text("1000000")
        probes = []
        real_probe = keeper_mod.probe_control

        def counted(served):
            probes.append(real_probe(served))
            return probes[-1]

        class _Clock:
            @staticmethod
            def monotonic():
                return 1e12 if sum(1 for _pid, why in probes if why) >= 3 else 0.0

            sleep = staticmethod(time.sleep)

        monkeypatch.setattr(keeper_mod, "probe_control", counted)
        monkeypatch.setattr(keeper_mod, "time", _Clock)
        with pytest.raises(keeper_mod.Refused) as refused:
            kept.reset()
        new = _starts(home)[-1]["pid"]
        said = (f"a reset stopped the daemon (pid {was}) and restored the snapshot; the "
                f"daemon it started (pid {new}) did not answer `hello` as itself within 30s "
                "(last: hello answered unavailable")
        assert said in str(refused.value) and "and was stopped" in str(refused.value)
        assert "then run `capability-daemon.sh down` and `up`" in str(refused.value)
        assert new != was and not _alive(new) and not _alive(was)
        assert said in kept.problem(None, answers=True)          # what `check` says next
    finally:
        kept.stop()


def test_a_hung_daemon_of_the_keepers_own_is_said_and_down_stops_it(shared):
    # SIGSTOP: alive, holding its socket, answering nothing. The lsof advice led to a
    # kill and then "exited by itself with code -9".
    home = shared.home
    hung = _starts(home)[-1]["pid"]
    os.kill(hung, signal.SIGSTOP)
    try:
        check = _check(home)
    finally:
        pass                          # left stopped: `down` is the advice under test
    assert check.returncode == 3
    assert f"(pid {hung}) is running and does not answer `hello`" in check.stderr
    assert "Run `capability-daemon.sh down`, which stops it, then `up`" in check.stderr
    assert "lsof" not in check.stderr
    assert _script("down", home).returncode == 0 and not _alive(hung)
    assert shared.up().returncode == 0 and _check(home).returncode == 0


# --- one request cannot end the keeper -----------------------------------------------

def _raw_request(home: Path, line: bytes) -> bytes:
    """`line` sent while its answer is read: the keeper answers a line too long after its
    first MAX_REQUEST_BYTES and closes, so the rest of it may have nowhere to go."""
    import threading

    def send():
        try:
            conn.sendall(line)
        except OSError:
            pass                      # the keeper refused it unread and closed: expected

    with _client(home) as conn:
        conn.settimeout(10)
        sender = threading.Thread(target=send)
        sender.start()
        answer = conn.makefile("rb").readline()
        sender.join(10)
        return answer


def test_a_request_too_long_or_too_deep_is_refused_and_the_keeper_serves_on(shared):
    # 200,000 `[` raised RecursionError out of the request's parse and ended the keeper
    # and its daemon.
    home = shared.home
    keeper, daemon = _keeper_pid(home), _starts(home)[-1]["pid"]
    long = json.loads(_raw_request(home, b"[" * 200_000 + b"\n"))
    assert long["ok"] is False and "longer than" in long["error"]
    deep = json.loads(_raw_request(home, b"[" * 3000 + b"\n"))
    assert deep["ok"] is False and "not a JSON request" in deep["error"]
    assert _alive(keeper) and _alive(daemon)
    assert "a client sent a request longer than" in _log(home)
    assert _check(home).returncode == 0


# --- the restore's bound and a termination stop everything it started -----------------

HANGING_RESTORE = r'''#!/usr/bin/env python3
import os, subprocess, sys, time
# As `uv run --script` does: the work runs in a child of the process the keeper started.
home = sys.argv[2]
child = subprocess.Popen([sys.executable, "-c",
    "import os, sys, time\n"
    "open(sys.argv[1] + '/restore-child.pid', 'w').write(str(os.getpid()))\n"
    "while True:\n"
    "    open(sys.argv[1] + '/restore-writes', 'a').write('x')\n"
    "    time.sleep(0.05)\n", home])
child.wait()
'''


def _hanging_restore(scratch: Path, monkeypatch) -> tuple[Path, keeper_mod.Keeper]:
    home = scratch / "x-eval"
    home.mkdir()
    script = scratch / "hang_restore.py"
    script.write_text(HANGING_RESTORE)
    script.chmod(0o755)
    monkeypatch.setattr(keeper_mod, "EVAL_HOME_STATE", str(script))
    kept = keeper_mod.Keeper(str(home), str(scratch), ["mix"], 1.0,
                             {"PATH": os.environ["PATH"], "FERMIX_HOME": str(home)})
    return home, kept


def _still_writing(home: Path) -> bool:
    before = (home / "restore-writes").stat().st_size
    time.sleep(0.5)
    return (home / "restore-writes").stat().st_size != before


def test_a_restore_past_its_bound_is_stopped_with_every_process_it_started(
        scratch, monkeypatch):
    # Run through `uv run --script`, the bound killed uv alone: the script's python went
    # on writing into the home under the `down` and `up` the refusal prescribed. The
    # bound's expiry is delivered by hand, once the restore's child is running.
    home, kept = _hanging_restore(scratch, monkeypatch)
    started = home / "restore-child.pid"

    class _Clock:
        @staticmethod
        def monotonic():
            return 1e12 if started.exists() and (home / "restore-writes").exists() else 0.0

        sleep = staticmethod(time.sleep)

    monkeypatch.setattr(keeper_mod, "time", _Clock)
    with pytest.raises(keeper_mod.Refused, match="did not finish within"):
        kept.reset()
    child = int(started.read_text())
    assert _wait_for(lambda: not _alive(child)), "the restore's child outlived its bound"
    assert not _still_writing(home)


def test_a_termination_mid_restore_stops_every_process_it_started(scratch, monkeypatch):
    import threading
    home, kept = _hanging_restore(scratch, monkeypatch)
    started = home / "restore-child.pid"
    previous = signal.signal(signal.SIGTERM, keeper_mod.SIGNALS)

    def terminate_once_running():
        if _wait_for(lambda: started.exists() and (home / "restore-writes").exists()):
            os.kill(os.getpid(), signal.SIGTERM)

    trigger = threading.Thread(target=terminate_once_running)
    trigger.start()
    try:
        with pytest.raises(SystemExit):
            kept.reset()
    finally:
        trigger.join(10)
        signal.signal(signal.SIGTERM, previous)
    child = int(started.read_text())
    assert _wait_for(lambda: not _alive(child)), "the restore's child outlived the keeper"
    assert not _still_writing(home)


# --- a daemon dead under its keeper is said wherever it is found ----------------------

def test_a_daemon_that_dies_under_its_keeper_is_said_wherever_it_is_found(shared, capsys):
    home = shared.home
    dead = _starts(home)[-1]["pid"]
    os.kill(dead, signal.SIGKILL)
    # The keeper notices when it happens, not when next asked.
    assert _wait_for(lambda: f"(pid {dead}) exited by itself with code -9" in _log(home))
    up = shared.up()
    assert up.returncode == 3 and "exited by itself with code -9" in up.stderr
    assert "daemon already up" not in up.stderr
    check = _check(home)
    assert check.returncode == 3 and "exited by itself with code -9" in check.stderr
    # A reset starts it again, and says the daemon had died, with its code: in its
    # reply, which the runner prints, and in the log.
    assert rc.home_resetter(_cfg(home))() is None
    assert f"(pid {dead}) had exited by itself with code -9" in capsys.readouterr().err
    assert f"(pid {dead}) had exited by itself with code -9" in _log(home)
    # The check's own advice, followed, ends in a working home too.
    os.kill(_starts(home)[-1]["pid"], signal.SIGKILL)
    assert _wait_for(lambda: _check(home).returncode == 3)
    assert _script("down", home).returncode == 0 and shared.up().returncode == 0
    assert _check(home).returncode == 0


# --- every refusal, and its advice followed to a working home ------------------------

def test_a_reset_on_a_home_whose_daemon_was_started_by_hand_is_refused_and_replaces_nothing(
        scratch, fake_mix, stray_daemons):
    # README §4's old manual loop: an earlier `up` left its snapshot, the model was
    # hand-edited into config.toml and the daemon started by hand. The reset used to
    # remove that daemon's socket (blinding the only guard), put the old config.toml
    # back under it and start a second daemon on the home.
    home = _seeded_home(scratch)
    state.snapshot(str(home))
    (home / "config.toml").write_text("# hand-edited: primary = model B\n")
    (home / "memory.db").write_text("the hand-started daemon's rows")
    daemon = _by_hand(home, fake_mix, stray_daemons)
    reset = _script("reset", home)
    assert reset.returncode == 3
    assert "started outside capability-daemon.sh" in reset.stderr
    assert f"kill {daemon.pid}" in reset.stderr
    assert daemon.poll() is None and (home / "daemon.sock").exists()
    assert (home / "config.toml").read_text() == "# hand-edited: primary = model B\n"
    assert (home / "memory.db").read_text() == "the hand-started daemon's rows"
    assert len(_starts(home)) == 1
    # `up` refuses the same way, before the seeder could, naming the same remedy.
    up = _up(home)
    assert up.returncode == 3 and f"kill {daemon.pid}" in up.stderr
    assert "stop it before seeding" not in up.stderr
    # The advice, followed: stop it by its pid, then `up`.
    daemon.terminate()
    daemon.wait()
    try:
        assert _up(home).returncode == 0
        assert _check(home).returncode == 0
    finally:
        _down(home, stray_daemons)


def test_the_scripts_own_daemon_without_its_keeper_is_stopped_by_down(shared):
    # The keeper was killed (or `up` predates it): its daemon still answers. The advice
    # used to say `up`, which the seeder refused, and called the daemon a foreign one.
    home = shared.home
    keeper, daemon = _keeper_pid(home), _starts(home)[-1]["pid"]
    os.kill(keeper, signal.SIGKILL)
    assert _wait_for(lambda: not _alive(keeper))
    check = _check(home)
    assert check.returncode == 3
    assert f"(pid {daemon}) runs without its keeper" in check.stderr
    assert f"`capability-daemon.sh down`, which stops pid {daemon}" in check.stderr
    up = shared.up()
    assert up.returncode == 3 and f"stops pid {daemon}" in up.stderr
    assert _script("down", home).returncode == 0 and not _alive(daemon)
    assert shared.up().returncode == 0 and _check(home).returncode == 0


def test_a_reset_while_a_daemon_the_keeper_did_not_start_answers_is_refused(
        shared, fake_mix, stray_daemons):
    # The daemon the pidfile and the keeper name is not the one answering the home.
    home = shared.home
    kept = _starts(home)[-1]["pid"]
    (home / "daemon.sock").unlink()            # its socket gone, a second daemon binds one
    intruder = _by_hand(home, fake_mix, stray_daemons)
    (home / "memory.db").write_text("rows the intruder holds open")
    reset = _script("reset", home)
    assert reset.returncode == 3
    assert f"a daemon this script did not start answers for {os.path.realpath(home)}" \
        in reset.stderr
    assert f"kill {intruder.pid}" in reset.stderr
    assert (home / "memory.db").read_text() == "rows the intruder holds open"
    assert _alive(kept) and intruder.poll() is None
    # The advice, followed: stop it by its pid, then `down` and `up`.
    intruder.terminate()
    intruder.wait()
    assert _script("down", home).returncode == 0
    assert shared.up().returncode == 0 and _check(home).returncode == 0


def test_a_reset_on_a_snapshot_taken_again_since_up_is_refused(shared):
    # A snapshot that is not the one this daemon's `up` took would put back a world the
    # daemon never started from, its config.toml (its model) included.
    home = shared.home
    daemon = _starts(home)[-1]["pid"]
    (home / state.SNAPSHOT_DIR / state.SNAPSHOT_ID).write_text("0123456789abcdef\n")
    (home / "config.toml").write_text("# the config the running daemon booted with\n")
    for verb in ("check", "reset"):
        refused = _script(verb, home)
        assert refused.returncode == 3
        assert "is not the one this daemon's `up` took" in refused.stderr
        assert "`capability-daemon.sh down`, then `up`" in refused.stderr
    assert (home / "config.toml").read_text() == "# the config the running daemon booted with\n"
    assert _alive(daemon)
    assert _script("down", home).returncode == 0
    assert shared.up().returncode == 0 and _check(home).returncode == 0


def test_a_check_for_another_opik_project_names_a_way_to_it(shared):
    # Its advice used to be an `up` that a running keeper makes a no-op.
    home = shared.home
    other = "fermix-other-eval"
    refused = _check(home, FERMIX_CAP_PROJECT=other)
    assert refused.returncode == 3 and f"this run reads {other}" in refused.stderr
    assert f"`capability-daemon.sh down`, then `FERMIX_CAP_OPIK=1 FERMIX_CAP_PROJECT={other} " \
           "capability-daemon.sh up`" in refused.stderr
    # `up` for that project says the same, never "already up".
    up = shared.up(FERMIX_CAP_PROJECT=other)
    assert up.returncode == 3 and f"FERMIX_CAP_PROJECT={other} capability-daemon.sh up" \
        in up.stderr and "daemon already up" not in up.stderr
    assert _script("down", home).returncode == 0
    assert shared.up(FERMIX_CAP_PROJECT=other).returncode == 0
    assert _check(home, FERMIX_CAP_PROJECT=other).returncode == 0


def test_the_project_advice_on_a_home_up_started_without_opik_ends_in_one(shared):
    # Followed from the same shell (FERMIX_CAP_OPIK=0 still set), its advice used to start
    # Opik off again, and the next check refused the same way.
    home = shared.home
    assert _script("down", home).returncode == 0
    assert shared.up(FERMIX_CAP_OPIK="0").returncode == 0
    refused = _check(home, FERMIX_CAP_PROJECT=PROJECT)
    assert refused.returncode == 3 and "(none: Opik off)" in refused.stderr
    advised = f"FERMIX_CAP_OPIK=1 FERMIX_CAP_PROJECT={PROJECT} capability-daemon.sh up"
    assert advised in refused.stderr
    assert _script("down", home).returncode == 0
    assert shared.up(FERMIX_CAP_OPIK="1", FERMIX_CAP_PROJECT=PROJECT).returncode == 0
    assert _check(home, FERMIX_CAP_PROJECT=PROJECT).returncode == 0


def test_a_home_whose_snapshot_is_gone_names_down_and_up(shared):
    # "No seeded-state snapshot" while a keeper runs: `up` alone is a no-op there.
    home = shared.home
    safe_rm.rm_rf(str(home / state.SNAPSHOT_DIR), str(home))
    refused = _script("reset", home)
    assert refused.returncode == 3 and "no seeded-state snapshot" in refused.stderr
    assert "run `capability-daemon.sh down`, then `up`" in refused.stderr
    assert _script("down", home).returncode == 0
    assert shared.up().returncode == 0 and _check(home).returncode == 0


def test_a_restore_that_fails_says_what_it_did_and_names_down_and_up(shared):
    # The restore refuses a symlink among the snapshot's entries, root or not (a
    # chmod 0 stops no root, and scripts/vultr-box.sh runs these tests as root).
    home = shared.home
    was = _starts(home)[-1]["pid"]
    saved = home / state.SNAPSHOT_DIR / "config.toml"
    held = home / "config.held"
    saved.rename(held)
    saved.symlink_to(held)
    refused = _script("reset", home)
    assert refused.returncode == 3 and "could not be restored" in refused.stderr
    assert "refusing a symlink" in refused.stderr
    said = (f"a reset stopped the daemon (pid {was}); the snapshot could not be restored")
    assert said in refused.stderr and "so nothing was started" in refused.stderr
    assert "then run `capability-daemon.sh down` and `up`" in refused.stderr
    assert not _alive(was) and _starts(home)[-1]["pid"] == was      # nothing started
    # `check` says the same, never "(pid None) does not answer".
    check = _check(home)
    assert check.returncode == 3 and said in check.stderr and "None" not in check.stderr
    assert _script("down", home).returncode == 0
    assert shared.up().returncode == 0 and _check(home).returncode == 0


def test_a_daemon_that_fails_to_boot_after_a_reset_names_the_log_then_down_and_up(shared):
    home = shared.home
    (home / "fail-boot").write_text("")
    try:
        was = _starts(home)[-1]["pid"]
        refused = _script("reset", home)
        assert refused.returncode == 3
        said = (f"a reset stopped the daemon (pid {was}) and restored the snapshot; the "
                "daemon it started (pid ")
        assert said in refused.stderr and "exited during its boot with code 1" in refused.stderr
        assert "daemon.log, then run `capability-daemon.sh down` and `up`" in refused.stderr
        assert "failing at boot" in _log(home)
        check = _check(home)
        assert check.returncode == 3 and said in check.stderr
    finally:
        (home / "fail-boot").unlink()                       # what the log says to fix
    assert _script("down", home).returncode == 0
    assert shared.up().returncode == 0 and _check(home).returncode == 0


def test_a_reset_on_a_home_no_keeper_runs_for_starts_nothing(
        scratch, fake_mix, stray_daemons):
    home = _seeded_home(scratch)
    state.snapshot(str(home))
    reset = _script("reset", home)
    assert reset.returncode == 3
    assert "no daemon started by `capability-daemon.sh up`" in reset.stderr
    assert "Run `capability-daemon.sh up`" in reset.stderr
    assert (home / "memory.db").read_text() == "seeded rows" and _starts(home) == []
    # The advice, followed.
    try:
        assert _up(home).returncode == 0 and _check(home).returncode == 0
    finally:
        _down(home, stray_daemons)


def _answers_without_a_pid(home: Path):
    """A process on <home>/daemon.sock that answers `hello` as an engine that cannot
    say who it is does (the golden `unavailable`, for the engine identity)."""
    import threading
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(home / "daemon.sock"))
    server.listen(4)
    server.settimeout(0.2)
    stop = threading.Event()

    def serve():
        while not stop.is_set():
            try:
                conn, _ = server.accept()
            except TimeoutError:
                continue
            with conn:
                size = int.from_bytes(keeper_mod._read(conn, 4), "big")
                request = json.loads(keeper_mod._read(conn, size))
                refused = json.loads(json.dumps(_golden("errors.jsonl", "unavailable")))
                refused["response"]["request_id"] = request["request_id"]
                refused["response"]["error"]["details"] = {"capability": "engine_identity"}
                reply = json.dumps(refused["response"]).encode()
                conn.sendall(len(reply).to_bytes(4, "big") + reply)

    thread = threading.Thread(target=serve)
    thread.start()

    def close():
        stop.set()
        thread.join(5)
        server.close()
        (home / "daemon.sock").unlink()
    return close


def test_a_daemon_that_cannot_say_which_process_it_is_names_how_to_find_it(
        scratch, fake_mix, stray_daemons):
    home = _seeded_home(scratch)
    state.snapshot(str(home))
    close = _answers_without_a_pid(home)
    try:
        for verb in ("check", "up"):
            refused = _script(verb, home)
            assert refused.returncode == 3
            assert "does not say which process it is" in refused.stderr
            assert f"`lsof {os.path.realpath(home / 'daemon.sock')}`" in refused.stderr
        assert _starts(home) == []
    finally:
        close()                                             # found and stopped
    try:
        assert _up(home).returncode == 0 and _check(home).returncode == 0
    finally:
        _down(home, stray_daemons)


def test_an_up_beside_what_a_killed_keeper_left_starts_afresh(
        scratch, fake_mix, stray_daemons):
    # A keeper killed outright leaves its pidfile and its socket file; its pid can be
    # another process's by then. `up` used to take a live pid for a running keeper and
    # refuse, naming `up` as the way out.
    home = _seeded_home(scratch)
    other = subprocess.Popen(["sleep", "300"])
    stray_daemons.append(other.pid)
    (home / "keeper.pid").write_text(f"{other.pid}\n")
    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stale.bind(str(home / keeper_mod.SOCKET_NAME))
    stale.close()                                       # a socket file nothing listens on
    try:
        up = _up(home)
        assert up.returncode == 0, up.stderr
        assert _check(home).returncode == 0
        assert other.poll() is None, "up signalled a process it did not start"
    finally:
        _down(home, stray_daemons)
        other.kill()
        other.wait()


def test_an_up_whose_daemon_fails_to_boot_names_the_log_and_works_once_fixed(shared):
    home = shared.home
    assert _script("down", home).returncode == 0
    (home / "fail-boot").write_text("")
    try:
        up = shared.up()
        assert up.returncode != 0
        assert "daemon did not come up" in up.stderr and "failing at boot" in up.stderr
        assert "exited during its boot" in up.stderr
        assert "stopped before its daemon answered" in up.stderr
        assert "no daemon started by" not in up.stderr
        # The keeper unlinks its files before it lets go of its socket, so the client
        # returning means they are gone.
        assert _files(home) == set(), "a failed up left a keeper or its files behind"
    finally:
        (home / "fail-boot").unlink()                       # what the log says to fix
    assert _script("down", home).returncode == 0
    assert shared.up().returncode == 0 and _check(home).returncode == 0


def test_a_keeper_slower_than_the_client_bound_names_check(scratch, monkeypatch, capsys):
    home = scratch / "x-eval"
    home.mkdir()
    monkeypatch.setattr(keeper_mod, "ANSWER_TIMEOUT_S", 0.3)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(home / keeper_mod.SOCKET_NAME))
    listener.listen(1)                                      # accepts, never answers
    try:
        assert keeper_mod.ask("check", str(home), None, None) == 3
    finally:
        listener.close()
    said = capsys.readouterr().err
    assert "did not answer within 0.3s; a reset may still be under way" in said
    assert "then run `capability-daemon.sh check`" in said


def test_ups_wait_says_its_keeper_stopped_whichever_way_the_race_went(scratch, capsys):
    # The keeper gone before `up`'s client connected read "no daemon started by up
    # runs ... Run up"; gone after, "closed the connection". Both are one sentence now.
    home = scratch / "x-eval"
    home.mkdir()
    gone = subprocess.Popen(["true"])
    gone.wait()
    assert keeper_mod.ask("check", str(home), None, wait_for=gone.pid) == 3
    assert "stopped before its daemon answered" in capsys.readouterr().err


def test_a_keeper_that_stops_mid_request_is_told_from_a_slow_one(scratch):
    # A keeper that exited with the request unanswered used to be reported as one that
    # had not answered in 240 s, with `check` as the way on: there is none to check.
    home = scratch / "x-eval"
    home.mkdir()
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(home / keeper_mod.SOCKET_NAME))
    listener.listen(1)

    def close_unanswered():
        conn, _ = listener.accept()
        conn.recv(256)
        conn.close()

    import threading
    closer = threading.Thread(target=close_unanswered)
    closer.start()
    try:
        done = subprocess.run([sys.executable, os.path.join(HERE, "eval_daemon_keeper.py"), "ask",
                               "check", str(home)], capture_output=True, text=True,
                              timeout=SCRIPT_TIMEOUT_S)
    finally:
        closer.join()
        listener.close()
    assert done.returncode == 3
    assert "closed the connection without an answer" in done.stderr
    assert "`capability-daemon.sh down` and `up`" in done.stderr
    assert "did not answer within" not in done.stderr


def test_down_leaves_a_daemon_it_did_not_start_and_its_socket_alone(
        scratch, fake_mix, stray_daemons):
    home = _seeded_home(scratch)
    daemon = _by_hand(home, fake_mix, stray_daemons)
    down = _script("down", home)
    assert down.returncode == 3 and "did not start" in down.stderr
    assert f"(pid {daemon.pid})" in down.stderr and f"kill {daemon.pid}" in down.stderr
    assert daemon.poll() is None and (home / "daemon.sock").exists()
    # The advice, followed: stop it by its pid, then `down` again.
    daemon.terminate()
    daemon.wait()
    assert _script("down", home).returncode == 0
    assert not (home / "daemon.sock").exists()


def test_snapshot_is_no_verb_of_the_script(scratch):
    # Nothing could restore a snapshot taken again under a running keeper; only `up`
    # takes one.
    home = _seeded_home(scratch)
    done = _script("snapshot", home)
    assert done.returncode == 2 and "usage" in done.stderr
    assert not (home / state.SNAPSHOT_DIR).exists()


def test_run_keeps_the_runners_exit_code_whatever_its_teardown_says(tmp_path, fake_mix):
    # `down` is `run`'s EXIT trap and can return 3 (a daemon it did not start still
    # answers); under `set -e` that replaced the runner's code (runner 5, script 3).
    bench = tmp_path / "benchmark"
    stubs = bench / "bin"
    stubs.mkdir(parents=True)
    shutil.copy(DAEMON_SCRIPT, stubs / "capability-daemon.sh")
    home = tmp_path / "run-eval"
    home.mkdir()
    sibling = {
        # The seeder, the snapshot helper and the private-suite sync: all succeed.
        "seed_capability_home.py": "#!/bin/sh\nexit 0\n",
        "eval_home_state.py": "#!/bin/sh\nexit 0\n",
        # The keeper: `up`'s first ask finds nothing running, every other one answers;
        # `serve` records its pid and lives until `down` stops it; `answering` names the
        # daemon that answers the home once the tier made one, as `down` asks it.
        "eval_daemon_keeper.py": "#!/bin/sh\ncase \"$*\" in *--for-up*) exit 4;; esac\n"
                                 "if [ \"$1\" = answering ]; then\n"
                                 "  [ -f \"$2/answering\" ] && { echo 4242; exit 0; }\n"
                                 "  exit 4\nfi\n"
                                 "[ \"$1\" = serve ] || exit 0\n"
                                 "echo $$ > \"$2/keeper.pid\"\necho $$ > \"$2/daemon.pid\"\n"
                                 "exec sleep 300\n",
        # The tier: the runner's own verdict, 5, and a daemon that then answers the home,
        # which `down` leaves alone and says so with exit 3.
        "tier.sh": "#!/bin/sh\ntouch \"$FERMIX_CAP_HOME/answering\"\nexit 5\n",
    }
    for name, body in sibling.items():
        (stubs / name).write_text(body)
        (stubs / name).chmod(0o755)
    (stubs / "run_capability.py").write_text("raise SystemExit(0)\n")   # the preflight
    done = subprocess.run([str(stubs / "capability-daemon.sh"), "run"],
                          env={**os.environ, "FERMIX_CAP_HOME": str(home),
                               "CAPABILITY_PRIVATE": "0", "FERMIX_CAP_OPIK": "0"},
                          capture_output=True, text=True, timeout=SCRIPT_TIMEOUT_S)
    keeper = home / "keeper.pid"
    assert not keeper.exists() or not _alive(int(keeper.read_text()))
    assert "did not start still answers" in done.stderr
    assert done.returncode == 5, done.stderr


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


def test_a_companion_socket_that_comes_up_after_the_control_socket_fails_no_drive(
        scratch, fake_mix, stray_daemons):
    # The live cues run lost five attempts this way: the reset returned once the
    # control socket answered, and the drive's connect beat the companion socket.
    home = scratch / "cap-eval"
    assert _up(home, FAKE_COMPANION_DELAY_S="2", **EXPORTING).returncode == 0
    try:
        assert rc.home_resetter(_cfg(home))() is None
        evidence = companion.drive(str(home), {}, "Brindle status", "e2e-mark-brindle",
                                   timeout_s=10)
        assert evidence.ok, evidence.error
        assert evidence.target.reply() == "Done."
    finally:
        _down(home, stray_daemons)


def test_a_companion_socket_that_never_answers_fails_the_reset_loudly(
        scratch, fake_mix, stray_daemons, monkeypatch):
    # A reset error stops the run as the harness's (test_a_failed_reset_stops_the_run…).
    home = scratch / "cap-eval"
    assert _up(home, FAKE_COMPANION_DELAY_S="600", **EXPORTING).returncode == 0
    monkeypatch.setattr(rc, "_COMPANION_READY_S", 0.5)
    try:
        error = rc.home_resetter(_cfg(home))()
        assert error is not None
        assert "answered its control socket" in error
        assert "did not answer a hello within 0.5s" in error
        assert f"{home / companion.SOCKET_NAME}: [Errno 2]" in error
    finally:
        _down(home, stray_daemons)


def test_the_runner_reports_a_reset_the_script_refused(scratch, fake_mix):
    home = _seeded_home(scratch)
    error = rc.home_resetter(_cfg(home))()
    assert "no seeded-state snapshot" in error
    assert _starts(home) == []


def test_the_pre_spend_check_asks_the_keeper_what_a_reset_would_refuse(
        scratch, fake_mix, stray_daemons, shared):
    # Before any spend, not only that a snapshot file exists: that the daemon answering
    # is the one `up` started, that the snapshot is that `up`'s, and that the daemon
    # exports to the project the run reads.
    home = _seeded_home(scratch)
    assert "no seeded-state snapshot" in rc.reset_precondition_error(_cfg(home))
    state.snapshot(str(home))
    daemon = _by_hand(home, fake_mix, stray_daemons)
    try:
        assert "started outside capability-daemon.sh" in rc.reset_precondition_error(_cfg(home))
    finally:
        daemon.terminate()
        daemon.wait()
    home = shared.home
    starts = len(_starts(home))
    assert rc.reset_precondition_error(_cfg(home)) is None
    assert "this run reads fermix-dev" in rc.reset_precondition_error(_cfg(home, "fermix-dev"))
    assert len(_starts(home)) == starts                    # the check replaced nothing


def test_reset_home_is_refused_without_the_isolated_mutation_profile(capsys):
    code = run_eval.main(["--suite", "cues", "--judge", "--dry-run", "--reset-home"])
    assert code == 2
    assert "--reset-home" in capsys.readouterr().err


# --- a behavioral case's `state:`: seeded before every attempt (M106) -------------

def _state_suite(tmp_path):
    """An isolated scenario whose first case seeds a jobs baseline and whose second
    does not."""
    spec = tmp_path / "fixtures" / "state" / "tides.json"
    spec.parent.mkdir(parents=True)
    spec.write_text('{"jobs": []}')
    path = tmp_path / "tides.yaml"
    path.write_text(
        "suite: tides\ntitle: Tides\nrisk: isolated_mutation\nscenarios:\n"
        "  - id: asked_why\n    title: Asked why\n    cases:\n"
        "      - id: seeded\n        state: fixtures/state/tides.json\n        query: why\n"
        "      - id: bare\n        query: why\n")
    return suites.load_all(str(tmp_path))[0]


def _seeding(events: list[str], error: str | None = None, unsent: str | None = None):
    def seed(cfg, suite, case):
        events.append(f"seed:{case.id}:{os.path.basename(suite.path)}:{case.state}")
        return (None, error) if error else ({"jobs": {"tides": {"id": "tides_1"}}}, None)

    def await_heals(home, manifest):
        events.append(f"await:{home}:{sorted(manifest['jobs'])}")
        return unsent

    return seed, await_heals


def _run_state_suite(tmp_path, monkeypatch, events, outcomes, fail_retries=0,
                     reset_home=None, **seeding):
    suite = _state_suite(tmp_path)
    jobs = run_eval.case_jobs([(suite, suite.scenarios)], repeat=1)
    _scripted(monkeypatch, events, outcomes)
    seed, await_heals = _seeding(events, **seeding)
    monkeypatch.setattr(run_eval, "seed_case_state", seed)
    monkeypatch.setattr(run_eval, "await_seeded_heals", await_heals)
    cfg = SimpleNamespace(daemon=SimpleNamespace(fermix_home="/h/x-eval"))
    return run_eval._execute_jobs(cfg, object(), jobs, "20261124T150000Z01234567", False, False,
                                  fail_retries=fail_retries, reset_home=reset_home)


def test_every_attempt_of_a_state_case_is_seeded_and_its_heals_awaited_first(
        tmp_path, monkeypatch):
    events: list[str] = []
    _results, _skipped, aborted = _run_state_suite(
        tmp_path, monkeypatch, events, {"seeded": ["fail", "pass"]}, fail_retries=1)
    assert aborted is None
    seeded = ["seed:seeded:tides.yaml:fixtures/state/tides.json",
              "await:/h/x-eval:['tides']", "seeded"]
    # The retry starts from the seed too; a case without `state:` is never seeded.
    assert events == [*seeded, *seeded, "bare"]


def test_with_reset_home_every_attempt_of_a_state_case_starts_from_the_snapshot(
        tmp_path, monkeypatch):
    # Live (M106): each attempt asked about the job the attempts before it had asked
    # about, and their conversations were still in the home for its turn to recall.
    events: list[str] = []
    _results, _skipped, aborted = _run_state_suite(
        tmp_path, monkeypatch, events, {"seeded": ["fail", "pass"]}, fail_retries=1,
        reset_home=_reset(events))
    assert aborted is None
    seeded = ["reset", "seed:seeded:tides.yaml:fixtures/state/tides.json",
              "await:/h/x-eval:['tides']", "seeded"]
    # The restore comes before the seed, for the retry too; `bare` seeds nothing.
    assert events == [*seeded, *seeded, "bare"]


def test_a_state_case_runs_only_with_reset_home(tmp_path):
    suite = _state_suite(tmp_path)
    cfg = SimpleNamespace(daemon=SimpleNamespace(fermix_home=str(tmp_path / "x-eval")))
    kept, held = run_eval.hold_out_unseeded(cfg, [(suite, suite.scenarios)], reset_home=False)
    assert [(name, case_id) for name, case_id, _why in held] == [("tides", "seeded")]
    assert "--reset-home" in held[0][2]
    assert [case.id for _suite, scns in kept for scn in scns for case in scn.cases] == ["bare"]
    _kept, held = run_eval.hold_out_unseeded(cfg, [(suite, suite.scenarios)], reset_home=True)
    assert held == []


def test_a_failed_state_seed_stops_the_run_before_the_case_is_driven(tmp_path, monkeypatch):
    events: list[str] = []
    results, _skipped, aborted = _run_state_suite(
        tmp_path, monkeypatch, events, {}, error="seed_state.exs exited 1: a job run in flight")
    assert events == ["seed:seeded:tides.yaml:fixtures/state/tides.json"]
    [case] = results[0]["scenarios"][0]["cases"]
    assert case["id"] == "seeded" and case["outcome"] == "incomplete"
    assert aborted["unrun"] == 1 and aborted["tool"] == "seed_state.exs"
    banner = report._abort_text(run_eval._persistable_abort(dict(aborted)))
    assert "the harness, not a product failure" in banner


# --- the capability runner: every trial of a `checker.state` task, from the snapshot --

LANES = "Ferncastle"


# The stores a turn's recall reads, under the engine's names: the conversation history
# and its search index, durable memories and theirs. The eval home's seeded memory.db is
# the empty one `up` leaves (the daemon makes its schema at boot), so a turn makes them.
_STORES = ("CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY, channel, chat_id, "
           "role, content);"
           "CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(content);"
           "CREATE TABLE IF NOT EXISTS memories (id INTEGER PRIMARY KEY, scope_type, key, "
           "value);"
           "CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(key, value);")


def _connect(home: Path) -> sqlite3.Connection:
    return sqlite3.connect(str(home / "memory.db"))


def _converse(home: Path, session: str, query: str, reply: str) -> None:
    """What the daemon keeps of one turn in the trial's own chat (`cli`, `session`): both
    messages and their index rows, the memory review's owner note on the turn, and the
    line that note renders into MEMORY.md, the prompt memory every owner turn carries."""
    conn = _connect(home)
    try:
        conn.executescript(_STORES)
        for role, text in (("user", query), ("assistant", reply)):
            conn.execute("INSERT INTO messages (channel, chat_id, role, content) "
                         "VALUES ('cli', ?, ?, ?)", (session, role, text))
            conn.execute("INSERT INTO messages_fts (content) VALUES (?)", (text,))
        conn.execute("INSERT INTO memories (scope_type, key, value) "
                     "VALUES ('owner', 'lane_timetable', ?)", (reply,))
        conn.execute("INSERT INTO memories_fts (key, value) VALUES ('lane_timetable', ?)",
                     (reply,))
        conn.commit()
    finally:
        conn.close()
    (home / "memory").mkdir(exist_ok=True)
    with open(home / "memory" / "MEMORY.md", "a", encoding="utf-8") as fh:
        fh.write(f"- {reply}\n")


def _recall(home: Path, term: str) -> list[str]:
    """Every place a turn could find `term` in: `memory_recall`'s history and memory
    search (`messages_fts`, `memories_fts`, any chat of the owner's) and the prompt
    memory (USER.md, MEMORY.md)."""
    found: list[str] = []
    if (home / "memory.db").exists():
        conn = _connect(home)
        try:
            conn.executescript(_STORES)
            found += [row[0] for row in conn.execute(
                "SELECT content FROM messages_fts WHERE messages_fts MATCH ?", (term,))]
            found += [row[0] for row in conn.execute(
                "SELECT value FROM memories_fts WHERE memories_fts MATCH ?", (term,))]
        finally:
            conn.close()
    prompts = [home / "memory" / name for name in ("USER.md", "MEMORY.md")]
    return found + [path.name for path in prompts
                    if path.exists() and term in path.read_text(encoding="utf-8")]


def _seeded_task():
    case = SimpleNamespace(
        id="planted_note_read_through_the_run", drive="ask", cross_session=False,
        timeout_ms=1000, expect={}, requires_tools=(), requires_tools_all=(),
        score_spec=None, rubric=None,
        turns=[SimpleNamespace(query=f"What did you make of my {LANES} pool lane timetable?",
                               expect={})],
        checker_spec={"script": "suites/capability/checkers/job_proposal.py", "mode": "json",
                      "reset": [], "state": "fixtures/state/lanes.json", "expect": {}})
    return SimpleNamespace(name="cap_lanes"), SimpleNamespace(id="lanes"), case


def _graded_turn() -> rc._Captured:
    trace = {"id": "tr-1", "_eval_trace_complete": True, "total_estimated_cost": 0.01,
             "usage": {"total_tokens": 10}, "metadata": {"iterations": 1}, "output": "ok"}
    view = grade.TurnView.build(trace, [], elapsed_ms=100.0)
    return rc._Captured("graded", view, trace, [], 100.0)


def _seeded_trials(home: Path, monkeypatch, events: list):
    """Two trials of a seeded task against the fake daemon, each trial's turn first
    recording what it could recall of the lanes and then leaving its own conversation
    behind, as a real turn does."""
    monkeypatch.setattr(rc.checker, "seed_workspace", lambda *_a: None)
    monkeypatch.setattr(rc.checker, "run_checker",
                        lambda *_a, **_k: rc.checker.CheckerResult(1.0, "ok", safety_ok=True))
    monkeypatch.setattr(rc, "_seed_state",
                        lambda *_a: events.append(("seed", len(_starts(home)))) or {"jobs": {}})

    def turn(_cfg, _opik, session, query, _timeout, _label):
        events.append(("recalled", _recall(home, LANES)))
        _converse(home, session, query, f"Last time I said 6:15 for the {LANES} lanes.")
        return _graded_turn()

    monkeypatch.setattr(rc, "_capture_turn", turn)
    cfg = SimpleNamespace(daemon=SimpleNamespace(fermix_home=str(home)),
                          opik=SimpleNamespace(project="fermix-capability-eval"))
    suite, scenario, case = _seeded_task()
    return rc.run_task(cfg, None, suite, scenario, case, 2, 2, 1.0, "20261127T090000Z", False)


def test_no_trial_of_a_seeded_task_can_recall_an_earlier_trials_conversation(
        shared, monkeypatch):
    # Live (M106): trial 2 of planted_note_read_through_the_run answered from trial 1's
    # conversation ("nothing has changed since I first looked") without reading the run.
    # Each trial's turn has a chat of its own, which no seed clears, and the memory review
    # writes what it said into the owner's memory: only the snapshot puts every one of
    # those stores back.
    home = shared.home
    starts = len(_starts(home))
    events: list = []
    out = _seeded_trials(home, monkeypatch, events)
    # Neither trial's turn could find anything of the lanes, the earlier trial's words
    # included...
    assert [event for event in events if event[0] == "recalled"] == [("recalled", [])] * 2
    # ...because each trial's seed ran on a daemon its own restore had just started.
    assert [event for event in events if event[0] == "seed"] == [
        ("seed", starts + 1), ("seed", starts + 2)]
    assert [trial.status for trial in out.trials] == ["ok", "ok"]


def test_a_seeded_trial_on_a_home_with_no_snapshot_stops_before_anything_runs(
        scratch, fake_mix, monkeypatch):
    home = _seeded_home(scratch)
    events: list = []
    with pytest.raises(rc.StateSeedError) as raised:
        _seeded_trials(home, monkeypatch, events)
    assert "no seeded-state snapshot" in raised.value.error
    assert (raised.value.case_id, raised.value.trial) == ("planted_note_read_through_the_run", 0)
    assert events == [] and _starts(home) == []


def test_a_seeded_heal_never_sent_leaves_only_that_attempt_incomplete(tmp_path, monkeypatch):
    events: list[str] = []
    results, _skipped, aborted = _run_state_suite(
        tmp_path, monkeypatch, events, {}, unsent="the daemon did not send jhl_1 within 150 s")
    assert aborted is None
    cases = {case["id"]: case for case in results[0]["scenarios"][0]["cases"]}
    assert cases["seeded"]["outcome"] == "incomplete"
    assert "jhl_1" in cases["seeded"]["turns"][0]["drive_error"]
    assert "seeded" not in events and "bare" in events      # never driven; the next one is


def _heals_db(home, rows, links=()):
    import sqlite3
    conn = sqlite3.connect(str(home / "memory.db"))
    conn.execute("CREATE TABLE job_heals (id, job_id, state)")
    conn.execute("CREATE TABLE job_heal_runs (run_id, heal_id, job_id)")
    conn.executemany("INSERT INTO job_heals VALUES (?,?,?)", rows)
    conn.executemany("INSERT INTO job_heal_runs VALUES (?,?,?)", links)
    conn.commit()
    conn.close()


class _Clock:
    """A clock the test moves: each sleep advances it, so no test waits."""

    def __init__(self):
        self.now = 0.0
        self.sleeps: list[float] = []

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds


MANIFEST = {"jobs": {"tides": {"id": "tides_1"}}}


def test_a_seeded_heal_that_was_sent_lets_the_turn_start_at_once(tmp_path):
    _heals_db(tmp_path, [("jhl_1", "tides_1", "waiting"),
                         ("jhl_2", "other_job", "open")])     # not a seeded job's
    clock = _Clock()
    assert run_eval.await_seeded_heals(str(tmp_path), MANIFEST, 150, clock, clock.sleep) is None
    assert clock.sleeps == []


def test_the_turn_waits_for_a_seeded_heal_and_gives_up_naming_it(tmp_path):
    _heals_db(tmp_path, [("jhl_1", "tides_1", "open")])
    clock = _Clock()
    why = run_eval.await_seeded_heals(str(tmp_path), MANIFEST, 3, clock, clock.sleep)
    assert "jhl_1" in why and "within 3 s" in why
    assert sum(clock.sleeps) == 3


def test_the_turn_waits_for_a_plugins_heal_a_seeded_run_opened(tmp_path):
    # A plugin's heal (M106 §6) has no job of its own: it is found by the run it took.
    _heals_db(tmp_path, [("jhl_1", None, "open"), ("jhl_2", None, "open")],
              links=[("run_1", "jhl_1", "tides_1"), ("run_2", "jhl_2", "other_job")])
    clock = _Clock()
    why = run_eval.await_seeded_heals(str(tmp_path), MANIFEST, 3, clock, clock.sleep)
    assert "jhl_1" in why and "jhl_2" not in why


def test_a_seed_with_no_jobs_waits_for_nothing(tmp_path):
    clock = _Clock()
    assert run_eval.await_seeded_heals(str(tmp_path), {"jobs": {}}, 150, clock,
                                       clock.sleep) is None


def test_a_store_without_the_heals_table_is_a_reason_not_a_crash(tmp_path):
    import sqlite3
    sqlite3.connect(str(tmp_path / "memory.db")).close()
    clock = _Clock()
    why = run_eval.await_seeded_heals(str(tmp_path), MANIFEST, 150, clock, clock.sleep)
    assert "could not be read" in why and "job_heals" in why


def test_dry_run_counts_the_attempts_seeded_with_state(capsys):
    code = run_eval.main(["--suite", "job_auto_heal", "--profile", "isolated_mutation",
                          "--judge", "--dry-run"])
    assert code == 0
    out = capsys.readouterr().out
    assert "state: 7 case trial(s) would each seed" in out
    assert "without --reset-home every one would be NOT EVALUATED" in out


def test_dry_run_counts_the_state_attempts_that_start_from_the_snapshot(capsys):
    code = run_eval.main(["--suite", "job_auto_heal", "--profile", "isolated_mutation",
                          "--judge", "--dry-run", "--reset-home"])
    out = capsys.readouterr().out
    assert code == 0
    assert "home reset: 7 case trial(s)" in out
    assert "NOT EVALUATED" not in out


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
