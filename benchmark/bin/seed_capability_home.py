#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Seed a disposable capability-eval FERMIX_HOME so `make capability` can run.

Creates the home, a git-backed workspace (the checker's per-trial scoring root),
a minimal strict config.toml, and the auth the scored model needs. The scored
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
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import tomllib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from evallib import safe_rm  # noqa: E402

DEV_HOME = os.path.expanduser("~/.fermix-dev")
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
STATE_DIRS = ("skills", "memory", "job_runs", "journals", "grants", "bootstrap",
              "browser", "harness")
STATE_FILES = ("memory.db", "memory.db-wal", "memory.db-shm")
# Only these keys are allowed in a provider block (else the daemon refuses boot).
_PROVIDER_KEYS = ("default_model", "reasoning_effort", "auth_mode", "base_url", "api_key")
# Primary provider id -> its key in the Fermix auth store ($FERMIX_HOME/auth.json),
# for OAuth providers whose token must be copied into the disposable home.
_OAUTH_PROFILE_KEY = {
    "openai_codex": "openai_codex",
    "anthropic": "anthropic_oauth",
    "xai": "xai_oauth",
}
# Providers whose api_key the daemon reads from an environment variable at boot
# (config/runtime.exs); the explicit/CI mode supports exactly these + ollama.
_ENV_KEY_PROVIDERS = {
    "openai": "OPENAI_API_KEY",
    "anthropic": "ANTHROPIC_API_KEY",
    "xai": "XAI_API_KEY",
    "openrouter": "OPENROUTER_API_KEY",
    "mistral": "MISTRAL_API_KEY",
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


def render_config(
    home: str, pid: str, blk: dict, profile: str | None,
    allowed_roots: tuple[str, ...] = (), explicit: bool = False,
) -> str:
    workspace = os.path.join(home, "workspace")
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
    # `<home>/skills` is always a sandbox root: it is where the daemon
    # materializes skills, and the skill tasks verify their created SKILL.md
    # with raw file reads. Under a workspace-only sandbox that read is denied
    # -> request_directory_access -> "stop and wait for the owner" — an
    # approval no eval can answer — so the turn ends before the deliverable
    # is written and the task scores 0 with nothing wrong in the product
    # (create_and_confirm_skill, 2026-08-06: 9 of 10 base trials died there).
    # Same rule as the harness consent below: pre-grant every human-decision
    # gate, scoped to this throwaway home. The runner precondition tolerates
    # it — only roots that escape the home are refused.
    roots = ", ".join(
        json.dumps(root) for root in (os.path.join(home, "skills"), *allowed_roots))
    lines += ["", "[sandbox]", 'mode = "strict"',
              f'workspace_root = "{workspace}"', f"allowed_roots = [{roots}]", ""]
    # Pre-approve coding agents in the disposable home. Consent is a setup decision
    # (design §23.3) and defaults false, and an unapproved host advertises no run
    # tool and renders no delegation steering at all (§23.4) — it does not stall,
    # it silently makes the candidate model do the coding by hand, so the harness
    # suite would grade main-agent coding instead of delegation and every
    # delegating task would score zero. Approving here is scoped to this throwaway home
    # whose sandbox is strict and rooted at the workspace above (the isolation the
    # --confirm-daemon-isolated / --confirm-isolated-env flags attest to). Left
    # unset: default_vendor (so both CLIs stay advertised for tasks that name
    # either) and cloud_enabled (defaults off — the cloud rail is not evaluated).
    lines += ["[fermix_core.harness]", "approved = true", ""]
    # Meetings (MILESTONE_21) are off until the operator turns them on, and a
    # fresh eval home has never made that decision — so `Meetings.ready?()` is
    # false, the seeder registers NO meetings tool, and a task asking the
    # notetaker to join scores 0 with nothing wrong in the product. Same rule as
    # the harness consent above: pre-grant every human-decision gate, scoped to
    # this throwaway home. It is deliberately not sufficient on its own —
    # `ready?()` also wants an installed meetbot sidecar or complete Zoom RTMS
    # credentials, and this seeder installs neither — so a home that never gets a
    # lane still advertises nothing and refuses locally rather than dialling out.
    lines += ["[fermix_core.meetings]", "enabled = true", ""]
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
    # Skill curation stays OFF in eval homes (MILESTONE_26_SKILL_CURATION §11):
    # the +15d first cycle already makes scheduled firing impossible during an
    # eval window, but a disabled entry also keeps /skills inert if a candidate
    # model wanders into it, and keeps suite behavior independent of daemon
    # uptime.
    lines += ["[fermix_core.skill_curation]", "enabled = false", ""]
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
    lines += ["[fermix_core.personalization]", 'user_name = "Eval Operator"',
              'timezone = "America/New_York"', 'communication_style = "concise"', ""]
    return "\n".join(lines)


def copy_oauth_token(home: str, pid: str) -> None:
    """Copy the primary provider's OAuth entry from the dev auth store into the
    disposable home so the daemon authenticates without an interactive login.

    OAuth tokens are home-scoped ($FERMIX_HOME/auth.json), not host-global — a
    fresh home has none. We only READ the dev store; the eval daemon writes any
    refresh to its own copy. A current token (valid hours out) is used as-is, so
    a normal short run never refreshes and never rotates the shared refresh token.
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
    parser.add_argument("--allow-root", dest="allow_roots", action="append", default=[],
                        help="absolute path appended to sandbox allowed_roots (repeatable)")
    return parser.parse_args()


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
        pid, blk, profile = primary_provider(dev)

    workspace = os.path.join(home, "workspace")
    os.makedirs(workspace, exist_ok=True)
    if not os.path.isdir(os.path.join(workspace, ".git")):
        subprocess.run(["git", "-C", workspace, "init", "-q"], check=True)
    reset_state(home)

    with open(os.path.join(home, "config.toml"), "w", encoding="utf-8") as fh:
        fh.write(render_config(home, pid, blk, profile, allowed_roots,
                               explicit=bool(args.provider)))

    if args.provider:
        env_name = _ENV_KEY_PROVIDERS.get(pid)
        auth = f"env ({env_name} must be set on the daemon process)" if env_name else "keyless"
    elif "api_key" in blk:
        auth = "keychain"
    else:
        copy_oauth_token(home, pid)
        auth = "oauth (token copied from dev store)"
    print(f"seeded {home}: scoring {pid}/{blk['default_model']} (auth={auth})")


if __name__ == "__main__":
    main()
