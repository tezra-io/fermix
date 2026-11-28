#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7", "certifi"]
# ///
"""Tests for evallib.experiments: the ids it mints and every request its writer sends.

Hermetic. The writer talks to a server this file starts on a loopback port of its
own, which records each request and answers only what the test scripted; a request no
test scripted is answered 500. No Opik is read or written here, on any machine: the
round trip against a live one is `bin/live_opik_writeback.py`, which runs only when
someone asks for it (`make opik-live`). The shapes asserted here are the ones that
module's docstring lists as checked against a live Opik, so a change to one is a change
to both. Run: `uv run bin/test_experiments.py`.
"""
from __future__ import annotations

import glob
import http.server
import json
import os
import re
import sys
import threading
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

import live_opik_writeback as live  # noqa: E402  (imported, never run from here)
from evallib import experiments as ex  # noqa: E402

PREFIX = "/api/v1/private"
# Opik's own words for the failure that showed this file was once not hermetic.
OPIK_500 = {"code": 500, "message": "There was an error processing your request."}


# --- ids (pure) -------------------------------------------------------------

def test_stable_id_is_deterministic_and_v7():
    a = ex.stable_id("task:capital_france")
    b = ex.stable_id("task:capital_france")
    assert a == b
    assert a[14] == "7"                              # version nibble
    assert ex.stable_id("other") != a


def test_uuid7_is_unique_and_v7():
    assert ex.uuid7() != ex.uuid7()
    assert ex.uuid7()[14] == "7"


# --- the writer's requests, against this file's own server -------------------

class _Recorder(http.server.BaseHTTPRequestHandler):
    """Records (method, path, JSON body) and answers the next scripted (status, body)."""

    def _answer(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        self.server.seen.append((self.command, self.path, json.loads(raw) if raw else None))
        scripted = self.server.answers
        status, body = scripted.pop(0) if scripted else (500, "no answer scripted")
        payload = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = do_PUT = do_DELETE = _answer

    def log_message(self, *_args):
        pass


@pytest.fixture(scope="module")
def _server():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Recorder)
    server.seen, server.answers = [], []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=10)


@pytest.fixture
def opik(_server):
    """The server with nothing seen and nothing scripted, and a writer aimed at it."""
    _server.seen.clear()
    _server.answers.clear()
    _server.writer = ex.ExperimentWriter(
        f"http://127.0.0.1:{_server.server_address[1]}{PREFIX}")
    return _server


def test_a_dataset_is_created_by_name_and_one_that_exists_is_taken(opik):
    opik.answers += [(201, None), (409, {"errors": ["Dataset already exists"]})]
    opik.writer.create_dataset("cap tasks", "ground truth")
    opik.writer.create_dataset("cap tasks", "ground truth")
    assert opik.seen == [("POST", f"{PREFIX}/datasets",
                          {"name": "cap tasks", "description": "ground truth"})] * 2


def test_a_dataset_is_looked_up_by_its_quoted_name(opik):
    opik.answers += [(200, {"content": [{"id": "d-1", "name": "cap tasks"}]}),
                     (200, {"content": []})]
    assert opik.writer.dataset_id("cap tasks") == "d-1"
    assert opik.writer.dataset_id("cap tasks") is None
    assert opik.seen == [("GET", f"{PREFIX}/datasets?name=cap%20tasks&size=1", None)] * 2


def test_a_dataset_item_is_put_as_one_sdk_item(opik):
    opik.answers += [(204, None)]
    opik.writer.upsert_dataset_item("cap tasks", "item-1", {"input": "q?", "expected": "a"})
    assert opik.seen == [("PUT", f"{PREFIX}/datasets/items", {
        "dataset_name": "cap tasks",
        "items": [{"id": "item-1", "source": "sdk", "data": {"input": "q?", "expected": "a"}}]})]


def test_an_experiment_is_created_with_metadata_only_when_given(opik):
    opik.answers += [(201, None), (409, {"errors": ["Experiment already exists"]})]
    opik.writer.create_experiment("e-1", "cfg", "cap tasks")
    opik.writer.create_experiment("e-1", "cfg", "cap tasks", metadata={"run_id": "r-1"})
    bare = {"id": "e-1", "name": "cfg", "dataset_name": "cap tasks"}
    assert opik.seen == [("POST", f"{PREFIX}/experiments", bare),
                         ("POST", f"{PREFIX}/experiments", {**bare,
                                                            "metadata": {"run_id": "r-1"}})]


def test_a_trace_is_linked_by_its_id_alone(opik):
    # The trace the daemon exported is named, never sent again: an item carrying a
    # trace payload would duplicate it.
    opik.answers += [(204, None), (204, None)]
    opik.writer.link_trace("e-1", "item-1", "t-1", item_id="x-1")
    opik.writer.link_trace("e-1", "item-1", "t-1")
    [(method, path, named), (_method, _path, minted)] = opik.seen
    assert (method, path) == ("POST", f"{PREFIX}/experiments/items")
    assert named == {"experiment_items": [{"id": "x-1", "experiment_id": "e-1",
                                           "dataset_item_id": "item-1", "trace_id": "t-1"}]}
    [item] = minted["experiment_items"]
    assert set(item) == {"id", "experiment_id", "dataset_item_id", "trace_id"}
    assert item["id"][14] == "7"


def test_feedback_scores_carry_the_project_and_go_a_thousand_at_a_time(opik):
    # Opik answers 204 and drops a score with no project_name, so the writer stamps it.
    opik.answers += [(204, None), (204, None)]
    scores = [{"id": f"t-{n}", "name": "cap", "value": 1.0, "source": "sdk"}
              for n in range(1001)]
    opik.writer.put_feedback_scores(scores, "proj-x")
    assert [(method, path, len(body["scores"])) for method, path, body in opik.seen] == [
        ("PUT", f"{PREFIX}/traces/feedback-scores", 1000),
        ("PUT", f"{PREFIX}/traces/feedback-scores", 1)]
    sent = [score for _method, _path, body in opik.seen for score in body["scores"]]
    assert sent == [{**score, "project_name": "proj-x"} for score in scores]
    assert "project_name" not in scores[0]           # the caller's rows are left alone


def test_a_score_an_experiment_and_a_dataset_are_deleted_by_id(opik):
    opik.answers += [(204, None)] * 3
    opik.writer.delete_feedback_score("t-1", "cap")
    opik.writer.delete_experiment("e-1")
    opik.writer.delete_dataset("d-1")
    assert opik.seen == [
        ("POST", f"{PREFIX}/traces/t-1/feedback-scores/delete", {"name": "cap"}),
        ("POST", f"{PREFIX}/experiments/delete", {"ids": ["e-1"]}),
        ("DELETE", f"{PREFIX}/datasets/d-1", None)]


WRITER_CALLS = {
    "create_dataset": lambda w: w.create_dataset("cap tasks"),
    "dataset_id": lambda w: w.dataset_id("cap tasks"),
    "upsert_dataset_item": lambda w: w.upsert_dataset_item("cap tasks", "item-1", {}),
    "delete_dataset": lambda w: w.delete_dataset("d-1"),
    "create_experiment": lambda w: w.create_experiment("e-1", "cfg", "cap tasks"),
    "link_trace": lambda w: w.link_trace("e-1", "item-1", "t-1"),
    "delete_experiment": lambda w: w.delete_experiment("e-1"),
    "put_feedback_scores": lambda w: w.put_feedback_scores([{"id": "t-1"}], "proj-x"),
    "delete_feedback_score": lambda w: w.delete_feedback_score("t-1", "cap"),
}


def test_every_call_of_the_writer_is_held_to_its_failure_here():
    public = {name for name, value in vars(ex.ExperimentWriter).items()
              if callable(value) and not name.startswith("_")}
    assert public == set(WRITER_CALLS)


@pytest.mark.parametrize("name", sorted(WRITER_CALLS))
def test_an_answer_a_call_does_not_take_raises_with_its_status_and_words(opik, name):
    opik.answers += [(500, OPIK_500)]
    with pytest.raises(ex.OpikWriteError) as raised:
        WRITER_CALLS[name](opik.writer)
    assert "HTTP 500" in str(raised.value)
    assert "error processing your request" in str(raised.value)
    assert len(opik.seen) == 1                       # said once, never tried again


@pytest.mark.parametrize("name", sorted(set(WRITER_CALLS) - {"create_dataset",
                                                             "create_experiment"}))
def test_only_the_two_creates_take_a_conflict(opik, name):
    opik.answers += [(409, {"errors": ["conflict"]})]
    with pytest.raises(ex.OpikWriteError, match="HTTP 409"):
        WRITER_CALLS[name](opik.writer)


@pytest.mark.parametrize("failure", [
    urllib.error.URLError(ConnectionRefusedError(61, "Connection refused")),
    TimeoutError("The read operation timed out"),    # an OSError, not a URLError
])
def test_a_server_that_cannot_be_reached_or_read_raises_the_writers_own_error(
        monkeypatch, failure):
    def refuse(_request, timeout=None):
        raise failure

    monkeypatch.setattr(ex.urllib.request, "urlopen", refuse)
    with pytest.raises(ex.OpikWriteError) as raised:
        ex.ExperimentWriter("http://opik.invalid/api/v1/private").dataset_id("cap tasks")
    assert raised.value.__cause__ is failure


# --- the developer tests are the same set on every machine -------------------

# A test that skips by what the machine holds is a different gate on each machine.
# This file once ran its writes whenever a local Opik answered: the gate then wrote
# to the developer's own Opik, CI skipped the same tests, and two gates at once
# collided on its fixed names. The count below only shrinks. The two left read the
# leaderboard store a capability run leaves under reports/, where one exists.
SKIPS_ALLOWED = {"test_pricing.py": 2}
LIVE_CHECK = os.path.join(HERE, "live_opik_writeback.py")
# Matched by the call's own name, so an import under another name is caught too.
SKIP = re.compile(r"\bskipif\(|\.skip\(|\bimportorskip\(|\.skipTest\(|"
                  r"\bmark\.skip\b|\bunittest\.skip")


def test_no_developer_test_skips_by_what_the_machine_holds():
    found = {}
    for path in sorted(glob.glob(os.path.join(HERE, "test_*.py"))):
        with open(path, encoding="utf-8") as fh:
            count = len(SKIP.findall(fh.read()))
        if count:
            found[os.path.basename(path)] = count
    assert found == SKIPS_ALLOWED


def test_the_tests_loop_runs_every_test_file_and_nothing_else():
    # `make tests` is what the gate and CI run. The live Opik check is no test file,
    # so it can never be in this loop.
    with open(os.path.join(os.path.dirname(HERE), "Makefile"), encoding="utf-8") as fh:
        [loop] = [line for line in fh.read().splitlines()
                  if line.lstrip().startswith("@for t in ")]
    named = loop.split(" in ", 1)[1].split(";", 1)[0].split()
    files = [os.path.basename(path)[len("test_"):-len(".py")]
             for path in glob.glob(os.path.join(HERE, "test_*.py"))]
    assert sorted(named) == sorted(files)
    assert not os.path.basename(LIVE_CHECK).startswith("test_") and os.path.isfile(LIVE_CHECK)


def test_the_live_check_never_decides_by_itself_whether_to_run():
    # Asked for, it runs: an Opik that is down is its failure, and no skip hides it.
    with open(LIVE_CHECK, encoding="utf-8") as fh:
        source = fh.read()
    assert not SKIP.search(source)


# --- what the live check leaves behind, with no Opik ---------------------------

class _Trace:
    """A reader whose trace holds the score for its first `reads_held` reads."""

    def __init__(self, reads_held: int):
        self.reads_held, self.reads = reads_held, 0

    def get_trace(self, _trace_id):
        self.reads += 1
        held = self.reads <= self.reads_held
        return {"feedback_scores": [{"name": "s-1"}] if held else []}


class _Deletes:
    def __init__(self):
        self.deleted = []

    def delete_feedback_score(self, trace_id, name):
        self.deleted.append((trace_id, name))


@pytest.fixture
def no_gap(monkeypatch):
    monkeypatch.setattr(live.time, "sleep", lambda _seconds: None)


def test_a_removal_opik_did_not_take_is_asked_for_again_and_then_said(no_gap):
    asked = []

    def slow_twice():
        asked.append(1)
        if len(asked) < live.REMOVAL_TRIES:
            raise ex.OpikWriteError("POST /x: timed out")

    assert live._removal("score s-1", slow_twice) == [] and len(asked) == live.REMOVAL_TRIES

    def never():
        asked.append(1)
        raise ex.OpikWriteError("POST /x: HTTP 500: 'down'")

    del asked[:]
    assert live._removal("score s-1", never) == ["score s-1 (POST /x: HTTP 500: 'down')"]
    assert len(asked) == live.REMOVAL_TRIES


def test_a_score_is_removed_only_once_the_trace_is_read_without_it(no_gap):
    writer, trace = _Deletes(), _Trace(reads_held=3)
    live._remove_score(writer, trace, "t-1", "s-1")
    assert writer.deleted == [("t-1", "s-1")] and trace.reads == 4
    stuck = _Trace(reads_held=10 ** 6)
    with pytest.raises(ex.OpikWriteError, match="still on the trace"):
        live._remove_score(writer, stuck, "t-1", "s-1")
    assert stuck.reads == live.SCORE_READS


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
