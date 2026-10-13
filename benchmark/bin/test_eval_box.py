#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7"]
# ///
"""Tests for the capability tier's Claude Code sign-in in `.github/workflows/eval-box.yml`.

The coding-harness tasks (suites/capability/harness.yaml) need a vendor CLI on the
eval daemon's PATH at boot, because tool advertisement is a boot snapshot, and a
GitHub-hosted runner ships none. Without one the runner holds those tasks out as
NOT EVALUATED and the release gate is red every week for an environment gap. So the
capability tier installs a pinned, checksum-verified Claude Code binary, pins its
model, and signs it in through Workload Identity Federation (an `oidc_federation`
profile fed by this job's GitHub OIDC token, kept fresh by a background loop)
before the daemon boots. No API key exists on the box.

A signed-out CLI is worse than a missing one: the daemon advertises
`claude_code_run`, every delegated run dies on auth, and the tasks score 0.00 as a
candidate failure. So these tests hold the step to failing loudly instead. The
structural group reads the workflows; the behavioural group runs the step's own
shell against a stub `curl` (release download and OIDC endpoint) and a stub Claude
Code binary. No network, no real credential, no spend.

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
CAPABILITY_TIMEOUT_MINUTES = 180


@pytest.fixture(scope="module")
def workflow():
    return yaml.safe_load(EVAL_BOX.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def steps(workflow):
    return workflow["jobs"]["box"]["steps"]


@pytest.fixture(scope="module")
def claude_step(steps):
    """The one step that installs and signs in Claude Code."""
    found = [s for s in steps if "oidc_federation" in s.get("run", "")]
    assert len(found) == 1, f"expected exactly one Claude Code sign-in step, got {len(found)}"
    return found[0]


@pytest.fixture(scope="module")
def stop_step(steps):
    found = [s for s in steps if s.get("name") == "Stop the Claude Code token refresher"]
    assert len(found) == 1
    return found[0]


def _step_index(steps, needle):
    found = [i for i, s in enumerate(steps) if needle in s.get("run", "")]
    assert len(found) == 1, needle
    return found[0]


# --- structure ----------------------------------------------------------------

def test_the_step_runs_on_the_capability_tier_only(claude_step):
    # The nightly runs this workflow with tier=regression and needs no vendor CLI.
    assert " ".join(str(claude_step["if"]).split()) == "inputs.tier == 'capability'"


def test_the_step_finishes_before_the_daemon_boots(steps, claude_step):
    assert steps.index(claude_step) < _step_index(steps, "capability-daemon.sh up"), \
        "claude_code_run is advertised from a boot snapshot, so claude must be on PATH first"


def test_the_federation_ids_come_from_repository_variables(steps, claude_step):
    env = claude_step["env"]
    for name in (*REQUIRED_VARS, WORKSPACE_VAR):
        assert env[name] == "${{ vars.%s }}" % name
    # Workload Identity Federation needs no secret, and no other step reads the IDs.
    assert "secrets." not in yaml.safe_dump(claude_step)
    others = [s.get("name") for s in steps
              if s is not claude_step and "vars.ANTHROPIC_EVAL_" in yaml.safe_dump(s)]
    assert others == []


def test_no_api_key_path_remains(workflow):
    # Comments may name the key a `bare` run would need; nothing may provide one.
    code = "\n".join(ln for ln in EVAL_BOX.read_text(encoding="utf-8").splitlines()
                     if not ln.lstrip().startswith("#"))
    for name in ("EVAL_CODEX_API_KEY", "EVAL_ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY",
                 "apiKeyHelper"):
        assert name not in code, name
    # PyYAML reads the bare key `on` as the boolean True.
    declared = workflow[True]["workflow_call"]["secrets"]
    assert not any("CODEX" in name or "ANTHROPIC" in name for name in declared)


def test_only_the_capability_caller_grants_the_id_token_permission(workflow):
    # The box job declares no permissions, so it inherits its caller's: only the
    # capability tier signs in through WIF, and the other tiers, the dangerous one
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
        if tier == "capability":
            assert permissions == {"contents": "read", "id-token": "write"}, (name, job_id)
        else:
            assert "id-token" not in (permissions or {}), (name, job_id)


def test_only_the_sign_in_step_requests_an_oidc_token(steps, claude_step):
    boot = steps[_step_index(steps, "capability-daemon.sh up")]
    for step in steps:
        if step is claude_step or step is boot:
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


def test_the_refresher_outlasts_the_tier_and_stops_after_the_daemon(workflow, steps,
                                                                    claude_step, stop_step):
    env = claude_step["env"]
    seconds, rounds = int(env["WIF_REFRESH_SECONDS"]), int(env["WIF_REFRESH_MAX"])
    # GitHub's OIDC tokens live about five minutes; a minute keeps the file ahead.
    assert seconds == 60
    timeout = str(workflow["jobs"]["box"]["timeout-minutes"])
    assert f"inputs.tier == 'capability' && {CAPABILITY_TIMEOUT_MINUTES}" in timeout
    assert seconds * rounds >= CAPABILITY_TIMEOUT_MINUTES * 60
    assert " ".join(str(stop_step["if"]).split()) == \
        "${{ always() && inputs.tier == 'capability' }}"
    assert steps.index(stop_step) > _step_index(steps, "capability-daemon.sh down")


def test_these_tests_run_in_the_tests_loop():
    # ci.yml runs `make -C benchmark tests`; a file missing from its loop never runs.
    makefile = (HERE.parent / "Makefile").read_text(encoding="utf-8")
    loop = [ln for ln in makefile.splitlines() if "for t in" in ln]
    assert any("eval_box" in ln.split() for ln in loop)


# --- behaviour: the step's own shell against stubs ------------------------------

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
# Exchanges the profile's identity token (it must be a whole JWT) and answers on
# the model the settings file pins, unless a test overrides what was used.
CALL_TEMPLATE = """\
token=$(jq -r '.authentication.identity_token.path' "$config/configs/$name.json")
    if ! grep -Eqx '[A-Za-z0-9_-]+[.][A-Za-z0-9_-]+[.][A-Za-z0-9_-]+' "$token"; then
      echo "no identity token" >&2; exit 1
    fi
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
out=""; header=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H) header="$2"; shift 2 ;;
    --retry|--max-time) shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
echo "$url" >> "$STUB_CURL_LOG"
case "$url" in
  "$STUB_OIDC_URL"*)
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

UNAME_STUB = """#!/bin/sh
[ "$1" = "-m" ] && { echo "$STUB_ARCH"; exit 0; }
exit 64
"""


def _stub(bin_dir: Path, name: str, body: str) -> None:
    path = bin_dir / name
    path.write_text(body)
    path.chmod(0o755)


def _claude_binary(path: Path, *, auth=AUTH_FROM_PROFILE, call=None, used='"$model"',
                   key_source="none") -> str:
    """The stub release binary; returns its sha256."""
    call = call or CALL_TEMPLATE % {"used": used, "key_source": key_source}
    path.write_text(CLAUDE_STUB % {"auth": auth, "call": call})
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _run_step(step, root: Path, *, binary=None, sha=None, arch="x86_64", vars_=None,
              oidc=True, oidc_fails=False, oidc_slow="", refresh_seconds="30",
              refresh_max="200"):
    """Execute the step's shell the way the runner would."""
    root.mkdir()
    stub_bin, home, runner_temp = root / "stubbin", root / "home", root / "runner_temp"
    for d in (stub_bin, home, runner_temp):
        d.mkdir()
    _stub(stub_bin, "curl", CURL_STUB)
    _stub(stub_bin, "uname", UNAME_STUB)
    binary_path = root / "claude-release"
    binary_sha = _claude_binary(binary_path, **(binary or {}))
    github_path, curl_log = root / "github_path", root / "curl.log"
    github_path.write_text("")
    oidc_fail = root / "oidc-fail"
    if oidc_fails:
        oidc_fail.write_text("")
    env = {"PATH": f"{stub_bin}{os.pathsep}{os.environ.get('PATH', '')}",
           "HOME": str(home), "RUNNER_TEMP": str(runner_temp),
           "GITHUB_PATH": str(github_path), "STUB_BINARY": str(binary_path),
           "STUB_CURL_LOG": str(curl_log), "STUB_ARCH": arch,
           "STUB_OIDC_URL": OIDC_URL, "STUB_OIDC_REQUEST_TOKEN": REQUEST_TOKEN,
           "STUB_OIDC_COUNT": str(root / "oidc-count"), "STUB_OIDC_FAIL": str(oidc_fail),
           "STUB_OIDC_SLOW": oidc_slow, "STUB_JWT_STEM": JWT_STEM,
           # The step's own env, with the values a test cannot take from it.
           **{k: str(v) for k, v in step["env"].items()},
           **(VAR_VALUES if vars_ is None else vars_),
           "CLAUDE_CODE_SHA256": sha or binary_sha,
           "WIF_REFRESH_SECONDS": refresh_seconds, "WIF_REFRESH_MAX": refresh_max}
    if oidc:
        env |= {"ACTIONS_ID_TOKEN_REQUEST_URL": OIDC_URL,
                "ACTIONS_ID_TOKEN_REQUEST_TOKEN": REQUEST_TOKEN}
    p = subprocess.run(["bash", "-c", step["run"]], cwd=str(root), env=env,
                       capture_output=True, text=True, timeout=60)
    return SimpleNamespace(
        status=p.returncode, output=p.stdout + p.stderr,
        published=github_path.read_text(), home=home, runner_temp=runner_temp,
        urls=curl_log.read_text().split() if curl_log.exists() else [],
        wif_dir=runner_temp / "anthropic-wif", oidc_fail=oidc_fail)


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
def run_step(claude_step, tmp_path):
    """Runs the step; stops every refresher a run started when the test ends."""
    started: list[Path] = []

    def run(**kwargs):
        result = _run_step(claude_step, tmp_path / f"run{len(started)}", **kwargs)
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


def test_a_signed_in_claude_is_put_on_the_daemons_path(run_step, claude_step):
    r = run_step()
    assert r.status == 0, r.output
    version = claude_step["env"]["CLAUDE_CODE_VERSION"]
    install_dir = r.runner_temp / f"claude-code-{version}" / "bin"
    assert r.published == f"{install_dir}\n"
    oidc = f"{OIDC_URL}&audience={AUDIENCE}"
    # One pinned download; one token for the preflight, a fresh one after it.
    assert r.urls == [f"https://downloads.claude.ai/claude-code-releases/{version}/"
                      "linux-x64/claude", oidc, oidc]
    settings = json.loads((r.home / ".claude" / "settings.json").read_text())
    assert settings == {"model": "claude-haiku-5-5",
                        "env": {"DISABLE_AUTOUPDATER": "1", "DISABLE_UPDATES": "1"}}
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
    # The file holds the token fetched after the preflight spent the first one.
    assert JWT_RE.fullmatch(jwt.read_text()).group(1) == "0002"
    assert _mode(jwt) == 0o600
    assert _mode(r.wif_dir) == 0o700 and _mode(anthropic_dir) == 0o700
    assert (r.wif_dir / "refresher.pid").exists()


def test_an_empty_workspace_variable_leaves_workspace_id_out(run_step):
    r = run_step(vars_={**VAR_VALUES, WORKSPACE_VAR: ""})
    assert r.status == 0, r.output
    profile = r.home / ".config" / "anthropic" / "configs" / "fermix-eval.json"
    assert "workspace_id" not in json.loads(profile.read_text())


def test_no_token_reaches_the_log(run_step):
    r = run_step(refresh_seconds="0.2")
    assert r.status == 0, r.output
    time.sleep(1.0)
    log = (r.wif_dir / "refresher.log").read_text()
    assert "refreshed" in log
    for text in (r.output, log):
        assert JWT_STEM not in text and REQUEST_TOKEN not in text


@pytest.mark.parametrize("name", REQUIRED_VARS)
def test_an_empty_required_variable_fails_before_anything_is_fetched(run_step, name):
    r = run_step(vars_={**VAR_VALUES, name: ""})
    _never_signed_in(r)
    assert any(name in ln for ln in _error_lines(r.output)), r.output
    assert r.urls == []


def test_a_job_without_the_id_token_permission_is_refused(run_step):
    r = run_step(oidc=False)
    _never_signed_in(r)
    assert any("id-token: write" in ln for ln in _error_lines(r.output)), r.output
    assert r.urls == []


def test_a_binary_that_fails_its_checksum_is_never_installed(run_step, claude_step):
    r = run_step(sha="0" * 64)
    _never_signed_in(r)
    assert any("checksum" in ln for ln in _error_lines(r.output)), r.output
    version = claude_step["env"]["CLAUDE_CODE_VERSION"]
    assert not (r.runner_temp / f"claude-code-{version}" / "bin" / "claude").exists()
    assert not any(url.startswith(OIDC_URL) for url in r.urls)


def test_a_failed_first_token_fetch_fails_the_step(run_step):
    r = run_step(oidc_fails=True)
    _never_signed_in(r)
    assert any("OIDC token" in ln for ln in _error_lines(r.output)), r.output
    assert not (r.wif_dir / "github-oidc.jwt").exists()


def test_a_claude_whose_preflight_call_fails_is_never_put_on_path(run_step):
    r = run_step(binary={"call": CALL_FAILS})
    _never_signed_in(r)
    assert any("Token exchange failed" in ln for ln in _error_lines(r.output)), r.output


def test_a_claude_on_the_wrong_model_is_never_put_on_path(run_step):
    r = run_step(binary={"used": "claude-sonnet-5-5"})
    _never_signed_in(r)
    assert any("claude-sonnet-5-5" in ln and "claude-haiku-5-5" in ln
               for ln in _error_lines(r.output)), r.output


def test_a_credential_other_than_the_profile_is_refused(run_step):
    r = run_step(binary={"auth": AUTH_FROM_LOGIN})
    _never_signed_in(r)
    assert any("Login method" in ln for ln in _error_lines(r.output)), r.output


def test_an_api_key_answering_the_call_is_refused(run_step):
    r = run_step(binary={"key_source": "apiKeyHelper"})
    _never_signed_in(r)
    assert any("apiKeyHelper" in ln for ln in _error_lines(r.output)), r.output


def test_the_refresher_keeps_replacing_the_token(run_step):
    r = run_step(refresh_seconds="0.2")
    assert r.status == 0, r.output
    time.sleep(1.2)
    jwt = r.wif_dir / "github-oidc.jwt"
    assert int(JWT_RE.fullmatch(jwt.read_text()).group(1)) > 3
    assert _mode(jwt) == 0o600


def test_the_refresher_never_exposes_a_partial_token(run_step):
    # The endpoint answers in two halves; a reader polling the file while the loop
    # replaces it must only ever see a whole token, never an empty or cut one.
    r = run_step(refresh_seconds="0.05", oidc_slow="0.15")
    assert r.status == 0, r.output
    jwt, seen, deadline = r.wif_dir / "github-oidc.jwt", set(), time.monotonic() + 2.0
    while time.monotonic() < deadline:
        content = jwt.read_text()
        assert JWT_RE.fullmatch(content), repr(content)
        seen.add(content)
        time.sleep(0.005)
    assert len(seen) >= 3, "the loop never replaced the token while it was polled"


def test_the_refresher_stops_at_its_cap(run_step):
    r = run_step(refresh_seconds="0.1", refresh_max="2")
    assert r.status == 0, r.output
    time.sleep(1.0)
    pid = int((r.wif_dir / "refresher.pid").read_text())
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)
    lines = (r.wif_dir / "refresher.log").read_text().splitlines()
    assert sum(ln.endswith(" refreshed") for ln in lines) == 2
    assert lines[-1].endswith("stopped at the cap of 2 refreshes")


def test_a_refresh_failure_is_logged_without_ending_the_loop(run_step):
    r = run_step(refresh_seconds="0.1")
    assert r.status == 0, r.output
    r.oidc_fail.write_text("")
    time.sleep(0.6)
    r.oidc_fail.unlink()
    time.sleep(0.6)
    log = (r.wif_dir / "refresher.log").read_text()
    assert " refresh FAILED" in log and log.rstrip().endswith(" refreshed")


def test_a_runner_the_pinned_binary_does_not_fit_is_refused(run_step):
    r = run_step(arch="aarch64")
    _never_signed_in(r)
    assert _error_lines(r.output), r.output
    assert r.urls == []


# --- behaviour: the step that stops the refresher -------------------------------

def _run_stop_step(stop_step, runner_temp: Path):
    p = subprocess.run(["bash", "-c", stop_step["run"]], env={
        "PATH": os.environ.get("PATH", ""), "RUNNER_TEMP": str(runner_temp)},
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
    assert any("1 identity-token refreshes failed" in ln for ln in _error_lines(output)), output
    assert "returned error: 503" in output


def test_the_stop_step_passes_when_no_refresher_started(stop_step, tmp_path):
    status, output = _run_stop_step(stop_step, tmp_path)
    assert status == 0, output
    assert "No token refresher was started" in output


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
