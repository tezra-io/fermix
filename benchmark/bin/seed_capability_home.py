#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Seed a disposable capability-eval FERMIX_HOME so `make capability` can run.

Creates the home, a git-backed workspace (the checker's per-trial scoring root),
a minimal config.toml with a strict machine.toml beside it (the sandbox and the
coding agents' approval are the machine's own settings), and the auth the scored
model needs. The scored
model is DERIVED from the primary provider in ~/.fermix-dev/config.toml, so the
disposable daemon benchmarks the same model you develop against, reusing the dev
home's credentials:

  * OAuth providers (openai_codex / anthropic / xai) store their token
    home-scoped in $FERMIX_HOME/auth.json, so a fresh home has none. The seed
    copies just that provider's entry from ~/.fermix-dev/auth.json (0600); see
    copy_oauth_token for the read-only / no-rotation guarantee.
  * API-key providers keep `[fermix_core] profile = "<dev profile>"` + a
    `@keyring` sentinel, so the existing `fermix:<profile>:<ENV>` keychain
    entry resolves unchanged.

The sandbox is always regenerated strict + home-scoped (never copied from the
dev config, whose allowed_roots escape the home and would fail the runner's
precondition). `<home>/skills` is always included as a sandbox root — skill
tasks verify their created SKILL.md with raw file reads, and the owner-approval
detour a denial triggers is unanswerable in an eval. Every seed also restores
the home's durable-state baseline (`reset_state`: skills, memory, jobs, journals,
grants, bootstrap), so a sweep measures the product rather than what the previous
sweep's model left behind. Regenerate on every `up`, with the daemon DOWN.

CI / explicit mode (`--provider` + `--model`) skips the dev-home derivation
entirely: no keychain, no auth.json copy, no `[fermix_core] profile` line. The
provider block carries no `api_key` — the daemon fills it at boot from the
provider's environment variable (config/runtime.exs), so no secret lands on
disk. Only api-key-env providers (plus keyless ollama) work here; OAuth
providers need the dev-home derivation. `--allow-root` appends absolute paths
to the sandbox `allowed_roots` (e.g. the repo checkout for behavioral
repo-read cases); omit it for capability runs, whose preconditions refuse any
root outside the home (the always-present `<home>/skills` root is in-home).

`--cues` (M60) turns cues on for the cue suites: `[fermix_core.cues]`
enabled on a free door port picked at seed time (so two eval homes never share
one), the local-push sources the cue suites post to with their tokens in the
`@file` store, and the default filter model (the scored model unless
`--cue-filter-model PROVIDER/MODEL` names a cheaper one). It is off by default:
cues add `manage_watcher` and `list_cues` to every owner turn, which would move
the measured surface of every unrelated suite for a feature that is off by default. The
watchers and their tasks live in memory.db, so `seed_cues.exs` makes them after
this script, with the daemon still down (`capability-daemon.sh up` runs it when
`eval-fixtures/cues.json` exists). That manifest records the door port and the
tokens for the `drive: cue` runner; a seed without `--cues` removes it and the
watchers' manifest, so the cue suites are held out as NOT EVALUATED, never scored.
`--cue-mandates` (needs `--cues`) adds the stub `http` plugin and the two
auto-mode mandates the mandate cases need; without it those cases are held out.
`--cues` also readies the coding agents for the follow-up cases
(M60_WATCHER_CODING_RUNS.md §9) without touching the operator's own: a stub
`codex` in `<home>/eval-bin` (`capability-daemon.sh` puts it first on the
daemon's PATH; it answers `--version` and refuses to run anything), a stub
Codex sign-in in `<home>/eval-codex` (`codex_home`), and a Claude Code config
dir that does not exist (`claude_config_dir`), so Claude Code is never ready
whether or not its program is installed. The harness consent is pre-granted
for every home (`harness_lines`); it and both folders are machine.toml keys.

`--voice` turns voice on for the `drive: voice` suites (grok_voice.yaml,
voice_greeting_goodbye.yaml): `[fermix_core.realtime]` enabled with one task
engine and its one model. `--voice-engine` picks it: `xai_realtime` (Grok Voice,
`grok-voice-3.0`, the default) or `openai_live` (GPT-Live, `gpt-live-1`), so a
suite that covers both engines runs once per engine. The voice key is the
engine's provider api_key slot, filled at daemon boot from `XAI_API_KEY` or
`OPENAI_API_KEY` (config/runtime.exs) and never written here; the realtime
socket starts only in a daemon run with realtime on (`mix fermix.dev`, not
`--no-realtime`) and that key present.

`--computers` (M97) makes the home an Always On server with two linked
computers, both away, for the computers suite (suites/computers.yaml): a
desktop row each in `mobile/devices.toml` (what `DeviceStore` reads) and a
record each in `device/computers/<device_id>.json` (its last offers, engine
version and when it was last seen), with `[fermix_core.always_on]` turned on so
a release build serves the `## Computers` section too (a dev build serves it
regardless). It is off by default: the section joins every owner turn, which
would move the measured prompt of every unrelated suite. No session ever
exists in an eval, so both computers are listed as away. The studio Mac offers
`places` (D13) and the home's place search is set to `backend = "computer"`,
so the home looks places up on that Mac, as a server does, and finds it away:
a dev build on a Mac would otherwise search Apple Maps itself. The seed records what
it wrote in `eval-fixtures/computers.json`; a seed without `--computers`
removes all of it, and a seed with it refuses a devices file it did not write.

Every seed picks a free loopback port for the runners' fixture server and
records it in `eval-fixtures/fixture_server.json` (`{"port": N}`), picked at
seed time like the cue door's (and never the door's own). `capability-daemon.sh`
starts the daemon with `FERMIX_EVAL_FIXTURE_ORIGIN=http://127.0.0.1:N` from it,
the one origin a development build's `web_fetch` reads past its private-address
guard, and both runners bind exactly that port (`evallib.fixture_server`), so a
fixture page is readable by `web_fetch` as well as the browser. A home without
the manifest (one seeded before it existed) gets neither.

`--coding-signed-out` (M98 D10) gives coding_harness's signed-out case a Claude
Code that fails every run as signed out: a stub `claude` in `<home>/eval-bin`
(`capability-daemon.sh` puts that folder first on the daemon's PATH) that
answers `--version` and, for a run, prints Claude Code's stream for a run it
cannot sign in for, ending "Not logged in · Please run /login", and exits 1. The
run starts no vendor and spends nothing outside Fermix. Off by default: with it,
every Claude Code run in the home fails, the lifecycle cases' included. A seed
without it removes the stub; the case's `requires: [coding_signed_out]` holds it
out of a home seeded without it.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tomllib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from evallib import safe_rm  # noqa: E402
from evallib.fixture_server import FIXTURE_MANIFEST  # noqa: E402

DEV_HOME = os.path.expanduser("~/.fermix-dev")
# This computer's own settings, beside config.toml (M97 §4): the engine reads
# the sandbox, computer use and history, the accessory link, what Fermix on a
# server may use on this computer (`[fermix_core.computer]`) and the dev plugin
# folder from it only. iMessage's section is the home's, in config.toml.
MACHINE_FILE = "machine.toml"
MACHINE_TABLES = ("sandbox", "fermix_core.computer_use", "fermix_core.computer_history",
                  "fermix_channels.accessories", "fermix_core.computer")
# Keys of a home table that are this computer's own, as table and key: the dev
# plugin folder (M97 §4), and the coding agents' approval and sign-in folders
# (M98 D5). The engine reads them from machine.toml only and strips a copy from
# config.toml at boot; the rest of `[fermix_core.harness]` stays in config.toml.
MACHINE_KEYS = (("fermix_core.plugins", "dev_local"),
                ("fermix_core.harness", "approved"),
                ("fermix_core.harness", "codex_home"),
                ("fermix_core.harness", "claude_config_dir"))
# Homes this script must never touch, compared as REALPATHS so a symlink cannot dress
# one of them up as a disposable eval home.
_NON_DISPOSABLE = tuple(os.path.realpath(os.path.expanduser(p))
                        for p in ("~/.fermix", "~/.fermix-dev", "~"))
# Durable state the daemon accumulates under a FERMIX_HOME. Reset on every seed so a
# sweep measures the product, not the residue of the previous sweep. Layout mirrors
# `FermixCore.Setup.ConfigStore` (`workspace_paths/0`, `memory_paths/0`) and
# `Jobs.Runner`'s output base; the sqlite sidecars go with the database they belong to.
# `workspace/` is NOT here: the checker seeds and tears down its own per-trial scoring
# dir under it, and the daemon's git-backed workspace root is part of the home's setup.
# `browser/` holds the Chrome user-data dirs (cookies, local storage, history) that
# `ChromeLauncher` persists per owner/profile, and `harness/` holds `Harness.Artifacts`
# run trees — both survive a sweep and are inherited by the next one's web and harness
# tasks, which is the residue this reset exists to remove.
# `device/coding.db` is this machine's coding store (`Harness.MachineStore`, M98 D3),
# where a run that fails to sign in marks its agent signed out (D10): the mark is
# sweep state, while the rest of `device/` (the --computers records) is the seed's.
STATE_DIRS = ("skills", "memory", "job_runs", "journals", "grants", "bootstrap",
              "browser", "harness", "eval-mcp")
STATE_FILES = ("memory.db", "memory.db-wal", "memory.db-shm",
               os.path.join("device", "coding.db"), os.path.join("device", "coding.db-wal"),
               os.path.join("device", "coding.db-shm"))
# Only these keys are allowed in a provider block (else the daemon refuses boot).
_PROVIDER_KEYS = ("default_model", "reasoning_effort", "auth_mode", "base_url", "api_key")
# M45 external skill credentials: one allowed sandbox variable whose value a harmless
# `command` source prints from a file this seed writes — the same record shape a value
# stored from Settings > Sandbox has, with no keychain and no operator environment. The
# cap_skill_credentials checker reads the same file for its gold, so the value lives
# here and nowhere else. At least 8 bytes, so the shell's redaction floor applies.
SKILL_TOKEN_NAME = "FERMIX_EVAL_SKILL_TOKEN"
SKILL_TOKEN_VALUE = "fxeval-desk-7Kq2-Rm9p"
SKILL_TOKEN_FILE = os.path.join("eval-fixtures", "skill_token")
# The cap_tool_discovery fixtures. Operator MCP tools are deferred exactly like plugin
# tools, so the invented halden_ops server is the eval home's deferred surface (a fresh
# home has no plugins, so without it nothing there is ever deferred); receipt-filing is a
# skill whose instructions are not in the prompt. The server keeps its state under
# eval-mcp/, which reset_state clears with the rest of the baseline. The same server is
# cap_untrusted_content's hostile surface (its order_notes tool); that pack needs no
# consent gate granted, because the writes its injection asks for must stay possible.
BENCH_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURE_MCP_SERVER = os.path.join(BENCH_DIR, "suites", "capability", "fixtures", "mcp",
                                  "halden_ops.py")
FIXTURE_SKILLS_DIR = os.path.join(BENCH_DIR, "suites", "capability", "fixtures", "skills")
# The skills the daemon itself seeds. `SkillRegistry` copies them only into an EMPTY
# skills dir, so a seeder that installs a fixture skill must lay these down too or the
# eval home would silently run without them.
BUNDLED_SKILLS_DIR = os.path.join(os.path.dirname(BENCH_DIR), "apps", "fermix_core", "priv",
                                  "skills")
MCP_STATE_DIR = "eval-mcp"
# Primary provider id -> its key in the Fermix auth store ($FERMIX_HOME/auth.json),
# for OAuth providers whose token must be copied into the disposable home.
# openai_codex signs in with ChatGPT, whose entry lives under `chatgpt`. Its access
# tokens last one hour and its refresh token rotates on every use: a run that
# outlives the copied access token refreshes in the eval home, and the dev home's
# copy is then refused as reused, so the dev home must sign in again. The copied
# entry carries the registration's issued client id; the eval home gets no host id
# file, because only a sign-in needs one.
_OAUTH_PROFILE_KEY = {
    "openai_codex": "chatgpt",
    "anthropic": "anthropic_oauth",
    "xai": "xai_oauth",
}
# Providers whose api_key the daemon reads from an environment variable at boot
# (config/runtime.exs); the explicit/CI mode supports exactly these + ollama.
# The task engines `--voice` can turn on (M70 Grok Voice, M41 GPT-Live): each
# engine's one shipped model and the daemon environment variable its provider's
# api_key slot is filled from at boot. The parser refuses either model under the
# default `openai_realtime` engine, so the engine is written beside the model;
# the provider follows from the engine.
VOICE_ENGINES = {
    "xai_realtime": ("grok-voice-3.0", "XAI_API_KEY"),
    "openai_live": ("gpt-live-1", "OPENAI_API_KEY"),
}
DEFAULT_VOICE_ENGINE = "xai_realtime"
# A spend bound for a disposable home: a voice case's call lasts a few minutes
# at most, and the daemon ends one that outlives this whatever its client does.
VOICE_MAX_SESSION_MINUTES = 5
# Cues (M60). Each local-push source the cue suites post to: the watcher that
# listens to it is made by seed_cues.exs, one watcher per source so a cue posted
# for one case never wakes another case's task. `eng-blogs` has no watcher: the
# behavioral suite's owner asks for one on it.
CUE_SOURCES = ("eval-news", "eval-alerts", "eval-research", "team-digest", "eng-blogs")
# With --cue-mandates: one source and watcher per mandate (a job takes one mandate).
CUE_MANDATE_SOURCES = ("eval-ops", "eval-ops-checked")
# A GitHub webhook with no signing secret stored: it waits for one, the source the
# behavioral suite's "is any of them broken?" finds. Nothing posts to it, it has no
# token, and the cue runner's manifest never names it.
CUE_WAITING_SOURCE = "release-hooks"
CUE_MANIFEST = os.path.join("eval-fixtures", "cues.json")
CUE_WATCHERS_MANIFEST = os.path.join("eval-fixtures", "cue_watchers.json")
# The stub http plugin the mandates grant. Its one tool posts to a host that
# cannot resolve (`.invalid`, RFC 2606), so an allowed call executes and fails
# without leaving the machine.
CUE_PLUGIN_DIR = "eval-plugins"
CUE_PLUGIN = "eval_tickets"
CUE_PLUGIN_TOOL = "eval_tickets_file"
# The follow-up cases' coding agents (with --cues): a stub `codex` first on the
# daemon's PATH, a stub Codex sign-in, and a Claude Code config dir never made.
CUE_BIN_DIR = "eval-bin"
CUE_CODEX_HOME = "eval-codex"
CUE_CLAUDE_DIR = "eval-claude"
CODEX_STUB = """#!/bin/sh
# The cue evals' stand-in for the Codex CLI (seed_capability_home.py --cues): it
# makes a follow-up that names Codex ready to set up, and never runs one.
if [ "$1" = "--version" ]; then
  echo "codex-cli eval-stub"
  exit 0
fi
echo "codex stub: the cue evals never run Codex" >&2
exit 1
"""
# The stub account's model list, as Codex caches it in its own config dir. Fermix
# checks a requested Codex model against it before launching, so a case asking
# for a model by its shown name finds the id only in Fermix's refusal. Invented.
CODEX_MODEL_LIST = {
    "fetched_at": "2026-11-03T04:00:00Z",
    "models": [
        {"slug": "gpt-lantern-gray-latest", "display_name": "Lantern Gray", "visibility": "list"},
        {"slug": "gpt-harbor-mist", "display_name": "Harbor Mist", "visibility": "list"},
        {"slug": "gpt-quiet-reserve", "display_name": "Quiet Reserve", "visibility": "hide"},
    ],
}
# With --coding-signed-out (M98 D10): a stub `claude` in the same folder, first on
# the daemon's PATH, that fails every run the way Claude Code fails one it cannot
# sign in for. The adapter reads the session id from the `system`/`init` event and
# the vendor's words from the terminal `result` event (the line `Harness.Run`
# quotes); the lines a real signed-out CLI prints between them are to confirm.
# The session id is invented.
CLAUDE_STUB = os.path.join(CUE_BIN_DIR, "claude")
CLAUDE_STUB_INIT = {"type": "system", "subtype": "init",
                    "session_id": "3f6b2d84-91ce-4a07-b5e2-6d0c8a71f9e3",
                    "apiKeySource": "none", "claude_code_version": "eval-stub"}
CLAUDE_NOT_LOGGED_IN = {"type": "result", "subtype": "success", "is_error": True,
                        "result": "Not logged in · Please run /login"}


def _json_line(event: dict) -> str:
    return json.dumps(event, ensure_ascii=False, separators=(",", ":"))


CLAUDE_SIGNED_OUT_STUB = f"""#!/bin/sh
# The coding_harness suite's stand-in for a signed-out Claude Code
# (seed_capability_home.py --coding-signed-out): it answers --version, and every
# run prints the stream Claude Code prints when it is not signed in, then exits 1.
if [ "$1" = "--version" ]; then
  echo "eval-stub (Claude Code)"
  exit 0
fi
printf '%s\\n' '{_json_line(CLAUDE_STUB_INIT)}'
printf '%s\\n' '{_json_line(CLAUDE_NOT_LOGGED_IN)}'
exit 1
"""
# Computers (M97), with --computers: two computers linked to this home, neither
# with a session. Each is a desktop row in the paired-device store (`DeviceStore`:
# lowercase uuid, name and model 1..255 bytes, a unique 32-byte Noise key, ISO
# 8601 UTC times, no phone field) and a record of what it last said about itself.
# `model` is the string the move writes for each system. Each files offer names
# the folders files and commands reach on that computer (`roots`, M97 F5) and
# the home `~` stands for there (`home`): the studio Mac its workspace and
# Projects (standard), loft Linux its workspace (strict), never Downloads. Every value is invented, and fixed, so every seed
# writes the same bytes.
COMPUTERS_MANIFEST = os.path.join("eval-fixtures", "computers.json")
HISTORY_MANIFEST = os.path.join("eval-fixtures", "computer_history.json")
DEVICES_FILE = os.path.join("mobile", "devices.toml")
COMPUTER_RECORDS_DIR = os.path.join("device", "computers")
COMPUTERS = (
    {"device_id": "6f1c2a9e-3b7d-4c21-9a8e-1d2f3a4b5c6d", "name": "studio Mac",
     "model": "macOS desktop", "platform": "macos", "backups": True,
     "created_at": "2026-10-02T09:00:00Z", "last_seen": "2026-11-09T22:40:00Z",
     "engine_version": "0.19.0", "offers_rev": "3a7c19e04b2d58f6",
     "offers": [{"id": "files", "state": "on",
                 "roots": ["/Users/avery/.fermix/workspace", "/Users/avery/Projects"],
                 "home": "/Users/avery"},
                {"id": "shell", "state": "on", "detail": "standard"},
                {"id": "browser", "state": "on"},
                {"id": "computer_use", "state": "on"},
                {"id": "imessage", "state": "on"},
                {"id": "history", "state": "on"},
                {"id": "places", "state": "on"}]},
    {"device_id": "b47e0d93-5a1c-4f68-8e2b-7c9d1a3f6e05", "name": "loft Linux",
     "model": "Linux desktop", "platform": "linux", "backups": False,
     "created_at": "2026-10-19T16:30:00Z", "last_seen": "2026-11-06T14:05:00Z",
     "engine_version": "0.19.0", "offers_rev": "c81e5f2a90d7b346",
     "offers": [{"id": "files", "state": "on", "roots": ["/home/rowan/.fermix/workspace"],
                 "home": "/home/rowan"},
                {"id": "shell", "state": "on", "detail": "strict"},
                {"id": "browser", "state": "on"},
                {"id": "imessage", "state": "unavailable",
                 "sentence": "Messages runs only on a Mac."},
                {"id": "history", "state": "unavailable",
                 "sentence": "Fermix records computer history only on a Mac for now."},
                {"id": "places", "state": "unavailable",
                 "sentence": "Looking places up in Apple Maps needs the Fermix app on a Mac."}]},
)
_ENV_KEY_PROVIDERS = {
    "openai": "OPENAI_API_KEY",
    "anthropic": "ANTHROPIC_API_KEY",
    "xai": "XAI_API_KEY",
    "openrouter": "OPENROUTER_API_KEY",
    "mistral": "MISTRAL_API_KEY",
    "venice": "VENICE_API_KEY",
}


def die(msg: str) -> None:
    print(f"seed_capability_home: {msg}", file=sys.stderr)
    raise SystemExit(1)


def primary_provider(dev: dict) -> tuple[str, dict, str | None]:
    core = dev.get("fermix_core", {})
    providers = core.get("providers", {})
    primary = [(pid, blk) for pid, blk in providers.items()
               if isinstance(blk, dict) and blk.get("primary") is True]
    if len(primary) != 1:
        die(f"expected exactly one primary provider in {DEV_HOME}/config.toml, found {len(primary)}")
    pid, blk = primary[0]
    if not blk.get("default_model"):
        die(f"primary provider {pid} has no default_model")
    return pid, blk, core.get("profile")


def dev_provider(dev: dict, pid: str) -> tuple[str, dict, str | None]:
    """A NAMED provider block from the dev config, scored as this home's primary: same
    model, effort and auth (keychain entry or OAuth login) the dev home uses for it.
    Lets a configuration arm score any configured provider, OAuth ones included,
    without exporting a key."""
    core = dev.get("fermix_core", {})
    blk = core.get("providers", {}).get(pid)
    if not isinstance(blk, dict):
        die(f"no [fermix_core.providers.{pid}] in {DEV_HOME}/config.toml")
    if not blk.get("default_model"):
        die(f"provider {pid} has no default_model in {DEV_HOME}/config.toml")
    return pid, blk, core.get("profile")


def render_config(
    home: str, pid: str, blk: dict, profile: str | None,
    explicit: bool = False, voice: str | None = None, cues: dict | None = None,
    computers: bool = False,
) -> str:
    uses_key = "api_key" in blk
    if explicit:
        source_note = ("# Disposable eval daemon (explicit/CI spec): strict, home-scoped sandbox; no\n"
                       "# channels/realtime; the provider key arrives via env at daemon boot, never on disk.")
    else:
        source_note = ("# Disposable capability-eval daemon: scores the ~/.fermix-dev primary model in a\n"
                       "# strict, home-scoped sandbox. No channels/realtime; auth reused from the dev home.")
    lines = [
        "# Managed by benchmark/bin/seed_capability_home.py — regenerated on each run.",
        source_note,
        "",
    ]
    # The profile ties @keyring back to the operator's keychain namespace; only
    # needed when the scored provider authenticates with an api key.
    if uses_key and isinstance(profile, str) and profile.strip():
        lines += ["[fermix_core]", f'profile = "{profile.strip()}"', ""]
    lines += [f"[fermix_core.providers.{pid}]", "primary = true"]
    for key in _PROVIDER_KEYS:
        if key == "api_key":
            if uses_key:
                lines.append('api_key = "@keyring"')
            continue
        if key in blk and blk[key] not in (None, ""):
            lines.append(f'{key} = "{blk[key]}"')
    # The halden_ops fixture MCP server (cap_tool_discovery). `/usr/bin/env python3`
    # because the server is standard-library only and this seeder's interpreter lives
    # in a uv cache the daemon should not depend on.
    server_args = ["python3", FIXTURE_MCP_SERVER,
                   "--state-dir", os.path.join(home, MCP_STATE_DIR, "halden_ops")]
    lines += ["[mcp.servers.halden_ops]", 'command = "/usr/bin/env"',
              f"args = [{', '.join(json.dumps(arg) for arg in server_args)}]", ""]
    # No `[fermix_core.harness]` here: the coding agents' approval and sign-in
    # folders are this computer's own (`render_machine`), and the home's harness
    # keys are left unset: default_vendor (so both CLIs stay advertised for tasks
    # that name either) and cloud_enabled (defaults off — the cloud rail is not
    # evaluated).
    # Meetings (MILESTONE_21) are off until the operator turns them on, and a
    # fresh eval home has never made that decision — so `Meetings.ready?()` is
    # false, the seeder registers NO meetings tool, and a task asking the
    # notetaker to join scores 0 with nothing wrong in the product. Same rule as
    # the harness consent (`harness_lines`): pre-grant every human-decision gate, scoped to
    # this throwaway home. It is deliberately not sufficient on its own —
    # `ready?()` also wants an installed meetbot sidecar or complete Zoom RTMS
    # credentials, and this seeder installs neither — so a home that never gets a
    # lane still advertises nothing and refuses locally rather than dialling out.
    lines += ["[fermix_core.meetings]", "enabled = true", ""]
    # Computer history stays off: see `render_machine`, which writes it.
    # The StackChan accessory link (M91) is another deliberate exception, and
    # it is not seeded: on, the daemon lists this Mac's USB serial ports every
    # two seconds and would open a port a paired robot's serial names, which
    # reaches real hardware on the eval host. No capability task needs it, and
    # the accessory_voice behavioral suite answers from self-knowledge with the
    # link off, so leaving its default (off) blocks nothing.
    # Computer use is not seeded at all, so its experimental `background` gate
    # (M42 slice 5) is off here as it is everywhere — deliberately, and recorded
    # so its absence never reads as an oversight either. It is the second
    # exception to pre-grant-every-gate: the surface needs a real window on a real
    # display and a person watching an on-screen panel appear over it, which is
    # exactly what a disposable home has none of, and the whole computer-use suite
    # is risk `desktop_input`, a class `make capability-auto` never loads. Its one
    # bound-window behavioural case is labelled attended and is run by hand.
    # Skill curation stays OFF in eval homes (MILESTONE_26_SKILL_CURATION §11):
    # the +15d first cycle already makes scheduled firing impossible during an
    # eval window, but a disabled entry also keeps /skills inert if a candidate
    # model wanders into it, and keeps suite behavior independent of daemon
    # uptime.
    lines += ["[fermix_core.skill_curation]", "enabled = false", ""]
    # Open loops (MILESTONE_78) are off until the owner turns them on, and a fresh
    # eval home has never made that decision — so the open_loop_* tools are not
    # advertised, the scheduler never starts, and both open-loop suites
    # (open_loops.yaml, capability/candidates/open_loop_checkin.yaml) score 0 with
    # nothing wrong in the product. Same rule as the harness consent (`harness_lines`):
    # pre-grant every human-decision gate, scoped to this throwaway home. `enabled`
    # is the section's only key; any other stops the daemon booting.
    lines += ["[fermix_core.open_loops]", "enabled = true", ""]
    # Temporal events (MILESTONE_30) hinge on two operator-setup decisions a
    # fresh home lacks, and event_store fails loudly without both — an unseeded
    # home would score every reminder task 0 with nothing wrong in the product
    # (the eval-home pitfall: pre-grant every human-decision gate here). The
    # delivery target names a platform this home holds no credentials for:
    # event acceptance only checks that the adapter module resolves, and if an
    # eval-window reminder ever came due, the unconfigured adapter terminates
    # the attempt first-try as adapter_unavailable without touching the network.
    lines += ["[fermix_core.jobs]", 'default_delivery_mode = "channel"', ""]
    lines += ["[fermix_core.jobs.default_delivery_target]",
              'platform = "telegram"', 'chat_id = "100001"', ""]
    # The owner-inbox ladder (`Delivery.OwnerInbox`) accepts that target only when
    # it IS the owner's own inbox, which it tells by the channel's explicit
    # `owner_user_id`. Without one, open-loop capture (M78) refuses every loop as
    # `:no_target` and the behavioural suite scores zero with nothing wrong in the
    # product: the pre-grant-every-gate rule again. The section carries the owner
    # id and nothing else; with no `bot_token` the Telegram poller stays in the
    # same misconfigured posture it has in every eval home today.
    lines += ["[fermix_channels.telegram]", 'owner_user_id = "100001"', ""]
    lines += ["[fermix_core.personalization]", 'user_name = "Eval Operator"',
              'timezone = "America/New_York"', 'communication_style = "concise"', ""]
    if voice:
        lines += voice_lines(voice)
    if cues:
        lines += cue_lines(home, cues)
    # With --computers: the home serves Always On, which the `## Computers`
    # section needs. A dev build serves it whatever this says; a release build
    # (`Home.AlwaysOnRelease`) only with it. `enabled` is the section's only key.
    if computers:
        lines += ["# Always On for the computers suite (--computers).",
                  "[fermix_core.always_on]", "enabled = true", ""]
        # Places are looked up on the studio Mac, as a server's are (D13): a Mac
        # dev daemon carries the Apple helper and would search Apple Maps itself.
        lines += ["[fermix_core.tools.place_search]", 'backend = "computer"', ""]
    return "\n".join(lines)


def render_machine(home: str, allowed_roots: tuple[str, ...] = (),
                   cues: dict | None = None) -> str:
    """The eval home's `machine.toml` (M97 §4): the settings that describe the
    computer the daemon runs on, which the engine reads from this file only and
    never from config.toml. The sandbox, the skill-credential fixture's
    environment source, computer history held off, the coding agents' approval
    and, with --cues, their sign-in folders (M98 D5), and, with cue mandates, the
    dev plugin folder the stub plugin is installed from."""
    workspace = os.path.join(home, "workspace")
    lines = ["# Managed by benchmark/bin/seed_capability_home.py — regenerated on each run.",
             "# This computer's own settings (sandbox, computer history, dev plugins).", ""]
    # `<home>/skills` is always a sandbox root: it is where the daemon
    # materializes skills, and the skill tasks verify their created SKILL.md
    # with raw file reads. Under a workspace-only sandbox that read is denied
    # -> request_directory_access -> "stop and wait for the owner" — an
    # approval no eval can answer — so the turn ends before the deliverable
    # is written and the task scores 0 with nothing wrong in the product
    # (create_and_confirm_skill, 2026-08-06: 9 of 10 base trials died there).
    # Same rule as the harness consent in `harness_lines`: pre-grant every
    # human-decision gate, scoped to this throwaway home. The runner
    # precondition tolerates it — only roots that escape the home are refused.
    roots = ", ".join(
        json.dumps(root) for root in (os.path.join(home, "skills"), *allowed_roots))
    lines += ["[sandbox]", 'mode = "strict"',
              f'workspace_root = "{workspace}"', f"allowed_roots = [{roots}]", ""]
    # The skill-credential fixture (M45): allowed, and read through a `command`
    # source, so every shell command the eval daemon runs receives it and the
    # redaction of its value is exercised on the real agent path.
    token_path = os.path.join(home, SKILL_TOKEN_FILE)
    lines += ["[sandbox.env]", f"allow = [{json.dumps(SKILL_TOKEN_NAME)}]", "",
              f"[sandbox.env.{SKILL_TOKEN_NAME}]", 'source = "command"',
              'command = "/bin/cat"', f"args = [{json.dumps(token_path)}]",
              "timeout_ms = 3000", ""]
    # Computer history (MILESTONE_32) is the DELIBERATE EXCEPTION to the
    # pre-grant-every-gate rule, recorded here so its absence never reads as an
    # oversight. Its `enabled` gate does not merely advertise a tool — it starts
    # a live capturer that would record the eval HOST's real screen activity
    # into this throwaway home and ship summaries to a provider, which is
    # exactly the private-data movement the capability runner exists to refuse:
    # the recall suite's positive half is risk `private_account_read`, a class
    # `make capability-auto` never loads. Pre-granting would leak, not unblock.
    # If a future capability task legitimately needs recall_activity, seed a
    # synthetic spool instead of enabling live capture.
    lines += ["[fermix_core.computer_history]", "enabled = false", ""]
    lines += harness_lines(home, cues)
    if cues and cues["mandates"]:
        lines += ["[fermix_core.plugins]",
                  f"dev_local = {json.dumps(os.path.join(home, CUE_PLUGIN_DIR))}", ""]
    return "\n".join(lines)


def harness_lines(home: str, cues: dict | None) -> list[str]:
    """This computer's `[fermix_core.harness]` keys (M98 D5): the approval, and with
    --cues the follow-up cases' sign-in folders. Fermix reads these three from
    machine.toml only; every other harness key is the home's, in config.toml."""
    # Pre-approve coding agents in the disposable home. Consent is a setup decision
    # (design §23.3) and defaults false, and an unapproved host advertises no run
    # tool and renders no delegation steering at all (§23.4) — it does not stall,
    # it silently makes the candidate model do the coding by hand, so the harness
    # suite would grade main-agent coding instead of delegation and every
    # delegating task would score zero. Approving here is scoped to this throwaway home
    # whose sandbox is strict and rooted at the workspace above (the isolation the
    # --confirm-daemon-isolated / --confirm-isolated-env flags attest to).
    lines = ["[fermix_core.harness]", "approved = true"]
    # With --cues, the follow-up cases' coding agents: the stub Codex sign-in, and
    # a Claude Code config dir that is never made (see the module docstring).
    if cues:
        lines += [f"codex_home = {json.dumps(os.path.join(home, CUE_CODEX_HOME))}",
                  f"claude_config_dir = {json.dumps(os.path.join(home, CUE_CLAUDE_DIR))}"]
    return lines + [""]


def cue_lines(home: str, cues: dict) -> list[str]:
    """Cues on, for the cue suites (`cap_cues`, `cues`): the switch, the door on this
    home's own port, every source the suites post to with its token in the `@file`
    store (the sentinel names the store; `write_cue_tokens` writes the files), one
    webhook still waiting for its signing secret, and the default filter model, which a watcher made without a model of its own uses.
    With mandates, the stub plugin they grant is enabled from the home's own
    dev_local directory. The mandate sections themselves name job ids that exist
    only once seed_cues.exs has made the jobs, so it appends them."""
    provider, model = cues["filter"]
    lines = ["# Cues (M60) for the cue suites; watchers and tasks are rows that",
             "# benchmark/bin/seed_cues.exs makes with the daemon down.",
             "[fermix_core.cues]", "enabled = true", f"door_port = {cues['door_port']}", ""]
    for ref in cue_sources(cues["mandates"]):
        lines += [f"[fermix_core.cues.sources.{ref}]", 'kind = "local_push"',
                  'token = "@file"', ""]
    lines += [f"[fermix_core.cues.sources.{CUE_WAITING_SOURCE}]", 'preset = "github"', ""]
    lines += ["[fermix_core.routing]", f"filter_provider = {json.dumps(provider)}",
              f"filter_model = {json.dumps(model)}", ""]
    if cues["mandates"]:
        lines += ["[fermix_core.plugins]", f"enabled = [{json.dumps(CUE_PLUGIN)}]", ""]
    return lines


def cue_sources(mandates: bool) -> tuple[str, ...]:
    return CUE_SOURCES + (CUE_MANDATE_SOURCES if mandates else ())


def free_door_port() -> int:
    """A port nothing listens on now, for this home's door. Picked at seed time so
    two eval homes never share a door; something taking it before the daemon boots
    leaves the door unavailable, which the cue runner reports as unreachable."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]
    finally:
        probe.close()


# Bound on the probes for a fixture port that is not the door's: two probes in a
# row rarely answer the same port, and eight never should.
FIXTURE_PORT_PROBES = 8


def free_fixture_port(door_port: int | None) -> int:
    """A port nothing listens on now and that is not this home's door, for the
    runners' fixture server (`FIXTURE_MANIFEST`). Something taking it before a run
    starts fails that run's fixture server loudly, naming the port."""
    for _probe in range(FIXTURE_PORT_PROBES):
        port = free_door_port()
        if port != door_port:
            return port
    die(f"no free fixture port other than the door's {door_port} "
        f"in {FIXTURE_PORT_PROBES} probes")


def write_fixture_manifest(home: str, door_port: int | None) -> int:
    """Record this seed's fixture port, rewritten on every seed: the port both runners
    bind and the origin capability-daemon.sh hands the daemon's web_fetch."""
    port = free_fixture_port(door_port)
    write_private(os.path.join(home, FIXTURE_MANIFEST), json.dumps({"port": port}) + "\n")
    return port


def cue_filter_route(value: str | None, pid: str, blk: dict) -> tuple[str, str]:
    """The default filter model: `--cue-filter-model PROVIDER/MODEL`, else the scored
    provider and model (always a route this home can authenticate)."""
    if value is None:
        return pid, blk["default_model"]
    provider, sep, model = value.partition("/")
    if not sep or not provider or not model:
        die(f"--cue-filter-model must be PROVIDER/MODEL, got {value!r}")
    return provider, model


def write_cue_fixtures(home: str, cues: dict) -> dict:
    """One fresh token per source in the file store (`secrets/cue_source.<ref>.token`,
    the name `SecretWriter.File` reads, directory 0700, file 0600), the stub plugin
    with mandates, and the manifest the `drive: cue` runner reads. Rewritten on
    every seed, so the tokens are the home's setup, not sweep state."""
    directory = os.path.join(home, "secrets")
    os.makedirs(directory, exist_ok=True)
    os.chmod(directory, 0o700)
    tokens = {}
    for ref in cue_sources(cues["mandates"]):
        tokens[ref] = secrets.token_urlsafe(24)
        write_private(os.path.join(directory, f"cue_source.{ref}.token"), tokens[ref])
    if cues["mandates"]:
        write_cue_plugin(home)
    write_coding_stubs(home)
    manifest = {"door_port": cues["door_port"], "mandates": cues["mandates"],
                "sources": {ref: {"token": token} for ref, token in tokens.items()}}
    write_private(os.path.join(home, CUE_MANIFEST), json.dumps(manifest, indent=2))
    return manifest


def clear_cue_fixtures(home: str) -> None:
    """A seed without --cues: remove both cue manifests a previous --cues seed left,
    so the runners hold the cue suites out instead of driving a home with cues off,
    and the coding stubs, so no other suite's daemon finds the stub `codex`."""
    for name in (CUE_MANIFEST, CUE_WATCHERS_MANIFEST,
                 os.path.join(CUE_BIN_DIR, "codex"), os.path.join(CUE_CODEX_HOME, "auth.json"),
                 os.path.join(CUE_CODEX_HOME, "models_cache.json")):
        path = os.path.join(home, name)
        if os.path.isfile(path):
            os.remove(safe_rm.check(path, home, min_below=1))


def write_coding_stubs(home: str) -> None:
    """The follow-up cases' coding agents: the stub `codex` (executable), its
    stub sign-in, a refresh token the Codex readiness check reads and nothing
    uses, and its account's model list. Claude Code's config dir is left unmade,
    so it is never ready."""
    stub = os.path.join(home, CUE_BIN_DIR, "codex")
    write_private(stub, CODEX_STUB)
    os.chmod(stub, 0o700)
    auth = {"tokens": {"refresh_token": "eval-stub-refresh-token"}}
    write_private(os.path.join(home, CUE_CODEX_HOME, "auth.json"), json.dumps(auth))
    write_private(os.path.join(home, CUE_CODEX_HOME, "models_cache.json"),
                  json.dumps(CODEX_MODEL_LIST))


def write_signed_out_claude(home: str) -> str:
    """The stub `claude` (executable, private) that fails every run as signed out."""
    stub = os.path.join(home, CLAUDE_STUB)
    write_private(stub, CLAUDE_SIGNED_OUT_STUB)
    os.chmod(stub, 0o700)
    return stub


def clear_signed_out_claude(home: str) -> None:
    """A seed without --coding-signed-out: remove the stub a previous seed left, so
    no other suite's daemon finds a Claude Code that fails every run."""
    stub = os.path.join(home, CLAUDE_STUB)
    if os.path.isfile(stub):
        os.remove(safe_rm.check(stub, home, min_below=1))


def write_private(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(path, 0o600)


def write_cue_plugin(home: str) -> str:
    """The stub `http` plugin the two mandates grant: one tool that files a ticket."""
    manifest = {
        "schema_version": 2, "name": CUE_PLUGIN, "display_name": "Eval tickets",
        "description": "Files a ticket in the eval tracker.", "category": "productivity",
        "version": "1.0.0", "plugin_api": 2, "auth": {"type": "none"},
        "tools": [{
            "name": CUE_PLUGIN_TOOL,
            "description": "File a ticket in a project of the eval tracker.",
            "read_only": False, "rail": "http",
            "parameters": {
                "type": "object", "required": ["project", "title"],
                "properties": {"project": {"type": "string"}, "title": {"type": "string"},
                               "body": {"type": "string"}}},
            "request": {"method": "POST", "url": "https://tickets.eval.invalid/api/tickets"},
        }],
    }
    path = os.path.join(home, CUE_PLUGIN_DIR, CUE_PLUGIN, "plugin.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2)
    return path


def computer_noise_pk(device_id: str) -> str:
    """A computer's Noise public key as its row stores it (standard base64 of 32
    bytes). Derived from its id, so every seed writes the same bytes and no two
    rows share one; no session ever uses it."""
    digest = hashlib.sha256(f"fermix-eval computer {device_id}".encode()).digest()
    return base64.b64encode(digest).decode("ascii")


def render_devices() -> str:
    """`mobile/devices.toml` with one desktop row per computer in `COMPUTERS`."""
    lines = ["# Managed by benchmark/bin/seed_capability_home.py --computers: the",
             "# computers linked to this home, both away (no session).", ""]
    for computer in COMPUTERS:
        lines += ["[[devices]]"]
        lines += [f"{key} = {json.dumps(computer[key])}"
                  for key in ("device_id", "name", "model")]
        lines += [f"noise_pk = {json.dumps(computer_noise_pk(computer['device_id']))}",
                  f"created_at = {json.dumps(computer['created_at'])}",
                  'kind = "desktop"',
                  f"platform = {json.dumps(computer['platform'])}",
                  f"last_seen = {json.dumps(computer['last_seen'])}",
                  f"backups = {json.dumps(computer['backups'])}", ""]
    return "\n".join(lines)


def computer_record(computer: dict) -> dict:
    """What a computer last said about itself, as the home keeps it on disk."""
    return {"v": 1, "engine_version": computer["engine_version"],
            "seen_at": computer["last_seen"], "offers_rev": computer["offers_rev"],
            "offers": computer["offers"]}


def computer_paths(home: str) -> list[str]:
    """Every file `write_computer_fixtures` writes, the manifest last."""
    records = [os.path.join(home, COMPUTER_RECORDS_DIR, f"{c['device_id']}.json")
               for c in COMPUTERS]
    return [os.path.join(home, DEVICES_FILE), *records, os.path.join(home, COMPUTERS_MANIFEST)]


def make_private_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)
    os.chmod(path, 0o700)


def write_computer_fixtures(home: str) -> dict:
    """The two computers (`COMPUTERS`): the devices file (directory 0700, file
    0600, the modes `DeviceStore` refuses anything but), one record each under
    `device/computers/` (0700 / 0600), and the manifest that says this seed
    wrote them. Rewritten whole on every seed. A devices file the manifest does
    not account for is refused, never overwritten: an eval home pairs nothing,
    so it is someone else's."""
    devices = os.path.join(home, DEVICES_FILE)
    if os.path.exists(devices) and not os.path.isfile(os.path.join(home, COMPUTERS_MANIFEST)):
        die(f"refusing to replace {devices}: this seed did not write it (no "
            f"{COMPUTERS_MANIFEST}); remove it or seed a fresh home")
    make_private_dir(os.path.dirname(devices))
    write_private(devices, render_devices())
    make_private_dir(os.path.join(home, os.path.dirname(COMPUTER_RECORDS_DIR)))
    make_private_dir(os.path.join(home, COMPUTER_RECORDS_DIR))
    for computer in COMPUTERS:
        path = os.path.join(home, COMPUTER_RECORDS_DIR, f"{computer['device_id']}.json")
        write_private(path, json.dumps(computer_record(computer), indent=2) + "\n")
    manifest = {"computers": [{key: c[key] for key in ("name", "platform", "last_seen")}
                              for c in COMPUTERS]}
    write_private(os.path.join(home, COMPUTERS_MANIFEST), json.dumps(manifest, indent=2))
    return manifest


def clear_computer_fixtures(home: str) -> None:
    """A seed without --computers: remove what a previous --computers seed wrote
    (its manifest says so), so no other suite's turns carry a `## Computers`
    section. A home without the manifest is left as it is."""
    if not os.path.isfile(os.path.join(home, COMPUTERS_MANIFEST)):
        return
    # seed_history.exs's manifest, written after a --computers seed with the
    # daemon down; its notes went with memory.db.
    history = os.path.join(home, HISTORY_MANIFEST)
    for path in [history, *computer_paths(home)]:
        if os.path.isfile(path):
            os.remove(safe_rm.check(path, home, min_below=1))


def voice_lines(engine: str) -> list[str]:
    """Voice on with one task engine, for the `drive: voice` suites. Turning
    voice on is the one human decision a voice case needs, on either engine:
    neither has a consent of its own (`screen_share` is read only by the
    Realtime engine, `camera_share` only by a phone's call). The call's
    conversation stays the product default (the chat), so the cases see what an
    owner's call does. No other gate is granted: computer history stays off
    (above), so nothing it guards can reach the voice provider."""
    if engine not in VOICE_ENGINES:
        raise ValueError(f"voice engine must be one of {sorted(VOICE_ENGINES)}, got {engine!r}")
    model, key_env = VOICE_ENGINES[engine]
    return [f"# Voice for drive: voice ({engine}). The key is {key_env} on the daemon",
            "# process, read at boot; the socket needs a daemon run with realtime on.",
            "[fermix_core.realtime]", "enabled = true", f'engine = "{engine}"',
            f'model = "{model}"', f"max_session_minutes = {VOICE_MAX_SESSION_MINUTES}",
            ""]


_TABLE_HEADER_RE = re.compile(r"^\s*\[\[?\s*([^\[\]]+?)\s*\]\]?\s*$")


def table_headers(toml_text: str) -> list[str]:
    """Every EXPLICIT table header in a TOML document, in order.

    Explicit headers, not tomllib's nested result: a fragment adding
    `[fermix_core.browser]` is fine beside the seeder's
    `[fermix_core.providers.<id>]` — both only imply `[fermix_core]` — while a
    second `[fermix_core.meetings]` is the duplicate TOML itself refuses. Only the
    headers each document actually writes can tell those apart."""
    headers = []
    for line in toml_text.splitlines():
        match = _TABLE_HEADER_RE.match(line)
        if match:
            headers.append(match.group(1).strip())
    return headers


def nested_table(parsed: dict, dotted: str) -> dict:
    """The table a parsed TOML document holds at `dotted` (`fermix_core.harness`),
    or an empty one where it holds none."""
    node = parsed
    for part in dotted.split("."):
        node = node.get(part) if isinstance(node, dict) else None
    return node if isinstance(node, dict) else {}


def extra_config_error(rendered: str, fragment: str) -> str | None:
    """Why this `--extra-config` fragment cannot be appended, or None.

    An arm's fragment is appended verbatim, so it must be a self-contained set of
    tables that the seeded config does not already write. The alternative is the
    daemon refusing the merged file at boot with a TOML parse error that names a
    line number in a generated file — a worse message for a condition that is
    knowable here."""
    try:
        parsed = tomllib.loads(fragment)
    except tomllib.TOMLDecodeError as exc:
        return f"--extra-config is not valid TOML: {exc}"
    bare = sorted(key for key, value in parsed.items() if not isinstance(value, dict))
    if bare:
        # Appended after the seeder's last table, a bare key would silently join
        # THAT table instead of the document root.
        return (f"--extra-config must start with a table header; top-level key(s) "
                f"{bare} would be appended into the seeder's last table")
    # The fragment is appended to config.toml only, so this computer's own settings
    # in it would be stripped at boot or never read. A home table split by key
    # (`MACHINE_KEYS`) is refused only for the machine's keys: the seeder writes no
    # `[fermix_core.harness]` in config.toml, so an arm may set its home keys.
    machine = sorted(header for header in table_headers(fragment)
                     if any(header == t or header.startswith(t + ".") for t in MACHINE_TABLES))
    machine += [f"{table}.{key}" for table, key in MACHINE_KEYS
                if key in nested_table(parsed, table)]
    if machine:
        return (f"--extra-config sets this computer's own settings {machine}, "
                f"which Fermix reads from {MACHINE_FILE}, never from config.toml")
    written = set(table_headers(rendered))
    clashes = sorted(set(table_headers(fragment)) & written)
    if clashes:
        return (f"--extra-config redefines table(s) {clashes} the seeder already writes; "
                "an arm changes what the seeder does not own, or the seeder learns "
                "the setting")
    return None


def read_extra_config(rendered: str, path: str) -> str:
    """The arm fragment to append, refused loudly if it cannot be appended."""
    resolved = os.path.abspath(os.path.expanduser(path))
    try:
        with open(resolved, encoding="utf-8") as fh:
            fragment = fh.read()
    except OSError as exc:
        die(f"cannot read --extra-config {resolved}: {exc}")
    problem = extra_config_error(rendered, fragment)
    if problem:
        die(problem)
    tables = ", ".join(table_headers(fragment)) or "none"
    print(f"appending --extra-config {resolved} (table(s): {tables})")
    return f"\n# --- appended from {resolved} (configuration arm) ---\n{fragment.strip()}\n"


def copy_oauth_token(home: str, pid: str) -> None:
    """Copy the scored provider's OAuth entry from the dev auth store into the
    disposable home so the daemon authenticates without an interactive login.

    OAuth tokens are home-scoped ($FERMIX_HOME/auth.json), not host-global — a
    fresh home has none. We only READ the dev store; the eval daemon writes any
    refresh to its own copy. A current token is used as-is, so a run shorter than
    its life never refreshes and never rotates the shared refresh token (an
    openai_codex token lives one hour; see _OAUTH_PROFILE_KEY).
    """
    key = _OAUTH_PROFILE_KEY.get(pid)
    if key is None:
        die(f"don't know the auth-store key for OAuth provider {pid!r}")
    dev_auth = os.path.join(DEV_HOME, "auth.json")
    if not os.path.isfile(dev_auth):
        die(f"{pid} authenticates via OAuth but {dev_auth} is missing — "
            "run `fermix auth login` on the dev daemon first")
    with open(dev_auth, encoding="utf-8") as fh:
        store = json.load(fh)
    entry = store.get("providers", {}).get(key)
    if not entry:
        die(f"no {key} OAuth token in {dev_auth} — run `fermix auth login` there first")
    dest = os.path.join(home, "auth.json")
    with open(dest, "w", encoding="utf-8") as fh:
        json.dump({"version": store.get("version", 2), "providers": {key: entry}}, fh)
    os.chmod(dest, 0o600)   # the store refuses to load a world-readable auth.json


def write_skill_token(home: str) -> str:
    """Write the skill-credential fixture value the seeded `command` source prints.

    Rewritten on every seed, so it is the home's setup rather than sweep state. No
    trailing newline: the value the daemon reads is byte-identical to the constant.
    Private (0600), like any credential file, although the value is a fixture."""
    path = os.path.join(home, SKILL_TOKEN_FILE)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(SKILL_TOKEN_VALUE)
    os.chmod(path, 0o600)
    return path


def reset_state(home: str) -> None:
    """Restore the eval home's durable-state baseline: remove everything a prior
    sweep's daemon wrote, leaving the home's setup (config.toml, auth.json) alone.

    THE DAEMON MUST BE DOWN. `capability-daemon.sh` seeds inside `up()`, before it
    starts the daemon; `down()` does not seed. Deleting `memory.db` under a live daemon
    would leave it writing to an unlinked file, so this refuses when the home answers a
    status probe — `up()`'s pidfile check cannot see a daemon started outside the
    script against the same home, which is the documented manual path.

    Trials are only independent if each starts from the same world. The home is
    disposable by convention only, so without this everything the previous sweep's
    model did persists: a created skill makes the next fresh `skill_create` fail
    "already exists" (a leftover `skills/eval-echo` poisoned two runs), a stored fact
    can false-green a broken memory store, and a scheduled job or accepted event keeps
    firing into the next sweep. Nothing removed here is irreplaceable: the daemon
    recreates each workspace dir at boot, `SkillRegistry` re-seeds the bundled skills,
    `Memory.Repo` recreates `memory.db` from its schema, and the bootstrap prompt files
    fall back to `Prompt.Defaults` until setup writes them.
    """
    # Recursive delete: re-assert main()'s disposable-home guard here so this
    # function is safe even if a future caller skips that validation, then route
    # every removal through SafeRm (strictly under the home, never the home itself).
    resolved = disposable_home(home, "reset state")
    if not os.path.isdir(resolved):
        die(f"refusing to reset state in a home that does not exist: {home}")
    if daemon_answers(resolved):
        die(f"a daemon is answering for {resolved} — stop it before seeding; deleting "
            "memory.db under a live daemon leaves it writing to an unlinked file")
    for name in STATE_DIRS:
        path = os.path.join(resolved, name)
        if os.path.isdir(path):
            safe_rm.rm_rf(path, resolved, min_below=1)
    for name in STATE_FILES:
        path = os.path.join(resolved, name)
        if os.path.isfile(path):
            os.remove(safe_rm.check(path, resolved, min_below=1))


def install_skills(home: str, private_dir: str | None = None) -> None:
    """Lay down the reset skills dir: the daemon's bundled skills, the public fixture
    skills, and the private holdout's skills when a run includes it. Runs right after
    reset_state, with the daemon down. The daemon would copy the bundled skills itself,
    but only into an empty dir, which a fixture skill makes it no longer be."""
    skills = os.path.join(disposable_home(home, "install skills"), "skills")
    if os.path.exists(skills):
        die(f"refusing to install skills over an existing {skills}: reset_state runs first")
    os.makedirs(skills)
    for source_root in (BUNDLED_SKILLS_DIR, FIXTURE_SKILLS_DIR):
        copy_skill_dirs(source_root, skills)
    # A holdout need not ship skills; when it does they live in <holdout>/skills.
    if private_dir and os.path.isdir(os.path.join(private_dir, "skills")):
        copy_skill_dirs(os.path.join(private_dir, "skills"), skills)


def copy_skill_dirs(source_root: str, skills: str) -> None:
    """Copy every skill directory (one holding a SKILL.md) under source_root."""
    if not os.path.isdir(source_root):
        die(f"skill source missing: {source_root}")
    names = sorted(n for n in os.listdir(source_root)
                   if os.path.isfile(os.path.join(source_root, n, "SKILL.md")))
    for name in names:
        dest = os.path.join(skills, name)
        if os.path.exists(dest):
            die(f"skill {name!r} exists in two sources ({source_root} and an earlier one); "
                "rename one, or the eval home would run whichever happened to win")
        shutil.copytree(os.path.join(source_root, name), dest)


def disposable_home(home: str, what: str) -> str:
    """The home as a REALPATH, refused unless it is disposable.

    realpath, not abspath: `safe_rm.check` resolves symlinks on both sides, so a link
    named `~/x-eval` pointing at `~/.fermix` cleared an abspath leaf check and every
    non-disposable comparison, and the removals then landed in the live home."""
    resolved = os.path.realpath(os.path.expanduser(home))
    if os.path.islink(os.path.expanduser(home)):
        die(f"refusing a symlinked home: {home} -> {resolved}")
    leaf = os.path.basename(resolved).lower()
    if "eval" not in leaf and "e2e" not in leaf:
        die(f"refusing to {what} outside an eval home: {resolved}")
    if resolved in _NON_DISPOSABLE:
        die(f"refusing a non-disposable home: {resolved}")
    return resolved


def daemon_answers(home: str) -> bool:
    """Whether a daemon is serving this home, by connecting to its control socket.

    The same evidence `capability-daemon.sh`'s ready loop waits on (`fermix-shim status`
    speaks to `<home>/daemon.sock`), read directly so the probe spawns nothing and
    depends on nothing outside the home. A stale socket file left by a killed daemon
    refuses the connection and correctly reads as "down"; `up()`'s pidfile check cannot
    see a daemon started outside the script at all."""
    path = os.path.join(home, "daemon.sock")
    if not os.path.exists(path):
        return False
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(2.0)
    try:
        probe.connect(path)
        return True
    except OSError:
        return False
    finally:
        probe.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Seed a disposable capability/e2e-eval FERMIX_HOME.")
    parser.add_argument("home", nargs="?", default="~/.fermix-capability-eval")
    parser.add_argument("--provider",
                        help="explicit mode: provider id (api-key-env providers or ollama)")
    parser.add_argument("--model",
                        help="explicit mode: default_model for the provider block")
    parser.add_argument("--reasoning-effort", dest="reasoning_effort",
                        help="explicit mode: optional reasoning_effort")
    parser.add_argument("--private-dir", dest="private_dir",
                        help="the private holdout clone; its skills/ are installed too "
                             "(make capability-auto passes it after syncing)")
    parser.add_argument("--dev-provider", dest="dev_provider",
                        help="score this provider block from ~/.fermix-dev/config.toml "
                             "(its model, effort and auth) instead of the dev primary")
    parser.add_argument("--allow-root", dest="allow_roots", action="append", default=[],
                        help="absolute path appended to sandbox allowed_roots (repeatable)")
    parser.add_argument("--voice", action="store_true",
                        help="turn voice on for the drive: voice suites (the daemon needs the "
                             "engine's key in its environment and realtime on)")
    parser.add_argument("--voice-engine", dest="voice_engine", choices=sorted(VOICE_ENGINES),
                        help=f"with --voice: the task engine (default {DEFAULT_VOICE_ENGINE}; "
                             + ", ".join(f"{engine} needs {key}" for engine, (_model, key)
                                         in sorted(VOICE_ENGINES.items())) + ")")
    parser.add_argument("--cues", action="store_true",
                        help="turn cues on for the cue suites (door, sources, default filter "
                             "model; seed_cues.exs then makes the watchers); off by default")
    parser.add_argument("--cue-filter-model", dest="cue_filter_model",
                        help="PROVIDER/MODEL for the cue watchers' default filter model "
                             "(default: the scored provider and model)")
    parser.add_argument("--cue-mandates", dest="cue_mandates", action="store_true",
                        help="with --cues: add the stub http plugin and the two mandates the "
                             "cue suite's mandate cases need (they are held out without it)")
    parser.add_argument("--computers", action="store_true",
                        help="link two computers to the home (studio Mac, loft Linux), both "
                             "away, and turn Always On on, for the computers suite; off by "
                             "default")
    parser.add_argument("--coding-signed-out", dest="coding_signed_out", action="store_true",
                        help="put a stub claude first on the daemon's PATH that fails every "
                             "run as signed out, for coding_harness's signed-out case; off "
                             "by default")
    parser.add_argument("--extra-config", dest="extra_config",
                        help="TOML fragment appended to the rendered config (one "
                             "configuration ARM's difference); refused when it "
                             "redefines a table the seeder already writes")
    return parser.parse_args()


def cue_spec(args: argparse.Namespace, pid: str, blk: dict) -> dict | None:
    """The cue seeding `--cues` asks for, or None (the default: cues off)."""
    if not args.cues:
        return None
    return {"door_port": free_door_port(), "mandates": args.cue_mandates,
            "filter": cue_filter_route(args.cue_filter_model, pid, blk)}


def explicit_spec(args: argparse.Namespace) -> tuple[str, dict]:
    pid = args.provider
    # anthropic/xai are in BOTH maps (api-key or OAuth auth modes); explicit
    # mode uses their env key. Only OAuth-only providers are refused here.
    if pid not in _ENV_KEY_PROVIDERS and pid != "ollama":
        if pid in _OAUTH_PROFILE_KEY:
            die(f"{pid} authenticates via OAuth only; explicit mode needs an api-key-env provider")
        known = ", ".join(sorted([*_ENV_KEY_PROVIDERS, "ollama"]))
        die(f"unknown explicit provider {pid!r} (known: {known})")
    blk = {"default_model": args.model}
    if args.reasoning_effort:
        blk["reasoning_effort"] = args.reasoning_effort
    return pid, blk


def main() -> None:
    args = parse_args()
    home = disposable_home(args.home, "seed")
    if bool(args.provider) != bool(args.model):
        die("explicit mode needs both --provider and --model")
    if args.provider and args.dev_provider:
        die("use --provider/--model (explicit mode) or --dev-provider, not both")
    if not args.cues and (args.cue_mandates or args.cue_filter_model):
        die("--cue-mandates and --cue-filter-model need --cues")
    if args.voice_engine and not args.voice:
        die("--voice-engine needs --voice")
    voice_engine = (args.voice_engine or DEFAULT_VOICE_ENGINE) if args.voice else None
    allowed_roots = tuple(
        os.path.abspath(os.path.expanduser(p)) for p in args.allow_roots)

    if args.provider:
        pid, blk = explicit_spec(args)
        profile = None
    else:
        dev_cfg = os.path.join(DEV_HOME, "config.toml")
        if not os.path.isfile(dev_cfg):
            die(f"no dev config to derive the scored model from: {dev_cfg}")
        with open(dev_cfg, "rb") as fh:
            dev = tomllib.load(fh)
        if args.dev_provider:
            pid, blk, profile = dev_provider(dev, args.dev_provider)
        else:
            pid, blk, profile = primary_provider(dev)

    workspace = os.path.join(home, "workspace")
    os.makedirs(workspace, exist_ok=True)
    if not os.path.isdir(os.path.join(workspace, ".git")):
        subprocess.run(["git", "-C", workspace, "init", "-q"], check=True)
    reset_state(home)
    install_skills(home, args.private_dir)
    write_skill_token(home)

    cues = cue_spec(args, pid, blk)
    if cues:
        write_cue_fixtures(home, cues)
    else:
        clear_cue_fixtures(home)
    if args.computers:
        write_computer_fixtures(home)
    else:
        clear_computer_fixtures(home)
    if args.coding_signed_out:
        write_signed_out_claude(home)
    else:
        clear_signed_out_claude(home)
    fixture_port = write_fixture_manifest(home, cues["door_port"] if cues else None)
    config = render_config(home, pid, blk, profile, explicit=bool(args.provider),
                           voice=voice_engine, cues=cues, computers=args.computers)
    if args.extra_config:
        config += read_extra_config(config, args.extra_config)
    with open(os.path.join(home, "config.toml"), "w", encoding="utf-8") as fh:
        fh.write(config)
    with open(os.path.join(home, MACHINE_FILE), "w", encoding="utf-8") as fh:
        fh.write(render_machine(home, allowed_roots, cues))

    if args.provider:
        env_name = _ENV_KEY_PROVIDERS.get(pid)
        auth = f"env ({env_name} must be set on the daemon process)" if env_name else "keyless"
    elif "api_key" in blk:
        auth = "keychain"
    else:
        copy_oauth_token(home, pid)
        auth = "oauth (token copied from dev store)"
    print(f"seeded {home}: scoring {pid}/{blk['default_model']} (auth={auth})")
    print(f"fixture server: 127.0.0.1:{fixture_port}, the origin the daemon's web_fetch reads")
    if cues:
        print(f"cues: door on 127.0.0.1:{cues['door_port']}, filter "
              f"{'/'.join(cues['filter'])}, mandates {'on' if cues['mandates'] else 'off'}; "
              "run seed_cues.exs next, daemon still down")
    if voice_engine:
        model, key_env = VOICE_ENGINES[voice_engine]
        print(f"voice: {voice_engine} ({model}) on; {key_env} must be set on the daemon "
              "process, started with realtime on (mix fermix.dev, not --no-realtime)")
    if args.computers:
        names = " and ".join(c["name"] for c in COMPUTERS)
        print(f"computers: {names} linked, both away; Always On on")
    if args.coding_signed_out:
        print(f"coding signed out: {CLAUDE_STUB} fails every Claude Code run as signed out; "
              "capability-daemon.sh puts it first on the daemon's PATH")


if __name__ == "__main__":
    main()
