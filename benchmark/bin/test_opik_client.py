#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8"]
# ///
"""Tests for Opik authentication, bounded reads/retries, correlation and settlement.

Pure; urlopen is monkeypatched, no network. Run: `uv run bin/test_opik_client.py`.
"""
from __future__ import annotations

import http.client
import io
import json
import os
import sys
from datetime import datetime, timezone

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from evallib.opik import OpikClient, OpikError  # noqa: E402
import evallib.opik as opik_mod  # noqa: E402


class _Resp(io.BytesIO):
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def _capture(monkeypatch):
    captured = {}

    def fake_urlopen(req, timeout=None):
        captured["headers"] = {k.lower(): v for k, v in req.header_items()}
        return _Resp(b"{}")

    monkeypatch.setattr(opik_mod.urllib.request, "urlopen", fake_urlopen)
    return captured


def _get_sequence(monkeypatch, *responses):
    pending = iter(responses)
    calls = []
    sleeps = []

    def fake_urlopen(_req, timeout=None):
        calls.append(timeout)
        response = next(pending)
        if isinstance(response, BaseException):
            raise response
        return response

    monkeypatch.setattr(opik_mod.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(opik_mod.time, "sleep", sleeps.append)
    return calls, sleeps


def test_cloud_auth_headers_attach_on_get(monkeypatch):
    captured = _capture(monkeypatch)
    client = OpikClient("https://example.test/api/v1/private", "proj",
                        api_key="k-123", workspace="ws-x")
    client._get("/projects")
    assert captured["headers"]["authorization"] == "k-123"
    assert captured["headers"]["comet-workspace"] == "ws-x"


def test_cloud_auth_headers_attach_on_post(monkeypatch):
    captured = _capture(monkeypatch)
    client = OpikClient("https://example.test/api/v1/private", "proj",
                        api_key="k-123", workspace="ws-x")
    client._post("/traces/delete", {"ids": []})
    assert captured["headers"]["authorization"] == "k-123"
    assert captured["headers"]["comet-workspace"] == "ws-x"


def test_local_unauthenticated_sends_no_auth_headers(monkeypatch):
    captured = _capture(monkeypatch)
    client = OpikClient("http://localhost:5173/api/v1/private", "proj")
    client._get("/projects")
    assert "authorization" not in captured["headers"]
    assert "comet-workspace" not in captured["headers"]


def test_empty_strings_count_as_unset(monkeypatch):
    captured = _capture(monkeypatch)
    client = OpikClient("http://localhost:5173/api/v1/private", "proj",
                        api_key="", workspace="")
    client._get("/projects")
    assert "authorization" not in captured["headers"]
    assert "comet-workspace" not in captured["headers"]


def test_get_retries_transport_errors_then_succeeds(monkeypatch):
    calls, sleeps = _get_sequence(
        monkeypatch,
        TimeoutError("status read timed out"),
        opik_mod.urllib.error.URLError(TimeoutError("request timed out")),
        _Resp(b'{"content": []}'),
    )

    client = OpikClient("https://example.test/api/v1/private", "proj")
    assert client.recent_traces() == []
    assert calls == [8.0, 8.0, 8.0]
    assert sleeps == [0.5, 1.0]


def test_get_stops_after_three_transport_failures(monkeypatch):
    calls, sleeps = _get_sequence(
        monkeypatch,
        TimeoutError("first timeout"),
        TimeoutError("second timeout"),
        TimeoutError("third timeout"),
    )

    client = OpikClient("https://example.test/api/v1/private", "proj")
    with pytest.raises(OpikError, match=r"GET .* failed after 3 attempts"):
        client.recent_traces()
    assert calls == [8.0, 8.0, 8.0]
    assert sleeps == [0.5, 1.0]


def test_get_uses_a_fresh_request_for_each_attempt(monkeypatch):
    requests = []
    sleeps = []

    def fake_urlopen(req, timeout=None):
        requests.append((req, req.type, req.host, timeout))
        if len(requests) < 3:
            req.set_proxy("proxy.test:8080", "http")
            raise TimeoutError("proxy read timed out")
        return _Resp(b"{}")

    monkeypatch.setattr(opik_mod.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(opik_mod.time, "sleep", sleeps.append)

    client = OpikClient("https://example.test/api/v1/private", "proj")
    assert client._get("/projects") == {}
    assert len({id(request[0]) for request in requests}) == 3
    assert [request[1:3] for request in requests] == [
        ("https", "example.test"),
        ("https", "example.test"),
        ("https", "example.test"),
    ]
    assert sleeps == [0.5, 1.0]


def test_get_retries_protocol_errors_until_exhausted(monkeypatch):
    calls, sleeps = _get_sequence(
        monkeypatch,
        http.client.IncompleteRead(b"first", 10),
        http.client.IncompleteRead(b"second", 10),
        http.client.IncompleteRead(b"third", 10),
    )

    client = OpikClient("https://example.test/api/v1/private", "proj")
    with pytest.raises(OpikError, match=r"GET .* failed after 3 attempts"):
        client.recent_traces()
    assert calls == [8.0, 8.0, 8.0]
    assert sleeps == [0.5, 1.0]


def _http_error(status: str | int, reason: str):
    return opik_mod.urllib.error.HTTPError(
        "https://example.test", status, reason, None, io.BytesIO(b"body"))


@pytest.mark.parametrize("status", sorted(opik_mod.RETRY_STATUSES))
def test_get_retries_a_transient_server_error_then_succeeds(monkeypatch, status):
    """A self-hosted Opik under memory pressure kills one query and serves the next.

    ClickHouse's OvercommitTracker picks a victim when the server sits at its
    memory ceiling, so the 500 says nothing about this request — a retry is the
    correct response, and without one a whole trial is lost to someone else's query.
    """
    calls, sleeps = _get_sequence(
        monkeypatch, _http_error(status, "server error"), _Resp(b'{"content": []}'))

    client = OpikClient("https://example.test/api/v1/private", "proj")
    assert client.recent_traces() == []
    assert calls == [8.0, 8.0]
    assert sleeps == [0.5]


def test_get_gives_up_on_a_persistent_server_error_and_names_the_status(monkeypatch):
    calls, sleeps = _get_sequence(monkeypatch, *[_http_error(500, "server error")] * 3)

    client = OpikClient("https://example.test/api/v1/private", "proj")
    with pytest.raises(OpikError, match=r"GET .*: HTTP 500: server error \(3 attempts\)"):
        client.recent_traces()
    assert calls == [8.0, 8.0, 8.0]
    assert sleeps == [0.5, 1.0]


@pytest.mark.parametrize("status", (400, 401, 403, 404, 422))
def test_get_does_not_retry_a_client_error(monkeypatch, status):
    """A 4xx is a statement about this request; repeating it just wastes the sweep."""
    calls, sleeps = _get_sequence(monkeypatch, _http_error(status, "client error"))

    client = OpikClient("https://example.test/api/v1/private", "proj")
    with pytest.raises(OpikError, match=rf"GET .*: HTTP {status}: client error"):
        client.recent_traces()
    assert calls == [8.0]
    assert sleeps == []


def test_post_never_retries_because_it_is_not_idempotent(monkeypatch):
    """Only GET is safe to repeat. A retried delete could act twice."""
    calls, sleeps = _get_sequence(monkeypatch, _http_error(500, "server error"))

    client = OpikClient("https://example.test/api/v1/private", "proj")
    with pytest.raises(OpikError, match=r"POST /traces/delete: HTTP 500"):
        client.delete_traces(["t1"])
    assert calls == [8.0]
    assert sleeps == []


def test_get_does_not_retry_malformed_json(monkeypatch):
    calls, sleeps = _get_sequence(monkeypatch, _Resp(b"{"))

    client = OpikClient("https://example.test/api/v1/private", "proj")
    with pytest.raises(OpikError, match=r"GET .*: bad JSON"):
        client.recent_traces()
    assert calls == [8.0]
    assert sleeps == []


def test_get_does_not_retry_invalid_utf8(monkeypatch):
    calls, sleeps = _get_sequence(monkeypatch, _Resp(b"\xff"))

    client = OpikClient("https://example.test/api/v1/private", "proj")
    with pytest.raises(OpikError, match=r"GET .*: bad JSON"):
        client.recent_traces()
    assert calls == [8.0]
    assert sleeps == []


def test_experiment_writer_attaches_cloud_auth(monkeypatch):
    import evallib.experiments as exp_mod
    from evallib.experiments import ExperimentWriter

    captured = {}

    def fake_urlopen(req, timeout=None):
        captured["headers"] = {k.lower(): v for k, v in req.header_items()}
        return _Resp(b"{}")

    monkeypatch.setattr(exp_mod.urllib.request, "urlopen", fake_urlopen)
    writer = ExperimentWriter("https://example.test/api/v1/private",
                              api_key="k-123", workspace="ws-x")
    writer._request("GET", "/datasets")
    assert captured["headers"]["authorization"] == "k-123"
    assert captured["headers"]["comet-workspace"] == "ws-x"


def test_experiment_writer_local_sends_no_auth(monkeypatch):
    import evallib.experiments as exp_mod
    from evallib.experiments import ExperimentWriter

    captured = {}

    def fake_urlopen(req, timeout=None):
        captured["headers"] = {k.lower(): v for k, v in req.header_items()}
        return _Resp(b"{}")

    monkeypatch.setattr(exp_mod.urllib.request, "urlopen", fake_urlopen)
    ExperimentWriter("http://localhost:5173/api/v1/private")._request("GET", "/datasets")
    assert "authorization" not in captured["headers"]
    assert "comet-workspace" not in captured["headers"]


def _trace(trace_id="t1", session="session", query="question", **overrides):
    return {"id": trace_id, "thread_id": f"cli:{session}", "name": "agent:main",
            "input": {"text": query}, "start_time": "2026-09-07T12:00:00Z",
            "end_time": "2026-09-07T12:00:01Z", "span_count": 1, **overrides}


def test_turn_lookup_filters_on_server_and_keeps_exact_input(monkeypatch):
    calls = []
    trace = _trace()

    def get(path, params):
        calls.append((path, params))
        return {"content": [trace], "total": 1}

    client = OpikClient("http://opik", "eval")
    monkeypatch.setattr(client, "_get", get)
    after = datetime(2026, 9, 7, 12, tzinfo=timezone.utc)
    assert client.find_turn_trace("session", "question", after, set()) == trace
    path, params = calls[0]
    filters = json.loads(params["filters"])
    assert path == "/traces" and params["size"] <= 10
    assert {"field": "thread_id", "operator": "ends_with", "value": "session"} in filters
    assert {"field": "name", "operator": "=", "value": "agent:main"} in filters
    assert {"field": "start_time", "operator": ">=",
            "value": "2026-09-07T12:00:00.000Z"} in filters
    assert params["truncate"] == "false"
    excluded = json.loads(params["exclude"])
    assert "output" in excluded and "feedback_scores" in excluded
    assert "input" not in excluded and "metadata" not in excluded


def test_filter_dates_use_utc_milliseconds_with_local_exact_comparison(monkeypatch):
    client = OpikClient("http://opik", "eval")
    calls = []
    monkeypatch.setattr(client, "_get",
                        lambda path, params: calls.append(params) or {"content": []})
    after = datetime.fromisoformat("2026-09-07T08:00:00.123456-04:00")
    assert client.find_turn_trace("session", "question", after, set()) is None
    date_filter = next(f for f in json.loads(calls[0]["filters"]) if f["field"] == "start_time")
    assert date_filter["value"] == "2026-09-07T12:00:00.123Z"


def test_turn_lookup_pages_within_session_instead_of_losing_an_older_turn(monkeypatch):
    pages = []

    def get(_path, params):
        pages.append(params["page"])
        if params["page"] == 1:
            return {"content": [_trace(f"old-{i}", query="other") for i in range(10)],
                    "total": 11}
        return {"content": [_trace("target")], "total": 11}

    client = OpikClient("http://opik", "eval")
    monkeypatch.setattr(client, "_get", get)
    assert client.find_turn_trace("session", "question", None, set())["id"] == "target"
    assert pages == [1, 2]


def test_turn_lookup_does_not_trust_a_total_count_from_before_ingestion(monkeypatch):
    client = OpikClient("http://opik", "eval")

    def get(_path, params):
        if params["page"] == 1:
            rows = [_trace("first")] + [_trace(str(i), query="other") for i in range(9)]
            return {"content": rows, "total": 10}
        return {"content": [_trace("second")], "total": 11}

    monkeypatch.setattr(client, "_get", get)
    assert client.find_turn_trace("session", "question", None, set()) is None


@pytest.mark.parametrize("rows,expected", [
    ([_trace("a"), _trace("b")], None),
    ([_trace(query="question plus more")], None),
    ([_trace(session="prefix-session")], None),
    ([_trace(name="memory_review:main")], None),
    ([_trace("seen"), _trace("new")], "new"),
])
def test_filtered_turn_still_requires_unique_exact_local_match(monkeypatch, rows, expected):
    client = OpikClient("http://opik", "eval")
    monkeypatch.setattr(client, "_get", lambda *_a: {"content": rows})
    found = client.find_turn_trace("session", "question", None, {"seen"})
    assert (found["id"] if found else None) == expected


def test_marker_lookup_scopes_thread_and_time_on_server(monkeypatch):
    calls = []
    client = OpikClient("http://opik", "eval")
    trace = _trace(thread_id="telegram:owner", input={"text": "hello (eval:marker)"})
    monkeypatch.setattr(client, "_get",
                        lambda path, params: calls.append(params) or {"content": [trace]})
    after = datetime(2026, 9, 7, 12, tzinfo=timezone.utc)
    assert client.find_marker_trace("telegram:", "(eval:marker)", after, set()) == trace
    filters = json.loads(calls[0]["filters"])
    assert {"field": "thread_id", "operator": "starts_with", "value": "telegram:"} in filters


def test_filtered_lookup_rechecks_timestamp_and_correlation(monkeypatch):
    client = OpikClient("http://opik", "eval")
    correlation = {"eval_run_id": "run", "case_id": "case", "turn_index": 1}
    rows = [_trace("old", start_time="2026-09-06T12:00:00Z", metadata=correlation),
            _trace("other", metadata={**correlation, "turn_index": 2}),
            _trace("match", metadata=correlation)]
    monkeypatch.setattr(client, "_get", lambda *_a: {"content": rows})
    after = datetime(2026, 9, 7, 12, tzinfo=timezone.utc)
    found = client.find_turn_trace("session", "question", after, set(), correlation)
    assert found["id"] == "match"


def test_spans_are_paged_and_only_tool_bodies_are_downloaded(monkeypatch):
    calls = []

    def get(path, params):
        calls.append((path, params))
        tool = json.loads(params["filters"])[0]["operator"] == "="
        if tool:
            return {"content": [{"id": "tool", "type": "tool", "input": "full input"}],
                    "total": 1}
        count = 2 if params["page"] == 1 else 1
        return {"content": [{"id": f"llm-{params['page']}-{i}", "type": "llm"}
                            for i in range(count)], "total": 3}

    client = OpikClient("http://opik", "eval")
    monkeypatch.setattr(client, "_get", get)
    spans = client.get_spans("trace", size=2)
    assert len(spans) == 4
    assert next(s for s in spans if s["type"] == "tool")["input"] == "full input"
    for path, params in calls:
        assert path == "/spans" and params["trace_id"] == "trace"
        assert params["size"] == 2 and params["truncate"] == "false"
        tool = json.loads(params["filters"])[0]["operator"] == "="
        assert ("input" in json.loads(params["exclude"])) is not tool
    assert len(calls) == 3


def test_lookup_refuses_to_return_partial_candidates_when_page_cap_is_reached(monkeypatch):
    calls = []

    def get(_path, params):
        calls.append(params["page"])
        return {"content": [_trace(f"{params['page']}-{i}") for i in range(params["size"])],
                "total": 100_000}

    client = OpikClient("http://opik", "eval")
    monkeypatch.setattr(client, "_get", get)
    with pytest.raises(OpikError, match="page cap"):
        client.find_turn_trace("session", "question", None, set())
    assert len(calls) <= 20


def test_span_pagination_rejects_repeated_ids(monkeypatch):
    client = OpikClient("http://opik", "eval")
    monkeypatch.setattr(client, "_get",
                        lambda *_a: {"content": [{"id": "repeated"}], "total": 2})
    with pytest.raises(OpikError, match="duplicate id"):
        client.get_spans("trace", size=1)


@pytest.mark.parametrize("size", [0, 201, True, "20"])
def test_span_page_size_is_bounded_before_any_request(size):
    with pytest.raises(ValueError, match="page size"):
        OpikClient("http://unused", "eval").get_spans("trace", size=size)


def test_settlement_downloads_spans_only_after_trace_closes_and_count_stabilizes(monkeypatch):
    client = OpikClient("http://opik", "eval")
    reads = []
    snapshots = iter([_trace(end_time=None), _trace(span_count=2), _trace(span_count=2)])

    def trace(_id):
        reads.append("trace")
        return next(snapshots)

    def spans(_id, size=200):
        reads.append("spans")
        assert size <= 200
        return [{"id": str(i), "end_time": "2026-09-07T12:00:01Z"} for i in range(2)]

    monkeypatch.setattr(client, "get_trace", trace)
    monkeypatch.setattr(client, "get_spans", spans)
    monkeypatch.setattr(opik_mod.time, "sleep", lambda _s: None)
    full, evidence = client.await_complete(_trace(), settle_s=10, interval_s=1)
    assert full["_eval_trace_complete"] and len(evidence) == 2
    assert reads == ["trace", "trace", "trace", "spans"]


def test_settlement_never_marks_missing_spans_complete(monkeypatch):
    client = OpikClient("http://opik", "eval")
    monkeypatch.setattr(client, "get_trace", lambda _id: _trace(span_count=2))
    monkeypatch.setattr(client, "get_spans", lambda *_a, **_k: [])
    monkeypatch.setattr(opik_mod.time, "sleep", lambda _s: None)
    full, _spans = client.await_complete(_trace(), settle_s=0)
    assert full["_eval_trace_complete"] is False


def test_settlement_never_marks_an_open_span_complete(monkeypatch):
    client = OpikClient("http://opik", "eval")
    monkeypatch.setattr(client, "get_trace", lambda _id: _trace())
    monkeypatch.setattr(client, "get_spans", lambda *_a, **_k: [{"id": "still-open"}])
    monkeypatch.setattr(opik_mod.time, "sleep", lambda _s: None)
    full, _spans = client.await_complete(_trace(), settle_s=1, interval_s=1)
    assert full["_eval_trace_complete"] is False
    assert any("span end_time missing" in issue for issue in full["_eval_trace_issues"])


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
