#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "certifi"]
# ///
"""Specs for the judge's HTTP transport policy.

The judge is the only producer of `incomplete` that has no retry of its own
(the Opik half got one in 4f35defc). A transient provider 5xx must not void a
run whose structural gates all passed; a *rejected* or malformed verdict must
never be re-rolled, because re-rolling launders a real refusal into a pass.
"""

from __future__ import annotations

import http.client
import io
import json
import sys
import urllib.error
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from evallib import judge  # noqa: E402

VERDICT = json.dumps({"pass": True, "score": 0.9, "rationale": "ok"})


class _Response(io.BytesIO):
    """Minimal urlopen context manager returning one chat-completions body."""

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self.close()
        return False


def _ok_body(content: str = VERDICT, model: str = "judge-model") -> bytes:
    return json.dumps({
        "model": model,
        "choices": [{"finish_reason": "stop", "message": {"content": content}}],
        "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15},
    }).encode()


def _http_error(code: int) -> urllib.error.HTTPError:
    return urllib.error.HTTPError(
        "https://api.openai.com/v1/chat/completions", code,
        f"Internal Server Error" if code >= 500 else "Unauthorized", {}, None)


@pytest.fixture
def dispatch(monkeypatch):
    """Drive judge_case with a scripted urlopen; record calls and backoff sleeps."""
    monkeypatch.setenv("EVAL_JUDGE_API_KEY", "test-key")
    monkeypatch.delenv("EVAL_JUDGE_BASE_URL", raising=False)
    state = SimpleNamespace(requests=[], sleeps=[])
    monkeypatch.setattr(judge.time, "sleep", state.sleeps.append)

    def run(outcomes):
        remaining = list(outcomes)

        def fake_urlopen(req, *_args, **_kwargs):
            state.requests.append(req)
            outcome = remaining.pop(0)
            if isinstance(outcome, Exception):
                raise outcome
            return _Response(outcome)

        monkeypatch.setattr(judge.urllib.request, "urlopen", fake_urlopen)
        cfg = SimpleNamespace(judge=SimpleNamespace(backend="openai", model="judge-model"))
        return judge.judge_case(
            cfg, "q", "r", "Judge this.", "case",
            candidate_routes=[{"provider": "openai", "model": "candidate-model"}])

    state.run = run
    return state


def test_transient_500_is_retried_and_the_verdict_still_lands(dispatch):
    result = dispatch.run([_http_error(500), _ok_body()])
    assert result.evaluated is True
    assert result.passed is True
    assert len(dispatch.requests) == 2
    assert dispatch.sleeps == [1.0]


def test_retries_are_bounded_and_the_run_stays_fail_loud(dispatch):
    result = dispatch.run([_http_error(500)] * 4)
    assert result.evaluated is False
    assert result.called is True
    assert "HTTP Error 500" in result.error
    assert len(dispatch.requests) == 4
    assert dispatch.sleeps == list(judge._JUDGE_RETRY_DELAYS_S)


def test_auth_failure_is_not_retried(dispatch):
    result = dispatch.run([_http_error(401)])
    assert result.evaluated is False
    assert len(dispatch.requests) == 1
    assert dispatch.sleeps == []


def test_a_malformed_verdict_is_never_re_rolled(dispatch):
    result = dispatch.run([_ok_body(content="not json at all")])
    assert result.evaluated is False
    assert len(dispatch.requests) == 1
    assert dispatch.sleeps == []


def test_a_rejecting_verdict_is_never_re_rolled(dispatch):
    body = json.dumps({"pass": False, "score": 0.1, "rationale": "no"})
    result = dispatch.run([_ok_body(content=body)])
    assert result.evaluated is True
    assert result.passed is False
    assert len(dispatch.requests) == 1


def test_incomplete_read_at_the_cap_returns_a_result_instead_of_escaping(dispatch):
    result = dispatch.run([http.client.IncompleteRead(b"partial")] * 4)
    assert result.evaluated is False
    assert result.called is True
    assert len(dispatch.requests) == 4


def test_each_attempt_builds_a_fresh_request(dispatch):
    dispatch.run([_http_error(503), _ok_body()])
    first, second = dispatch.requests
    assert first is not second
    assert first.data == second.data


def test_the_invalid_verdict_error_never_echoes_judge_prose(dispatch):
    secret = "CANDIDATE-PROSE-MARKER"
    result = dispatch.run([_ok_body(content=secret)])
    assert result.evaluated is False
    assert secret not in result.error
    assert "invalid verdict shape" in result.error


def test_the_request_asks_for_exactly_the_verdict_the_parser_accepts(dispatch):
    dispatch.run([_ok_body()])
    body = json.loads(dispatch.requests[0].data)
    schema = body["response_format"]["json_schema"]["schema"]
    assert body["response_format"]["json_schema"]["strict"] is True
    assert set(schema["properties"]) == {"pass", "score", "rationale"}
    assert set(schema["required"]) == set(schema["properties"])
    assert schema["additionalProperties"] is False


def test_a_missing_tool_record_is_sent_as_not_recorded_not_as_no_tools(dispatch):
    dispatch.run([_ok_body()])
    sent = json.loads(json.loads(dispatch.requests[0].data)["messages"][1]["content"])
    assert sent["tool_evidence"] == judge.NOT_RECORDED
    assert judge._evaluation_data("q", "r", "x", None, [], None)["tool_evidence"] == []


def test_a_verdict_in_schema_order_parses(dispatch):
    body = json.dumps({"rationale": "met both", "score": 1.0, "pass": True})
    result = dispatch.run([_ok_body(content=body)])
    assert result.evaluated is True
    assert result.score == 1.0


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
