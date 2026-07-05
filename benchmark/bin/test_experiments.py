#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8"]
# ///
"""Integration tests for evallib.experiments against the LIVE local Opik.

These verify the write side end-to-end (the finding-#1 trace-link path returns
204) using a real trace from the dev project. They self-clean (everything is
named *DELETEME* and deleted on teardown) and SKIP cleanly if Opik is down or the
project has no traces yet. Run: `uv run bin/test_experiments.py`.

Env: OPIK_BASE_URL (default http://localhost:5173/api/v1/private),
     OPIK_PROJECT  (default fermix-dev).
"""
from __future__ import annotations

import os
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

from evallib import experiments as ex  # noqa: E402
from evallib.opik import OpikClient, OpikError  # noqa: E402

BASE = os.environ.get("OPIK_BASE_URL", "http://localhost:5173/api/v1/private")
PROJECT = os.environ.get("OPIK_PROJECT", "fermix-dev")


def _opik_up() -> bool:
    try:
        urllib.request.urlopen(BASE.rstrip("/") + "/projects?size=1", timeout=4).read()
        return True
    except (urllib.error.URLError, OSError):
        return False


pytestmark = pytest.mark.skipif(not _opik_up(), reason="local Opik not reachable")


def _score_present(trace_id: str, name: str, tries: int = 6, delay: float = 0.5) -> bool:
    """Poll the trace until `name` shows in its feedback_scores (Opik ingests
    scores asynchronously)."""
    client = OpikClient(BASE, PROJECT)
    for _ in range(tries):
        scores = client.get_trace(trace_id).get("feedback_scores") or []
        if any(s.get("name") == name for s in scores):
            return True
        time.sleep(delay)
    return False


# --- pure (no network) ------------------------------------------------------

def test_stable_id_is_deterministic_and_v7():
    a = ex.stable_id("task:capital_france")
    b = ex.stable_id("task:capital_france")
    assert a == b
    assert a[14] == "7"                              # version nibble
    assert ex.stable_id("other") != a


def test_uuid7_is_unique_and_v7():
    assert ex.uuid7() != ex.uuid7()
    assert ex.uuid7()[14] == "7"


# --- live writeback ---------------------------------------------------------

@pytest.fixture
def writer():
    return ex.ExperimentWriter(BASE)


@pytest.fixture
def a_trace_id():
    traces = OpikClient(BASE, PROJECT).recent_traces(size=1)
    if not traces:
        pytest.skip(f"no traces in project {PROJECT} to link")
    return traces[0]["id"]


def test_full_writeback_roundtrip(writer, a_trace_id):
    ds = "cap-eval-test-DELETEME"
    item_id = ex.stable_id("cap-eval-test:item0")
    exp_id = ex.stable_id("cap-eval-test:exp0")
    created = []
    try:
        # dataset + item
        writer.create_dataset(ds, "capability eval writeback test")
        writer.create_dataset(ds, "idempotent second create")     # 409 tolerated
        assert writer.dataset_id(ds) is not None
        writer.upsert_dataset_item(ds, item_id, {"input": "q?", "expected_output": "a"})
        writer.upsert_dataset_item(ds, item_id, {"input": "q?", "expected_output": "a2"})  # upsert

        # experiment + the finding-#1 link of an existing trace by id
        writer.create_experiment(exp_id, "cap-eval-cfg-DELETEME", ds)
        created.append("exp")
        writer.link_trace(exp_id, item_id, a_trace_id)            # must not raise (204)

        # feedback score on the real trace — and ASSERT it actually attached
        # (the batch endpoint 204s but silently drops scores missing project_name).
        writer.put_feedback_scores([{"id": a_trace_id, "name": "cap_eval_DELETEME",
                                     "value": 0.5, "source": "sdk", "reason": "test"}], PROJECT)
        assert _score_present(a_trace_id, "cap_eval_DELETEME"), "feedback score did not attach"
        writer.delete_feedback_score(a_trace_id, "cap_eval_DELETEME")
    finally:
        if "exp" in created:
            writer.delete_experiment(exp_id)
        dsid = writer.dataset_id(ds)
        if dsid:
            writer.delete_dataset(dsid)
        # belt-and-suspenders: ensure no spike score lingers on the real trace
        try:
            writer.delete_feedback_score(a_trace_id, "cap_eval_DELETEME")
        except Exception:
            pass


def test_bad_request_raises(writer):
    with pytest.raises(ex.OpikWriteError):
        writer.create_experiment("not-a-uuid", "x", "nonexistent-dataset-DELETEME")


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
