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
precondition). Regenerate on every `up`.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tomllib

DEV_HOME = os.path.expanduser("~/.fermix-dev")
# Only these keys are allowed in a provider block (else the daemon refuses boot).
_PROVIDER_KEYS = ("default_model", "reasoning_effort", "auth_mode", "base_url", "api_key")
# Primary provider id -> its key in the Fermix auth store ($FERMIX_HOME/auth.json),
# for OAuth providers whose token must be copied into the disposable home.
_OAUTH_PROFILE_KEY = {
    "openai_codex": "openai_codex",
    "anthropic": "anthropic_oauth",
    "xai": "xai_oauth",
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


def render_config(home: str, pid: str, blk: dict, profile: str | None) -> str:
    workspace = os.path.join(home, "workspace")
    uses_key = "api_key" in blk
    lines = [
        "# Managed by benchmark/bin/seed_capability_home.py — regenerated on each run.",
        "# Disposable capability-eval daemon: scores the ~/.fermix-dev primary model in a",
        "# strict, home-scoped sandbox. No channels/realtime; auth reused from the dev home.",
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
    lines += ["", "[sandbox]", 'mode = "strict"',
              f'workspace_root = "{workspace}"', "allowed_roots = []", ""]
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


def main() -> None:
    home = os.path.abspath(os.path.expanduser(
        sys.argv[1] if len(sys.argv) > 1 else "~/.fermix-capability-eval"))
    leaf = os.path.basename(home).lower()
    if "eval" not in leaf and "e2e" not in leaf:
        die(f"home leaf must contain 'eval' or 'e2e' (got {home!r})")
    if home in (os.path.expanduser("~/.fermix"), os.path.expanduser("~/.fermix-dev"),
                os.path.expanduser("~")):
        die(f"refusing a non-disposable home: {home}")

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

    with open(os.path.join(home, "config.toml"), "w", encoding="utf-8") as fh:
        fh.write(render_config(home, pid, blk, profile))

    if "api_key" in blk:
        auth = "keychain"
    else:
        copy_oauth_token(home, pid)
        auth = "oauth (token copied from dev store)"
    print(f"seeded {home}: scoring {pid}/{blk['default_model']} (auth={auth})")


if __name__ == "__main__":
    main()
