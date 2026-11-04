"""Starting and stopping one fixture application around one task attempt.

Every attempt gets a FRESH state file: the fixture is launched pointing at a
path that must not exist yet, and it counts as ready once it has written that
file with no events in it (every fixture writes it before building its window).
The process is stopped on every path, a refused start included, so a run never
leaves a fixture window behind for the next attempt to act on.
"""

from __future__ import annotations

import os
import subprocess
import time

from desktoplib import oracle

# Bounded waits, each with what happens at its cap.
READY_TRIES = 100            # × READY_STEP_S: no state file by then -> fixture_not_ready
READY_STEP_S = 0.1
WINDOW_SETTLE_S = 2.0        # after the state file, for the window to map and register
STOP_TIMEOUT_S = 5.0         # after SIGTERM, then SIGKILL
SELF_TEST_TIMEOUT_S = 120.0  # a self-test that runs longer is a failed preflight
STATE_POLL_S = 0.1


class FixtureError(RuntimeError):
    """The fixture could not be run as an attempt needs. `kind` names why."""

    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind


class FixtureProcess:
    """One fixture process; a context manager that stops it on every exit."""

    def __init__(self, argv: list[str], env: dict, state_file: str, log_path: str,
                 settle_s: float = WINDOW_SETTLE_S, ready_tries: int = READY_TRIES):
        if not argv or not state_file:
            raise ValueError("a fixture needs a command and a state file")
        self.argv, self.env, self.state_file = list(argv), dict(env), state_file
        self.log_path, self.settle_s, self.ready_tries = log_path, settle_s, ready_tries
        self._process: subprocess.Popen | None = None
        self._log = None

    def __enter__(self) -> "FixtureProcess":
        self.start()
        return self

    def __exit__(self, *_exc) -> bool:
        self.stop()
        return False

    def start(self) -> None:
        if os.path.exists(self.state_file):
            raise FixtureError("state_exists", f"{self.state_file} already exists; every "
                               "attempt starts from a fresh state file")
        self._log = open(self.log_path, "w", encoding="utf-8")
        try:
            self._process = self._spawn()
            self._wait_ready()
            time.sleep(self.settle_s)
            if not self.alive():
                raise FixtureError("fixture_exited", self._exited_message())
        except BaseException:
            self.stop()
            raise

    def _spawn(self) -> subprocess.Popen:
        try:
            return subprocess.Popen(self.argv, env={**os.environ, **self.env},
                                    stdin=subprocess.DEVNULL, stdout=self._log,
                                    stderr=subprocess.STDOUT)
        except OSError as exc:
            raise FixtureError("launch_failed", f"cannot start {self.argv[0]}: {exc}") from exc

    def _wait_ready(self) -> None:
        for _ in range(self.ready_tries):
            if not self.alive():
                raise FixtureError("fixture_exited", self._exited_message())
            if self._fresh_state_written():
                return
            time.sleep(READY_STEP_S)
        raise FixtureError("fixture_not_ready", f"no state file at {self.state_file} after "
                           f"{self.ready_tries * READY_STEP_S:.0f} s (log: {self.log_path})")

    def _fresh_state_written(self) -> bool:
        if not os.path.exists(self.state_file):
            return False
        if oracle.read_state(self.state_file):
            raise FixtureError("fixture_not_fresh", f"{self.state_file} held events before the "
                               "task was sent")
        return True

    def _exited_message(self) -> str:
        return (f"the fixture exited with status {self._process.returncode} "
                f"(log: {self.log_path})")

    def alive(self) -> bool:
        return self._process is not None and self._process.poll() is None

    def stop(self) -> None:
        if self._process is not None and self._process.poll() is None:
            self._process.terminate()
            try:
                self._process.wait(STOP_TIMEOUT_S)
            except subprocess.TimeoutExpired:
                self._process.kill()
                self._process.wait(STOP_TIMEOUT_S)
        if self._log is not None:
            self._log.close()
            self._log = None


def wait_for_settled_state(path: str, quiet_s: float, max_s: float) -> tuple[list[dict], bool]:
    """The fixture's events once they stop changing for `quiet_s`. A fixture may
    record a moment after the turn's reply (the macOS one samples its fields
    four times a second). At `max_s` the last read is returned with
    `settled=False`, which the attempt records."""
    deadline = time.monotonic() + max_s
    events = oracle.read_state(path)
    quiet_since = time.monotonic()
    while time.monotonic() < deadline:
        time.sleep(STATE_POLL_S)
        latest = oracle.read_state(path)
        if latest != events:
            events, quiet_since = latest, time.monotonic()
            continue
        if time.monotonic() - quiet_since >= quiet_s:
            return events, True
    return events, False


def self_test_controls(argv: list[str], env: dict, state_file: str,
                       timeout_s: float = SELF_TEST_TIMEOUT_S) -> set[str]:
    """Run the fixture's own `--self-test` (which drives every control once) and
    answer the control names it recorded: the preflight that the corpus and the
    fixture agree on what is there to assert on."""
    try:
        done = subprocess.run([*argv, "--self-test"], env={**os.environ, **env},
                              stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=timeout_s, check=False)
    except subprocess.TimeoutExpired as exc:
        raise FixtureError("self_test_failed",
                           f"the fixture self-test ran past {timeout_s:.0f} s") from exc
    if done.returncode != 0:
        tail = (done.stdout + done.stderr).strip()[-600:]
        raise FixtureError("self_test_failed", f"the fixture self-test exited "
                           f"{done.returncode}: {tail}")
    return {event["control"] for event in oracle.read_state(state_file)}
