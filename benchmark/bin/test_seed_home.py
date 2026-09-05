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


def _populate_state(home):
    """Every durable-state path a prior sweep's daemon leaves behind."""
    for name in seed.STATE_DIRS:
        (home / name / "leftover").mkdir(parents=True)
        (home / name / "leftover" / "f.txt").write_text("from the previous sweep\n")
    for name in seed.STATE_FILES:
        (home / name).write_text("stale\n")


def test_reset_state_removes_every_durable_state_path(tmp_path):
    # A trial is only independent if it starts from the baseline: a skill, a memory
    # row, a scheduled job or an event left by the previous sweep changes what the
    # next one measures.
    home = tmp_path / "x-eval"
    home.mkdir()
    _populate_state(home)
    seed.reset_state(str(home))
    for name in seed.STATE_DIRS + seed.STATE_FILES:
        assert not (home / name).exists(), name


def test_reset_state_keeps_the_homes_configuration(tmp_path):
    # config.toml and auth.json are the home's SETUP, not per-sweep state.
    home = tmp_path / "x-eval"
    home.mkdir()
    _populate_state(home)
    (home / "config.toml").write_text("# managed\n")
    (home / "auth.json").write_text("{}\n")
    seed.reset_state(str(home))
    assert (home / "config.toml").exists() and (home / "auth.json").exists()


def test_reset_state_is_a_noop_on_a_fresh_home(tmp_path):
    home = tmp_path / "x-eval"
    home.mkdir()
    seed.reset_state(str(home))
    assert not (home / "skills").exists()


def test_reset_state_refuses_a_non_eval_home(tmp_path):
    home = tmp_path / "realhome"
    home.mkdir()
    _populate_state(home)
    with pytest.raises(SystemExit):
        seed.reset_state(str(home))
    assert (home / "skills").exists()
    assert (home / "memory.db").exists()


def test_reset_state_refuses_a_home_that_is_not_a_directory(tmp_path):
    missing = tmp_path / "x-eval"
    with pytest.raises(SystemExit):
        seed.reset_state(str(missing))


def test_reset_state_documents_the_daemon_down_requirement(tmp_path):
    # The contract has to be written down where the next reader of this function
    # will see it.
    doc = seed.reset_state.__doc__.lower()
    assert "daemon" in doc and "down" in doc


def test_reset_state_refuses_while_a_daemon_answers_the_home(tmp_path, monkeypatch):
    # `up()` skips seeding only when its own pidfile names a live pid, so a daemon
    # started outside the script against the same home is invisible to it — and
    # unlinking memory.db under one leaves it writing to an unlinked file.
    home = tmp_path / "x-eval"
    home.mkdir()
    _populate_state(home)
    monkeypatch.setattr(seed, "daemon_answers", lambda _home: True)
    with pytest.raises(SystemExit):
        seed.reset_state(str(home))
    assert (home / "memory.db").exists()


def test_reset_state_refuses_a_symlinked_home(tmp_path):
    # safe_rm compares REALPATHS, so an abspath leaf check let `~/x-eval -> ~/.fermix`
    # through and the removals landed in the live home.
    real = tmp_path / "realhome"
    real.mkdir()
    _populate_state(real)
    link = tmp_path / "x-eval"
    link.symlink_to(real)
    with pytest.raises(SystemExit):
        seed.reset_state(str(link))
    assert (real / "memory.db").exists()


def test_browser_and_harness_state_are_part_of_the_baseline():
    # ConfigStore owns browser/ (Chrome user-data dirs: cookies, local storage,
    # history) and Harness.Artifacts keeps harness/runs/<id>; both survive a sweep
    # and are inherited by the next one's web and harness tasks.
    assert "browser" in seed.STATE_DIRS and "harness" in seed.STATE_DIRS


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
