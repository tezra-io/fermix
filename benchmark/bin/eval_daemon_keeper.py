#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""The one process that starts, stops and restores a disposable eval home's daemon.

`capability-daemon.sh up` seeds the home, snapshots it and starts this keeper, handing it
on stdin the environment the daemon is to run with, exactly as the script built it
(`env -0`: through a pipe, never a file). The keeper starts the daemon with it and stays
beside it for its whole life, holding that environment in its own memory, and the id of
the snapshot `up` took (`eval_home_state.SNAPSHOT_ID`). A reset (`capability-daemon.sh
reset`, which both runners ask for before a trial or an attempt that must start from the
seeded world) is a request to this keeper over `<home>/keeper.sock`: it stops the daemon
it started, puts that snapshot back and starts the daemon again with that environment.
Nothing else restarts the daemon, so a reset never boots it with a runner's environment
(a judge's key, a shell's exports), nor with what the keeper's own interpreter added to
its environment, and the keeper refuses one, replacing nothing, when:

- a daemon it did not start answers the home's control socket (one started by hand, a
  second one), or one answers that cannot say which process it is;
- the home's snapshot is not the one its `up` took (taken again since);
- the run asking reads another Opik project than the daemon exports to.

`check` asks the same questions, and also that the daemon answers, and changes nothing:
the runners ask it before any spend. A daemon that exits by itself under the keeper is
logged when it happens (within a second), refused by `check` and named, with its exit
code, by the `reset` that starts it again. A boot the keeper started is waited for until
its bound, whatever answers in the meantime; at the bound the keeper stops that daemon.
A reset that fails says what it stopped, restored and started, and `check` says the same
until the next start. Every refusal ends in a sequence that works from the state it
names.

  eval_daemon_keeper.py serve HOME --cwd DIR --ready-timeout S -- CMD...  < env -0
                                                         run by `up`, in the background
  eval_daemon_keeper.py ask check|reset HOME [--project P] [--wait-for PID] [--for-up]
                                                         exit 0, or 3 with the reason
                                                         (--for-up: 4, silently, when
                                                         nothing of an earlier `up` runs)
  eval_daemon_keeper.py answering HOME                   the pid of the daemon that
                                                         answers HOME (exit 0), 4 when
                                                         none does, 3 when it cannot say

The keeper serves requests one at a time and survives anything one client does: a
client that goes away before its reply, says nothing (it is given `REQUEST_TIMEOUT_S`),
or sends a line that is not a JSON object of at most `MAX_REQUEST_BYTES` is logged once
and the loop goes on. Only SIGTERM, SIGHUP or SIGINT (what `capability-daemon.sh down`
sends) ends it, and it stops its daemon first; a restore it runs is killed with its whole
process group by its bound or by that termination. The
daemon it starts gets its pid in <home>/daemon.pid and the keeper its own in
<home>/keeper.pid. A daemon is told by the pid it reports on its control socket, which
is the process the keeper started (`mix` execs its way to the BEAM): the engine's
management `hello` (apps/fermix_core/priv/management/PROTOCOL.md), a v1 request whose
reply carries the daemon's OS pid as `result.engine.pid`, a string (`System.pid()`).
It is the smallest request that names the pid, needs no session before it and no
owner, and is answered by every role an eval engine boots in.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import eval_home_state  # noqa: E402

# As long as daemon.sock: a home whose daemon's sockets fit AF_UNIX fits the keeper's.
SOCKET_NAME = "keeper.sock"
KEEPER_PIDFILE = "keeper.pid"
DAEMON_PIDFILE = "daemon.pid"
CONTROL_SOCKET = "daemon.sock"
EVAL_HOME_STATE = os.path.join(HERE, "eval_home_state.py")
OPS = ("check", "reset")
# The management version `hello` is asked under: the engine's current one, as `fermix
# status` declares it (Fermix.CLI.Daemon.Client). The eval daemon is built from this
# checkout, so its window holds it; test_home_reset checks it against the golden.
PROTOCOL_VERSION = 2
REFUSED = 3
NOTHING_RUNS = 4          # `ask --for-up`: no keeper and no daemon, so `up` may start one
TERMINATING = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)
# The daemon's own SIGTERM shutdown, as `down` always allowed it, then SIGKILL and its wait.
STOP_WAIT_S = 15
KILL_WAIT_S = 5
# A copy of memory.db and a few trees: far under this, which only a stuck disk reaches.
# The restore runs in a process group of its own, which the bound (or a termination)
# kills whole, then waits KILL_WAIT_S for.
RESTORE_TIMEOUT_S = 60
POLL_S = 0.1
# How often the idle keeper looks at its daemon, so an exit is logged when it happens.
WATCH_S = 1.0
# One `hello` probe of the control socket: connect, ask, read the answer.
PROBE_TIMEOUT_S = 5.0
# A client says what it wants at once; one that says nothing is let go after this. A
# request is one short JSON line; a longer one is refused unread.
REQUEST_TIMEOUT_S = 5.0
MAX_REQUEST_BYTES = 4096
# The longest a client waits for its answer, and the one bound the others derive from.
# The worst reset: the probe before it, the daemon's stop, the restore and its kill, the
# boot (READY_TIMEOUT) and its last probe, which may run past it, then the stop of a
# daemon that never answered; the keeper refuses a READY_TIMEOUT that would not fit
# (`MAX_READY_S`), and the runners' own timeouts are set above ANSWER_TIMEOUT_S. A
# request queued behind another waits for it inside the same bound. At the bound the
# client says the keeper did not answer and exits 3; the keeper finishes the request,
# its reply to a client that went away is logged, and it serves on.
ANSWER_TIMEOUT_S = 240
_STOP_S = STOP_WAIT_S + KILL_WAIT_S
RESET_OVERHEAD_S = (PROBE_TIMEOUT_S + _STOP_S + RESTORE_TIMEOUT_S + KILL_WAIT_S
                    + PROBE_TIMEOUT_S + _STOP_S + 10)
MAX_READY_S = int(ANSWER_TIMEOUT_S - RESET_OVERHEAD_S)
# The last entry `up` pipes after the daemon's environment: a hand-over without it, at
# its end, was cut short (or is not `env -0` output) and is refused before anything runs.
ENV_END = "EVAL_KEEPER_ENV_END=1"


class Refused(Exception):
    """What the keeper will not do, in the words it tells the caller."""


class BootFailed(Refused):
    """A daemon the keeper started that exited, or never answered as itself, in its
    boot: the words say which, and that it is stopped."""


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _log(message: str) -> None:
    """One line in daemon.log (the keeper's stdout)."""
    print(f"eval_daemon_keeper {_now()}: {message}", flush=True)


def _read(conn: socket.socket, size: int) -> bytes:
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            raise OSError("the connection closed mid-reply")
        data += chunk
    return data


def hello_frame() -> dict:
    """The management `hello` request, as the engine's golden frame has it."""
    return {"request_id": f"eval-keeper-{os.getpid()}", "protocol_version": PROTOCOL_VERSION,
            "method": "hello", "params": {}}


def hello_pid(reply, request_id: str) -> int:
    """The OS pid a daemon's reply to `hello_frame()` names, or ValueError saying why
    it names none (another request's reply, an error envelope, no `engine.pid`)."""
    if not isinstance(reply, dict) or reply.get("request_id") != request_id:
        raise ValueError(f"not a reply to its hello: {json.dumps(reply)[:160]}")
    if "error" in reply:
        error = reply["error"] if isinstance(reply["error"], dict) else {}
        raise ValueError(f"hello answered {error.get('code')}: {error.get('message')} "
                         f"{json.dumps(error.get('details'))}")
    result = reply.get("result")
    engine = result.get("engine") if isinstance(result, dict) else None
    pid = engine.get("pid") if isinstance(engine, dict) else None
    if not isinstance(pid, str) or not pid.isdigit():
        raise ValueError(f"hello's engine.pid is {pid!r}, not a process id")
    return int(pid)


def probe_control(home: str) -> tuple[int | None, str | None]:
    """What answers <home>/daemon.sock, asked `hello` ({packet, 4} JSON): (its pid, None)
    when a daemon answers with its pid; (None, None) when nothing answers there; (None,
    why) when something answers and does not say which process it is: one still booting,
    one hung, one that is not a Fermix daemon."""
    path = os.path.join(home, CONTROL_SOCKET)
    if not os.path.exists(path):
        return None, None
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(PROBE_TIMEOUT_S)
    try:
        conn.connect(path)
    except OSError:
        conn.close()
        return None, None
    try:
        hello = hello_frame()
        body = json.dumps(hello).encode()
        conn.sendall(struct.pack(">I", len(body)) + body)
        reply = json.loads(_read(conn, struct.unpack(">I", _read(conn, 4))[0]))
        return hello_pid(reply, hello["request_id"]), None
    except (OSError, ValueError, RecursionError) as exc:
        return None, str(exc) or type(exc).__name__
    finally:
        conn.close()


def _unknown_answer(home: str, why: str, after: str) -> str:
    path = os.path.join(home, CONTROL_SOCKET)
    return (f"a process answers {path} and does not say which process it is ({why}): "
            f"nothing was stopped or replaced. Find it with `lsof {path}`, stop it, then "
            f"run {after}.")


def control_pid(home: str) -> int | None:
    """The OS pid the daemon answering <home>/daemon.sock reports for itself, or None
    when nothing answers there. One that answers and cannot say which process it is is
    refused, as a foreign one is."""
    pid, unclear = probe_control(home)
    if unclear is not None:
        raise Refused(_unknown_answer(home, unclear, "`capability-daemon.sh up`"))
    return pid


def _nothing_answers(home: str) -> bool:
    """True only when no process answers <home>/daemon.sock, so its file is stale."""
    pid, unclear = probe_control(home)
    return pid is None and unclear is None


def _write_pid(path: str, pid: int) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(f"{pid}\n")


def _read_pid(path: str) -> int | None:
    try:
        with open(path, encoding="utf-8") as fh:
            return int(fh.read().strip())
    except (FileNotFoundError, ValueError):
        return None


def _unlink(path: str) -> None:
    if os.path.lexists(path):
        os.remove(path)


def read_environment(stream, home: str) -> dict[str, str]:
    """The daemon's environment as `up` hands it over: `env -0`'s NAME=value entries,
    each ended by a NUL, then ENV_END. Refused, before anything starts, when it does not
    end in ENV_END (cut short, or not `env -0` output: a newline-separated block), holds
    an entry that is not NAME=value, or names another FERMIX_HOME than the home served."""
    raw = stream.read()
    end = ENV_END.encode() + b"\0"
    if not raw.endswith(end) or raw.count(end) != 1 or \
            (len(raw) > len(end) and not raw[:-len(end)].endswith(b"\0")):
        raise ValueError(f"the hand-over does not end in {ENV_END}: it was cut short, or is "
                         "not the `env -0` output `capability-daemon.sh up` pipes")
    env = {}
    for entry in raw[:-len(end)].split(b"\0")[:-1]:
        name, sep, value = entry.decode("utf-8", "surrogateescape").partition("=")
        if not sep or not name:
            raise ValueError(f"not an environment entry: {entry[:40]!r}")
        env[name] = value
    given = env.get("FERMIX_HOME")
    if given is None or os.path.realpath(os.path.expanduser(given)) != home:
        raise ValueError(f"the hand-over's FERMIX_HOME is {given!r}, not {home}")
    return env


class _Signals:
    """SIGTERM, SIGHUP and SIGINT end the keeper (SystemExit), except while it spawns
    the daemon and records its pid: a signal then is held and acted on right after, so
    no daemon is ever left without its pidfile and without its keeper."""

    def __init__(self):
        self.holding = False
        self.held = False

    def __call__(self, _signum, _frame) -> None:
        if self.holding:
            self.held = True
            return
        raise SystemExit(0)

    def hold(self) -> None:
        self.holding = True

    def release(self) -> None:
        self.holding = False
        if self.held:
            self.held = False
            raise SystemExit(0)


SIGNALS = _Signals()


class Keeper:
    """The daemon of one home, the environment and the snapshot its `up` gave it."""

    def __init__(self, home: str, cwd: str, command: list[str], ready_s: float,
                 env: dict[str, str]):
        self.home, self.cwd, self.command, self.ready_s = home, cwd, command, ready_s
        self.env = env
        self.snapshot = eval_home_state.snapshot_id(home)
        exporting = env.get("FERMIX_OPIK_ENABLED") == "1"
        self.project = env.get("FERMIX_OPIK_PROJECT") if exporting else None
        self.child: subprocess.Popen | None = None
        # (pid, exit code, when) of a daemon that exited by itself, once it is noticed.
        self.exited: tuple[int, int, str] | None = None
        # What a reset that failed did, in the words it refused with, until a start.
        self.halted: str | None = None

    def mine(self) -> int | None:
        """The pid of the daemon this keeper started, while it runs."""
        self.watch()
        return self.child.pid if self.child is not None else None

    def watch(self) -> None:
        """Notice, once, that the daemon exited by itself, and log it then."""
        if self.child is None or self.child.poll() is None:
            return
        self.exited = (self.child.pid, self.child.returncode, _now())
        self.child = None
        _unlink(os.path.join(self.home, DAEMON_PIDFILE))
        _log(f"the daemon (pid {self.exited[0]}) exited by itself with code "
             f"{self.exited[1]}; nothing restarts it until a reset or `up`")

    def start(self, why: str) -> None:
        """Start the daemon with `up`'s environment and wait until it answers as the
        process it is, or raise: it exited, or did not answer in time."""
        print(f"\n=== capability-daemon {why}: starting the daemon at {_now()} ===", flush=True)
        SIGNALS.hold()
        try:
            # stdin from /dev/null, as a background job's was: the keeper's own stdin is
            # the pipe its environment came on.
            self.child = subprocess.Popen(self.command, cwd=self.cwd, env=self.env,
                                          stdin=subprocess.DEVNULL)
            _write_pid(os.path.join(self.home, DAEMON_PIDFILE), self.child.pid)
        finally:
            SIGNALS.release()
        self.exited, self.halted = None, None
        deadline = time.monotonic() + self.ready_s
        last = "nothing answered"
        while time.monotonic() < deadline:
            if self.child.poll() is not None:
                pid, code, self.child = self.child.pid, self.child.returncode, None
                _unlink(os.path.join(self.home, DAEMON_PIDFILE))
                raise BootFailed(f"the daemon it started (pid {pid}) exited during its boot "
                                 f"with code {code}")
            # Not ready yet, whatever it is: nothing answers, an answer that is not a pid
            # (an early `unavailable`, a probe that timed out), another pid. Only the
            # bound ends the wait.
            answering, unclear = probe_control(self.home)
            if answering == self.child.pid:
                return
            last = unclear or (f"pid {answering} answered" if answering else last)
            time.sleep(POLL_S)
        pid = self.child.pid
        self.stop()
        raise BootFailed(f"the daemon it started (pid {pid}) did not answer `hello` as "
                         f"itself within {self.ready_s:g}s (last: {last}), and was stopped")

    def stop(self) -> None:
        """Stop the daemon this keeper started (SIGTERM, SIGKILL after STOP_WAIT_S), then
        remove its control socket unless another process answers on it."""
        if self.child is not None:
            if self.child.poll() is None:
                self.child.terminate()
                # A stopped daemon (SIGSTOP) acts on its SIGTERM only once continued.
                os.kill(self.child.pid, signal.SIGCONT)
                try:
                    self.child.wait(STOP_WAIT_S)
                except subprocess.TimeoutExpired:
                    self.child.kill()
                    self.child.wait(KILL_WAIT_S)
            self.child = None
        _unlink(os.path.join(self.home, DAEMON_PIDFILE))
        if _nothing_answers(self.home):
            _unlink(os.path.join(self.home, CONTROL_SOCKET))

    def problem(self, project: str | None, answers: bool) -> str | None:
        """Why this keeper may not act for the run asking, or None."""
        mine = self.mine()
        answering, unclear = probe_control(self.home)
        if unclear is not None:
            return self._unclear(mine, unclear)
        if answering is not None and answering != mine:
            return (f"a daemon this script did not start answers for {self.home} (pid "
                    f"{answering}; the one `up` started is {mine or 'not running'}): "
                    f"nothing was stopped or replaced. Stop it (`kill {answering}`), then "
                    "run `capability-daemon.sh down` and `up`.")
        if answers and answering is None:
            return self._not_answering(mine)
        on_disk = eval_home_state.snapshot_id(self.home)
        if on_disk != self.snapshot:
            return (f"the snapshot in {self.home} ({on_disk or 'none'}) is not the one this "
                    f"daemon's `up` took ({self.snapshot}): a reset would put back a world "
                    "the daemon did not start from, its config.toml included. Nothing was "
                    "stopped or replaced; run `capability-daemon.sh down`, then `up`.")
        if project is not None and project != self.project:
            return (f"the daemon exports its traces to Opik project "
                    f"{self.project or '(none: Opik off)'}, and this run reads {project}: a "
                    "restarted daemon keeps the project `up` gave it. Run "
                    "`capability-daemon.sh down`, then `FERMIX_CAP_OPIK=1 "
                    f"FERMIX_CAP_PROJECT={project} capability-daemon.sh up`.")
        return None

    def _unclear(self, mine: int | None, why: str) -> str:
        """Something answers the control socket and does not say which process it is.
        While the keeper's own daemon runs, the socket is that daemon's (the engine's
        lock lets no second daemon start on the home): it is alive and not answering."""
        if mine is not None:
            return (f"the daemon `up` started for {self.home} (pid {mine}) is running and "
                    f"does not answer `hello` ({why}): it may be hung. Nothing was stopped "
                    "or replaced. Run `capability-daemon.sh down`, which stops it, then "
                    "`up`.")
        return _unknown_answer(self.home, why, "`capability-daemon.sh down` and `up`")

    def _not_answering(self, mine: int | None) -> str:
        if self.exited is not None:
            pid, code, when = self.exited
            return (f"the daemon `up` started for {self.home} (pid {pid}) exited by itself "
                    f"with code {code} at {when}; see {self.home}/daemon.log, then run "
                    "`capability-daemon.sh down` and `up`.")
        if self.halted is not None:
            return self.halted
        if mine is None:
            return (f"no daemon runs for {self.home} under its keeper; see "
                    f"{self.home}/daemon.log for why, then run `capability-daemon.sh down` "
                    "and `up`.")
        return (f"the daemon `up` started for {self.home} (pid {mine}) runs and nothing "
                f"answers its control socket; see {self.home}/daemon.log, then run "
                "`capability-daemon.sh down` and `up`.")

    def answer(self, request: dict) -> dict:
        op = request.get("op")
        if op not in OPS:
            return {"ok": False, "error": f"unknown request {op!r}; one of {list(OPS)}"}
        revived = None
        try:
            problem = self.problem(request.get("project"), answers=op == "check")
            if problem:
                raise Refused(problem)
            if op == "reset":
                revived = self.reset()
        except Refused as exc:
            return {"ok": False, "error": str(exc)}
        except (OSError, subprocess.SubprocessError) as exc:
            _log(f"{op} failed: {exc}")
            return {"ok": False, "error": f"the {op} failed ({exc}); see "
                                          f"{self.home}/daemon.log, then run "
                                          "`capability-daemon.sh down` and `up`"}
        return {"ok": True, "daemon_pid": self.mine(), "snapshot_id": self.snapshot,
                "project": self.project, "revived": revived}

    def reset(self) -> dict | None:
        """Stop the daemon, put the snapshot back, start it with the same environment.
        Returns what became of a daemon that had exited by itself before it, if one had,
        which the reply names: a daemon that died between two trials is evidence. A reset
        that fails says exactly what it stopped, restored and started, and `check` says
        the same until a start."""
        self.watch()
        revived = None
        if self.exited is not None:
            pid, code, when = self.exited
            revived = {"pid": pid, "code": code, "at": when}
            _log(f"reset: the daemon `up` started (pid {pid}) had exited by itself with "
                 f"code {code} at {when}; starting it again from the snapshot")
        was = self.child.pid if self.child is not None else None
        self.stop()
        stopped = f"stopped the daemon (pid {was})" if was else "found no daemon running"
        try:
            self._restore()
        except (Refused, OSError) as exc:
            self._halt(f"a reset {stopped}; {exc}, so nothing was started")
        try:
            self.start("reset")
        except BootFailed as exc:
            self._halt(f"a reset {stopped} and restored the snapshot; {exc}")
        except OSError as exc:
            self._halt(f"a reset {stopped} and restored the snapshot; the daemon could not "
                       f"be started ({exc})")
        return revived

    def _halt(self, what: str) -> None:
        self.halted = (f"{what}. Nothing runs for {self.home} now: see {self.home}/daemon.log, "
                       "then run `capability-daemon.sh down` and `up`.")
        _log(self.halted)
        raise Refused(self.halted)

    def _restore(self) -> None:
        """eval_home_state.py restore, in a process group of its own: the bound, and a
        termination of the keeper, kill that group whole, so nothing of the restore runs
        on into the home after the keeper has said it stopped."""
        with tempfile.TemporaryFile() as err:
            proc = subprocess.Popen([sys.executable, EVAL_HOME_STATE, "restore", self.home],
                                    env=self.env, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=err,
                                    start_new_session=True)
            deadline = time.monotonic() + RESTORE_TIMEOUT_S
            try:
                while proc.poll() is None:
                    if time.monotonic() > deadline:
                        raise Refused(f"the snapshot restore did not finish within "
                                      f"{RESTORE_TIMEOUT_S}s and was stopped, every process "
                                      "it started with it; the home is part-restored")
                    time.sleep(POLL_S)
            finally:
                _kill_group(proc)
            err.seek(0)
            said = err.read().decode("utf-8", "replace")
        if proc.returncode != 0:
            tail = " ".join(said.strip().splitlines()[-3:])
            raise Refused(f"the snapshot could not be restored ({tail}); the home may be "
                          "part-restored")


def _kill_group(proc: subprocess.Popen) -> None:
    """SIGKILL every process of `proc`'s own group (start_new_session), then reap it."""
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass                         # the group is empty: every member has exited
    proc.wait(KILL_WAIT_S)


def _listen(home: str) -> socket.socket:
    path = os.path.join(home, SOCKET_NAME)
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.connect(path)
    except OSError:
        _unlink(path)
    else:
        raise SystemExit(f"eval_daemon_keeper: a keeper already answers {path}")
    finally:
        probe.close()
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(8)
    listener.settimeout(WATCH_S)
    return listener


class _BadRequest(Exception):
    """A request line the keeper will not act on, in the words it answers with."""


def _read_request(stream) -> dict:
    """One request line: at most MAX_REQUEST_BYTES, a JSON object. A client that sends
    nothing within REQUEST_TIMEOUT_S, or closes first, raises OSError."""
    line = stream.readline(MAX_REQUEST_BYTES + 1)
    if not line:
        raise OSError("it closed before sending a request")
    if len(line) > MAX_REQUEST_BYTES and not line.endswith(b"\n"):
        raise _BadRequest(f"a request longer than {MAX_REQUEST_BYTES} bytes, refused unread")
    try:
        request = json.loads(line)
    except (ValueError, RecursionError) as exc:
        raise _BadRequest(f"not a JSON request ({type(exc).__name__})") from exc
    if not isinstance(request, dict):
        raise _BadRequest(f"not a JSON object ({type(request).__name__})")
    return request


def _serve_one(keeper: Keeper, conn: socket.socket) -> None:
    """One request and its reply."""
    conn.settimeout(REQUEST_TIMEOUT_S)
    with conn, conn.makefile("rwb") as stream:
        try:
            reply = keeper.answer(_read_request(stream))
        except _BadRequest as exc:
            _log(f"a client sent {exc}; answered with a refusal")
            reply = {"ok": False, "error": str(exc)}
        stream.write(json.dumps(reply).encode() + b"\n")
        stream.flush()


def _loop(keeper: Keeper, listener: socket.socket) -> None:
    """Serve until a terminating signal: nothing one client does ends it. A client gone,
    or silent past REQUEST_TIMEOUT_S, is one line in the log; any other failure of one
    request is one line naming its type, and the loop serves on."""
    while True:
        try:
            conn, _addr = listener.accept()
        except TimeoutError:
            keeper.watch()
            continue
        try:
            _serve_one(keeper, conn)
        except OSError as exc:
            _log(f"a client went away before its reply, or said nothing in "
                 f"{REQUEST_TIMEOUT_S:g}s ({exc}); serving on")
        except Exception as exc:  # noqa: BLE001 — the connection boundary; logged, typed
            _log(f"a request failed with {type(exc).__name__}: {exc}; its client got no "
                 "answer; serving on")


def serve(home: str, cwd: str, command: list[str], ready_s: float,
          env: dict[str, str]) -> int:
    keeper = Keeper(home, cwd, command, ready_s, env)
    if keeper.snapshot is None:
        print(f"eval_daemon_keeper: {home} holds no snapshot id; `capability-daemon.sh up` "
              "takes the snapshot this keeper restores", file=sys.stderr)
        return REFUSED
    for signum in TERMINATING:
        signal.signal(signum, SIGNALS)
    listener = _listen(home)
    _write_pid(os.path.join(home, KEEPER_PIDFILE), os.getpid())
    try:
        keeper.start("up")
        _loop(keeper, listener)
    except Refused as exc:
        print(f"eval_daemon_keeper: up: {exc}; the keeper exits and nothing runs for "
              f"{home}: see {home}/daemon.log, fix what it says, then run "
              "`capability-daemon.sh up`", file=sys.stderr, flush=True)
        return 1
    finally:
        for signum in TERMINATING:
            signal.signal(signum, signal.SIG_IGN)
        keeper.stop()
        # The files first, then the socket: a client waiting on it returns only once
        # nothing of this keeper is left in the home.
        _unlink(os.path.join(home, SOCKET_NAME))
        _unlink(os.path.join(home, KEEPER_PIDFILE))
        listener.close()
    return 0


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def _connect(home: str, wait_for: int | None) -> socket.socket | None:
    """A connection to the home's keeper, or None when none answers. With `wait_for`,
    knock again while that process (the keeper `up` just launched) is alive."""
    path = os.path.join(home, SOCKET_NAME)
    deadline = time.monotonic() + ANSWER_TIMEOUT_S
    while True:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            conn.connect(path)
            return conn
        except OSError:
            conn.close()
        if wait_for is None or not _alive(wait_for) or time.monotonic() > deadline:
            return None
        time.sleep(0.1)


def no_keeper(home: str) -> str:
    """Why no reset can be carried out for a home no keeper answers, and what works from
    there: the script's own daemon left without its keeper is stopped by `down`; a
    daemon started any other way is stopped by its pid."""
    answering, unclear = probe_control(home)
    recorded = _read_pid(os.path.join(home, DAEMON_PIDFILE))
    if unclear is not None and recorded is not None and _alive(recorded):
        return (f"no keeper runs for {home}, and something answers its control socket "
                f"without saying which process it is ({unclear}); daemon.pid names pid "
                f"{recorded}, which runs: nothing was stopped or replaced. Run "
                f"`capability-daemon.sh down`, which stops pid {recorded}, then `up`.")
    if unclear is not None:
        return _unknown_answer(home, unclear, "`capability-daemon.sh up`")
    if answering is None:
        return (f"no daemon started by `capability-daemon.sh up` runs for {home} (no keeper "
                f"answers on {SOCKET_NAME}): nothing was stopped or replaced. Run "
                "`capability-daemon.sh up`; to score a model of your choice, give it to "
                "`up`: FERMIX_CAP_SEED_ARGS='--dev-provider <id>' (that provider block of "
                "~/.fermix-dev/config.toml) or '--provider <id> --model <model>' (its key in "
                "`up`'s environment).")
    if _read_pid(os.path.join(home, DAEMON_PIDFILE)) == answering:
        return (f"the daemon `capability-daemon.sh up` started for {home} (pid {answering}) "
                "runs without its keeper (the keeper was killed, or `up` predates it): "
                "nothing was stopped or replaced. Run `capability-daemon.sh down`, which "
                f"stops pid {answering}, then `up`.")
    return (f"a daemon started outside capability-daemon.sh answers for {home} (pid "
            f"{answering}) and no keeper runs: nothing was stopped or replaced. Stop it "
            f"(`kill {answering}`), then run `capability-daemon.sh up`.")


def _keeper_stopped(home: str) -> str:
    return (f"the keeper `up` started for {home} stopped before its daemon answered: see "
            f"{home}/daemon.log (its last lines follow), fix what it says, then run "
            "`capability-daemon.sh up`")


def _no_answer(home: str, reason: str | None) -> str:
    if reason is None:
        return (f"the keeper of {home} did not answer within {ANSWER_TIMEOUT_S}s; a reset "
                f"may still be under way: see {home}/daemon.log, then run "
                "`capability-daemon.sh check`")
    return (f"the keeper of {home} closed the connection without an answer ({reason}): it "
            f"has stopped; see {home}/daemon.log, then run `capability-daemon.sh down` and "
            "`up`")


def ask(op: str, home: str, project: str | None, wait_for: int | None,
        for_up: bool = False) -> int:
    conn = _connect(home, wait_for)
    if conn is None:
        if wait_for is not None:                # `up`'s own keeper: it went, unanswered
            print(f"eval_daemon_keeper: {_keeper_stopped(home)}", file=sys.stderr)
            return REFUSED
        if for_up and _nothing_answers(home):
            return NOTHING_RUNS
        print(f"eval_daemon_keeper: {no_keeper(home)}", file=sys.stderr)
        return REFUSED
    conn.settimeout(ANSWER_TIMEOUT_S)
    try:
        with conn, conn.makefile("rwb") as stream:
            stream.write(json.dumps({"op": op, "project": project}).encode() + b"\n")
            stream.flush()
            line = stream.readline()
    except TimeoutError:
        line, reason = b"", None
    except OSError as exc:
        line, reason = b"", str(exc)
    else:
        reason = "the connection closed"
    if not line:
        why = _keeper_stopped(home) if wait_for is not None and reason is not None \
            else _no_answer(home, reason)
        print(f"eval_daemon_keeper: {why}", file=sys.stderr)
        return REFUSED
    reply = json.loads(line)
    if not reply.get("ok"):
        print(f"eval_daemon_keeper: {reply.get('error')}", file=sys.stderr)
        return REFUSED
    revived = reply.get("revived")
    if revived:
        print(f"eval_daemon_keeper: WARNING the daemon `up` started (pid {revived['pid']}) "
              f"had exited by itself with code {revived['code']} at {revived['at']}, before "
              "this reset started it again: see daemon.log", file=sys.stderr)
    print(f"eval home {home}: daemon pid {reply['daemon_pid']}, snapshot "
          f"{reply['snapshot_id']}, Opik project {reply['project'] or '(none)'}")
    return 0


def answering(home: str) -> int:
    """`capability-daemon.sh down`'s question: which daemon answers the home now."""
    try:
        pid = control_pid(home)
    except Refused as exc:
        print(f"eval_daemon_keeper: {exc}", file=sys.stderr)
        return REFUSED
    if pid is None:
        return NOTHING_RUNS
    print(pid)
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    # `serve`'s daemon command is everything after `--`, the keeper's own flags before.
    command = argv[argv.index("--") + 1:] if "--" in argv else []
    argv = argv[:argv.index("--")] if "--" in argv else argv
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="mode", required=True)
    served = sub.add_parser("serve")
    served.add_argument("home")
    served.add_argument("--cwd", required=True)
    served.add_argument("--ready-timeout", type=float, required=True)
    asked = sub.add_parser("ask")
    asked.add_argument("op", choices=OPS)
    asked.add_argument("home")
    asked.add_argument("--project")
    asked.add_argument("--wait-for", type=int)
    asked.add_argument("--for-up", action="store_true")
    sub.add_parser("answering").add_argument("home")
    args = parser.parse_args(argv)
    home = os.path.realpath(os.path.expanduser(args.home))
    if args.mode == "answering":
        return answering(home)
    if args.mode == "ask":
        return ask(args.op, home, args.project, args.wait_for, args.for_up)
    if not command:
        parser.error("serve needs the daemon's command after --")
    if not 0 < args.ready_timeout <= MAX_READY_S:
        parser.error(f"--ready-timeout (READY_TIMEOUT) must be in (0, {MAX_READY_S}] s: a "
                     f"reset's boot must fit the {ANSWER_TIMEOUT_S} s a client waits for it")
    try:
        env = read_environment(sys.stdin.buffer, home)
    except ValueError as exc:
        parser.error(f"the daemon's environment: {exc}; nothing was started")
    return serve(home, args.cwd, command, args.ready_timeout, env)


if __name__ == "__main__":
    sys.exit(main())
