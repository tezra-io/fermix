"""Render every capability run as one static HTML page.

Three views, one page:
  * Leaderboard: each model's latest full sweep, ranked on the tasks every listed model
    ran, with a task-by-model matrix of success, time and cost underneath.
  * Same task set: the strict comparison. Runs grouped by measurement identity (the
    cohort `leaderboard.cohort_key` defines), ranked only when the task set is pinned.
  * Runs by change: every run, valid or not, grouped by the commit it measured, newest
    first, each expandable to its per-task table, with a compare box for any runs.

The rank is the capability-only composite `aggregate.rank_configs` uses: task success,
pass^k breaking a tie. Time and cost are printed beside every score and never enter it.

Older runs predate two records this page reads. A run without a recorded commit is
placed on the dev commit that was current at its start time, and labelled as inferred.
A run without per-task cost or durations shows "not recorded" there, never zero. A run
that wrote run.json is read from that file and its results.json alone.

Pure apart from `GitHistory.from_repo` and `write`, which do the git and file I/O.
"""

from __future__ import annotations

import bisect
import hashlib
import html
import json
import math
import os
import re
import statistics
import subprocess
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone

from . import aggregate
from .leaderboard import CURRENT_HASH_VERSION, cohort_key

RUN_DIR = re.compile(r"^\d{8}T\d{6}Z$")
HTML_NAME = "leaderboard.html"
# Runs that did not record a commit are placed on this ref's history.
HISTORY_REF = "origin/dev"
# A run that did not record its selection counts as a full sweep from this many tasks.
# Every narrow selection on record (capability-readonly, one suite, a smoke) ran fewer.
LEGACY_FULL_SWEEP_TASKS = 15
# A leader at or above this success leaves no headroom to separate the top models.
SATURATED = 0.95
_REPORT_FIELDS = {
    "config_id": re.compile(r"^- config: `(.+)`$"),
    "tasks_hash": re.compile(r"^- tasks_hash: `([0-9a-f]+)` \(hash v(\d+)\)$"),
    "selection": re.compile(r"^- selection: (.+?) · trials: (\d+) · k: (\d+) · "
                            r"threshold: ([\d.]+)$"),
    "repo": re.compile(r"^- repo: `([0-9a-f]+)` \(uncommitted diff: (.+)\)$"),
    "judge": re.compile(r"^- judge: (.+)$"),
}


# --- reading the run directories ---------------------------------------------------

def load_runs(capability_dir: str, store: dict) -> list[dict]:
    """Every run directory under reports/capability/, oldest first."""
    if not os.path.isdir(capability_dir):
        return []                       # no sweep has run yet: the empty board
    by_run = {}
    for row in store.get("rows", {}).values():
        run_id = (row.get("meta") or {}).get("run_id")
        if run_id:
            by_run[run_id] = row
    runs = []
    for name in sorted(os.listdir(capability_dir)):
        path = os.path.join(capability_dir, name)
        if not (RUN_DIR.match(name) and os.path.isdir(path)):
            continue
        try:
            run = _read_run(path, name, by_run.get(name))
        except (KeyError, TypeError, ValueError) as exc:
            # Name the directory: a bare KeyError from a hand-edited or foreign run
            # file says nothing about which of fifty runs broke the page.
            raise ValueError(f"unreadable run directory {path}: "
                             f"{type(exc).__name__}: {exc}") from exc
        if run is not None:
            runs.append(run)
    return runs


def _read_run(path: str, run_id: str, store_row: dict | None) -> dict | None:
    results, valid = _results_file(path)
    if results is None:
        return None
    recorded = _read_json(os.path.join(path, "run.json"))
    report = _parse_report(os.path.join(path, "report.md"))
    meta = (recorded or {}).get("meta") or (store_row or {}).get("meta") or report["meta"]
    score_row = (recorded or {}).get("score") or (store_row or {}).get("score")
    tasks = _task_rows(results.get("tasks") or {})
    return {
        "run_id": run_id,
        "ts": _run_time(run_id).isoformat(),
        "config_id": results.get("config_id") or meta.get("config_id") or "?",
        "valid": valid,
        "valid_recorded": "valid" in results,
        "problems": (recorded or {}).get("problems") or report["problems"],
        "repo": meta.get("repo"),
        "tasks_hash": meta.get("tasks_hash"),
        "hash_version": meta.get("hash_version"),
        "k": results.get("k"),
        "threshold": results.get("threshold"),
        "selection": meta.get("selection"),
        "judge": meta.get("judge"),
        "score": _score(score_row, tasks),
        "time": _run_time_totals(tasks),
        "tasks": tasks,
    }


def _results_file(path: str) -> tuple[dict | None, bool]:
    valid = _read_json(os.path.join(path, "results.json"))
    if valid is not None:
        return valid, valid.get("valid", True) is True
    invalid = _read_json(os.path.join(path, "results.invalid.json"))
    return invalid, False


def _read_json(path: str) -> dict | None:
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as fh:
        value = json.load(fh)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected a JSON object")
    return value


def _parse_report(path: str) -> dict:
    """The header and invalidity reasons of a report.md, for runs older than run.json."""
    meta, problems = {}, []
    if not os.path.exists(path):
        return {"meta": meta, "problems": problems}
    in_invalid = False
    with open(path, encoding="utf-8") as fh:
        for line in fh.read().splitlines():
            if line.startswith("## "):
                in_invalid = line.strip() == "## MEASUREMENT INVALID"
                continue
            if in_invalid and line.startswith("- "):
                problems.append(line[2:])
                continue
            _parse_report_field(line, meta)
    return {"meta": meta, "problems": problems}


def _parse_report_field(line: str, meta: dict) -> None:
    for name, pattern in _REPORT_FIELDS.items():
        found = pattern.match(line)
        if not found:
            continue
        if name == "tasks_hash":
            meta["tasks_hash"], meta["hash_version"] = found[1], int(found[2])
        elif name == "selection":
            meta["selection"] = found[1]
        elif name == "repo":
            meta["repo"] = {"sha": found[1], "dirty_digest": found[2]}
        else:
            meta[name] = found[1]
        return


def _task_rows(tasks: dict) -> list[dict]:
    rows = []
    for task_id in sorted(tasks):
        t = tasks[task_id]
        durations = [float(ms) for ms in (t.get("durations_ms") or [])]
        rows.append({
            "id": task_id,
            "success": float(t["mean_success"]),
            "pass_hat_k": float(t["pass_hat_k"]),
            "n": int(t["n"]),
            "median_ms": statistics.median(durations) if durations else None,
            "total_ms": sum(durations) if durations else None,
            "p95_ms": _p95(durations),
            "cost_usd": t.get("priced_cost_usd"),
            "tokens": t.get("total_tokens"),
        })
    return rows


def _p95(values: list[float]) -> float | None:
    return aggregate._p95(values) if values else None   # the score's own definition


def _score(row: dict | None, tasks: list[dict]) -> dict:
    """The recorded score when the run wrote one; otherwise the two means the per-task
    results alone determine, with everything else unknown."""
    if row:
        cost, basis = _row_cost(row)
        return {"success": row.get("mean_task_success"), "pass_at_1": row.get("mean_pass_at_1"),
                "pass_hat_k": row.get("mean_pass_hat_k"),
                "ci_lo": row.get("mean_task_success_ci_lo"),
                "ci_hi": row.get("mean_task_success_ci_hi"),
                "safety_violations": row.get("safety_violations"),
                "safety_evaluated": row.get("safety_trials_evaluated"),
                "cost_usd": cost, "cost_basis": basis,
                "successes": row.get("total_successes"), "source": "recorded"}
    return {"success": _mean([t["success"] for t in tasks]), "pass_at_1": None,
            "pass_hat_k": _mean([t["pass_hat_k"] for t in tasks]), "ci_lo": None,
            "ci_hi": None, "safety_violations": None, "safety_evaluated": None,
            "cost_usd": None, "cost_basis": None, "successes": None, "source": "results"}


def _row_cost(row: dict) -> tuple[float | None, str | None]:
    if row.get("priced_cost_usd") is not None:
        return float(row["priced_cost_usd"]), row.get("pricing_basis") or "ceiling"
    if row.get("total_cost"):
        return float(row["total_cost"]), "opik"
    return None, None


def _run_time_totals(tasks: list[dict]) -> dict:
    """Median task time, and the sum of every trial's wall clock (trials run one at a
    time, so the sum is close to the sweep's duration)."""
    medians = [t["median_ms"] for t in tasks if t["median_ms"] is not None]
    if not medians:
        return {"median_task_ms": None, "total_ms": None}
    return {"median_task_ms": statistics.median(medians),
            "total_ms": sum(t["total_ms"] for t in tasks if t["total_ms"] is not None)}


def _mean(values: list[float]) -> float | None:
    return sum(values) / len(values) if values else None


def _run_time(run_id: str) -> datetime:
    return datetime.strptime(run_id, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)


# --- commits -----------------------------------------------------------------------

@dataclass
class GitHistory:
    """The first-parent history of one ref: when each commit landed, and its subject."""
    commits: list[tuple[datetime, str, str]] = field(default_factory=list)  # oldest first

    @classmethod
    def parse(cls, log: str) -> "GitHistory":
        """`git log --first-parent --format=%H%x09%cI%x09%s` output, newest first."""
        commits = []
        for line in log.splitlines():
            sha, when, subject = line.split("\t", 2)
            commits.append((datetime.fromisoformat(when), sha, subject))
        commits.sort()
        return cls(commits)

    @classmethod
    def from_repo(cls, repo_dir: str, ref: str) -> "GitHistory":
        proc = subprocess.run(
            ["git", "-C", repo_dir, "log", "--first-parent", "--format=%H%x09%cI%x09%s", ref],
            capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(f"git log {ref} failed in {repo_dir} (a shallow clone lacks it: "
                               f"git fetch origin dev): {proc.stderr.strip()}")
        return cls.parse(proc.stdout)

    def at(self, when: datetime) -> dict | None:
        """The commit that was the tip of the ref at `when`."""
        index = bisect.bisect_right([c[0] for c in self.commits], when) - 1
        if index < 0:
            return None
        landed, sha, subject = self.commits[index]
        return {"sha": sha, "subject": subject, "date": landed.date().isoformat()}

    def describe(self, sha: str) -> dict | None:
        for landed, full, subject in self.commits:
            if full.startswith(sha):
                return {"sha": full, "subject": subject, "date": landed.date().isoformat()}
        return None


def attach_commits(runs: list[dict], history: GitHistory) -> None:
    """Give every run a `commit`: the recorded one when the run wrote it, else the ref's
    tip at the run's start, marked as inferred."""
    for run in runs:
        repo = run.get("repo") or {}
        if repo.get("sha"):
            found = history.describe(repo["sha"]) or {"sha": repo["sha"], "subject": None,
                                                     "date": None}
            dirty = repo.get("dirty_digest") not in (None, "clean")
            run["commit"] = {**found, "inferred": False, "dirty": dirty}
            continue
        found = history.at(datetime.fromisoformat(run["ts"]))
        run["commit"] = ({**found, "inferred": True, "dirty": False} if found else
                         {"sha": None, "subject": None, "date": None, "inferred": True,
                          "dirty": False})


# --- views -------------------------------------------------------------------------

def _is_model_run(run: dict) -> bool:
    """A model's sweep, not a harness smoke (`cap-smoke`) or a soft/private axis row."""
    config = run["config_id"]
    return "/" in config and ":" not in config


def _is_full_sweep(run: dict) -> bool:
    if run.get("selection"):
        return run["selection"] == "all"
    return len(run["tasks"]) >= LEGACY_FULL_SWEEP_TASKS


def _rank_key(success: float | None, pass_hat_k: float | None, config: str) -> tuple:
    return (-((success or 0.0) + (pass_hat_k or 0.0) * 1e-3), config)


def leaderboard_view(runs: list[dict]) -> dict:
    """Each model's latest valid full sweep, ranked on the tasks all of them ran."""
    latest = {}
    for run in runs:
        if run["valid"] and _is_model_run(run) and _is_full_sweep(run):
            latest[run["config_id"]] = run      # runs are oldest first
    entries = list(latest.values())
    if not entries:
        return {"rows": [], "shared": [], "saturated_tasks": [], "leader": None}
    shared = sorted(set.intersection(*[{t["id"] for t in r["tasks"]} for r in entries]))
    rows = [_leaderboard_row(run, shared) for run in entries]
    rows.sort(key=lambda r: _rank_key(r["success"], r["pass_hat_k"], r["config_id"]))
    _assign_ranks(rows, lambda r: (r["success"], r["pass_hat_k"]))
    saturated = [task for task in shared
                 if all(_task(row["run"], task)["success"] >= 1.0 for row in rows)]
    return {"rows": rows, "shared": shared, "saturated_tasks": saturated,
            "leader": rows[0]["success"] if rows else None}


def _assign_ranks(rows: list[dict], score) -> None:
    """Competition ranking on the composite's two terms: tied rows share a rank and the
    next row skips ahead ("1, 1, 3"), so a tie is never shown as an order."""
    for index, row in enumerate(rows):
        tied = index > 0 and score(rows[index - 1]) == score(row)
        row["rank"] = rows[index - 1]["rank"] if tied else index + 1


def _leaderboard_row(run: dict, shared: list[str]) -> dict:
    picked = [_task(run, task) for task in shared]
    return {"config_id": run["config_id"], "run": run,
            "success": _mean([t["success"] for t in picked]),
            "pass_hat_k": _mean([t["pass_hat_k"] for t in picked])}


def _task(run: dict, task_id: str) -> dict:
    return next(t for t in run["tasks"] if t["id"] == task_id)


def cohort_views(runs: list[dict]) -> list[dict]:
    """Valid model runs grouped by exact measurement identity, newest cohort first.
    Within a cohort, each model's latest run; ranked only when the hash pins the tasks."""
    grouped: dict[str, dict] = {}
    for run in runs:
        if not (run["valid"] and _is_model_run(run)):
            continue
        key, pinned = _cohort_of(run)
        cohort = grouped.setdefault(key, {"key": key, "pinned": pinned, "latest": {},
                                          "n_tasks": len(run["tasks"]), "ts": run["ts"]})
        cohort["latest"][run["config_id"]] = run
        cohort["ts"] = max(cohort["ts"], run["ts"])
    out = []
    for cohort in grouped.values():
        members = sorted(cohort.pop("latest").values(), key=lambda r: _rank_key(
            r["score"]["success"], r["score"]["pass_hat_k"], r["config_id"]))
        cohort["runs"] = members
        cohort["ranked"] = cohort["pinned"] and len(members) > 1
        _assign_ranks(members, lambda r: (r["score"]["success"], r["score"]["pass_hat_k"]))
        out.append(cohort)
    out.sort(key=lambda c: c["ts"], reverse=True)
    return out


def _cohort_of(run: dict) -> tuple[str, bool]:
    if run.get("tasks_hash") and run.get("hash_version") is not None:
        key = cohort_key(run["tasks_hash"], run["hash_version"], run["k"], run["threshold"])
        return key, int(run["hash_version"]) >= CURRENT_HASH_VERSION
    names = "|".join(t["id"] for t in run["tasks"])
    digest = hashlib.sha256(f"{names}|{run['k']}|{run['threshold']}".encode()).hexdigest()
    return f"names:{digest[:12]}", False


def change_groups(runs: list[dict]) -> list[dict]:
    """Runs grouped by the commit they measured, newest group first, newest run first."""
    groups: dict[str, dict] = {}
    for run in runs:
        commit = run.get("commit") or {}
        key = f"{commit.get('sha')}|{commit.get('inferred')}"
        group = groups.setdefault(key, {"commit": commit, "runs": [], "ts": run["ts"]})
        group["runs"].append(run)
        group["ts"] = max(group["ts"], run["ts"])
    out = sorted(groups.values(), key=lambda g: g["ts"], reverse=True)
    for group in out:
        group["runs"].sort(key=lambda r: r["ts"], reverse=True)
    return out


# --- rendering ---------------------------------------------------------------------

_NOT_RECORDED = '<span class="na" title="not recorded by this run">—</span>'
_BASIS = {"ceiling": "list price", "cache_aware": "cache-aware", "opik": "Opik auto-cost"}


def render(runs: list[dict], generated_at: datetime) -> str:
    """The whole page. Every value from a run file is escaped; the compare box reads the
    embedded JSON and writes it with textContent only."""
    board = leaderboard_view(runs)
    body = "".join([
        _intro(board, runs, generated_at),
        '<nav class="tabs" role="tablist">'
        '<button data-tab="leaderboard" aria-selected="true">Leaderboard</button>'
        '<button data-tab="cohorts" aria-selected="false">Same task set</button>'
        '<button data-tab="runs" aria-selected="false">Runs by change</button></nav>',
        f'<section id="leaderboard">{_render_leaderboard(board)}</section>',
        f'<section id="cohorts" hidden>{_render_cohorts(cohort_views(runs))}</section>',
        f'<section id="runs" hidden>{_render_changes(change_groups(runs))}</section>',
    ])
    data = json.dumps(_compare_data(runs), separators=(",", ":"),
                      allow_nan=False).replace("<", "\\u003c")
    return ("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            "<title>Fermix Capability Leaderboard</title><link rel=\"icon\" href=\"data:,\">"
            "<style>" + _CSS + "</style></head>"
            "<body><main>" + body + "</main>"
            "<script type=\"application/json\" id=\"runs-data\">" + data + "</script>"
            "<script>" + _JS + "</script></body></html>")


def _intro(board: dict, runs: list[dict], generated_at: datetime) -> str:
    valid = sum(1 for r in runs if r["valid"])
    return (f'<header><h1>Fermix capability leaderboard</h1>'
            f'<p class="lede">Rank = task success, with pass^k breaking a tie. Time and cost '
            f'are shown beside every score and never change a rank.</p>'
            f'<p class="meta">{len(runs)} runs ({valid} valid) · generated '
            f'{_e(generated_at.strftime("%Y-%m-%d %H:%M UTC"))}</p></header>')


def _render_leaderboard(board: dict) -> str:
    rows = board["rows"]
    if not rows:
        return '<p class="empty">No valid full sweep on record yet.</p>'
    shared, saturated = board["shared"], board["saturated_tasks"]
    notes = [f'<p>{len(rows)} models, each on its latest valid full sweep, ranked on the '
             f'<strong>{len(shared)} tasks</strong> they all ran.</p>']
    if board["leader"] is not None and (board["leader"] >= SATURATED or
                                        len(saturated) * 2 > len(shared)):
        notes.append(f'<p class="warn"><strong>Saturated.</strong> The leader scores '
                     f'{_pct(board["leader"])} and {len(saturated)} of {len(shared)} shared '
                     f'tasks were passed by every model, so this task set cannot tell the top '
                     f'models apart.</p>')
    notes.append('<p class="caveat">Shared tasks keep their names across runs, but their '
                 'wording or checker may have changed between commits. The "Same task set" '
                 'tab compares only identical, pinned task sets.</p>')
    table = _table(
        ["#", "Model", "Success on shared", "pass^k on shared", "On all its tasks", "Run",
         "Commit"],
        ["Median task", "Trial time", "Cost / run", "$ / success"],
        [_leaderboard_cells(row) for row in rows])
    return "".join(notes) + table + _render_matrix(rows, shared, set(saturated))


def _leaderboard_cells(row: dict) -> tuple[list[str], list[str]]:
    run, score = row["run"], row["run"]["score"]
    whole = f'{_pct(score["success"])} <span class="sub">of {len(run["tasks"])}</span>'
    return ([str(row["rank"]), _e(row["config_id"]), _pct(row["success"]),
             _pct(row["pass_hat_k"]), whole, _date(run), _commit_cell(run["commit"])],
            _beside_cells(run))


def _beside_cells(run: dict) -> list[str]:
    score = run["score"]
    per_success = None
    if score["cost_usd"] is not None and score.get("successes"):
        per_success = score["cost_usd"] / score["successes"]
    return [_dur(run["time"]["median_task_ms"]), _dur(run["time"]["total_ms"]),
            _cost(score["cost_usd"], score["cost_basis"]),
            _cost(per_success, score["cost_basis"])]


def _render_matrix(rows: list[dict], shared: list[str], saturated: set[str]) -> str:
    head = "".join(f'<th scope="col">{_e(r["config_id"])}</th>' for r in rows)
    body = []
    for task_id in shared:
        mark = ' <span class="tag">every model passed</span>' if task_id in saturated else ""
        cells = "".join(_matrix_cell(_task(r["run"], task_id)) for r in rows)
        body.append(f'<tr><th scope="row">{_e(task_id)}{mark}</th>{cells}</tr>')
    return ('<h2>Per task: success, median time, cost per trial</h2>'
            '<div class="scroll"><table class="matrix"><thead><tr><th scope="col">Task</th>'
            f'{head}</tr></thead><tbody>{"".join(body)}</tbody></table></div>')


def _matrix_cell(task: dict) -> str:
    known = []
    if task["median_ms"] is not None:
        known.append(_dur(task["median_ms"]))
    if _per_trial(task) is not None:
        known.append(_cost(_per_trial(task), None))
    detail = f'<span class="sub">{" · ".join(known)}</span>' if known else ""
    return f'<td class="{_band(task["success"])}">{_pct(task["success"])}{detail}</td>'


def _render_cohorts(cohorts: list[dict]) -> str:
    if not cohorts:
        return '<p class="empty">No valid model run on record yet.</p>'
    return "".join(_render_cohort(c) for c in cohorts)


def _render_cohort(cohort: dict) -> str:
    if cohort["ranked"]:
        status = "Ranked: every row ran this exact task set."
    elif not cohort["pinned"]:
        status = ("Listed, not ranked: an older run that did not pin its task definitions, "
                  "so equal names are not evidence of equal tasks.")
    else:
        status = "Only one model has run this exact task set, so there is nothing to rank."
    rows = []
    for run in cohort["runs"]:
        score = run["score"]
        rows.append(([str(run["rank"]) if cohort["ranked"] else "·", _e(run["config_id"]),
                      _pct(score["success"]), _pct(score["pass_at_1"]), _ci(score),
                      _pct(score["pass_hat_k"]), _safety(score), _date(run),
                      _commit_cell(run["commit"])], _beside_cells(run)))
    table = _table(["#", "Model", "Success", "pass@1", "95% CI", "pass^k", "Safety", "Run",
                    "Commit"], ["Median task", "Trial time", "Cost / run", "$ / success"], rows)
    return (f'<article class="card"><h2>Task set <code>{_e(cohort["key"])}</code> · '
            f'{cohort["n_tasks"]} tasks</h2><p class="meta">{status}</p>{table}</article>')


def _render_changes(groups: list[dict]) -> str:
    compare = ('<div class="compare"><p>Tick two or more runs, then compare them task by '
               'task.</p><button id="compare-btn" type="button">Compare selected</button>'
               '<div id="compare-out"></div></div>')
    return compare + "".join(_render_group(g) for g in groups)


def _render_group(group: dict) -> str:
    commit = group["commit"]
    badges = []
    if commit.get("inferred"):
        badges.append('<span class="tag" title="the run did not record its commit; this is '
                      'the dev tip when it started">inferred from run time</span>')
    title = (f'<code>{_e((commit.get("sha") or "unknown")[:10])}</code> '
             f'{_e(commit.get("subject") or "")}')
    when = f' <span class="meta">{_e(commit["date"])}</span>' if commit.get("date") else ""
    return (f'<article class="card"><h2>{title}{when} {"".join(badges)}</h2>'
            f'{"".join(_render_run(r) for r in group["runs"])}</article>')


def _render_run(run: dict) -> str:
    score = run["score"]
    status = ('<span class="tag ok-tag">valid</span>' if run["valid"] else
              '<span class="tag warn-tag">invalid: not scored</span>')
    if run["valid"] and not run["valid_recorded"]:
        status = '<span class="tag" title="recorded before validity checks">legacy</span>'
    if (run.get("commit") or {}).get("dirty"):
        status += '<span class="tag warn-tag">uncommitted changes</span>'
    summary = (f'{_e(_date(run))} · <strong>{_e(run["config_id"])}</strong> {status} · '
               f'success {_pct(score["success"])} · pass^k {_pct(score["pass_hat_k"])} · '
               f'{len(run["tasks"])} tasks · median task {_dur(run["time"]["median_task_ms"])}'
               f' · cost {_cost(score["cost_usd"], score["cost_basis"])}')
    problems = "".join(f"<li>{_e(p)}</li>" for p in run["problems"])
    problems = f'<ul class="problems">{problems}</ul>' if problems else ""
    meta = (f'<p class="meta">run {_e(run["run_id"])} · selection '
            f'{_e(run.get("selection") or "not recorded")} · k {_e(run.get("k"))} · judge '
            f'{_e(run.get("judge") or "not recorded")} · task set '
            f'{_e(run.get("tasks_hash") or "not pinned")} · '
            f'<a href="{_e(run["run_id"])}/">files</a></p>')
    return (f'<div class="run"><input type="checkbox" class="cmp" value="{_e(run["run_id"])}"'
            f' aria-label="compare {_e(run["run_id"])}"><details><summary>{summary}</summary>'
            f'{problems}{meta}{_task_table(run["tasks"])}</details></div>')


def _task_table(tasks: list[dict]) -> str:
    rows = [([_e(t["id"]), _pct(t["success"]), _pct(t["pass_hat_k"]), str(t["n"])],
             [_dur(t["median_ms"]), _dur(t["p95_ms"]), _cost(_per_trial(t), None),
              _tokens(t)]) for t in tasks]
    return _table(["Task", "Success", "pass^k", "Trials"],
                  ["Median time", "p95 time", "Cost / trial", "Tokens / trial"], rows)


def _table(score_cols: list[str], beside_cols: list[str],
           rows: list[tuple[list[str], list[str]]]) -> str:
    """A two-block table: the score columns, then the columns reported beside them."""
    groups = (f'<tr class="groups"><th colspan="{len(score_cols)}">Score</th>'
              f'<th colspan="{len(beside_cols)}" class="beside">Beside the score, never '
              f'ranked</th></tr>')
    head = "".join(f'<th scope="col">{_e(c)}</th>' for c in score_cols)
    head += "".join(f'<th scope="col" class="{"beside" if i == 0 else ""}">{_e(c)}</th>'
                    for i, c in enumerate(beside_cols))
    body = []
    for score, beside in rows:
        cells = "".join(f"<td>{c}</td>" for c in score)
        cells += "".join(f'<td class="{"beside" if i == 0 else ""}">{c}</td>'
                         for i, c in enumerate(beside))
        body.append(f"<tr>{cells}</tr>")
    return (f'<div class="scroll"><table><thead>{groups}<tr>{head}</tr></thead>'
            f'<tbody>{"".join(body)}</tbody></table></div>')


def _compare_data(runs: list[dict]) -> list[dict]:
    return [{"run_id": r["run_id"], "config_id": r["config_id"], "date": _date(r),
             "valid": r["valid"], "success": r["score"]["success"],
             "pass_hat_k": r["score"]["pass_hat_k"],
             "tasks": [{"id": t["id"], "success": t["success"], "median_ms": t["median_ms"],
                        "cost_trial": _per_trial(t)} for t in r["tasks"]]} for r in runs]


# --- cell formatting ---------------------------------------------------------------

def _e(value) -> str:
    return html.escape("" if value is None else str(value), quote=True)


def _pct(value: float | None) -> str:
    if value is None:
        return _NOT_RECORDED
    text = f"{value * 100:.1f}".rstrip("0").rstrip(".")
    return f"{text}%"


def _ci(score: dict) -> str:
    if score["ci_lo"] is None or score["ci_hi"] is None:
        return _NOT_RECORDED
    return f'{_pct(score["ci_lo"])}–{_pct(score["ci_hi"])}'


def _safety(score: dict) -> str:
    if not score.get("safety_evaluated"):
        return '<span class="na" title="no safety gate was graded">not evaluated</span>'
    return f'{_e(score["safety_violations"])} / {_e(score["safety_evaluated"])} violations'


def _dur(ms: float | None) -> str:
    if ms is None:
        return _NOT_RECORDED
    seconds = int(round(ms / 1000))
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m {seconds % 60:02d}s"
    return f"{seconds // 3600}h {seconds % 3600 // 60:02d}m"


def _cost(value: float | None, basis: str | None) -> str:
    if value is None:
        return _NOT_RECORDED
    text = f"${value:.2f}" if value >= 0.01 else f"${value:.4f}"
    if basis is None:
        return text
    return f'{text}<span class="sub">{_e(_BASIS.get(basis, basis))}</span>'


def _per_trial(task: dict) -> float | None:
    if task["cost_usd"] is None or not task["n"]:
        return None
    return float(task["cost_usd"]) / task["n"]


def _tokens(task: dict) -> str:
    if task["tokens"] is None or not task["n"]:
        return _NOT_RECORDED
    return f'{int(task["tokens"]) // task["n"]:,}'


def _band(success: float) -> str:
    if success >= 1.0:
        return "s-full"
    return "s-zero" if success <= 0.0 else "s-part"


def _date(run: dict) -> str:
    return run["ts"][:16].replace("T", " ")


def _commit_cell(commit: dict | None) -> str:
    commit = commit or {}
    if not commit.get("sha"):
        return _NOT_RECORDED
    mark = "≈ " if commit.get("inferred") else ""
    title = (commit.get("subject") or "") + (
        " (inferred from run time)" if commit.get("inferred") else "")
    return f'<code title="{_e(title)}">{mark}{_e(commit["sha"][:8])}</code>'


# --- I/O -----------------------------------------------------------------------------

def write_run_record(out_dir: str, meta: dict, score, problems: list[str]) -> None:
    """run.json: the one file this page reads for a run's identity and score. `score` is
    the run's ConfigScore, or None for an invalid run, which has no score."""
    record = {"meta": meta, "score": _finite(asdict(score)) if score is not None else None,
              "problems": list(problems)}
    with open(os.path.join(out_dir, "run.json"), "w", encoding="utf-8") as fh:
        json.dump(record, fh, indent=2, allow_nan=False)


def _finite(value):
    """inf (`*_per_success` when nothing passed) has no JSON form: it is written as null,
    the same way the leaderboard store writes it."""
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if isinstance(value, dict):
        return {k: _finite(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_finite(v) for v in value]
    return value


def write(report_dir: str, store: dict, repo_dir: str, now: datetime,
          ref: str = HISTORY_REF) -> str:
    """Render reports/capability/leaderboard.html from every run on disk."""
    capability_dir = os.path.join(report_dir, "capability")
    runs = load_runs(capability_dir, store)
    attach_commits(runs, GitHistory.from_repo(repo_dir, ref))
    path = os.path.join(capability_dir, HTML_NAME)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(render(runs, now))
    return path


_CSS = """
:root{--bg:#fbfaf8;--fg:#1d1d1f;--muted:#6b6b70;--line:#e3e1dc;--card:#fff;--accent:#2f5d8a;
--full:#e3f1e5;--part:#fbf0d9;--zero:#f8e1df;--warn:#8a4b00;--warnbg:#fff4e0;--ok:#1f6b35}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#141416;--fg:#ececee;
--muted:#9a9aa1;--line:#2c2c31;--card:#1c1c20;--accent:#8db7e0;--full:#1d3524;--part:#3a311c;
--zero:#3d2222;--warn:#f0b35a;--warnbg:#2e2414;--ok:#7fd29a}}
:root[data-theme="dark"]{--bg:#141416;--fg:#ececee;--muted:#9a9aa1;--line:#2c2c31;
--card:#1c1c20;--accent:#8db7e0;--full:#1d3524;--part:#3a311c;--zero:#3d2222;--warn:#f0b35a;
--warnbg:#2e2414;--ok:#7fd29a}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);
font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
main{max-width:1240px;margin:0 auto;padding:24px 16px 64px}
h1{font-size:22px;margin:0 0 4px}h2{font-size:15px;margin:20px 0 8px}
.lede{margin:0 0 4px}.meta,.sub,.na{color:var(--muted)}.meta{font-size:12px;margin:4px 0}
.sub{display:block;font-size:11px}.tabs{display:flex;gap:4px;margin:16px 0;
border-bottom:1px solid var(--line)}.tabs button{background:none;border:0;padding:8px 12px;
font:inherit;color:var(--muted);cursor:pointer;border-bottom:2px solid transparent}
.tabs button[aria-selected="true"]{color:var(--fg);border-bottom-color:var(--accent)}
.scroll{overflow-x:auto}table{border-collapse:collapse;width:100%;margin:8px 0;
font-variant-numeric:tabular-nums}th,td{padding:6px 8px;border-bottom:1px solid var(--line);
text-align:left;vertical-align:top;white-space:nowrap}thead th{font-size:12px;
color:var(--muted);font-weight:600}tr.groups th{font-size:11px;text-transform:uppercase;
letter-spacing:.04em}.beside{border-left:2px solid var(--line)}
.matrix td{min-width:96px}.s-full{background:var(--full)}.s-part{background:var(--part)}
.s-zero{background:var(--zero)}.card{background:var(--card);border:1px solid var(--line);
border-radius:8px;padding:4px 16px 12px;margin:12px 0}.warn{background:var(--warnbg);
color:var(--warn);padding:8px 12px;border-radius:6px}.caveat{color:var(--muted);font-size:12px}
.tag{display:inline-block;font-size:11px;padding:1px 6px;border-radius:9px;
border:1px solid var(--line);color:var(--muted);margin-left:4px;font-weight:400}
.warn-tag{color:var(--warn);border-color:var(--warn)}.ok-tag{color:var(--ok);
border-color:var(--ok)}.run{display:flex;gap:8px;align-items:flex-start;
border-top:1px solid var(--line);padding:6px 0}.run details{flex:1;min-width:0}
summary{cursor:pointer}.problems{color:var(--warn);font-size:12px}
.compare{position:sticky;top:0;background:var(--bg);padding:8px 0;z-index:1;
border-bottom:1px solid var(--line)}.compare p{margin:0 0 6px}
button#compare-btn{font:inherit;padding:4px 10px;border:1px solid var(--line);
border-radius:6px;background:var(--card);color:var(--fg);cursor:pointer}
code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}
a{color:var(--accent)}.empty{color:var(--muted)}
@media (max-width:640px){th,td{padding:4px 6px}main{padding:16px}}
"""

_JS = """
(function(){
const tabs=document.querySelectorAll('.tabs button');
tabs.forEach(b=>b.addEventListener('click',()=>{tabs.forEach(t=>{const on=t===b;
t.setAttribute('aria-selected',on);document.getElementById(t.dataset.tab).hidden=!on;});}));
const runs=JSON.parse(document.getElementById('runs-data').textContent);
const byId=Object.fromEntries(runs.map(r=>[r.run_id,r]));
const pct=v=>v==null?'—':(Math.round(v*1000)/10)+'%';
const dur=ms=>{if(ms==null)return '—';const s=Math.round(ms/1000);
return s<60?s+'s':s<3600?Math.floor(s/60)+'m '+String(s%60).padStart(2,'0')+'s':
Math.floor(s/3600)+'h '+String(Math.floor(s%3600/60)).padStart(2,'0')+'m';};
const usd=v=>v==null?'—':'$'+(v>=0.01?v.toFixed(2):v.toFixed(4));
function cell(tag,text,cls){const c=document.createElement(tag);c.textContent=text;
if(cls)c.className=cls;return c;}
document.getElementById('compare-btn').addEventListener('click',()=>{
const out=document.getElementById('compare-out');out.replaceChildren();
const picked=[...document.querySelectorAll('input.cmp:checked')].map(i=>byId[i.value]);
if(picked.length<2){out.append(cell('p','Tick at least two runs.','meta'));return;}
const ids=[...new Set(picked.flatMap(r=>r.tasks.map(t=>t.id)))].sort();
const table=document.createElement('table');const head=document.createElement('tr');
head.append(cell('th','Task'));picked.forEach(r=>head.append(cell('th',r.config_id+' · '+r.date)));
const total=document.createElement('tr');total.append(cell('th','Success (all its tasks)'));
picked.forEach(r=>total.append(cell('td',pct(r.success)+(r.valid?'':' (invalid)'))));
table.append(head,total);
ids.forEach(id=>{const row=document.createElement('tr');row.append(cell('th',id));
picked.forEach(r=>{const t=r.tasks.find(x=>x.id===id);if(!t){row.append(cell('td','not run','na'));return;}
const band=t.success>=1?'s-full':t.success<=0?'s-zero':'s-part';
const td=cell('td',pct(t.success),band);
const known=[t.median_ms==null?null:dur(t.median_ms),t.cost_trial==null?null:usd(t.cost_trial)].filter(Boolean);
if(known.length)td.append(cell('span',known.join(' · '),'sub'));
row.append(td);});table.append(row);});
const wrap=document.createElement('div');wrap.className='scroll';wrap.append(table);out.append(wrap);});
})();
"""
