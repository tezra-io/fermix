#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7", "certifi"]
# ///
"""The write side of evallib.experiments against a LIVE Opik, run only when asked for.

This is not a developer test: `make tests`, the gate and CI never run it, and it never
starts because a port happens to answer. `make opik-live` (or
`uv run bin/live_opik_writeback.py`) is the one way in.

It WRITES to the Opik a runner would write to: config.yaml's `opik` section under the
runners' own environment (OPIK_BASE_URL, OPIK_PROJECT, OPIK_API_KEY, OPIK_WORKSPACE).
It makes one dataset with one item, one experiment linked to the project's newest
trace, and one feedback score on that trace, each named for this run alone
(`...-<run>-DELETEME`, so two runs at once share nothing) and each deleted before it
ends. The trace itself is read and never changed beyond that score.

Asked for, it runs: an Opik that cannot be reached, or a project with no trace to
link, fails here and is never skipped. It proves what the hermetic tests cannot: that
a live Opik takes the requests `bin/test_experiments.py` holds the writer to, links an
existing trace by its id, keeps a score that names its project, and refuses a
malformed experiment.
"""
from __future__ import annotations

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import pytest  # noqa: E402

from evallib import config as cfgmod  # noqa: E402
from evallib import experiments as ex  # noqa: E402
from evallib.opik import OpikClient, OpikError  # noqa: E402

# Opik ingests a score a moment after it answers 204: the trace is read until the
# score shows, at most this many times, this far apart.
SCORE_READS = 12
SCORE_READ_GAP_S = 0.5
# A removal Opik did not take (a slow answer, a 5xx) is asked for again, this many
# times in all, before the run says what it could not remove.
REMOVAL_TRIES = 3


@pytest.fixture(scope="module")
def opik():
    return cfgmod.load(SKILL_DIR).opik


@pytest.fixture
def writer(opik):
    return ex.ExperimentWriter(opik.base_url, api_key=opik.api_key, workspace=opik.workspace)


@pytest.fixture
def reader(opik):
    return OpikClient(opik.base_url, opik.project, api_key=opik.api_key,
                      workspace=opik.workspace)


@pytest.fixture
def run():
    """This run's own mark, in every name it writes."""
    return ex.uuid7()[-12:]


def _score_names(reader, trace_id: str) -> list[str]:
    scores = reader.get_trace(trace_id).get("feedback_scores") or []
    return [score.get("name") for score in scores]


def _score_reads(reader, trace_id: str, name: str, shows: bool) -> bool:
    """Whether the trace comes to hold the score (`shows`), or to hold it no more,
    within SCORE_READS reads."""
    for _ in range(SCORE_READS):
        if (name in _score_names(reader, trace_id)) == shows:
            return True
        time.sleep(SCORE_READ_GAP_S)
    return False


def test_a_run_writes_links_scores_and_removes_all_of_it(opik, writer, reader, run):
    traces = reader.recent_traces(size=1)
    assert traces, (f"project {opik.project!r} at {opik.base_url} holds no trace to link: "
                    "name a project that has one with OPIK_PROJECT")
    trace_id = traces[0]["id"]
    dataset = f"opik-live-{run}-DELETEME"
    score = f"opik_live_{run}_DELETEME"
    item_id, experiment_id = ex.uuid7(), ex.uuid7()
    made_experiment = scored = shown = False
    try:
        writer.create_dataset(dataset, "live write-back check, safe to delete")
        writer.create_dataset(dataset, "a second create of the same name is taken")
        assert writer.dataset_id(dataset) is not None
        writer.upsert_dataset_item(dataset, item_id, {"input": "q?", "expected_output": "a"})
        writer.upsert_dataset_item(dataset, item_id, {"input": "q?", "expected_output": "a2"})

        writer.create_experiment(experiment_id, f"opik-live-{run}-DELETEME", dataset)
        made_experiment = True
        writer.link_trace(experiment_id, item_id, trace_id)

        scored = True
        writer.put_feedback_scores([{"id": trace_id, "name": score, "value": 0.5,
                                     "source": "sdk", "reason": "live write-back check"}],
                                   opik.project)
        shown = _score_reads(reader, trace_id, score, shows=True)
        assert shown, "Opik answered 204 and kept no score"
    finally:
        # Each removal is tried whatever the one before it did, and one that did not
        # go through fails the run by name: nothing is left behind unsaid.
        left = []
        if scored:
            left += _removal(f"score {score} on trace {trace_id}",
                             lambda: _remove_score(writer, reader, trace_id, score))
        if scored and not shown:
            # A delete can reach Opik before the score it was sent to remove does.
            left.append(f"score {score} on trace {trace_id} (it never showed, so it may "
                        "still arrive after its delete)")
        if made_experiment:
            left += _removal(f"experiment {experiment_id}",
                             lambda: writer.delete_experiment(experiment_id))
        left += _removal(f"dataset {dataset}", lambda: _delete_dataset(writer, dataset))
        assert not left, "removal not confirmed, look in Opik for: " + "; ".join(left)


def _delete_dataset(writer, name: str) -> None:
    dataset_id = writer.dataset_id(name)
    if dataset_id is not None:
        writer.delete_dataset(dataset_id)


def _remove_score(writer, reader, trace_id: str, name: str) -> None:
    """Delete the score and read the trace until it is gone: this one sits on a trace
    the run did not make, so its removal is seen, not assumed."""
    writer.delete_feedback_score(trace_id, name)
    if not _score_reads(reader, trace_id, name, shows=False):
        raise ex.OpikWriteError(f"still on the trace {SCORE_READS} reads after its delete")


def _removal(what: str, remove) -> list[str]:
    """Nothing once `remove` went through, tried REMOVAL_TRIES times at most; else
    what could not be removed, with the last reason."""
    reason = None
    for _ in range(REMOVAL_TRIES):
        try:
            remove()
            return []
        except (ex.OpikWriteError, OpikError) as exc:
            reason = exc
    return [f"{what} ({reason})"]


def test_a_malformed_experiment_is_refused(writer, run):
    # Refused by Opik with a 4xx of its own; an Opik that is down is not a refusal.
    with pytest.raises(ex.OpikWriteError, match=r"HTTP 4\d\d"):
        writer.create_experiment("not-a-uuid", "x", f"opik-live-{run}-no-such-dataset-DELETEME")


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
