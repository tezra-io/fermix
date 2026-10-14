#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7"]
# ///
"""Tests for the eval box's Anthropic sign-in in `.github/workflows/eval-box.yml`.

Every JUDGED tier (regression, capability) grades replies with the Claude judge,
and the capability tier's coding-harness tasks (suites/capability/harness.yaml)
also delegate to Claude Code. Both sign in through Workload Identity Federation:
one step writes an `oidc_federation` profile fed by this job's GitHub OIDC token,
proves the judge answers through it with one real verdict, and starts a background
loop that keeps the token fresh. A second step, on the capability tier only,
installs a pinned, checksum-verified Claude Code binary, pins its model and proves
it signs in through the same profile before the daemon boots. No API key exists on
the box.

A judge or CLI that cannot authenticate is worse than none: the judged cases go
incomplete, or the daemon advertises `claude_code_run` and every delegated run
scores 0.00 as a candidate failure. So these tests hold the steps to failing
loudly instead. The structural group reads the workflows; the behavioural group
runs the steps' own shell against a stub `curl` (release download and OIDC
endpoint), a stub `uv` standing in for the judge preflight, and a stub Claude Code
binary. GitHub OIDC tokens are single-use, so both stubs refuse a token that was
already exchanged. No network, no real credential, no spend.

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
PREFLIGHT_SOURCE = "profile fermix-eval (oidc_federation)"


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

def test_the_sign_in_runs_on_every_judged_tier_and_only_those(wif_step, stop_step):
    assert _condition(wif_step) == JUDGED_IF
    assert _condition(stop_step) == f"${{{{ always() && ({JUDGED_IF}) }}}}"


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


def test_the_sign_in_precedes_claude_code_and_both_precede_the_daemon(steps, wif_step,
                                                                       claude_step):
    boot = _step_index(steps, "capability-daemon.sh up")
    assert steps.index(wif_step) < steps.index(claude_step) < boot, \
        "claude_code_run is advertised from a boot snapshot, so claude must be on PATH first"


def test_every_judged_step_comes_after_the_sign_in(steps, wif_step):
    for step_id in ("regression", "capability_judged"):
        assert steps.index(wif_step) < steps.index(_step_by_id(steps, step_id)), step_id


def test_the_preflight_loads_the_judge_settings_of_the_tiers_runner(wif_step):
    expression = " ".join(str(wif_step["env"]["JUDGE_CONFIG"]).split())
    assert expression == ("${{ inputs.tier == 'regression' && 'behavioral_config.yaml'"
                          " || 'config.yaml' }}")
    assert wif_step["working-directory"] == "benchmark"
    run = wif_step["run"]
    assert 'uv run bin/judge_preflight.py --config "$JUDGE_CONFIG"' in run
    assert '--expect-source "profile $WIF_PROFILE (oidc_federation)"' in run


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


def test_no_api_key_path_remains(workflow):
    # Comments may name the key a `bare` run would need; nothing may provide one.
    # EVAL_JUDGE_API_KEY belonged to the OpenAI judge, which no tier uses.
    code = "\n".join(ln for ln in EVAL_BOX.read_text(encoding="utf-8").splitlines()
                     if not ln.lstrip().startswith("#"))
    for name in ("EVAL_CODEX_API_KEY", "EVAL_ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY",
                 "EVAL_JUDGE_API_KEY", "apiKeyHelper"):
        assert name not in code, name
    # PyYAML reads the bare key `on` as the boolean True.
    declared = workflow[True]["workflow_call"]["secrets"]
    assert not any("CODEX" in name or "ANTHROPIC" in name or "JUDGE" in name
                   for name in declared)


def test_only_judged_tier_callers_grant_the_id_token_permission(workflow):
    # The box job declares no permissions, so it inherits its caller's: only the
    # judged tiers sign in through WIF, and the other tiers, the dangerous one
    # above all, must never hold the right to mint GitHub OIDC tokens. A direct
    # dispatch gets the repository's read-only default, and the sign-in step
    # refuses it.
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
        if tier in JUDGED_TIERS:
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


def test_the_refresher_outlasts_every_judged_tier_and_stops_after_the_daemon(
        workflow, steps, wif_step, claude_step, stop_step):
    env = wif_step["env"]
    seconds, rounds = int(env["WIF_REFRESH_SECONDS"]), int(env["WIF_REFRESH_MAX"])
    # GitHub's OIDC tokens live about five minutes; a minute keeps the file ahead.
    assert seconds == 60
    timeout = str(workflow["jobs"]["box"]["timeout-minutes"])
    assert f"inputs.tier == 'capability' && {CAPABILITY_TIMEOUT_MINUTES}" in timeout
    assert "inputs.tier == 'regression' && 60" in timeout
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

# Stands in for `uv run bin/judge_preflight.py`: exchanges the active profile's
# identity token as the SDK would (once per token), then reports what the real
# script prints, or the sentence it fails with.
UV_STUB = """#!/bin/sh
. "$(dirname "$0")/stub.env"
printf '%s\\n' "$*" >> "$STUB_UV_LOG"
case "$*" in
  "run bin/judge_preflight.py --config "*" --expect-source "*) ;;
  *) echo "unexpected uv call: $*" >&2; exit 64 ;;
esac
config="$HOME/.config/anthropic"
name=$(cat "$config/active_config")
token=$(jq -r '.authentication.identity_token.path' "$config/configs/$name.json")
if ! grep -Eqx '[A-Za-z0-9_-]+[.][A-Za-z0-9_-]+[.][A-Za-z0-9_-]+' "$token"; then
  echo "the judge did not answer: anthropic judge credential failed: no identity token"; exit 1
fi
if grep -qxF "$(cat "$token")" "$STUB_SPENT_LOG" 2>/dev/null; then
  echo "the judge did not answer: anthropic judge credential failed: token exchange failed (HTTP 401)"; exit 1
fi
cat "$token" >> "$STUB_SPENT_LOG"
if [ -e "$STUB_JUDGE_FAIL" ]; then
  echo "Installed 18 packages in 40ms"
  echo "the judge did not answer: anthropic judge API error (HTTP 404, not_found_error): model: claude-opus-5-5"
  exit 1
fi
echo "judge anthropic/claude-opus-5-5 answered through profile $name (oidc_federation): pass"
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
               rotation_wait=None):
    """Executes the given steps' shell in order, the way the runner would, sharing
    one HOME, RUNNER_TEMP and GITHUB_PATH; stops at the first step that fails."""
    root.mkdir()
    stub_bin, home, runner_temp = root / "stubbin", root / "home", root / "runner_temp"
    for d in (stub_bin, home, runner_temp):
        d.mkdir()
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
            "WIF_PROFILE": str(job_env["WIF_PROFILE"])}
    if oidc:
        base |= {"ACTIONS_ID_TOKEN_REQUEST_URL": OIDC_URL,
                 "ACTIONS_ID_TOKEN_REQUEST_TOKEN": REQUEST_TOKEN}
    # The steps' own env, with the values a test cannot take from it.
    overrides = {**(VAR_VALUES if vars_ is None else vars_),
                 "CLAUDE_CODE_SHA256": sha or binary_sha,
                 "WIF_REFRESH_SECONDS": refresh_seconds, "WIF_REFRESH_MAX": refresh_max}
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
        spent=spent)


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


def test_the_regression_tier_signs_the_judge_in_and_keeps_the_token_fresh(run_box):
    r = run_box(tier="regression")
    assert r.status == 0, r.output
    # One token for the judge preflight, a fresh one after it; no Claude Code.
    assert r.urls == [OIDC, OIDC]
    assert r.published == ""
    assert r.uv_calls == ["run bin/judge_preflight.py --config behavioral_config.yaml "
                          f"--expect-source {PREFLIGHT_SOURCE}"]
    assert f"answered through {PREFLIGHT_SOURCE}" in r.output
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
    # The preflight spent the first token; the file holds the unspent second one.
    assert [JWT_RE.fullmatch(t).group(1) for t in _spent(r)] == ["0001"]
    assert JWT_RE.fullmatch(jwt.read_text()).group(1) == "0002"
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
    assert r.urls[:3] == [OIDC, OIDC, f"https://downloads.claude.ai/claude-code-releases/"
                                      f"{version}/linux-x64/claude"]
    assert r.uv_calls == ["run bin/judge_preflight.py --config config.yaml "
                          f"--expect-source {PREFLIGHT_SOURCE}"]
    settings = json.loads((r.home / ".claude" / "settings.json").read_text())
    assert settings == {"model": "claude-haiku-5-5",
                        "env": {"DISABLE_AUTOUPDATER": "1", "DISABLE_UPDATES": "1"}}
    # The judge and Claude Code each exchanged a different token, and the step
    # waited for a rotation, so the file now holds one nobody has spent.
    spent = _spent(r)
    assert len(spent) == 2 and len(set(spent)) == 2
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


def test_a_judge_whose_preflight_fails_stops_the_tier(run_box):
    r = run_box(tier="regression", judge_fails=True)
    _never_signed_in(r)
    errors = _error_lines(r.output)
    assert any("judge preflight failed" in ln and "HTTP 404" in ln for ln in errors), r.output


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
    # The first two fetches run in the step itself; every later one is the refresher's.
    assert len(envs) >= 4 and envs[2:] == ["clean"] * len(envs[2:]), envs


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


# --- behaviour: the step that stops the refresher -------------------------------

def _run_stop_step(stop_step, runner_temp: Path, tier: str = "regression"):
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
    assert any("1 identity-token refreshes failed during the regression tier" in ln
               and "judge" in ln for ln in errors), output
    assert "returned error: 503" in output


def test_the_stop_step_passes_when_no_refresher_started(stop_step, tmp_path):
    status, output = _run_stop_step(stop_step, tmp_path)
    assert status == 0, output
    assert "No token refresher was started" in output


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
