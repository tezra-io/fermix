#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7"]
# ///
"""Tests for the capability tier's Codex sign-in in `.github/workflows/eval-box.yml`.

The coding-harness tasks (suites/capability/harness.yaml) need a vendor CLI on the
eval daemon's PATH at boot, because tool advertisement is a boot snapshot, and a
GitHub-hosted runner ships none. Without one the runner holds those tasks out as
NOT EVALUATED and the release gate is red every week for an environment gap. So the
capability tier installs a pinned, checksum-verified Codex package and signs it in
with EVAL_CODEX_API_KEY before the daemon boots.

A signed-out CLI is worse than a missing one: the daemon advertises `codex_run`,
every delegated run dies on auth, and the tasks score 0.00 as a candidate failure.
So these tests hold the step to failing loudly instead. The structural group reads
the workflow; the behavioural group runs the step's own shell against a stub `curl`
and a stub Codex package. No network, no real key, no spend.

Run: `uv run bin/test_eval_box.py`."""
from __future__ import annotations

import hashlib
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile

import pytest
import yaml

HERE = Path(__file__).resolve().parent
WORKFLOW = HERE.parent.parent / ".github" / "workflows" / "eval-box.yml"
SECRET = "EVAL_CODEX_API_KEY"
ASSET = "codex-package-x86_64-unknown-linux-musl.tar.gz"
# An invented key. Real `codex login status` prints a key's first eight characters,
# which GitHub's log masking (whole secret values only) would not hide.
KEY = "sk-invented-eval-key-0000"
KEY_FRAGMENT = KEY[:8]


@pytest.fixture(scope="module")
def workflow():
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def steps(workflow):
    return workflow["jobs"]["box"]["steps"]


@pytest.fixture(scope="module")
def codex_step(steps):
    """The one step that signs the Codex CLI in."""
    found = [s for s in steps if "login --with-api-key" in s.get("run", "")]
    assert len(found) == 1, f"expected exactly one Codex sign-in step, got {len(found)}"
    return found[0]


# --- structure ----------------------------------------------------------------

def test_the_step_runs_on_the_capability_tier_only(codex_step):
    # The nightly runs this workflow with tier=regression and has no Codex secret.
    assert " ".join(str(codex_step["if"]).split()) == "inputs.tier == 'capability'"


def test_the_step_finishes_before_the_daemon_boots(steps, codex_step):
    boot = [i for i, s in enumerate(steps) if "capability-daemon.sh up" in s.get("run", "")]
    assert len(boot) == 1
    assert steps.index(codex_step) < boot[0], \
        "codex_run is advertised from a boot snapshot, so Codex must be on PATH first"


def test_the_key_comes_from_its_own_secret_and_reaches_no_other_step(steps, codex_step):
    assert codex_step["env"][SECRET] == "${{ secrets.%s }}" % SECRET
    others = [s.get("name") for s in steps
              if s is not codex_step and SECRET in yaml.safe_dump(s)]
    assert others == []


def test_the_reusable_workflow_declares_the_secret_optional(workflow):
    # PyYAML reads the bare key `on` as the boolean True.
    secrets = workflow[True]["workflow_call"]["secrets"]
    # Required would make the nightly regression tier, which inherits secrets and
    # never reads this one, depend on it. The step itself refuses an empty value.
    assert secrets[SECRET] == {"required": False}


def test_these_tests_run_in_the_tests_loop():
    # ci.yml runs `make -C benchmark tests`; a file missing from its loop never runs.
    makefile = (HERE.parent / "Makefile").read_text(encoding="utf-8")
    loop = [ln for ln in makefile.splitlines() if "for t in" in ln]
    assert any("eval_box" in ln.split() for ln in loop)


def test_the_package_is_pinned_by_version_and_checksum(codex_step):
    env = codex_step["env"]
    assert re.fullmatch(r"\d+\.\d+\.\d+", str(env["CODEX_VERSION"]))
    assert re.fullmatch(r"[0-9a-f]{64}", str(env["CODEX_PACKAGE_SHA256"]))
    run = codex_step["run"]
    assert "releases/latest" not in run
    assert "releases/download/rust-v$CODEX_VERSION/" in run


# --- behaviour: the step's own shell against stubs ------------------------------

CODEX_STUB = """#!/bin/sh
# Stand-in for the Codex CLI: the calls the step makes.
auth="$HOME/.codex/auth.json"
# The harness spawns codex under env -i with HOME, PATH, TERM and USER only, so a
# probe that can see the step's own environment proves nothing about a run.
probe_env_is_wiped() {
  [ -z "${EVAL_CODEX_API_KEY:-}" ] || { echo "probe ran in the step env"; exit 3; }
}
case "$*" in
  --version) echo "codex-cli 0.0.0-stub" ;;
  "login --with-api-key")
    key=$(cat)
    mkdir -p "$HOME/.codex"
    %(persist)s
    echo "Successfully logged in" ;;
  "login status")
    probe_env_is_wiped
    if [ -s "$auth" ]; then
      echo "Logged in using an API key - $(cut -c1-8 "$auth")***"
      exit 0
    fi
    echo "Not logged in"
    exit 1 ;;
  "sandbox -- /bin/true")
    probe_env_is_wiped
    %(sandbox)s ;;
  *) echo "unexpected codex call: $*" >&2; exit 64 ;;
esac
"""
SANDBOX_DENIED = ('echo "bwrap: No permissions to create a new namespace"; exit 1')

CURL_STUB = """#!/bin/sh
# Serves the stub package for whatever URL is asked, and records the URL.
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    https://*) echo "$1" >> "$STUB_CURL_LOG"; shift ;;
    *) shift ;;
  esac
done
cp "$STUB_PACKAGE" "$out"
"""

UNAME_STUB = """#!/bin/sh
[ "$1" = "-m" ] && { echo "$STUB_ARCH"; exit 0; }
exit 64
"""


def _package(path: Path, *, login_persists: bool, sandbox_works: bool) -> str:
    """A tarball in the release package's layout (`bin/codex` at the root); returns
    its sha256."""
    persist = 'printf "%s" "$key" > "$auth"' if login_persists else ":"
    sandbox = "exit 0" if sandbox_works else SANDBOX_DENIED
    body = (CODEX_STUB % {"persist": persist, "sandbox": sandbox}).encode()
    with tarfile.open(path, "w:gz") as tar:
        info = tarfile.TarInfo("bin/codex")
        info.size = len(body)
        info.mode = 0o755
        tar.addfile(info, io.BytesIO(body))
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _stub(bin_dir: Path, name: str, body: str) -> None:
    path = bin_dir / name
    path.write_text(body)
    path.chmod(0o755)


def run_codex_step(codex_step, tmp_path, *, key=KEY, login_persists=True,
                   sandbox_works=True, sha=None, arch="x86_64"):
    """Execute the step's shell the way the runner would. Returns
    (status, combined output, published PATH lines, the URLs fetched, HOME)."""
    stub_bin = tmp_path / "stubbin"
    stub_bin.mkdir()
    for name, body in (("curl", CURL_STUB), ("uname", UNAME_STUB)):
        _stub(stub_bin, name, body)
    package = tmp_path / "package.tar.gz"
    package_sha = _package(package, login_persists=login_persists,
                           sandbox_works=sandbox_works)
    home, runner_temp = tmp_path / "home", tmp_path / "runner_temp"
    home.mkdir()
    runner_temp.mkdir()
    github_path, curl_log = tmp_path / "github_path", tmp_path / "curl.log"
    github_path.write_text("")
    env = {"PATH": f"{stub_bin}{os.pathsep}{os.environ.get('PATH', '')}",
           "HOME": str(home), "RUNNER_TEMP": str(runner_temp),
           "GITHUB_PATH": str(github_path), "STUB_PACKAGE": str(package),
           "STUB_CURL_LOG": str(curl_log), "STUB_ARCH": arch,
           # The step's own env, with the two values a test cannot take from it.
           **{k: str(v) for k, v in codex_step["env"].items()},
           "CODEX_PACKAGE_SHA256": sha or package_sha, SECRET: key}
    p = subprocess.run(["bash", "-c", codex_step["run"]], cwd=str(tmp_path), env=env,
                       capture_output=True, text=True, timeout=30)
    urls = curl_log.read_text().split() if curl_log.exists() else []
    return p.returncode, p.stdout + p.stderr, github_path.read_text(), urls, home


def _error_lines(output: str) -> list[str]:
    return [ln for ln in output.splitlines() if ln.startswith("::error::")]


def test_a_signed_in_codex_is_put_on_the_daemons_path(codex_step, tmp_path):
    status, output, published, urls, home = run_codex_step(codex_step, tmp_path)
    assert status == 0, output
    version = codex_step["env"]["CODEX_VERSION"]
    assert published == f"{tmp_path / 'runner_temp'}/codex-{version}/bin\n"
    assert urls == [f"https://github.com/openai/codex/releases/download/rust-v{version}/{ASSET}"]
    # On disk where a harness run reads it: the daemon's HOME, no CODEX_HOME.
    assert (home / ".codex" / "auth.json").read_text() == KEY


def test_no_fragment_of_the_key_reaches_the_public_log(codex_step, tmp_path):
    status, output, *_rest = run_codex_step(codex_step, tmp_path)
    assert status == 0, output
    assert KEY_FRAGMENT not in output


def test_an_empty_secret_fails_loudly_before_anything_is_fetched(codex_step, tmp_path):
    status, output, published, urls, _home = run_codex_step(codex_step, tmp_path, key="")
    assert status != 0
    assert any(SECRET in ln for ln in _error_lines(output)), output
    assert urls == [] and published == ""


def test_a_package_that_fails_its_checksum_is_never_installed(codex_step, tmp_path):
    status, output, published, _urls, home = run_codex_step(
        codex_step, tmp_path, sha="0" * 64)
    assert status != 0
    assert any("checksum" in ln for ln in _error_lines(output)), output
    assert published == ""
    assert not (home / ".codex").exists()


def test_a_codex_that_is_not_signed_in_is_never_put_on_path(codex_step, tmp_path):
    # Installed but signed out: the daemon would advertise codex_run and every
    # delegated run would score 0.00 as the candidate's failure.
    status, output, published, *_rest = run_codex_step(
        codex_step, tmp_path, login_persists=False)
    assert status != 0
    assert any("login status" in ln for ln in _error_lines(output)), output
    assert published == ""


def test_a_codex_that_cannot_start_its_sandbox_is_never_put_on_path(codex_step, tmp_path):
    # Signed in but sandbox-less: every command a delegated run makes fails, which
    # scores as the candidate's failure just the same.
    status, output, published, *_rest = run_codex_step(
        codex_step, tmp_path, sandbox_works=False)
    assert status != 0
    assert any("sandbox" in ln and "bwrap" in ln for ln in _error_lines(output)), output
    assert published == ""


def test_a_runner_the_pinned_package_does_not_fit_is_refused(codex_step, tmp_path):
    status, output, published, urls, _home = run_codex_step(
        codex_step, tmp_path, arch="aarch64")
    assert status != 0
    assert _error_lines(output), output
    assert urls == [] and published == ""


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
