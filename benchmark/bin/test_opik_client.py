#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8"]
# ///
"""Tests for the harness Opik client's hosted-cloud auth: `authorization` +
`Comet-Workspace` headers attach when configured and never otherwise. Pure;
urlopen is monkeypatched, no network. Run: `uv run bin/test_opik_client.py`."""
from __future__ import annotations

import io
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from evallib.opik import OpikClient  # noqa: E402
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
