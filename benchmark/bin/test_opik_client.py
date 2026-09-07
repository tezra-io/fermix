#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8"]
# ///
"""Tests for the harness Opik client's auth and bounded GET transport retry.

Pure; urlopen is monkeypatched, no network. Run: `uv run bin/test_opik_client.py`.
"""
from __future__ import annotations

import http.client
import io
import os
import sys

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


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
