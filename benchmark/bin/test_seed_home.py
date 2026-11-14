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
import base64
import json
import os
import re
import subprocess
import sys
import tomllib
from datetime import datetime, timedelta

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
        "/tmp/x-eval", "openai", {"default_model": "gpt-5.6-luna"}, None)
    doc = tomllib.loads(cfg)
    provider = doc["fermix_core"]["providers"]["openai"]
    assert provider["primary"] is True
    assert provider["default_model"] == "gpt-5.6-luna"
    assert "api_key" not in provider
    assert "profile" not in doc["fermix_core"]
    # M97 §4: the sandbox is the machine's own setting, in machine.toml only.
    assert "sandbox" not in doc
    sandbox = tomllib.loads(seed.render_machine("/tmp/x-eval", ("/tmp/x-eval/extra",)))["sandbox"]
    assert sandbox["mode"] == "strict"
    assert sandbox["workspace_root"] == "/tmp/x-eval/workspace"
    assert sandbox["allowed_roots"] == ["/tmp/x-eval/skills", "/tmp/x-eval/extra"]
    # M26 §11: skill curation stays off in eval homes.
    assert doc["fermix_core"]["skill_curation"]["enabled"] is False
    # M21: meetings is default-off, so eval homes pre-grant the enable gate.
    assert doc["fermix_core"]["meetings"]["enabled"] is True
    # M78: open loops are default-off; the section carries `enabled` and nothing else,
    # since any other key stops the daemon booting.
    assert doc["fermix_core"]["open_loops"] == {"enabled": True}
    # M78: the configured Telegram target is the owner's own inbox only with the
    # channel's explicit owner id, or open-loop capture refuses as `:no_target`.
    assert doc["fermix_channels"]["telegram"] == {"owner_user_id": "100001"}


def test_render_config_keyring_mode_unchanged():
    cfg = seed.render_config(
        "/tmp/x-eval", "openai", {"default_model": "m", "api_key": "@keyring"}, "default")
    doc = tomllib.loads(cfg)
    assert doc["fermix_core"]["profile"] == "default"
    assert doc["fermix_core"]["providers"]["openai"]["api_key"] == "@keyring"
    assert tomllib.loads(seed.render_machine("/tmp/x-eval"))["sandbox"]["allowed_roots"] == [
        "/tmp/x-eval/skills"]


def test_render_config_always_roots_the_homes_skills_dir():
    # Skill tasks verify their created SKILL.md with raw file reads; without
    # this root the strict sandbox denies the read and the model detours into
    # request_directory_access — an owner approval no eval can grant — ending
    # the turn before the deliverable is written (create_and_confirm_skill
    # scored 0 that way with nothing wrong in the product). The runner
    # precondition allows it: only roots that ESCAPE the home are refused.
    doc = tomllib.loads(seed.render_machine("/tmp/x-eval"))
    assert doc["sandbox"]["allowed_roots"] == ["/tmp/x-eval/skills"]


def test_render_config_allows_the_skill_credential_fixture():
    # M45: the credential eval needs one allowed sandbox variable whose value a
    # harmless `command` source prints — the same record shape a value stored
    # from Settings > Sandbox has — so no keychain and no operator env is read.
    env = tomllib.loads(seed.render_machine("/tmp/x-eval"))["sandbox"]["env"]
    assert env["allow"] == [seed.SKILL_TOKEN_NAME]
    source = env[seed.SKILL_TOKEN_NAME]
    assert source["source"] == "command"
    assert source["command"] == "/bin/cat"
    assert source["args"] == ["/tmp/x-eval/eval-fixtures/skill_token"]
    assert isinstance(source["timeout_ms"], int) and source["timeout_ms"] > 0


def test_write_skill_token_writes_the_fixture_value_privately(tmp_path):
    home = tmp_path / "x-eval"
    home.mkdir()
    path = seed.write_skill_token(str(home))
    assert path == str(home / "eval-fixtures" / "skill_token")
    # No trailing newline: the value the helper prints is byte-identical to it.
    assert (home / "eval-fixtures" / "skill_token").read_text() == seed.SKILL_TOKEN_VALUE
    assert os.stat(path).st_mode & 0o777 == 0o600
    # Long enough that the shell's 8-byte redaction floor applies to it.
    assert len(seed.SKILL_TOKEN_VALUE.encode()) >= 8


def test_the_fixture_token_is_not_durable_state():
    # Seeding rewrites it every time; reset_state must not be what removes it.
    assert "eval-fixtures" not in seed.STATE_DIRS


def _populate_state(home):
    """Every durable-state path a prior sweep's daemon leaves behind."""
    for name in seed.STATE_DIRS:
        (home / name / "leftover").mkdir(parents=True)
        (home / name / "leftover" / "f.txt").write_text("from the previous sweep\n")
    for name in seed.STATE_FILES:
        (home / name).parent.mkdir(parents=True, exist_ok=True)
        (home / name).write_text("stale\n")


_DEV = {"fermix_core": {"profile": "fermix-dev", "providers": {
    "openai_codex": {"primary": True, "default_model": "gpt-6.1-sol", "auth_mode": "oauth"},
    "anthropic": {"primary": False, "default_model": "claude-opus-4-8",
                  "reasoning_effort": "xhigh", "auth_mode": "oauth"},
    "mistral": {"primary": False, "default_model": "mistral-large-latest",
                "api_key": "@keyring"},
    "broken": {"primary": False}}}}


def test_dev_provider_scores_a_named_block_with_its_own_model_and_auth():
    pid, blk, profile = seed.dev_provider(_DEV, "anthropic")
    assert (pid, blk["default_model"], blk["auth_mode"], profile) == (
        "anthropic", "claude-opus-4-8", "oauth", "fermix-dev")
    doc = tomllib.loads(seed.render_config("/tmp/x-eval", pid, blk, profile))
    block = doc["fermix_core"]["providers"]["anthropic"]
    assert block["primary"] is True and block["reasoning_effort"] == "xhigh"


def test_dev_provider_keeps_the_keychain_sentinel_for_an_api_key_block():
    pid, blk, profile = seed.dev_provider(_DEV, "mistral")
    doc = tomllib.loads(seed.render_config("/tmp/x-eval", pid, blk, profile))
    assert doc["fermix_core"]["providers"]["mistral"]["api_key"] == "@keyring"
    assert doc["fermix_core"]["profile"] == "fermix-dev"


@pytest.mark.parametrize("pid", ["nope", "broken"])
def test_dev_provider_refuses_an_unknown_or_modelless_block(pid):
    with pytest.raises(SystemExit):
        seed.dev_provider(_DEV, pid)


def test_render_config_wires_the_tool_discovery_fixture_server():
    # cap_tool_discovery needs one deferred surface in a home that has no plugins.
    doc = tomllib.loads(seed.render_config(
        "/tmp/x-eval", "openai", {"default_model": "gpt-5.6-luna"}, None))
    server = doc["mcp"]["servers"]["halden_ops"]
    assert server["command"] == "/usr/bin/env"
    python, script, flag, state = server["args"]
    assert python == "python3" and os.path.isfile(script) and script.endswith("halden_ops.py")
    assert (flag, state) == ("--state-dir", "/tmp/x-eval/eval-mcp/halden_ops")
    # The daemon refuses boot on the removed `approved` key; MCP tools are visible by default.
    assert "approved" not in server


def test_install_skills_lays_down_the_bundled_and_fixture_skills(tmp_path):
    # SkillRegistry seeds its bundled skills only into an EMPTY dir, so installing a
    # fixture skill alone would leave the eval home without self-knowledge.
    home = tmp_path / "x-eval"
    home.mkdir()
    seed.install_skills(str(home))
    installed = sorted(p.name for p in (home / "skills").iterdir())
    bundled = sorted(p for p in os.listdir(seed.BUNDLED_SKILLS_DIR)
                     if os.path.isfile(os.path.join(seed.BUNDLED_SKILLS_DIR, p, "SKILL.md")))
    assert set(bundled) <= set(installed) and "receipt-filing" in installed
    assert (home / "skills" / "receipt-filing" / "SKILL.md").is_file()


def test_install_skills_adds_the_private_holdouts_skills(tmp_path):
    home = tmp_path / "x-eval"
    home.mkdir()
    private = tmp_path / "fermix-eval-private"
    (private / "skills" / "notes-mailer").mkdir(parents=True)
    (private / "skills" / "notes-mailer" / "SKILL.md").write_text("---\nname: notes-mailer\n---\n")
    seed.install_skills(str(home), str(private))
    assert (home / "skills" / "notes-mailer" / "SKILL.md").is_file()
    assert (home / "skills" / "receipt-filing" / "SKILL.md").is_file()


def test_a_skill_named_in_two_sources_is_refused_not_silently_overwritten(tmp_path):
    home = tmp_path / "x-eval"
    home.mkdir()
    private = tmp_path / "fermix-eval-private"
    (private / "skills" / "garage").mkdir(parents=True)          # also a public fixture
    (private / "skills" / "garage" / "SKILL.md").write_text("---\nname: garage\n---\n")
    with pytest.raises(SystemExit):
        seed.install_skills(str(home), str(private))


def test_install_skills_refuses_a_skills_dir_that_was_not_reset(tmp_path):
    home = tmp_path / "x-eval"
    (home / "skills").mkdir(parents=True)
    with pytest.raises(SystemExit):
        seed.install_skills(str(home))


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


def test_reset_state_clears_the_coding_stores_sign_in_marks_and_keeps_the_rest_of_device(
        tmp_path):
    # M98 D10: a run that fails to sign in marks its agent signed out in this
    # machine's coding store (`Harness.MachineStore`, device/coding.db). A mark left
    # by one sweep's signed-out case must not greet the next sweep of the same home.
    # The computers' records beside it are the --computers seed's own, not sweep state.
    home = tmp_path / "x-eval"
    (home / "device" / "computers").mkdir(parents=True)
    record = home / "device" / "computers" / "6f1c2a9e-3b7d-4c21-9a8e-1d2f3a4b5c6d.json"
    record.write_text('{"v": 1}\n')
    store = [home / "device" / name for name in ("coding.db", "coding.db-wal", "coding.db-shm")]
    for path in store:
        path.write_text("a mark from the last sweep\n")

    seed.reset_state(str(home))

    assert not any(path.exists() for path in store)
    assert record.read_text() == '{"v": 1}\n'


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


def test_openai_codex_copies_its_sign_in_with_chatgpt_entry(tmp_path, monkeypatch):
    # openai_codex signs in with ChatGPT, whose entry the auth store keeps under
    # `chatgpt`; an older Codex-client entry under `openai_codex` is never read.
    dev = tmp_path / "dev"
    dev.mkdir()
    chatgpt = {"auth_mode": "oauth_siwc", "client_id": "oaiapp_seed", "status": "ready"}
    stale = {"auth_mode": "chatgpt", "status": "ready"}
    (dev / "auth.json").write_text(json.dumps(
        {"version": 2, "providers": {"chatgpt": chatgpt, "openai_codex": stale}}))
    monkeypatch.setattr(seed, "DEV_HOME", str(dev))
    home = tmp_path / "x-eval"
    home.mkdir()

    seed.copy_oauth_token(str(home), "openai_codex")

    copied = json.loads((home / "auth.json").read_text())
    assert copied == {"version": 2, "providers": {"chatgpt": chatgpt}}
    assert (home / "auth.json").stat().st_mode & 0o777 == 0o600


def test_no_separate_chatgpt_provider_is_seeded():
    assert "chatgpt" not in seed._OAUTH_PROFILE_KEY


def test_browser_and_harness_state_are_part_of_the_baseline():
    # ConfigStore owns browser/ (Chrome user-data dirs: cookies, local storage,
    # history) and Harness.Artifacts keeps harness/runs/<id>; both survive a sweep
    # and are inherited by the next one's web and harness tasks.
    assert "browser" in seed.STATE_DIRS and "harness" in seed.STATE_DIRS


def test_voice_turns_grok_voice_on_with_its_engine_and_no_key():
    cfg = seed.render_config(
        "/tmp/x-eval", "openai", {"default_model": "gpt-5.6-luna"}, None, voice="xai_realtime")
    doc = tomllib.loads(cfg)

    # The parser refuses a Grok model under the default openai_realtime engine,
    # so the engine is written beside the model; the provider follows from it.
    assert doc["fermix_core"]["realtime"] == {
        "enabled": True, "engine": "xai_realtime", "model": "grok-voice-3.0",
        "max_session_minutes": 5}
    # The voice key arrives as XAI_API_KEY at daemon boot, never on disk: no
    # xai provider block, and no key in any block that is written.
    assert "xai" not in doc["fermix_core"]["providers"]
    assert "api_key" not in cfg
    # Turning voice on grants nothing else: computer history stays off, in the
    # machine's own file (M97 §4).
    assert "computer_history" not in doc["fermix_core"]
    machine = tomllib.loads(seed.render_machine("/tmp/x-eval"))
    assert machine["fermix_core"]["computer_history"]["enabled"] is False


def test_voice_can_turn_gpt_live_on_with_its_engine_and_no_key():
    cfg = seed.render_config(
        "/tmp/x-eval", "anthropic", {"default_model": "claude-x"}, None, voice="openai_live")
    doc = tomllib.loads(cfg)

    # GPT-Live's one model under its own engine; the key is the openai provider's
    # slot, filled from OPENAI_API_KEY at daemon boot and never written here.
    assert doc["fermix_core"]["realtime"] == {
        "enabled": True, "engine": "openai_live", "model": "gpt-live-1",
        "max_session_minutes": 5}
    assert "openai" not in doc["fermix_core"]["providers"]
    assert "api_key" not in cfg and "OPENAI_API_KEY" in cfg
    # No consent of its own to grant, and none granted: the Realtime-only and
    # phone-only settings stay at the product's defaults, computer history off.
    realtime = doc["fermix_core"]["realtime"]
    assert "screen_share" not in realtime and "camera_share" not in realtime
    assert "computer_history" not in doc["fermix_core"]


def test_an_unknown_voice_engine_is_refused():
    with pytest.raises(ValueError, match="voice engine must be one of"):
        seed.voice_lines("openai_realtime")


@pytest.mark.parametrize("flags, engine, model", [
    (["--voice"], "xai_realtime", "grok-voice-3.0"),
    (["--voice", "--voice-engine", "xai_realtime"], "xai_realtime", "grok-voice-3.0"),
    (["--voice", "--voice-engine", "openai_live"], "openai_live", "gpt-live-1"),
])
def test_the_voice_engine_is_chosen_at_seed_time(tmp_path, monkeypatch, capsys, flags, engine,
                                                 model):
    doc = _seed_main(monkeypatch, tmp_path / "x-eval", *flags)

    assert (doc["fermix_core"]["realtime"]["engine"],
            doc["fermix_core"]["realtime"]["model"]) == (engine, model)
    key_env = seed.VOICE_ENGINES[engine][1]
    assert f"voice: {engine} ({model}) on; {key_env} must be set" in capsys.readouterr().out


def test_a_voice_engine_needs_voice(tmp_path, monkeypatch):
    with pytest.raises(SystemExit):
        _seed_main(monkeypatch, tmp_path / "x-eval", "--voice-engine", "openai_live")
    with pytest.raises(SystemExit):
        _seed_main(monkeypatch, tmp_path / "x-eval", "--voice", "--voice-engine", "grok")


def test_without_voice_the_eval_home_has_no_realtime_section():
    cfg = seed.render_config(
        "/tmp/x-eval", "openai", {"default_model": "gpt-5.6-luna"}, None)
    assert "realtime" not in tomllib.loads(cfg)["fermix_core"]


# --- cues (M60) -------------------------------------------------------------------

def _cues(mandates=False):
    return {"door_port": 45123, "mandates": mandates, "filter": ("openai", "gpt-cheap")}


def test_cues_are_on_with_every_source_its_token_store_and_the_default_filter():
    doc = tomllib.loads(seed.render_config(
        "/tmp/x-eval", "openai", {"default_model": "m"}, None, cues=_cues()))
    cues = doc["fermix_core"]["cues"]
    assert cues["enabled"] is True and cues["door_port"] == 45123
    assert sorted(cues["sources"]) == sorted(seed.CUE_SOURCES + (seed.CUE_WAITING_SOURCE,))
    for ref in seed.CUE_SOURCES:
        assert cues["sources"][ref] == {"kind": "local_push", "token": "@file"}
    # One webhook waits for its signing secret: the source "is any of them broken?"
    # finds. It has no token, so the cue runner's manifest never names it.
    assert cues["sources"][seed.CUE_WAITING_SOURCE] == {"preset": "github"}
    assert doc["fermix_core"]["routing"] == {"filter_provider": "openai",
                                             "filter_model": "gpt-cheap"}
    # Without --cue-mandates no plugin is enabled, so no turn sees a ticket tool.
    assert "plugins" not in doc["fermix_core"]


def test_cue_mandates_add_their_sources_and_the_stub_plugin_from_the_home():
    doc = tomllib.loads(seed.render_config(
        "/tmp/x-eval", "openai", {"default_model": "m"}, None, cues=_cues(mandates=True)))
    assert set(seed.CUE_MANDATE_SOURCES) <= set(doc["fermix_core"]["cues"]["sources"])
    assert doc["fermix_core"]["plugins"] == {"enabled": [seed.CUE_PLUGIN]}
    # The dev plugin folder is this computer's own (M97 §4).
    machine = tomllib.loads(seed.render_machine("/tmp/x-eval", cues=_cues(mandates=True)))
    assert machine["fermix_core"]["plugins"] == {"dev_local": "/tmp/x-eval/eval-plugins"}
    assert "plugins" not in tomllib.loads(seed.render_machine("/tmp/x-eval"))["fermix_core"]


def test_cue_fixtures_write_one_private_token_per_source_and_the_manifest(tmp_path):
    home = tmp_path / "x-eval"
    home.mkdir()
    manifest = seed.write_cue_fixtures(str(home), _cues(mandates=True))
    secrets = home / "secrets"
    assert secrets.stat().st_mode & 0o777 == 0o700
    for ref in seed.cue_sources(True):
        # The name SecretWriter.File reads for {:cue_source, ref, :token}.
        path = secrets / f"cue_source.{ref}.token"
        assert path.read_text() == manifest["sources"][ref]["token"]
        assert path.stat().st_mode & 0o777 == 0o600
    on_disk = json.loads((home / "eval-fixtures" / "cues.json").read_text())
    assert on_disk == manifest and on_disk["door_port"] == 45123
    plugin = json.loads((home / "eval-plugins" / seed.CUE_PLUGIN / "plugin.json").read_text())
    [tool] = plugin["tools"]
    assert tool["name"] == seed.CUE_PLUGIN_TOOL and tool["rail"] == "http"
    assert tool["request"]["url"].startswith("https://tickets.eval.invalid/")
    assert plugin["auth"] == {"type": "none"}


def test_tokens_are_fresh_on_every_seed(tmp_path):
    home = tmp_path / "x-eval"
    home.mkdir()
    first = seed.write_cue_fixtures(str(home), _cues())
    second = seed.write_cue_fixtures(str(home), _cues())
    assert first["sources"]["eval-news"]["token"] != second["sources"]["eval-news"]["token"]


def test_the_cue_filter_model_is_the_scored_model_unless_named():
    assert seed.cue_filter_route(None, "openai", {"default_model": "m"}) == ("openai", "m")
    assert seed.cue_filter_route("anthropic/haiku-x", "openai", {"default_model": "m"}) == (
        "anthropic", "haiku-x")
    with pytest.raises(SystemExit):
        seed.cue_filter_route("just-a-model", "openai", {"default_model": "m"})


def _seed_main(monkeypatch, home, *flags):
    monkeypatch.setattr(sys, "argv", ["seed_capability_home.py", str(home), "--provider",
                                      "openai", "--model", "gpt-x", *flags])
    seed.main()
    # M97 §4: the seed writes the machine's own settings beside config.toml.
    assert _machine(home)["sandbox"]["mode"] == "strict"
    return tomllib.loads((home / "config.toml").read_text())


def _machine(home):
    return tomllib.loads((home / seed.MACHINE_FILE).read_text())


# The harness keys that are each computer's own (M98 D5): Fermix reads them from
# machine.toml only and strips a copy from config.toml at boot.
_HARNESS_MACHINE_KEYS = {"approved", "codex_home", "claude_config_dir"}


@pytest.mark.parametrize("cues", [None, _cues()])
def test_the_harness_approval_is_this_computers_own_setting(cues):
    # Pre-granted in every eval home, and written where Fermix reads it: a copy in
    # config.toml would be stripped at boot and every harness suite would score 0.
    cfg = tomllib.loads(seed.render_config(
        "/tmp/x-eval", "openai", {"default_model": "m"}, None, cues=cues))
    assert not _HARNESS_MACHINE_KEYS & set(cfg["fermix_core"].get("harness", {}))
    harness = tomllib.loads(seed.render_machine("/tmp/x-eval", cues=cues))["fermix_core"]["harness"]
    assert harness["approved"] is True
    assert set(harness) <= _HARNESS_MACHINE_KEYS


def test_a_default_seed_leaves_cues_off_and_no_cue_manifest(tmp_path, monkeypatch):
    # Cues add manage_watcher and list_cues to every owner turn of every suite, so a
    # home gets them only when a run asks (--cues); a previous --cues seed's
    # manifests go, so the runners hold the cue suites out instead of driving them.
    home = tmp_path / "x-eval"
    on = _seed_main(monkeypatch, home, "--cues")
    assert on["fermix_core"]["cues"]["enabled"] is True
    assert (home / seed.CUE_MANIFEST).is_file()
    (home / seed.CUE_WATCHERS_MANIFEST).write_text("{}")   # what seed_cues.exs leaves

    off = _seed_main(monkeypatch, home)
    assert "cues" not in off["fermix_core"]
    assert "routing" not in off["fermix_core"] and "plugins" not in off["fermix_core"]
    assert not (home / seed.CUE_MANIFEST).exists()
    assert not (home / seed.CUE_WATCHERS_MANIFEST).exists()


def test_cues_ready_codex_and_leave_claude_code_unready_for_the_follow_up_cases(
        tmp_path, monkeypatch):
    # M60_WATCHER_CODING_RUNS.md §9: a follow-up naming Codex is ready to set up and
    # one naming Claude Code is not, whatever the host has installed; the harness
    # consent is granted for every home, and the operator's own sign-ins are never read.
    home = tmp_path / "x-eval"
    on = _seed_main(monkeypatch, home, "--cues")
    # The approval and both sign-in folders are this computer's own (M98 D5).
    assert "harness" not in on["fermix_core"]
    assert _machine(home)["fermix_core"]["harness"] == {
        "approved": True, "codex_home": str(home / seed.CUE_CODEX_HOME),
        "claude_config_dir": str(home / seed.CUE_CLAUDE_DIR)}
    assert not (home / seed.CUE_CLAUDE_DIR).exists()

    stub = home / seed.CUE_BIN_DIR / "codex"
    assert stub.stat().st_mode & 0o777 == 0o700
    version = subprocess.run([str(stub), "--version"], capture_output=True, text=True)
    assert version.returncode == 0 and version.stdout.strip() == "codex-cli eval-stub"
    assert subprocess.run([str(stub), "exec", "anything"], capture_output=True).returncode == 1
    auth = json.loads((home / seed.CUE_CODEX_HOME / "auth.json").read_text())
    assert auth["tokens"]["refresh_token"]
    # The stub account's model list, which Fermix checks a requested model against.
    models = json.loads((home / seed.CUE_CODEX_HOME / "models_cache.json").read_text())
    assert ("gpt-lantern-gray-latest", "Lantern Gray") in {
        (m["slug"], m["display_name"]) for m in models["models"]}

    # A seed without --cues takes the stubs away, so no other suite finds them.
    off = _seed_main(monkeypatch, home)
    assert "harness" not in off["fermix_core"]
    assert _machine(home)["fermix_core"]["harness"] == {"approved": True}
    assert not stub.exists() and not (home / seed.CUE_CODEX_HOME / "auth.json").exists()
    assert not (home / seed.CUE_CODEX_HOME / "models_cache.json").exists()


@pytest.mark.parametrize("flags", [["--cue-mandates"], ["--cue-filter-model", "openai/m"]])
def test_cue_options_need_cues(tmp_path, monkeypatch, flags):
    with pytest.raises(SystemExit):
        _seed_main(monkeypatch, tmp_path / "x-eval", *flags)


def test_the_door_port_is_free_and_not_the_default():
    port = seed.free_door_port()
    assert 1024 < port < 65536 and port != 4032


# --- the fixture server's port ------------------------------------------------------

def _fixture_manifest(home):
    return json.loads((home / seed.FIXTURE_MANIFEST).read_text())


@pytest.mark.parametrize("flags", [[], ["--cues"]])
def test_every_seed_records_a_fresh_fixture_port_that_is_not_the_door(
        tmp_path, monkeypatch, flags):
    # The runners bind it and capability-daemon.sh hands it to the daemon's
    # web_fetch, so every seed writes it, private, and a reseed picks again.
    home = tmp_path / "x-eval"
    cfg = _seed_main(monkeypatch, home, *flags)
    manifest = _fixture_manifest(home)
    assert set(manifest) == {"port"}
    assert isinstance(manifest["port"], int) and 1024 < manifest["port"] < 65536
    assert (home / seed.FIXTURE_MANIFEST).stat().st_mode & 0o777 == 0o600
    if flags:
        assert manifest["port"] != cfg["fermix_core"]["cues"]["door_port"]
    # The manifest is the seed's setup, not sweep state: no reset removes it.
    assert "eval-fixtures" not in seed.STATE_DIRS


def test_the_fixture_port_is_never_the_doors(monkeypatch):
    answers = iter([4301, 4301, 4302])
    monkeypatch.setattr(seed, "free_door_port", lambda: next(answers))
    assert seed.free_fixture_port(4301) == 4302


def test_a_fixture_port_probe_that_only_finds_the_door_is_refused(monkeypatch):
    monkeypatch.setattr(seed, "free_door_port", lambda: 4301)
    with pytest.raises(SystemExit):
        seed.free_fixture_port(4301)


# --- computers (M97) ---------------------------------------------------------------

# The rules `FermixChannels.Mobile.DeviceStore` reads a row by (decode_device/1,
# validate_new/1, validate_desktop/1, validate_loaded_uniqueness/2).
_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_ROW_REQUIRED = {"device_id", "name", "model", "noise_pk", "created_at"}
_ROW_OPTIONAL = {"kind", "apns_key_salt", "push_token", "last_seen", "platform", "signer_role",
                 "version_code", "boot_state", "device_locked", "relay_list_rev", "backups"}
_PHONE_ONLY = {"apns_key_salt", "push_token", "signer_role", "version_code", "boot_state",
               "device_locked"}
# The computer record (M97 §3.2): offer ids, states, and a sentence unless on.
_OFFER_IDS = {"files", "shell", "browser", "computer_use", "imessage", "history", "voice",
              "attachments", "accessory", "notifications"}
_OFFER_STATES = {"on", "off", "unavailable"}


def _utc(value):
    # DateTime.from_iso8601/1 must answer offset 0.
    assert isinstance(value, str) and value.endswith("Z"), value
    parsed = datetime.fromisoformat(value)
    assert parsed.utcoffset() == timedelta(0)
    return parsed


def _assert_desktop_row(row):
    assert _ROW_REQUIRED <= set(row) and set(row) <= _ROW_REQUIRED | _ROW_OPTIONAL, row
    assert not _PHONE_ONLY & set(row), row
    assert _UUID.match(row["device_id"])
    for field in ("name", "model"):
        assert 1 <= len(row[field].encode()) <= 255
    assert len(base64.b64decode(row["noise_pk"], validate=True)) == 32
    _utc(row["created_at"])
    _utc(row["last_seen"])
    assert row["kind"] == "desktop" and row["platform"] in ("macos", "linux")
    assert isinstance(row["backups"], bool)


def _assert_record(record, row):
    assert set(record) == {"v", "engine_version", "seen_at", "offers_rev", "offers"}
    assert record["v"] == 1 and record["engine_version"]
    assert re.fullmatch(r"[0-9a-f]{16}", record["offers_rev"])
    assert _utc(record["seen_at"]) == _utc(row["last_seen"])
    ids = [offer["id"] for offer in record["offers"]]
    assert len(ids) == len(set(ids)) and set(ids) <= _OFFER_IDS
    for offer in record["offers"]:
        assert set(offer) <= {"id", "state", "sentence", "detail", "roots", "home"}
        assert ("roots" not in offer) or (offer["id"] == "files" and offer["state"] == "on"
                                          and all(r.startswith("/") for r in offer["roots"]))
        assert offer["state"] in _OFFER_STATES
        assert ("sentence" in offer) == (offer["state"] != "on"), offer
        assert offer.get("sentence", "x") and offer.get("detail", "x")


def _offers(record):
    return {offer["id"]: offer for offer in record["offers"]}


def _computer_tree(home):
    """Every path the computers fixture owns, with its bytes (files) and mode."""
    tree = {}
    for top in ("mobile", "device", "eval-fixtures/computers.json"):
        root = home / top
        for path in [root, *sorted(root.rglob("*"))] if root.is_dir() else [root]:
            data = path.read_bytes() if path.is_file() else None
            tree[str(path.relative_to(home))] = (data, path.stat().st_mode & 0o777)
    return tree


def test_the_computers_fixture_writes_two_away_computers_the_store_reads(tmp_path):
    home = tmp_path / "x-eval"
    home.mkdir()
    seed.write_computer_fixtures(str(home))

    # The modes DeviceStore refuses anything but, and the same for the records.
    for directory in ("mobile", "device", "device/computers"):
        assert (home / directory).stat().st_mode & 0o777 == 0o700, directory
    devices = home / "mobile" / "devices.toml"
    assert devices.stat().st_mode & 0o777 == 0o600
    rows = tomllib.loads(devices.read_text())["devices"]
    assert [row["name"] for row in rows] == ["studio Mac", "loft Linux"]
    for row in rows:
        _assert_desktop_row(row)
    assert len({row["device_id"] for row in rows}) == 2
    assert len({row["noise_pk"] for row in rows}) == 2

    records = {}
    for row in rows:
        path = home / "device" / "computers" / f"{row['device_id']}.json"
        assert path.stat().st_mode & 0o777 == 0o600
        records[row["name"]] = json.loads(path.read_text())
        _assert_record(records[row["name"]], row)
    assert sorted(p.name for p in (home / "device" / "computers").iterdir()) == sorted(
        f"{row['device_id']}.json" for row in rows)

    # studio Mac: every usual offer on, its shell standard.
    mac = _offers(records["studio Mac"])
    assert {oid for oid, offer in mac.items() if offer["state"] == "on"} == {
        "files", "shell", "browser", "computer_use", "imessage", "history"}
    assert mac["shell"]["detail"] == "standard"
    # The folders files and commands reach there (M97 F5): never Downloads.
    assert mac["files"]["roots"] == ["/Users/avery/.fermix/workspace", "/Users/avery/Projects"]
    assert mac["files"]["home"] == "/Users/avery"
    # loft Linux: files, a strict shell and the browser; Messages and history cannot run.
    linux = _offers(records["loft Linux"])
    assert {oid for oid, offer in linux.items() if offer["state"] == "on"} == {
        "files", "shell", "browser"}
    assert linux["shell"]["detail"] == "strict"
    assert linux["files"]["roots"] == ["/home/rowan/.fermix/workspace"]
    assert linux["imessage"] == {"id": "imessage", "state": "unavailable",
                                 "sentence": "Messages runs only on a Mac."}
    assert linux["history"] == {"id": "history", "state": "unavailable",
                                "sentence": "Fermix records computer history only on a Mac for now."}
    assert {row["platform"] for row in rows} == {"macos", "linux"}

    manifest = json.loads((home / seed.COMPUTERS_MANIFEST).read_text())
    assert [c["name"] for c in manifest["computers"]] == ["studio Mac", "loft Linux"]


def test_a_second_computers_seed_writes_the_same_bytes(tmp_path, monkeypatch):
    home = tmp_path / "x-eval"
    _seed_main(monkeypatch, home, "--computers")
    first = _computer_tree(home)
    _seed_main(monkeypatch, home, "--computers")
    assert _computer_tree(home) == first
    assert any(path.endswith(".json") and path.startswith("device") for path in first)


def test_computers_turn_always_on_on_and_a_seed_without_them_takes_them_away(
        tmp_path, monkeypatch, capsys):
    # The `## Computers` section joins every owner turn of every suite, so a home
    # has the computers only when a run asks (--computers), like cues.
    home = tmp_path / "x-eval"
    on = _seed_main(monkeypatch, home, "--computers")
    assert on["fermix_core"]["always_on"] == {"enabled": True}
    assert "computers: studio Mac and loft Linux linked, both away" in capsys.readouterr().out
    written = seed.computer_paths(str(home))
    assert all(os.path.isfile(path) for path in written)

    off = _seed_main(monkeypatch, home)
    assert "always_on" not in off["fermix_core"]
    assert not any(os.path.exists(path) for path in written)


def test_without_computers_the_config_has_no_always_on_section():
    cfg = seed.render_config("/tmp/x-eval", "openai", {"default_model": "m"}, None)
    assert "always_on" not in tomllib.loads(cfg)["fermix_core"]


# --- a signed-out Claude Code (M98 D10) ------------------------------------------

# Claude Code's terminal line for a run it cannot sign in for, as `Harness.Run`
# quotes it; the lines before it are to confirm against a real signed-out CLI.
_NOT_LOGGED_IN = ('{"type":"result","subtype":"success","is_error":true,'
                  '"result":"Not logged in · Please run /login"}')


def _claude_run(stub):
    """The stub run the way `Adapters.ClaudeHeadless` renders a run."""
    return subprocess.run(
        [str(stub), "-p", "--output-format", "stream-json", "--verbose", "--disallowed-tools",
         "Edit(.codex/**)", "--", "Add a --shout flag to the greeter."],
        capture_output=True, text=True, encoding="utf-8", env={"PATH": "/usr/bin:/bin"})


def test_coding_signed_out_puts_a_claude_first_that_fails_every_run_as_signed_out(
        tmp_path, monkeypatch, capsys):
    home = tmp_path / "x-eval"
    on = _seed_main(monkeypatch, home, "--coding-signed-out")
    stub = home / seed.CLAUDE_STUB
    assert stub.parent == home / seed.CUE_BIN_DIR   # the folder the daemon's PATH starts with
    assert stub.stat().st_mode & 0o777 == 0o700
    assert "coding signed out:" in capsys.readouterr().out

    # Found at boot: `Harness.Vendors` reads the first line of `--version`.
    version = subprocess.run([str(stub), "--version"], capture_output=True, text=True)
    assert version.returncode == 0 and version.stdout.strip()

    run = _claude_run(stub)
    assert run.returncode == 1
    lines = run.stdout.splitlines()
    events = [json.loads(line) for line in lines]
    # The init event carries the session id the adapter records; the terminal
    # `result` event, with its words, is the last line.
    assert events[0]["type"] == "system" and events[0]["subtype"] == "init"
    assert events[0]["session_id"]
    assert lines[-1] == _NOT_LOGGED_IN
    assert [e["type"] for e in events].count("result") == 1

    # Nothing else in the home changes: the approval stays the only harness key,
    # and Claude Code's sign-in folder is the host's own as in any other seed.
    assert "harness" not in on["fermix_core"]
    assert _machine(home)["fermix_core"]["harness"] == {"approved": True}


def test_a_seed_without_coding_signed_out_takes_the_stub_claude_away(tmp_path, monkeypatch):
    home = tmp_path / "x-eval"
    _seed_main(monkeypatch, home, "--coding-signed-out", "--cues")
    claude, codex = home / seed.CLAUDE_STUB, home / seed.CUE_BIN_DIR / "codex"
    assert claude.is_file() and codex.is_file()

    # Each flag takes away only its own stub.
    _seed_main(monkeypatch, home, "--cues")
    assert not claude.exists() and codex.is_file()
    _seed_main(monkeypatch, home, "--coding-signed-out")
    assert claude.is_file() and not codex.exists()
    _seed_main(monkeypatch, home)
    assert not claude.exists() and not codex.exists()


def test_computers_refuse_a_devices_file_the_seed_did_not_write(tmp_path, monkeypatch):
    # An eval home pairs nothing, so a devices file with no manifest is someone
    # else's: refused, never overwritten, and a seed without --computers leaves it.
    home = tmp_path / "x-eval"
    (home / "mobile").mkdir(parents=True)
    foreign = home / "mobile" / "devices.toml"
    foreign.write_text("devices = []\n")
    with pytest.raises(SystemExit):
        seed.write_computer_fixtures(str(home))
    assert foreign.read_text() == "devices = []\n"
    seed.clear_computer_fixtures(str(home))
    assert foreign.read_text() == "devices = []\n"


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
