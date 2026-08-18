#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8"]
# ///
"""Tests for seed_capability_home's config rendering, the explicit/CI mode
(provider spec, refusals, allowed_roots), and the skills-dir reset. Hermetic:
no daemon, no dev home, no host state — writes only under pytest tmp dirs.
Run: `uv run bin/test_seed_home.py`."""
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
    assert sandbox["allowed_roots"] == ["/tmp/x-eval/skills", "/tmp/x-eval/extra"]
    # M26 §11: skill curation stays off in eval homes.
    assert doc["fermix_core"]["skill_curation"]["enabled"] is False
    # M21: meetings is default-off, so eval homes pre-grant the enable gate.
    assert doc["fermix_core"]["meetings"]["enabled"] is True


def test_render_config_keyring_mode_unchanged():
    cfg = seed.render_config(
        "/tmp/x-eval", "openai", {"default_model": "m", "api_key": "@keyring"}, "default")
    doc = tomllib.loads(cfg)
    assert doc["fermix_core"]["profile"] == "default"
    assert doc["fermix_core"]["providers"]["openai"]["api_key"] == "@keyring"
    assert doc["sandbox"]["allowed_roots"] == ["/tmp/x-eval/skills"]


def test_render_config_always_roots_the_homes_skills_dir():
    # Skill tasks verify their created SKILL.md with raw file reads; without
    # this root the strict sandbox denies the read and the model detours into
    # request_directory_access — an owner approval no eval can grant — ending
    # the turn before the deliverable is written (create_and_confirm_skill
    # scored 0 that way with nothing wrong in the product). The runner
    # precondition allows it: only roots that ESCAPE the home are refused.
    cfg = seed.render_config("/tmp/x-eval", "openai", {"default_model": "m"}, None)
    doc = tomllib.loads(cfg)
    assert doc["sandbox"]["allowed_roots"] == ["/tmp/x-eval/skills"]


def test_reset_skills_removes_the_skills_tree(tmp_path):
    home = tmp_path / "x-eval"
    (home / "skills" / "eval-echo").mkdir(parents=True)
    (home / "skills" / "eval-echo" / "SKILL.md").write_text("# eval-echo\n")
    seed.reset_skills(str(home))
    assert not (home / "skills").exists()


def test_reset_skills_is_a_noop_without_a_skills_dir(tmp_path):
    home = tmp_path / "x-eval"
    home.mkdir()
    seed.reset_skills(str(home))
    assert not (home / "skills").exists()


def test_reset_skills_refuses_a_non_eval_home(tmp_path):
    home = tmp_path / "realhome"
    (home / "skills").mkdir(parents=True)
    with pytest.raises(SystemExit):
        seed.reset_skills(str(home))
    assert (home / "skills").exists()


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
