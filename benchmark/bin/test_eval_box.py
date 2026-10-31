#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7"]
# ///
"""Tests for the eval box's candidate, judge and Anthropic sign-in in
`.github/workflows/eval-box.yml`.

The daemon under test runs on Anthropic's provider (the `model` input, at the
job's CANDIDATE_REASONING_EFFORT) with the ANTHROPIC_API_KEY secret, which the boot
step and the judged steps hold. Every JUDGED tier (regression, capability) grades
replies with the Claude judge, whose SDK reads that same key on the judged steps
only (the preflight, the regression tier, the capability tier's judged axis); one
step proves it with a real verdict before anything else is spent. The capability
tier's coding-harness tasks (suites/capability/harness.yaml)
delegate to Claude Code, which signs in through Workload Identity Federation: one
step writes an `oidc_federation` profile fed by this job's GitHub OIDC token and
starts a background loop that keeps the token fresh, and a second installs a
pinned, checksum-verified Claude Code binary, pins its model and proves it signs in
through that profile before the daemon boots.

A key that is missing, a judge that cannot answer, or a CLI that cannot
authenticate is worse than none: every turn fails, the judged cases go incomplete,
or the daemon advertises `claude_code_run` and every delegated run scores 0.00 as a
candidate failure. So these tests hold the steps to failing loudly instead. The
structural group reads the workflows; the behavioural group runs the steps' own
shell against a stub `curl` (release download and OIDC endpoint), a stub `uv`
standing in for the judge preflight, a stub capability-daemon.sh and a stub Claude
Code binary. GitHub OIDC tokens are single-use, so the stubs refuse a token that
was already exchanged. No network, no real credential, no spend.

Run: `uv run bin/test_eval_box.py`."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time
from types import SimpleNamespace

import pytest
import yaml

HERE = Path(__file__).resolve().parent
WORKFLOWS = HERE.parent.parent / ".github" / "workflows"
EVAL_BOX = WORKFLOWS / "eval-box.yml"
DANGEROUS_SUITE = HERE.parent / "suites" / "dangerous" / "sandbox_verify.yaml"
JUDGED_TIERS = ("regression", "capability")
JUDGED_IF = "inputs.tier == 'regression' || inputs.tier == 'capability'"
CAPABILITY_IF = "inputs.tier == 'capability'"
CANDIDATE = "claude-opus-5-5"
ANTHROPIC_SECRET = "${{ secrets.ANTHROPIC_API_KEY }}"
JUDGE = "claude-haiku-5-5"
# An invented key: it may reach a step's environment, never its output.
INVENTED_ANTHROPIC_KEY = "invented-anthropic-key-8d2f"
# The judge settings each judged tier's runner loads.
JUDGE_CONFIGS = {"regression": "behavioral_config.yaml", "capability": "config.yaml"}
REQUIRED_VARS = ("ANTHROPIC_EVAL_ORGANIZATION_ID", "ANTHROPIC_EVAL_SERVICE_ACCOUNT_ID",
                 "ANTHROPIC_EVAL_FEDERATION_RULE_ID")
WORKSPACE_VAR = "ANTHROPIC_EVAL_WORKSPACE_ID"
# Invented identifiers in the shapes the token exchange expects.
VAR_VALUES = {
    "ANTHROPIC_EVAL_ORGANIZATION_ID": "5b0e6d2a-1c3f-4e8b-9a7d-2f4c6e8a0b1d",
    "ANTHROPIC_EVAL_SERVICE_ACCOUNT_ID": "svac_011CInventedAccount0001",
    "ANTHROPIC_EVAL_FEDERATION_RULE_ID": "fdrl_011CInventedRule000001",
    WORKSPACE_VAR: "wrkspc_011CInventedSpace0001",
}
OIDC_URL = "https://oidc.invalid/idtoken?api-version=2.0"
# An invented OIDC request credential, and the stem of every invented JWT the stub
# endpoint serves: neither may ever reach the public log.
REQUEST_TOKEN = "invented-oidc-request-credential-7f3a"
JWT_STEM = "eyJinventedHeader"
JWT_RE = re.compile(rf"{JWT_STEM}\.payload(\d{{4}})\.signature\1\n?")
AUDIENCE = "https://api.anthropic.com"
OIDC = f"{OIDC_URL}&audience={AUDIENCE}"
CAPABILITY_TIMEOUT_MINUTES = 180


@pytest.fixture(scope="module")
def workflow():
    return yaml.safe_load(EVAL_BOX.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def steps(workflow):
    return workflow["jobs"]["box"]["steps"]


def _step_by_id(steps, step_id):
    found = [s for s in steps if s.get("id") == step_id]
    assert len(found) == 1, f"expected exactly one step with id {step_id}, got {len(found)}"
    return found[0]


@pytest.fixture(scope="module")
def wif_step(steps):
    """The one step that signs in to Anthropic through federation."""
    return _step_by_id(steps, "wif_sign_in")


@pytest.fixture(scope="module")
def judge_step(steps):
    """The one step that proves the judge answers before anything is spent."""
    return _step_by_id(steps, "judge_preflight")


@pytest.fixture(scope="module")
def seed_step(steps):
    """The one step that seeds the eval home and boots the daemon under test."""
    return steps[_step_index(steps, "capability-daemon.sh up")]


@pytest.fixture(scope="module")
def claude_step(steps):
    """The one step that installs Claude Code and proves its sign-in."""
    return _step_by_id(steps, "claude_code")


@pytest.fixture(scope="module")
def stop_step(steps):
    found = [s for s in steps if s.get("name") == "Stop the Anthropic identity-token refresher"]
    assert len(found) == 1
    return found[0]


def _step_index(steps, needle):
    found = [i for i, s in enumerate(steps) if needle in s.get("run", "")]
    assert len(found) == 1, needle
    return found[0]


def _condition(step) -> str:
    return " ".join(str(step["if"]).split())


# --- structure ----------------------------------------------------------------

def test_the_judge_preflight_runs_on_every_judged_tier_and_only_those(judge_step):
    assert _condition(judge_step) == JUDGED_IF


def test_the_sign_in_runs_on_the_capability_tier_only(wif_step, stop_step):
    # Only Claude Code signs in through federation; the judge uses an API key.
    assert _condition(wif_step) == CAPABILITY_IF
    assert _condition(stop_step) == f"${{{{ always() && {CAPABILITY_IF} }}}}"


def test_claude_code_is_installed_on_the_capability_tier_only(claude_step):
    # The nightly regression tier is judged but delegates nothing to a vendor CLI.
    assert _condition(claude_step) == "inputs.tier == 'capability'"


def test_the_judged_tiers_are_the_ones_whose_steps_judge(steps):
    regression = _step_by_id(steps, "regression")["run"]
    assert "--check --judge" in regression and "bin/tier.sh regression" in regression
    assert "bin/tier.sh capability-judged" in _step_by_id(steps, "capability_judged")["run"]


def test_the_dangerous_tier_is_never_judged(steps):
    # So it never needs the sign-in, and its caller never grants id-token: write.
    assert "--judge" not in _step_by_id(steps, "dangerous")["run"]
    suite = yaml.safe_load(DANGEROUS_SUITE.read_text(encoding="utf-8"))
    assert suite["defaults"]["judge"] is False
    for scenario in suite["scenarios"]:
        assert scenario.get("judge", False) is False
        for case in scenario["cases"]:
            assert case.get("judge", False) is False and "rubric" not in case, case["id"]


def test_the_judge_is_proven_first_and_the_sign_in_precedes_claude_code_and_the_daemon(
        steps, judge_step, wif_step, claude_step):
    boot = _step_index(steps, "capability-daemon.sh up")
    # The cheapest refusal comes before anything is spent or signed in.
    assert steps.index(judge_step) < steps.index(wif_step)
    assert steps.index(wif_step) < steps.index(claude_step) < boot, \
        "claude_code_run is advertised from a boot snapshot, so claude must be on PATH first"


def test_every_judged_step_comes_after_the_judge_preflight(steps, judge_step):
    for step_id in ("regression", "capability_judged"):
        assert steps.index(judge_step) < steps.index(_step_by_id(steps, step_id)), step_id


def test_the_preflight_loads_the_judge_settings_of_the_tiers_runner(judge_step):
    expression = " ".join(str(judge_step["env"]["JUDGE_CONFIG"]).split())
    assert expression == ("${{ inputs.tier == 'regression' && 'behavioral_config.yaml'"
                          " || 'config.yaml' }}")
    assert judge_step["working-directory"] == "benchmark"
    run = judge_step["run"]
    assert 'uv run bin/judge_preflight.py --config "$JUDGE_CONFIG"' in run
    # The preflight refuses a judge on the candidate's model before any call, and
    # the judge must answer through the secret, never through a profile on the box.
    assert '--candidate-model "$CANDIDATE_MODEL"' in run
    assert "--expect-source ANTHROPIC_API_KEY" in run


def test_the_candidate_is_anthropic_opus_at_medium_effort(workflow, seed_step):
    # PyYAML reads the bare key `on` as the boolean True.
    triggers = workflow[True]
    for kind in ("workflow_call", "workflow_dispatch"):
        assert triggers[kind]["inputs"]["model"]["default"] == CANDIDATE, kind
    env = workflow["jobs"]["box"]["env"]
    assert env["CANDIDATE_MODEL"] == "${{ inputs.model }}"
    assert env["CANDIDATE_REASONING_EFFORT"] == "medium"
    assert ('seed_args="--provider anthropic --model ${CANDIDATE_MODEL} '
            '--reasoning-effort ${CANDIDATE_REASONING_EFFORT}"') in seed_step["run"]


def test_the_federation_ids_come_from_repository_variables(steps, wif_step, claude_step):
    env = wif_step["env"]
    for name in (*REQUIRED_VARS, WORKSPACE_VAR):
        assert env[name] == "${{ vars.%s }}" % name
    # Workload Identity Federation needs no secret, and no other step reads the IDs.
    for step in (wif_step, claude_step):
        assert "secrets." not in yaml.safe_dump(step), step["name"]
    others = [s.get("name") for s in steps
              if s is not wif_step and "vars.ANTHROPIC_EVAL_" in yaml.safe_dump(s)]
    assert others == []


def test_the_declared_secrets_are_the_shared_anthropic_key_and_opiks(workflow):
    # One Anthropic key serves the candidate daemon and the judge; the retired
    # OpenAI judge secret is declared nowhere.
    # PyYAML reads the bare key `on` as the boolean True.
    declared = workflow[True]["workflow_call"]["secrets"]
    assert set(declared) == {"ANTHROPIC_API_KEY", "FERMIX_OPIK_API_KEY",
                             "FERMIX_OPIK_WORKSPACE"}
    assert all(spec["required"] is True for spec in declared.values())


def _steps_naming(steps, needle):
    return [s for s in steps if needle in yaml.safe_dump(s)]


def test_the_anthropic_key_reaches_the_boot_and_the_judged_steps_only(steps, seed_step):
    holders = _steps_naming(steps, "secrets.ANTHROPIC_API_KEY")
    judged = [_step_by_id(steps, step_id)
              for step_id in ("judge_preflight", "regression", "capability_judged")]
    assert holders == sorted([*judged, seed_step], key=steps.index)
    for step in holders:
        assert step["env"]["ANTHROPIC_API_KEY"] == ANTHROPIC_SECRET, step.get("id")
    # The daemon holds no other provider's key (Opik's is the exporter's, not a
    # model's), so it can neither spend one nor fail a turn over to another provider.
    provider_keys = [n for n in seed_step["env"] if n.endswith("_API_KEY") and "OPIK" not in n]
    assert provider_keys == ["ANTHROPIC_API_KEY"]


def test_no_step_reads_the_retired_openai_judge_key(steps):
    for step in steps:
        names = list(step.get("env", {}))
        assert "EVAL_JUDGE_API_KEY" not in names, step.get("id")
        assert not any("OPENAI" in name for name in names), step.get("id")
    assert _steps_naming(steps, "secrets.OPENAI_API_KEY") == []


def test_no_other_api_key_path_remains():
    # Comments may name a key; no step may read one from anywhere else.
    for path in sorted(WORKFLOWS.glob("*.yml")):
        code = "\n".join(ln for ln in path.read_text(encoding="utf-8").splitlines()
                         if not ln.lstrip().startswith("#"))
        for name in ("EVAL_CODEX_API_KEY", "EVAL_ANTHROPIC_API_KEY",
                     "secrets.EVAL_JUDGE_API_KEY", "secrets.OPENAI_API_KEY",
                     "EVAL_JUDGE_API_KEY", "apiKeyHelper"):
            assert name not in code, (path.name, name)


def test_only_the_capability_tier_caller_grants_the_id_token_permission(workflow):
    # The box job declares no permissions, so it inherits its caller's: only the
    # capability tier signs in through WIF (for Claude Code), and the other tiers,
    # the dangerous one above all, must never hold the right to mint GitHub OIDC
    # tokens. A direct dispatch gets the repository's read-only default, and the
    # sign-in step refuses it.
    assert "permissions" not in workflow["jobs"]["box"]
    callers = {}
    for path in sorted(WORKFLOWS.glob("*.yml")):
        jobs = yaml.safe_load(path.read_text(encoding="utf-8")).get("jobs", {})
        for job_id, job in jobs.items():
            if job.get("uses") == "./.github/workflows/eval-box.yml":
                callers[(path.name, job_id)] = (job.get("with", {}).get("tier"),
                                                job.get("permissions"))
    assert set(callers) >= {("eval-weekly.yml", "capability"),
                            ("eval-weekly.yml", "dangerous"),
                            ("eval-nightly.yml", "regression")}
    for (name, job_id), (tier, permissions) in callers.items():
        if tier == "capability":
            assert permissions == {"contents": "read", "id-token": "write"}, (name, job_id)
        else:
            assert "id-token" not in (permissions or {}), (name, job_id)


def test_only_the_sign_in_step_requests_an_oidc_token(steps, wif_step):
    boot = steps[_step_index(steps, "capability-daemon.sh up")]
    for step in steps:
        if step is wif_step or step is boot:
            continue
        assert "ACTIONS_ID_TOKEN_REQUEST" not in yaml.safe_dump(step), step.get("name")
    # The daemon, and every process the candidate drives through it, never holds
    # the job's credential for minting OIDC tokens.
    run = boot["run"]
    unset = run.index("unset ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL")
    assert unset < run.index("capability-daemon.sh up")
    assert run.count("ACTIONS_ID_TOKEN_REQUEST_TOKEN") == 1


def test_the_binary_is_pinned_by_version_and_checksum(claude_step):
    env = claude_step["env"]
    assert re.fullmatch(r"\d+\.\d+\.\d+", str(env["CLAUDE_CODE_VERSION"]))
    assert re.fullmatch(r"[0-9a-f]{64}", str(env["CLAUDE_CODE_SHA256"]))
    run = claude_step["run"]
    assert ("https://downloads.claude.ai/claude-code-releases/$CLAUDE_CODE_VERSION/"
            "linux-x64/claude") in run
    for unpinned in ("/latest", "/stable", "install.sh", "npm ", "claude update",
                     "claude install"):
        assert unpinned not in run, unpinned


def test_the_model_is_pinned_to_haiku(claude_step):
    assert claude_step["env"]["CLAUDE_MODEL"] == "claude-haiku-5-5"


def test_the_refresher_outlasts_the_capability_tier_and_stops_after_the_daemon(
        workflow, steps, wif_step, claude_step, stop_step):
    env = wif_step["env"]
    seconds, rounds = int(env["WIF_REFRESH_SECONDS"]), int(env["WIF_REFRESH_MAX"])
    # GitHub's OIDC tokens live about five minutes; a minute keeps the file ahead.
    assert seconds == 60
    timeout = str(workflow["jobs"]["box"]["timeout-minutes"])
    assert f"inputs.tier == 'capability' && {CAPABILITY_TIMEOUT_MINUTES}" in timeout
    assert seconds * rounds >= CAPABILITY_TIMEOUT_MINUTES * 60
    # Claude Code waits for one rotation after its preflight, so the bound must
    # cover a whole period with room to spare.
    assert int(claude_step["env"]["WIF_ROTATION_WAIT_SECONDS"]) >= 2 * seconds
    assert steps.index(stop_step) > _step_index(steps, "capability-daemon.sh down")


def test_these_tests_run_in_the_tests_loop():
    # ci.yml runs `make -C benchmark tests`; a file missing from its loop never runs.
    makefile = (HERE.parent / "Makefile").read_text(encoding="utf-8")
    loop = [ln for ln in makefile.splitlines() if "for t in" in ln]
    assert any("eval_box" in ln.split() for ln in loop)


# --- behaviour: the steps' own shell against stubs ------------------------------

CLAUDE_STUB = """#!/bin/sh
# Stand-in for the Claude Code binary: the calls the step makes.
# The harness spawns claude under env -i with HOME, PATH, TERM and USER only, so a
# probe that can see the step's own environment proves nothing about a run.
probe_env_is_wiped() {
  if [ -n "${ANTHROPIC_EVAL_ORGANIZATION_ID:-}${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}${RUNNER_TEMP:-}" ]; then
    echo "probe ran in the step env"; exit 3
  fi
}
config="$HOME/.config/anthropic"
name=$(cat "$config/active_config" 2>/dev/null)
case "$*" in
  --version) echo "0.0.0-stub (Claude Code)" ;;
  "auth status --text")
    probe_env_is_wiped
    %(auth)s ;;
  "-p --output-format stream-json --verbose --max-turns 1 -- "*)
    probe_env_is_wiped
    %(call)s ;;
  *) echo "unexpected claude call: $*" >&2; exit 64 ;;
esac
"""
AUTH_FROM_PROFILE = """\
if grep -q '"oidc_federation"' "$config/configs/$name.json" 2>/dev/null; then
      echo "Profile: credentials-file · oidc_federation · profile $name"; exit 0
    fi
    echo "Not logged in. Run claude auth login to authenticate."; exit 1"""
AUTH_FROM_LOGIN = 'echo "Login method: Claude Max account"; exit 0'
# Exchanges the profile's identity token (a whole JWT, used once: a GitHub token's
# `jti` refuses a second exchange) and answers on the model the settings file pins,
# unless a test overrides what was used.
CALL_TEMPLATE = """\
token=$(jq -r '.authentication.identity_token.path' "$config/configs/$name.json")
    if ! grep -Eqx '[A-Za-z0-9_-]+[.][A-Za-z0-9_-]+[.][A-Za-z0-9_-]+' "$token"; then
      echo "no identity token" >&2; exit 1
    fi
    if grep -qxF "$(cat "$token")" "%(spent)s" 2>/dev/null; then
      echo "API Error: Token exchange failed with status 401: the identity token was already used" >&2; exit 1
    fi
    cat "$token" >> "%(spent)s"
    model=$(jq -r '.model' "$HOME/.claude/settings.json")
    used=%(used)s
    echo '{"type":"system","subtype":"init","model":"'"$model"'","apiKeySource":"%(key_source)s"}'
    echo '{"type":"result","subtype":"success","is_error":false,"result":"OK","modelUsage":{"'"$used"'":{}}}'"""
CALL_FAILS = """\
echo '{"type":"system","subtype":"init","model":"claude-haiku-5-5","apiKeySource":"none"}'
    echo '{"type":"result","subtype":"success","is_error":true,"result":"API Error: Token exchange failed with status 401 (request-id req_invented): Authentication failed","modelUsage":{}}'
    exit 1"""

CURL_STUB = """#!/bin/sh
# Serves the stub Claude Code binary for a release URL and a numbered invented JWT
# for the OIDC endpoint (optionally in two halves, slowly), and records each URL.
# Its settings come from stub.env beside it, read as plain shell variables, so it
# works from the refresher's wiped environment and `env` below shows only what the
# caller really passed down. Every argv and every inherited environment is
# recorded, so a test can prove the OIDC request credential reached neither.
. "$(dirname "$0")/stub.env"
printf '%s\\n' "$*" >> "$STUB_ARGV_LOG"
out=""; header=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H) header="$2"; [ "$header" != "@-" ] || IFS= read -r header; shift 2 ;;
    --retry|--max-time) shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
echo "$url" >> "$STUB_CURL_LOG"
case "$url" in
  "$STUB_OIDC_URL"*)
    if env | grep -qF "$STUB_OIDC_REQUEST_TOKEN"; then echo "inherited" >> "$STUB_ENV_LOG"
    else echo "clean" >> "$STUB_ENV_LOG"; fi
    if [ "$header" != "Authorization: Bearer $STUB_OIDC_REQUEST_TOKEN" ] || [ -e "$STUB_OIDC_FAIL" ]; then
      echo "curl: (22) The requested URL returned error: 403" >&2; exit 22
    fi
    n=$(( $(cat "$STUB_OIDC_COUNT" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$STUB_OIDC_COUNT"
    printf '{"count":1,"value":"%s.payload%04d' "$STUB_JWT_STEM" "$n"
    [ -z "$STUB_OIDC_SLOW" ] || sleep "$STUB_OIDC_SLOW"
    printf '.signature%04d"}\\n' "$n" ;;
  *) cp "$STUB_BINARY" "$out" ;;
esac
"""

# Stands in for `uv run bin/judge_preflight.py`: records its argv and whether the
# judge's key reached it (never the value), then reports what the real script
# prints, or the sentence it fails with.
UV_STUB = """#!/bin/sh
. "$(dirname "$0")/stub.env"
printf '%s\\n' "$*" >> "$STUB_UV_LOG"
case "$*" in
  "run bin/judge_preflight.py --config "*" --candidate-model "*" --expect-source ANTHROPIC_API_KEY") ;;
  *) echo "unexpected uv call: $*" >&2; exit 64 ;;
esac
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then echo "key=set" >> "$STUB_UV_LOG"
else echo "key=unset" >> "$STUB_UV_LOG"; fi
if [ -e "$STUB_JUDGE_FAIL" ]; then
  echo "Installed 18 packages in 40ms"
  echo "the judge did not answer: anthropic judge API error (HTTP 401, authentication_error): invalid x-api-key [request req_invented]"
  exit 1
fi
echo "judge anthropic/claude-haiku-5-5 answered through ANTHROPIC_API_KEY: pass (310 input / 41 output tokens)"
"""

# Stands in for benchmark/bin/capability-daemon.sh: records how the boot step called
# it, the seed arguments it passed, and which credentials reached the daemon's
# environment (by name, never by value).
DAEMON_STUB = """#!/bin/sh
log="$(dirname "$0")/daemon-stub.log"
printf 'argv=%s\\n' "$*" >> "$log"
printf 'seed_args=%s\\n' "${FERMIX_CAP_SEED_ARGS:-}" >> "$log"
for name in ANTHROPIC_API_KEY OPENAI_API_KEY EVAL_JUDGE_API_KEY ACTIONS_ID_TOKEN_REQUEST_TOKEN; do
  eval "value=\\${$name:-}"
  if [ -n "$value" ]; then echo "$name=set" >> "$log"; else echo "$name=unset" >> "$log"; fi
done
"""

UNAME_STUB = """#!/bin/sh
[ "$1" = "-m" ] && { echo "$STUB_ARCH"; exit 0; }
exit 64
"""


def _stub(bin_dir: Path, name: str, body: str) -> None:
    path = bin_dir / name
    path.write_text(body)
    path.chmod(0o755)


def _claude_binary(path: Path, spent: Path, *, auth=AUTH_FROM_PROFILE, call=None,
                   used='"$model"', key_source="none") -> str:
    """The stub release binary; returns its sha256."""
    call = call or CALL_TEMPLATE % {"used": used, "key_source": key_source,
                                    "spent": spent}
    path.write_text(CLAUDE_STUB % {"auth": auth, "call": call})
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _run_steps(workflow, run_steps, root: Path, *, tier="capability", binary=None,
               sha=None, arch="x86_64", vars_=None, oidc=True, oidc_fails=False,
               oidc_slow="", judge_fails=False, refresh_seconds="30", refresh_max="200",
               rotation_wait=None, anthropic_key=INVENTED_ANTHROPIC_KEY):
    """Executes the given steps' shell in order, the way the runner would, sharing
    one HOME, RUNNER_TEMP and GITHUB_PATH; stops at the first step that fails."""
    root.mkdir()
    stub_bin, home, runner_temp = root / "stubbin", root / "home", root / "runner_temp"
    daemon_bin = root / "benchmark" / "bin"
    for d in (stub_bin, home, runner_temp, daemon_bin):
        d.mkdir(parents=True)
    _stub(daemon_bin, "capability-daemon.sh", DAEMON_STUB)
    for name, body in (("curl", CURL_STUB), ("uname", UNAME_STUB), ("uv", UV_STUB)):
        _stub(stub_bin, name, body)
    spent = root / "spent-tokens.log"
    binary_path = root / "claude-release"
    binary_sha = _claude_binary(binary_path, spent, **(binary or {}))
    github_path, curl_log = root / "github_path", root / "curl.log"
    github_path.write_text("")
    oidc_fail, judge_fail = root / "oidc-fail", root / "judge-fail"
    if oidc_fails:
        oidc_fail.write_text("")
    if judge_fails:
        judge_fail.write_text("")
    argv_log, env_log, uv_log = root / "curl-argv.log", root / "curl-env.log", root / "uv.log"
    stub_env = {"STUB_BINARY": str(binary_path), "STUB_CURL_LOG": str(curl_log),
                "STUB_OIDC_URL": OIDC_URL, "STUB_OIDC_REQUEST_TOKEN": REQUEST_TOKEN,
                "STUB_OIDC_COUNT": str(root / "oidc-count"),
                "STUB_OIDC_FAIL": str(oidc_fail), "STUB_OIDC_SLOW": oidc_slow,
                "STUB_JWT_STEM": JWT_STEM, "STUB_ARGV_LOG": str(argv_log),
                "STUB_ENV_LOG": str(env_log), "STUB_UV_LOG": str(uv_log),
                "STUB_SPENT_LOG": str(spent), "STUB_JUDGE_FAIL": str(judge_fail)}
    (stub_bin / "stub.env").write_text(
        "".join(f"{k}='{v}'\n" for k, v in stub_env.items()))
    job_env = workflow["jobs"]["box"]["env"]
    base = {"PATH": f"{stub_bin}{os.pathsep}{os.environ.get('PATH', '')}",
            "HOME": str(home), "RUNNER_TEMP": str(runner_temp),
            "GITHUB_PATH": str(github_path), "STUB_ARCH": arch, "TIER": tier,
            "WIF_PROFILE": str(job_env["WIF_PROFILE"]), "CANDIDATE_MODEL": CANDIDATE,
            "CANDIDATE_REASONING_EFFORT": str(job_env["CANDIDATE_REASONING_EFFORT"]),
            "EVAL_HOME": str(root / "eval-home"),
            "GITHUB_WORKSPACE": str(root / "workspace")}
    if oidc:
        base |= {"ACTIONS_ID_TOKEN_REQUEST_URL": OIDC_URL,
                 "ACTIONS_ID_TOKEN_REQUEST_TOKEN": REQUEST_TOKEN}
    # The steps' own env, with the values a test cannot take from it.
    overrides = {**(VAR_VALUES if vars_ is None else vars_),
                 "CLAUDE_CODE_SHA256": sha or binary_sha,
                 "WIF_REFRESH_SECONDS": refresh_seconds, "WIF_REFRESH_MAX": refresh_max,
                 "ANTHROPIC_API_KEY": anthropic_key}
    output, status = "", 0
    for step in run_steps:
        env = {**base, **{k: str(v) for k, v in step.get("env", {}).items()}}
        env |= {k: v for k, v in overrides.items() if k in step.get("env", {})}
        if "JUDGE_CONFIG" in env:
            env["JUDGE_CONFIG"] = JUDGE_CONFIGS[tier]
        if rotation_wait is not None and "WIF_ROTATION_WAIT_SECONDS" in env:
            env["WIF_ROTATION_WAIT_SECONDS"] = rotation_wait
        p = subprocess.run(["bash", "-c", step["run"]], cwd=str(root), env=env,
                           capture_output=True, text=True, timeout=60)
        output += p.stdout + p.stderr
        status = p.returncode
        if status != 0:
            break
    return SimpleNamespace(
        status=status, output=output,
        published=github_path.read_text(), home=home, runner_temp=runner_temp,
        urls=curl_log.read_text().split() if curl_log.exists() else [],
        wif_dir=runner_temp / "anthropic-wif", oidc_fail=oidc_fail,
        argv_log=argv_log, env_log=env_log,
        uv_calls=uv_log.read_text().splitlines() if uv_log.exists() else [],
        spent=spent,
        daemon=(daemon_bin / "daemon-stub.log").read_text().splitlines()
        if (daemon_bin / "daemon-stub.log").exists() else [])


def _stop_refresher(wif_dir: Path) -> None:
    """Ends a refresher loop and the `sleep` it is waiting in, which would
    otherwise outlive the test as an orphan."""
    pidfile = wif_dir / "refresher.pid"
    if not pidfile.exists():
        return
    pid = pidfile.read_text().strip()
    children = subprocess.run(["pgrep", "-P", pid], capture_output=True,
                              text=True).stdout.split()
    for target in [pid, *children]:
        try:
            os.kill(int(target), signal.SIGTERM)
        except ProcessLookupError:
            pass  # already gone: a loop that reached its cap, or a finished sleep


@pytest.fixture
def run_box(workflow, wif_step, claude_step, tmp_path):
    """Runs the sign-in (and, with claude=True, the Claude Code step after it);
    stops every refresher a run started when the test ends."""
    started: list[Path] = []

    def run(*, claude=False, steps=None, **kwargs):
        chosen = steps or ([wif_step, claude_step] if claude else [wif_step])
        result = _run_steps(workflow, chosen, tmp_path / f"run{len(started)}", **kwargs)
        started.append(result.wif_dir)
        return result

    yield run
    for wif_dir in started:
        _stop_refresher(wif_dir)


def _error_lines(output: str) -> list[str]:
    return [ln for ln in output.splitlines() if ln.startswith("::error::")]


def _mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def _never_signed_in(r) -> None:
    assert r.status != 0
    assert r.published == ""
    assert not (r.wif_dir / "refresher.pid").exists()


def _claude_never_on_path(r) -> None:
    assert r.status != 0
    assert r.published == ""


def _spent(r) -> list[str]:
    return r.spent.read_text().splitlines() if r.spent.exists() else []


def _await_oidc_fetches(r, n: int, timeout: float = 5.0) -> None:
    """Waits, at most `timeout` seconds, until the OIDC endpoint has served `n` tokens."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if r.env_log.exists() and len(r.env_log.read_text().split()) >= n:
            return
        time.sleep(0.05)
    raise AssertionError(f"fewer than {n} OIDC fetches within {timeout}s")


def test_the_sign_in_writes_the_profile_and_keeps_the_token_fresh(run_box):
    r = run_box()
    assert r.status == 0, r.output
    # One token for Claude Code's first exchange; the judge needs none.
    assert r.urls == [OIDC]
    assert r.published == ""
    assert r.uv_calls == []
    anthropic_dir = r.home / ".config" / "anthropic"
    assert (anthropic_dir / "active_config").read_text() == "fermix-eval\n"
    jwt = r.wif_dir / "github-oidc.jwt"
    profile = json.loads((anthropic_dir / "configs" / "fermix-eval.json").read_text())
    assert profile == {
        "version": "1.0",
        "authentication": {
            "type": "oidc_federation",
            "federation_rule_id": VAR_VALUES["ANTHROPIC_EVAL_FEDERATION_RULE_ID"],
            "service_account_id": VAR_VALUES["ANTHROPIC_EVAL_SERVICE_ACCOUNT_ID"],
            "identity_token": {"source": "file", "path": str(jwt)}},
        "organization_id": VAR_VALUES["ANTHROPIC_EVAL_ORGANIZATION_ID"],
        "workspace_id": VAR_VALUES[WORKSPACE_VAR]}
    # Nothing has exchanged it yet.
    assert _spent(r) == []
    assert JWT_RE.fullmatch(jwt.read_text()).group(1) == "0001"
    assert _mode(jwt) == 0o600
    assert _mode(r.wif_dir) == 0o700 and _mode(anthropic_dir) == 0o700
    assert (r.wif_dir / "refresher.pid").exists()


def test_the_capability_tier_signs_in_then_puts_a_proven_claude_on_path(run_box,
                                                                        claude_step):
    r = run_box(claude=True, refresh_seconds="0.2")
    assert r.status == 0, r.output
    version = claude_step["env"]["CLAUDE_CODE_VERSION"]
    install_dir = r.runner_temp / f"claude-code-{version}" / "bin"
    assert r.published == f"{install_dir}\n"
    assert r.urls[:2] == [OIDC, f"https://downloads.claude.ai/claude-code-releases/"
                                f"{version}/linux-x64/claude"]
    assert r.uv_calls == []
    settings = json.loads((r.home / ".claude" / "settings.json").read_text())
    assert settings == {"model": "claude-haiku-5-5",
                        "env": {"DISABLE_AUTOUPDATER": "1", "DISABLE_UPDATES": "1"}}
    # Claude Code's preflight exchanged one token and the step waited for a
    # rotation, so the file now holds one nobody has spent.
    spent = _spent(r)
    assert len(spent) == 1
    assert (r.wif_dir / "github-oidc.jwt").read_text().strip() not in spent


def test_an_empty_workspace_variable_leaves_workspace_id_out(run_box):
    r = run_box(vars_={**VAR_VALUES, WORKSPACE_VAR: ""})
    assert r.status == 0, r.output
    profile = r.home / ".config" / "anthropic" / "configs" / "fermix-eval.json"
    assert "workspace_id" not in json.loads(profile.read_text())


def test_no_token_reaches_the_log(run_box):
    r = run_box(claude=True, refresh_seconds="0.2")
    assert r.status == 0, r.output
    time.sleep(1.0)
    log = (r.wif_dir / "refresher.log").read_text()
    assert "refreshed" in log
    for text in (r.output, log):
        assert JWT_STEM not in text and REQUEST_TOKEN not in text


@pytest.mark.parametrize("name", REQUIRED_VARS)
def test_an_empty_required_variable_fails_before_anything_is_fetched(run_box, name):
    r = run_box(vars_={**VAR_VALUES, name: ""})
    _never_signed_in(r)
    assert any(name in ln for ln in _error_lines(r.output)), r.output
    assert r.urls == [] and r.uv_calls == []


def test_a_job_without_the_id_token_permission_is_refused(run_box):
    r = run_box(oidc=False)
    _never_signed_in(r)
    assert any("id-token: write" in ln for ln in _error_lines(r.output)), r.output
    assert r.urls == []


def test_a_failed_first_token_fetch_fails_the_step(run_box):
    r = run_box(oidc_fails=True)
    _never_signed_in(r)
    assert any("OIDC token" in ln for ln in _error_lines(r.output)), r.output
    assert not (r.wif_dir / "github-oidc.jwt").exists()
    assert r.uv_calls == []




def test_a_binary_that_fails_its_checksum_is_never_installed(run_box, claude_step):
    r = run_box(claude=True, sha="0" * 64)
    _claude_never_on_path(r)
    assert any("checksum" in ln for ln in _error_lines(r.output)), r.output
    version = claude_step["env"]["CLAUDE_CODE_VERSION"]
    assert not (r.runner_temp / f"claude-code-{version}" / "bin" / "claude").exists()


def test_claude_code_without_the_sign_in_is_refused(run_box, claude_step):
    r = run_box(steps=[claude_step])
    _claude_never_on_path(r)
    assert any("sign-in did not finish" in ln for ln in _error_lines(r.output)), r.output
    assert r.urls == []


def test_a_claude_whose_preflight_call_fails_is_never_put_on_path(run_box):
    r = run_box(claude=True, binary={"call": CALL_FAILS})
    _claude_never_on_path(r)
    assert any("Token exchange failed" in ln for ln in _error_lines(r.output)), r.output


def test_a_claude_on_the_wrong_model_is_never_put_on_path(run_box):
    r = run_box(claude=True, binary={"used": "claude-sonnet-5-5"})
    _claude_never_on_path(r)
    assert any("claude-sonnet-5-5" in ln and "claude-haiku-5-5" in ln
               for ln in _error_lines(r.output)), r.output


def test_a_credential_other_than_the_profile_is_refused(run_box):
    r = run_box(claude=True, binary={"auth": AUTH_FROM_LOGIN})
    _claude_never_on_path(r)
    assert any("Login method" in ln for ln in _error_lines(r.output)), r.output


def test_an_api_key_answering_the_call_is_refused(run_box):
    r = run_box(claude=True, binary={"key_source": "apiKeyHelper"})
    _claude_never_on_path(r)
    assert any("apiKeyHelper" in ln for ln in _error_lines(r.output)), r.output


def test_claude_code_waits_for_a_fresh_token_after_its_preflight(run_box):
    # The refresher's next rotation is half a minute away and the bound is two
    # seconds: the step must fail rather than hand the first run a spent token.
    r = run_box(claude=True, refresh_seconds="30", rotation_wait="2")
    _claude_never_on_path(r)
    assert any("did not replace the token" in ln for ln in _error_lines(r.output)), r.output


def test_a_runner_the_pinned_binary_does_not_fit_is_refused(run_box):
    r = run_box(claude=True, arch="aarch64")
    _claude_never_on_path(r)
    assert _error_lines(r.output), r.output
    assert not any(url.startswith("https://downloads.claude.ai/") for url in r.urls)


def test_the_refresher_keeps_replacing_the_token(run_box):
    r = run_box(refresh_seconds="0.2")
    assert r.status == 0, r.output
    time.sleep(1.2)
    jwt = r.wif_dir / "github-oidc.jwt"
    assert int(JWT_RE.fullmatch(jwt.read_text()).group(1)) > 3
    assert _mode(jwt) == 0o600


def test_the_request_credential_never_reaches_a_command_line(run_box):
    # Any process on the box can read another's argv from /proc/<pid>/cmdline, so
    # curl takes the Authorization header on stdin, on every fetch.
    r = run_box(refresh_seconds="0.2")
    assert r.status == 0, r.output
    _await_oidc_fetches(r, 4)
    assert REQUEST_TOKEN not in r.argv_log.read_text()
    assert "-H @-" in r.argv_log.read_text()


def test_the_refresher_starts_from_a_wiped_environment(run_box):
    # The refresher outlives the step beside the processes the candidate drives,
    # and /proc/<pid>/environ is readable by the same user, so it holds the
    # request credential only in a shell variable read from a file descriptor.
    r = run_box(refresh_seconds="0.2")
    assert r.status == 0, r.output
    _await_oidc_fetches(r, 4)
    envs = r.env_log.read_text().split()
    # The first fetch runs in the step itself; every later one is the refresher's.
    assert len(envs) >= 4 and envs[1:] == ["clean"] * len(envs[1:]), envs


def test_the_refresher_never_exposes_a_partial_token(run_box):
    # The endpoint answers in two halves; a reader polling the file while the loop
    # replaces it must only ever see a whole token, never an empty or cut one.
    r = run_box(refresh_seconds="0.05", oidc_slow="0.15")
    assert r.status == 0, r.output
    jwt, seen, deadline = r.wif_dir / "github-oidc.jwt", set(), time.monotonic() + 2.0
    while time.monotonic() < deadline:
        content = jwt.read_text()
        assert JWT_RE.fullmatch(content), repr(content)
        seen.add(content)
        time.sleep(0.005)
    assert len(seen) >= 3, "the loop never replaced the token while it was polled"


def test_the_refresher_stops_at_its_cap(run_box):
    r = run_box(refresh_seconds="0.1", refresh_max="2")
    assert r.status == 0, r.output
    time.sleep(1.0)
    pid = int((r.wif_dir / "refresher.pid").read_text())
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)
    lines = (r.wif_dir / "refresher.log").read_text().splitlines()
    assert sum(ln.endswith(" refreshed") for ln in lines) == 2
    assert lines[-1].endswith("stopped at the cap of 2 refreshes")


def test_a_refresh_failure_is_logged_without_ending_the_loop(run_box):
    r = run_box(refresh_seconds="0.1")
    assert r.status == 0, r.output
    r.oidc_fail.write_text("")
    time.sleep(0.6)
    r.oidc_fail.unlink()
    time.sleep(0.6)
    log = (r.wif_dir / "refresher.log").read_text()
    assert " refresh FAILED" in log and log.rstrip().endswith(" refreshed")


# --- behaviour: the judge preflight ----------------------------------------------

@pytest.mark.parametrize("tier", JUDGED_TIERS)
def test_the_judge_preflight_proves_the_judge_before_anything_is_spent(run_box, judge_step,
                                                                       tier):
    r = run_box(steps=[judge_step], tier=tier)
    assert r.status == 0, r.output
    assert r.uv_calls == [f"run bin/judge_preflight.py --config {JUDGE_CONFIGS[tier]} "
                          f"--candidate-model {CANDIDATE} --expect-source ANTHROPIC_API_KEY",
                          "key=set"]
    assert f"judge anthropic/{JUDGE} answered through ANTHROPIC_API_KEY" in r.output
    assert INVENTED_ANTHROPIC_KEY not in r.output
    assert r.urls == [] and r.daemon == []


def test_an_empty_anthropic_secret_stops_a_judged_tier_before_the_preflight(run_box,
                                                                            judge_step):
    r = run_box(steps=[judge_step], tier="regression", anthropic_key="")
    assert r.status != 0
    errors = _error_lines(r.output)
    assert any("ANTHROPIC_API_KEY is empty" in ln and "anthropic backend" in ln
               and "behavioral_config.yaml" in ln for ln in errors), r.output
    assert r.uv_calls == []


def test_a_judge_whose_preflight_fails_stops_the_tier(run_box, judge_step):
    r = run_box(steps=[judge_step], tier="regression", judge_fails=True)
    assert r.status != 0
    errors = _error_lines(r.output)
    assert any("judge preflight failed" in ln and "HTTP 401" in ln
               for ln in errors), r.output


# --- behaviour: the boot of the daemon under test --------------------------------

def test_the_daemon_boots_on_the_anthropic_candidate_at_medium_effort(run_box, seed_step):
    r = run_box(steps=[seed_step], tier="regression")
    assert r.status == 0, r.output
    assert r.daemon[:2] == ["argv=up",
                            f"seed_args=--provider anthropic --model {CANDIDATE} "
                            f"--reasoning-effort medium --allow-root {r.home.parent}/workspace"]
    # The candidate's key, which the judge's own steps share; nothing of the OIDC
    # exchange and no other provider's key.
    assert r.daemon[2:] == ["ANTHROPIC_API_KEY=set", "OPENAI_API_KEY=unset",
                            "EVAL_JUDGE_API_KEY=unset",
                            "ACTIONS_ID_TOKEN_REQUEST_TOKEN=unset"]
    assert INVENTED_ANTHROPIC_KEY not in r.output


def test_a_missing_anthropic_key_stops_the_boot_with_a_sentence(run_box, seed_step):
    r = run_box(steps=[seed_step], tier="regression", anthropic_key="")
    assert r.status != 0
    errors = _error_lines(r.output)
    assert any("ANTHROPIC_API_KEY is empty" in ln and CANDIDATE in ln and "medium" in ln
               for ln in errors), r.output
    assert r.daemon == []


# --- behaviour: the step that stops the refresher -------------------------------

def _run_stop_step(stop_step, runner_temp: Path, tier: str = "capability"):
    p = subprocess.run(["bash", "-c", stop_step["run"]], env={
        "PATH": os.environ.get("PATH", ""), "RUNNER_TEMP": str(runner_temp), "TIER": tier},
        capture_output=True, text=True, timeout=30)
    return p.returncode, p.stdout + p.stderr


def _fake_refresher(tmp_path: Path, log: str):
    wif_dir = tmp_path / "anthropic-wif"
    wif_dir.mkdir()
    proc = subprocess.Popen(["sleep", "30"])
    (wif_dir / "refresher.pid").write_text(f"{proc.pid}\n")
    (wif_dir / "refresher.log").write_text(log)
    return proc


def test_the_stop_step_ends_a_clean_refresher(stop_step, tmp_path):
    proc = _fake_refresher(tmp_path, "2026-10-03T08:00:00Z refreshed\n" * 3)
    status, output = _run_stop_step(stop_step, tmp_path)
    assert status == 0, output
    assert proc.wait(timeout=5) == -signal.SIGTERM
    assert "3 refreshed, 0 failed" in output


def test_the_stop_step_fails_the_job_when_a_refresh_failed(stop_step, tmp_path):
    proc = _fake_refresher(tmp_path, "2026-10-03T08:00:00Z refreshed\n"
                           "curl: (22) The requested URL returned error: 503\n"
                           "2026-10-03T08:01:00Z refresh FAILED\n")
    status, output = _run_stop_step(stop_step, tmp_path)
    proc.wait(timeout=5)
    assert status != 0
    errors = _error_lines(output)
    assert any("1 identity-token refreshes failed during the capability tier" in ln
               and "claude_code_run" in ln for ln in errors), output
    assert "returned error: 503" in output


def test_the_stop_step_passes_when_no_refresher_started(stop_step, tmp_path):
    status, output = _run_stop_step(stop_step, tmp_path)
    assert status == 0, output
    assert "No token refresher was started" in output


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
