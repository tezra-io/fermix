#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8"]
# ///
"""Tests for seed_capability_home's config rendering and the explicit/CI mode
(provider spec, refusals, allowed_roots). Pure; no daemon, no dev home, no
filesystem writes. Run: `uv run bin/test_seed_home.py`."""
from __future__ import annotations

import argparse
import os
import sys
import tomllib

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import seed_capability_home as seed


def _args(**overrides):
    base = {"provider": None, "model": None, "reasoning_effort": None, "allow_roots": []}
    base.update(overrides)
    return argparse.Namespace(**base)


def test_explicit_spec_builds_an_env_key_provider_block():
    pid, blk = seed.explicit_spec(_args(provider="openai", model="gpt-5.6-luna"))
    assert pid == "openai"
    assert blk == {"default_model": "gpt-5.6-luna"}


def test_explicit_spec_carries_reasoning_effort():
    _pid, blk = seed.explicit_spec(
        _args(provider="openai", model="gpt-5.6-luna", reasoning_effort="low"))
    assert blk["reasoning_effort"] == "low"


def test_explicit_mode_allows_env_key_anthropic():
    pid, _blk = seed.explicit_spec(_args(provider="anthropic", model="claude-x"))
    assert pid == "anthropic"


def test_explicit_mode_allows_keyless_ollama():
    pid, _blk = seed.explicit_spec(_args(provider="ollama", model="llama3"))
    assert pid == "ollama"


def test_explicit_mode_refuses_oauth_only_provider():
    with pytest.raises(SystemExit):
        seed.explicit_spec(_args(provider="openai_codex", model="m"))


def test_explicit_mode_refuses_unknown_provider():
    with pytest.raises(SystemExit):
        seed.explicit_spec(_args(provider="nope", model="m"))


def test_render_config_explicit_mode_has_no_secret_and_parses():
    cfg = seed.render_config(
        "/tmp/x-eval", "openai", {"default_model": "gpt-5.6-luna"}, None,
        ("/tmp/x-eval/extra",))
    doc = tomllib.loads(cfg)
    provider = doc["fermix_core"]["providers"]["openai"]
    assert provider["primary"] is True
    assert provider["default_model"] == "gpt-5.6-luna"
    assert "api_key" not in provider
    assert "profile" not in doc["fermix_core"]
    sandbox = doc["sandbox"]
    assert sandbox["mode"] == "strict"
    assert sandbox["workspace_root"] == "/tmp/x-eval/workspace"
    assert sandbox["allowed_roots"] == ["/tmp/x-eval/extra"]


def test_render_config_keyring_mode_unchanged():
    cfg = seed.render_config(
        "/tmp/x-eval", "openai", {"default_model": "m", "api_key": "@keyring"}, "default")
    doc = tomllib.loads(cfg)
    assert doc["fermix_core"]["profile"] == "default"
    assert doc["fermix_core"]["providers"]["openai"]["api_key"] == "@keyring"
    assert doc["sandbox"]["allowed_roots"] == []


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
