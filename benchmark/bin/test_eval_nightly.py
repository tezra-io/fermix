#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7"]
# ///
"""Tests for the unchanged-night skip in `.github/workflows/eval-nightly.yml`.

A scheduled nightly evaluates two things: dev's commit (the box and the macOS smoke
check it out) and main's workflow files (a schedule runs the default branch's
workflows). When neither has changed since a green night in the same ISO week,
the night spends nothing: a first job names both commits and the week in one cache
key and looks it up; every evaluating job runs only when that lookup missed; a
final job saves the key once every tier is green. A manual dispatch always runs.

The `alert` job files an issue for any tier that failed or produced no evidence.
A tier the gate skipped on purpose is not that, so it must file nothing; a tier
that was cancelled, failed, or was skipped for any other reason (the gate itself
failing included) must still file exactly as before.

The job graph is evaluated here as GitHub evaluates it: each job's `if:` through
a small expression evaluator (with the implicit `success() &&` GitHub adds when an
expression names no status function), the gate's own shell against a stub `gh`,
and the alert's own script under node against a stub GitHub client. No network,
no credential, no spend.

Run: `uv run bin/test_eval_nightly.py`."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import pytest
import yaml

HERE = Path(__file__).resolve().parent
NIGHTLY = HERE.parent.parent / ".github" / "workflows" / "eval-nightly.yml"
GATE = "changes"
RECORD = "record-green"
ALERT = "alert"
TIERS = ("regression", "macos-smoke")
# Invented commits in the shape the gate expects.
DEV_SHA = "1f0e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6"
OTHER_DEV_SHA = "2a0e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6"
WORKFLOW_SHA = "9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d"
OTHER_WORKFLOW_SHA = "8f8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d"
REPO = "tezra-io/fermix"
FULL_SHA_PIN = re.compile(r"^[\w.-]+/[\w./-]+@[0-9a-f]{40}$")


@pytest.fixture(scope="module")
def workflow():
    return yaml.safe_load(NIGHTLY.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def jobs(workflow):
    return workflow["jobs"]


def _step(job, step_id):
    found = [s for s in job["steps"] if s.get("id") == step_id]
    assert len(found) == 1, f"expected one step with id {step_id}, got {len(found)}"
    return found[0]


def _needs(job) -> list[str]:
    needs = job.get("needs", [])
    return [needs] if isinstance(needs, str) else list(needs)


# --- a GitHub expression evaluator (the subset these workflows use) -------------

_TOKEN = re.compile(r"\s*(?:(\|\||&&|==|!=|!|\(|\))|'((?:[^']|'')*)'|([A-Za-z_][\w.-]*))")
_STATUS_FUNCTIONS = ("success", "failure", "cancelled", "always")


def _tokens(text: str) -> list[tuple[str, str]]:
    out, pos, text = [], 0, text.strip()
    while pos < len(text):
        match = _TOKEN.match(text, pos)
        assert match and match.end() > pos, f"cannot read expression at: {text[pos:]!r}"
        op, string, name = match.groups()
        out.append(("op", op) if op else ("str", string.replace("''", "'"))
                   if string is not None else ("name", name))
        pos = match.end()
    return out


class _Expr:
    """Recursive descent over: || && == != ! ( ) 'string' true false fn() a.b.c"""

    def __init__(self, text: str, ctx: dict):
        self.toks, self.i, self.ctx = _tokens(text), 0, ctx

    def value(self):
        result = self._or()
        assert self.i == len(self.toks), f"trailing tokens: {self.toks[self.i:]}"
        return result

    def _peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else (None, None)

    def _take(self, kind, value=None):
        tok = self._peek()
        if tok[0] == kind and (value is None or tok[1] == value):
            self.i += 1
            return tok
        return None

    def _or(self):
        left = self._and()
        while self._take("op", "||"):
            right = self._and()
            left = left or right
        return left

    def _and(self):
        left = self._cmp()
        while self._take("op", "&&"):
            right = self._cmp()
            left = left and right
        return left

    def _cmp(self):
        left = self._unary()
        for op in ("==", "!="):
            if self._take("op", op):
                right = self._unary()
                same = _loose_equal(left, right)
                return same if op == "==" else not same
        return left

    def _unary(self):
        if self._take("op", "!"):
            return not self._unary()
        return self._primary()

    def _primary(self):
        if self._take("op", "("):
            inner = self._or()
            assert self._take("op", ")"), "unbalanced parentheses"
            return inner
        tok = self._peek()
        self.i += 1
        if tok[0] == "str":
            return tok[1]
        assert tok[0] == "name", f"unexpected token {tok}"
        if tok[1] in ("true", "false"):
            return tok[1] == "true"
        if self._take("op", "("):
            assert self._take("op", ")"), "only argument-free functions are supported"
            return self.ctx["functions"][tok[1]]()
        value = self.ctx
        for part in tok[1].split("."):
            value = value.get(part) if isinstance(value, dict) else None
        return value


def _loose_equal(left, right) -> bool:
    # GitHub compares strings case-insensitively; a null never equals a string.
    if isinstance(left, str) and isinstance(right, str):
        return left.lower() == right.lower()
    return left == right


def _condition(job) -> str:
    text = str(job.get("if", "success()")).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    text = " ".join(text.split())
    if not any(re.search(rf"\b{fn}\(\)", text) for fn in _STATUS_FUNCTIONS):
        text = f"success() && ({text})"
    return text


def _job_runs(job, needs: dict, *, event: str, run_cancelled: bool) -> bool:
    results = [n["result"] for n in needs.values()]
    ctx = {
        "needs": needs,
        "github": {"event_name": event},
        "functions": {
            "always": lambda: True,
            "cancelled": lambda: run_cancelled,
            "success": lambda: not run_cancelled and all(r == "success" for r in results),
            "failure": lambda: any(r == "failure" for r in results),
        },
    }
    return bool(_Expr(_condition(job), ctx).value())


def _order(jobs) -> list[str]:
    done, order = set(), []
    while len(order) < len(jobs):
        ready = [j for j in jobs if j not in done and set(_needs(jobs[j])) <= done]
        assert ready, "the job graph has a cycle"
        for j in ready:
            done.add(j)
            order.append(j)
    return order


def simulate(jobs, *, outcomes=None, outputs=None, event="schedule", run_cancelled=False):
    """{job: result}. A job whose `if:` holds ends with its scenario outcome
    (default success); one whose `if:` fails is skipped and publishes nothing."""
    outcomes, outputs = outcomes or {}, outputs or {}
    state = {}
    for job_id in _order(jobs):
        needs = {n: state[n] for n in _needs(jobs[job_id])}
        if _job_runs(jobs[job_id], needs, event=event, run_cancelled=run_cancelled):
            result = outcomes.get(job_id, "success")
            published = outputs.get(job_id, {}) if result != "cancelled" else {}
        else:
            result, published = "skipped", {}
        state[job_id] = {"result": result, "outputs": published}
    return state


def _gate_says(changed: bool) -> dict:
    return {GATE: {"changed": "true" if changed else "false", "dev_sha": DEV_SHA,
                   "key": f"eval-nightly-green-dev-{DEV_SHA}"}}


def _green_outputs(changed=True) -> dict:
    return {**_gate_says(changed), "regression": {"exit_code": "0"}}


# --- the alert's own script under node -------------------------------------------

_ALERT_HARNESS = """
const calls = [];
const github = {
  paginate: async () => [],
  rest: { issues: {
    listForRepo: function listForRepo() {},
    createComment: async (a) => { calls.push({op: "comment", ...a}); },
    create: async (a) => { calls.push({op: "create", ...a}); return {data: {number: 101}}; },
    addLabels: async (a) => { calls.push({op: "labels", ...a}); },
  } },
};
const context = {repo: {owner: "tezra-io", repo: "fermix"},
                 serverUrl: "https://github.invalid", runId: 7};
(async () => {
%s
})().then(() => console.log(JSON.stringify(calls)),
          (e) => { console.error(e); process.exit(1); });
"""


def _run_alert_script(alert_job, needs: dict) -> list[dict]:
    node = shutil.which("node")
    assert node, "node is required: the alert job runs its script under actions/github-script"
    script = alert_job["steps"][0]["with"]["script"]
    env = {**os.environ, "NEEDS": json.dumps(needs), "WORKFLOW": "eval-nightly"}
    r = subprocess.run([node, "-e", _ALERT_HARNESS % script], env=env, text=True,
                       capture_output=True, timeout=30)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def issues_filed(jobs, **scenario) -> list[str]:
    """The issue titles the night files (a skipped alert job files none)."""
    state = simulate(jobs, **scenario)
    if state[ALERT]["result"] == "skipped":
        return []
    needs = {n: state[n] for n in _needs(jobs[ALERT])}
    return [c["title"] for c in _run_alert_script(jobs[ALERT], needs) if c["op"] == "create"]


# --- the gate's own shell against a stub gh --------------------------------------

def _run_gate_step(step, tmp_path: Path, *, values: dict, gh_prints: str = DEV_SHA):
    """Run one gate step's `run:` with its env resolved from `values` (keyed by the
    expression text); an expression the test does not know fails the test."""
    stub_dir = tmp_path / "bin"
    stub_dir.mkdir(exist_ok=True)
    gh = stub_dir / "gh"
    gh.write_text("#!/bin/sh\n"
                  f'[ "$*" = "api repos/{REPO}/git/ref/heads/dev --jq .object.sha" ] '
                  '|| { echo "stub gh: unexpected call: $*" >&2; exit 64; }\n'
                  f"printf '%s\\n' '{gh_prints}'\n")
    gh.chmod(0o755)
    out, summary = tmp_path / "output", tmp_path / "summary"
    out.write_text("")
    summary.write_text("")
    env = {"PATH": f"{stub_dir}:{os.environ['PATH']}", "HOME": str(tmp_path),
           "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": str(summary)}
    for name, expr in (step.get("env") or {}).items():
        assert expr in values, f"the test does not know how to resolve {name}: {expr}"
        env[name] = values[expr]
    r = subprocess.run(["bash", "-c", step["run"]], env=env, text=True,
                       capture_output=True, timeout=30)
    published = dict(ln.split("=", 1) for ln in out.read_text().splitlines() if "=" in ln)
    return r, published, summary.read_text()


def _key_values(workflow_sha=WORKFLOW_SHA) -> dict:
    return {"${{ github.token }}": "invented-token", "${{ github.repository }}": REPO,
            "${{ github.workflow_sha }}": workflow_sha}


def _decide(jobs, tmp_path, *, event: str, hit: str):
    step = _step(jobs[GATE], "decide")
    values = {"${{ github.event_name }}": event, "${{ steps.lookup.outputs.cache-hit }}": hit,
              "${{ steps.key.outputs.key }}": "eval-nightly-green-invented"}
    r, published, summary = _run_gate_step(step, tmp_path, values=values)
    assert r.returncode == 0, r.stderr
    return published["changed"], summary


# --- the gate ---------------------------------------------------------------------

def _iso_week() -> str:
    return subprocess.run(["date", "-u", "+%G-W%V"], capture_output=True, text=True,
                          check=True).stdout.strip()


def test_the_key_names_the_dev_commit_the_workflow_commit_and_the_week(jobs, tmp_path):
    step = _step(jobs[GATE], "key")
    before = _iso_week()
    r, published, _ = _run_gate_step(step, tmp_path, values=_key_values())
    weeks = {before, _iso_week()}  # a run that straddles Monday 00:00 UTC
    assert r.returncode == 0, r.stderr
    assert published["dev_sha"] == DEV_SHA
    key = published["key"]
    assert re.fullmatch(r"\d{4}-W\d{2}", before)
    assert DEV_SHA in key and WORKFLOW_SHA in key
    assert any(key.endswith(f"-{week}") for week in weeks)


def test_a_change_to_either_commit_changes_the_key(jobs, tmp_path):
    step = _step(jobs[GATE], "key")
    keys = set()
    for dev, workflow_sha in ((DEV_SHA, WORKFLOW_SHA), (OTHER_DEV_SHA, WORKFLOW_SHA),
                              (DEV_SHA, OTHER_WORKFLOW_SHA)):
        r, published, _ = _run_gate_step(step, tmp_path, values=_key_values(workflow_sha),
                                         gh_prints=dev)
        assert r.returncode == 0, r.stderr
        keys.add(published["key"])
    assert len(keys) == 3


@pytest.mark.parametrize("printed", ["", "dev", "not-a-commit", DEV_SHA[:12]])
def test_a_dev_ref_that_does_not_resolve_to_a_commit_fails_the_gate(jobs, tmp_path, printed):
    r, published, _ = _run_gate_step(_step(jobs[GATE], "key"), tmp_path,
                                     values=_key_values(), gh_prints=printed)
    assert r.returncode != 0
    assert "::error::" in r.stdout
    assert "key" not in published


def test_a_scheduled_night_already_green_this_week_skips(jobs, tmp_path):
    changed, summary = _decide(jobs, tmp_path, event="schedule", hit="true")
    assert changed == "false"
    assert "eval-nightly-green-invented" in summary


@pytest.mark.parametrize("hit", ["", "false"])
def test_a_scheduled_night_without_a_green_record_runs(jobs, tmp_path, hit):
    # actions/cache leaves cache-hit unset on a miss.
    changed, _ = _decide(jobs, tmp_path, event="schedule", hit=hit)
    assert changed == "true"


@pytest.mark.parametrize("hit", ["", "false", "true"])
def test_a_manual_dispatch_always_runs(jobs, tmp_path, hit):
    changed, _ = _decide(jobs, tmp_path, event="workflow_dispatch", hit=hit)
    assert changed == "true"


def test_the_lookup_reads_the_key_without_downloading(jobs):
    lookup = _step(jobs[GATE], "lookup")
    assert lookup["uses"].split("@")[0] == "actions/cache/restore"
    assert lookup["with"]["lookup-only"] is True
    assert lookup["with"]["key"] == "${{ steps.key.outputs.key }}"
    assert "restore-keys" not in lookup["with"], "only an exact key may skip a night"
    outputs = jobs[GATE]["outputs"]
    assert outputs["changed"] == "${{ steps.decide.outputs.changed }}"
    assert outputs["key"] == "${{ steps.key.outputs.key }}"
    assert outputs["dev_sha"] == "${{ steps.key.outputs.dev_sha }}"


def test_the_save_and_the_lookup_name_the_same_entry(jobs):
    # The cache version hashes the path list and the compression method, so a save
    # under another path, or from another runner image, is one the lookup never finds.
    lookup = _step(jobs[GATE], "lookup")
    save = [s for s in jobs[RECORD]["steps"] if str(s.get("uses", "")).startswith("actions/cache/save@")]
    assert len(save) == 1
    save = save[0]
    assert save["with"]["key"] == "${{ needs.changes.outputs.key }}"
    assert save["with"]["path"] == lookup["with"]["path"]
    assert jobs[RECORD]["runs-on"] == jobs[GATE]["runs-on"]
    assert lookup["uses"].split("@")[1] == save["uses"].split("@")[1]


def test_new_actions_are_pinned_to_a_full_commit_sha(jobs):
    for job_id in (GATE, RECORD):
        for step in jobs[job_id]["steps"]:
            if "uses" in step:
                assert FULL_SHA_PIN.match(step["uses"]), step["uses"]


# --- the graph --------------------------------------------------------------------

def test_every_evaluating_job_waits_for_the_gate_and_its_answer(jobs):
    evaluating = [j for j in jobs if j not in (GATE, RECORD, ALERT)]
    assert set(evaluating) == set(TIERS), "a new tier must be added to these tests"
    for job_id in evaluating:
        assert GATE in _needs(jobs[job_id]), job_id
    state = simulate(jobs, outputs=_gate_says(changed=False))
    for job_id in evaluating:
        assert state[job_id]["result"] == "skipped", job_id
    state = simulate(jobs, outputs=_gate_says(changed=True))
    for job_id in evaluating:
        assert state[job_id]["result"] == "success", job_id


def test_a_manual_dispatch_runs_every_tier(jobs, tmp_path):
    changed, _ = _decide(jobs, tmp_path, event="workflow_dispatch", hit="true")
    state = simulate(jobs, outputs=_gate_says(changed == "true"), event="workflow_dispatch")
    for tier in TIERS:
        assert state[tier]["result"] == "success", tier


def test_the_tiers_evaluate_the_commit_the_key_names(jobs):
    # Not `dev` at whatever moment each tier starts: dev can move while the box
    # waits for the eval-box group, and the green record must name what ran.
    assert jobs["regression"]["with"]["ref"] == "${{ needs.changes.outputs.dev_sha }}"
    checkouts = [s for s in jobs["macos-smoke"]["steps"]
                 if str(s.get("uses", "")).startswith("actions/checkout@")]
    assert [s["with"]["ref"] for s in checkouts] == ["${{ needs.changes.outputs.dev_sha }}"]


def test_a_night_is_recorded_green_only_when_every_tier_is_green(jobs):
    assert set(_needs(jobs[RECORD])) == {GATE, *TIERS}
    green = simulate(jobs, outputs=_green_outputs())
    assert green[RECORD]["result"] == "success"
    reds = [
        {"outcomes": {"regression": "failure"}, "outputs": {**_gate_says(True),
                                                            "regression": {"exit_code": "5"}}},
        {"outcomes": {"regression": "cancelled"}, "outputs": _green_outputs()},
        {"outcomes": {"macos-smoke": "failure"}, "outputs": _green_outputs()},
        {"outcomes": {"macos-smoke": "cancelled"}, "outputs": _green_outputs()},
        {"outcomes": {GATE: "failure"}, "outputs": {}},
        {"outputs": _green_outputs(changed=False)},
        # A green job that published no runner code is not a positive signal.
        {"outputs": _gate_says(True)},
        {"outputs": _green_outputs(), "run_cancelled": True},
    ]
    for scenario in reds:
        state = simulate(jobs, **scenario)
        assert state[RECORD]["result"] == "skipped", scenario


# --- the alert --------------------------------------------------------------------

def test_an_unchanged_night_files_nothing(jobs):
    state = simulate(jobs, outputs=_gate_says(changed=False))
    assert state[ALERT]["result"] == "skipped"
    assert issues_filed(jobs, outputs=_gate_says(changed=False)) == []


def test_a_green_night_files_nothing(jobs):
    assert issues_filed(jobs, outputs=_green_outputs()) == []


def test_a_failed_tier_still_files(jobs):
    titles = issues_filed(jobs, outcomes={"regression": "failure"},
                          outputs={**_gate_says(True), "regression": {"exit_code": "4"}})
    assert titles == ["eval-nightly: the regression tier has no valid measurement"]
    titles = issues_filed(jobs, outcomes={"macos-smoke": "failure"}, outputs=_green_outputs())
    assert titles == ["eval-nightly: the macos-smoke tier is failing"]


def test_a_cancelled_tier_still_files(jobs):
    titles = issues_filed(jobs, outcomes={"regression": "cancelled"}, outputs=_green_outputs())
    assert titles == ["eval-nightly: the regression tier produced no evidence"]
    titles = issues_filed(jobs, outcomes={t: "cancelled" for t in TIERS},
                          outputs=_green_outputs(), run_cancelled=True)
    assert titles == [f"eval-nightly: the {t} tier produced no evidence" for t in TIERS]


@pytest.mark.parametrize("gate", ["failure", "cancelled"])
def test_tiers_a_broken_gate_skipped_still_file_and_the_gate_is_no_tier(jobs, gate):
    # The gate failing is not an intentional skip: its tiers produced no evidence.
    titles = issues_filed(jobs, outcomes={GATE: gate}, outputs={})
    assert titles == [f"eval-nightly: the {t} tier produced no evidence" for t in TIERS]


def test_a_skipped_tier_on_a_changed_night_still_files(jobs):
    # Any skip the gate did not decide (here, a tier whose own condition failed)
    # is absent evidence, exactly as before the gate existed.
    needs = {GATE: {"result": "success", "outputs": _gate_says(True)[GATE]},
             "regression": {"result": "skipped", "outputs": {}},
             "macos-smoke": {"result": "success", "outputs": {}}}
    assert _job_runs(jobs[ALERT], needs, event="schedule", run_cancelled=False)
    filed = [c["title"] for c in _run_alert_script(jobs[ALERT], needs) if c["op"] == "create"]
    assert filed == ["eval-nightly: the regression tier produced no evidence"]


def test_the_macos_smoke_runs_the_box_candidate():
    # One nightly, one candidate: the ungraded smoke answers on the model the
    # graded tier measures.
    box = (NIGHTLY.parent / "eval-box.yml").read_text(encoding="utf-8")
    smoke = (HERE.parent / "ci" / "macos_smoke.sh").read_text(encoding="utf-8")
    box_defaults = set(re.findall(r"default: (gpt-[\w.-]+)", box))
    smoke_default = re.findall(r'SMOKE_MODEL="\$\{SMOKE_MODEL:-([\w.-]+)\}"', smoke)
    assert len(box_defaults) == 1 and smoke_default == list(box_defaults)


def test_these_tests_run_in_the_tests_loop():
    # ci.yml runs `make -C benchmark tests`; a file missing from its loop never runs.
    makefile = (HERE.parent / "Makefile").read_text(encoding="utf-8")
    loop = [ln for ln in makefile.splitlines() if "for t in" in ln]
    assert any("eval_nightly" in ln.split() for ln in loop)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
