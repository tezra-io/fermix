"""Paired agentic-uplift analysis.

Uplift = TaskSuccess(model + Fermix tools) − TaskSuccess(same model, baseline) on
the SAME tasks, same scorer (EVAL_CAPABILITY_SCORING.md §0/§4). The baseline arm is
the raw model with no Fermix scaffold (bin/run_baseline.py) — or a tools-disabled
Fermix daemon. Because both arms run the same task set, this is a PAIRED design:
we report McNemar's exact test on the discordant pairs and a CI on the difference
of correlated proportions — far tighter and more honest than two independent error
bars.

Pure and dependency-free (exact McNemar via the binomial, no scipy). NOT a place
for the raw subtraction of a Tier-0 lm-eval score — that's a different task set and
metric (§0); this only compares matched per-task outcomes.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass

_Z95 = 1.959963984540054
# Both arms round mean_success to 4 dp before storing it, so an exact fractional bar
# (majority_threshold(7) = 4/7 = 0.571428…) is a hair ABOVE the stored 0.5714 that
# cleared it — a true majority binarized as a fail at trial counts 7, 12, 14, 15, 17,
# 19 and 21. Half a rounding unit of slack restores the intended comparison; the gap
# between two achievable means is 1/n, three orders of magnitude wider, so nothing
# that should fail slips through.
_STORED_SCORE_TOLERANCE = 5e-5


@dataclass
class UpliftResult:
    n: int                          # paired tasks (shared by both arms)
    fermix_pass_rate: float
    baseline_pass_rate: float
    uplift: float                   # fermix_pass_rate - baseline_pass_rate (pp as fraction)
    discordant_fermix_only: int     # b: fermix passed, baseline failed
    discordant_baseline_only: int   # c: fermix failed, baseline passed
    p_value: float                  # McNemar exact (two-sided)
    ci_low: float
    ci_high: float


def mcnemar_exact(b: int, c: int) -> float:
    """Two-sided exact McNemar p-value from the discordant counts.

    Under H0 each discordant pair is a fair coin, so the count b ~ Binomial(b+c,
    0.5); the two-sided p is 2·P(X ≤ min(b,c)), capped at 1. Exact (no normal
    approx, no continuity fudge, no scipy) — correct for small samples where the
    chi-square approximation is unreliable."""
    if b < 0 or c < 0:
        raise ValueError(f"discordant counts must be >= 0, got b={b} c={c}")
    n = b + c
    if n == 0:
        return 1.0
    k = min(b, c)
    tail = sum(math.comb(n, i) for i in range(k + 1)) * (0.5 ** n)
    return min(1.0, 2.0 * tail)


def paired_uplift(fermix: dict[str, float], baseline: dict[str, float],
                  threshold: float) -> UpliftResult:
    """Compare two arms on their SHARED tasks. Each arm maps task_id -> success
    score (0..1, e.g. a task's mean_success); a task 'passes' an arm when its score
    >= threshold. Raises if the arms share no tasks (a misaligned comparison)."""
    if not 0 < threshold <= 1:
        raise ValueError(f"threshold must be in (0, 1], got {threshold}")
    shared = sorted(set(fermix) & set(baseline))
    if not shared:
        raise ValueError("the two arms share no task ids — nothing to pair")

    bar = threshold - _STORED_SCORE_TOLERANCE
    f_pass = {t: fermix[t] >= bar for t in shared}
    b_pass = {t: baseline[t] >= bar for t in shared}
    n = len(shared)
    # 2x2 paired table: a=both pass, b=fermix-only, c=baseline-only, d=both fail.
    a = sum(1 for t in shared if f_pass[t] and b_pass[t])
    b_only = sum(1 for t in shared if f_pass[t] and not b_pass[t])
    c_only = sum(1 for t in shared if b_pass[t] and not f_pass[t])
    d = n - a - b_only - c_only
    f_rate = (a + b_only) / n
    b_rate = (a + c_only) / n

    p = mcnemar_exact(b_only, c_only)
    lo, hi = _newcombe_paired_ci(a, b_only, c_only, d)
    return UpliftResult(n=n, fermix_pass_rate=f_rate, baseline_pass_rate=b_rate,
                        uplift=f_rate - b_rate, discordant_fermix_only=b_only,
                        discordant_baseline_only=c_only, p_value=p, ci_low=lo, ci_high=hi)


def _wilson(k: int, n: int, z: float) -> tuple[float, float]:
    """Wilson score interval for a single proportion k/n. Non-degenerate even at
    k=0 or k=n (unlike Wald), which is why the paired interval below doesn't
    collapse to a zero-width CI at the boundary."""
    if n == 0:
        return 0.0, 1.0
    p = k / n
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    half = (z / denom) * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return max(0.0, center - half), min(1.0, center + half)


def _newcombe_paired_ci(a: int, b: int, c: int, d: int) -> tuple[float, float]:
    """95% CI on the difference of paired proportions p1−p2 via Newcombe's (1998)
    score-based MOVER method (his method 10): square-and-add Wilson intervals for
    each marginal proportion with a correlation correction. Unlike the Wald
    interval it never collapses at the boundary (b=10,c=0 → a real width, not
    [δ,δ]) and tracks the exact test far better in the small-discordant regime this
    benchmark runs in."""
    n = a + b + c + d
    if n == 0:
        return -1.0, 1.0
    p1, p2 = (a + b) / n, (a + c) / n
    delta = p1 - p2
    l1, u1 = _wilson(a + b, n, _Z95)
    l2, u2 = _wilson(a + c, n, _Z95)
    denom = math.sqrt((a + b) * (c + d) * (a + c) * (b + d))
    phi = (a * d - b * c) / denom if denom > 0 else 0.0
    lo = delta - math.sqrt(max(0.0, (p1 - l1) ** 2 - 2 * phi * (p1 - l1) * (u2 - p2) + (u2 - p2) ** 2))
    hi = delta + math.sqrt(max(0.0, (u1 - p1) ** 2 - 2 * phi * (u1 - p1) * (p2 - l2) + (p2 - l2) ** 2))
    return max(-1.0, lo), min(1.0, hi)


# --- arm compatibility ------------------------------------------------------

def majority_threshold(trials: int) -> float:
    """The pass bar for "strictly more than half of an arm's trials' worth of credit".

    Expressed as a `>=` bar over mean_success so there is one binarization rule in
    this module: with 4 trials the bar is 3/4, so a 2-of-4 tie fails. A bare 0.5 bar
    compared with `>=` called that tie a majority.

    The arms store MEAN success, which keeps partial credit, so this is a bar on mean
    credit and not a strict count of passing trials: under an f1/judge scorer four
    trials each scoring 0.8 clear a 3/4 bar although no trial reached any pass line.
    For a binary scorer (exact/numeric/contains/regex) the two readings coincide."""
    if trials < 1:
        raise ValueError(f"majority_threshold: need at least 1 trial, got {trials}")
    return (trials // 2 + 1) / trials


def arm_trial_counts(payload: dict) -> set[int]:
    """The distinct per-task trial counts this arm recorded. More than one means the
    arm is ragged and has no single sample size to pair on."""
    return {int(t["n"]) for t in payload.get("tasks", {}).values()}


def compare_arms(fermix: dict, baseline: dict) -> list[str]:
    """Every reason these two arms cannot be paired; empty list = they can.

    A paired test assumes matched observations. Intersecting whatever task ids happen
    to overlap, at whatever k and trial count each arm ran, silently reports a
    comparison of two different experiments — so the mismatches are named and the
    caller refuses rather than publishing the intersection."""
    problems = []
    for field in ("k", "threshold"):
        mine, theirs = fermix.get(field), baseline.get(field)
        if mine is None or theirs is None:
            problems.append(f"{field} missing: fermix {mine!r}, baseline {theirs!r} — an arm "
                            f"that did not record its own identity cannot be paired")
        elif mine != theirs:
            problems.append(f"{field} differs: fermix {mine} vs baseline {theirs}")
    problems += _validity_problems(fermix, baseline)
    problems += _trial_count_problems(fermix, baseline)
    problems += _task_set_problems(fermix, baseline)
    return problems


def _validity_problems(fermix: dict, baseline: dict) -> list[str]:
    """An arm that did not measure what it reports cannot support a claim. An arm
    written before `valid` existed did not record the answer, which is not the same as
    recording True — refuse it and make the operator re-run."""
    problems = []
    for name, payload in (("fermix", fermix), ("baseline", baseline)):
        recorded = payload.get("valid")
        if recorded is None:
            problems.append(f"the {name} arm records no measurement validity — re-run it; "
                            "an arm that never said whether it was valid cannot be paired")
        elif recorded is not True:
            problems.append(f"the {name} arm is an INVALID measurement (valid={recorded!r}): "
                            "its per-task numbers are evidence about the harness")
    return problems


def _trial_count_problems(fermix: dict, baseline: dict) -> list[str]:
    f_counts, b_counts = arm_trial_counts(fermix), arm_trial_counts(baseline)
    problems = []
    for arm, counts in (("fermix", f_counts), ("baseline", b_counts)):
        if not counts:
            problems.append(f"the {arm} arm recorded no tasks")
        elif len(counts) > 1:
            problems.append(f"the {arm} arm is ragged: tasks ran {sorted(counts)} trials")
    if f_counts and b_counts and len(f_counts) == 1 == len(b_counts) and f_counts != b_counts:
        problems.append(f"trial count differs: fermix {f_counts.pop()} vs baseline {b_counts.pop()}")
    return problems


def _task_set_problems(fermix: dict, baseline: dict) -> list[str]:
    f_ids, b_ids = set(fermix.get("tasks", {})), set(baseline.get("tasks", {}))
    if f_ids == b_ids:
        return []
    only_f, only_b = sorted(f_ids - b_ids), sorted(b_ids - f_ids)
    return [f"task sets differ — excluded from any pairing: "
            f"fermix-only {only_f or 'none'}; baseline-only {only_b or 'none'}"]


# --- arm results I/O (the shared pairing surface) ---------------------------

def write_arm(path: str, *, arm: str, config_id: str, suite: str, k: int,
              threshold: float, tasks: dict, valid: bool) -> None:
    """Persist one arm's per-task results. `tasks` maps "<suite>/<case>" ->
    {mean_success, pass_hat_k, n}. Both the Fermix arm (run_capability.py) and the
    baseline arm (run_baseline.py) write this identical shape so they pair cleanly.

    `valid` is the arm's own measurement validity and is REQUIRED: a run whose trials
    had no usable evidence still produces per-task numbers, and an uplift claim built
    on them is a claim about the harness. The pairing refuses such an arm."""
    if not isinstance(valid, bool):
        raise TypeError(f"write_arm: valid must be a bool, got {type(valid).__name__}")
    payload = {"arm": arm, "config_id": config_id, "suite": suite,
               "k": k, "threshold": threshold, "valid": valid, "tasks": tasks}
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)


def load_arm(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def tasks_success(payload: dict) -> dict:
    """task_id -> mean_success (0..1), the input paired_uplift expects."""
    return {key: float(v["mean_success"]) for key, v in payload.get("tasks", {}).items()}


def render_md(r: UpliftResult, *, label: str, baseline_label: str, suite: str,
              k: int, trials: int, task_ids: list[str]) -> str:
    """The defensible claim line (§6 marketing discipline) — scope always attached.

    The claim names the ACTUAL paired tasks and each arm's real k/n, because a reader
    cannot otherwise tell whether "on 24 tasks" meant the whole suite or the handful
    that happened to intersect. Significance wording is driven by the EXACT McNemar p
    (the authoritative test), never by whether the CI visually excludes 0; if the
    Newcombe CI and the exact test disagree (possible at tiny samples), that's flagged
    rather than silently contradicting."""
    if r.n != len(task_ids):
        raise ValueError(f"render_md: {r.n} paired tasks but {len(task_ids)} task ids given")
    significant = r.p_value < 0.05
    sig = "significant" if significant else "not significant"
    ci_excludes_zero = r.ci_low > 0 or r.ci_high < 0
    caveat = (" — note: at this sample the CI and exact test mildly disagree; trust the exact p"
              if ci_excludes_zero != significant else "")
    return (
        f"## Agentic uplift — `{label}` vs `{baseline_label}` on suite `{suite}`\n\n"
        f"On {r.n} paired task(s) — both arms ran exactly these, k={k} over {trials} trials "
        f"each, same programmatic scorer: "
        f"**{r.fermix_pass_rate * 100:.1f}% with Fermix vs {r.baseline_pass_rate * 100:.1f}% "
        f"baseline** — uplift **{r.uplift * 100:+.1f}pp** "
        f"(95% CI [{r.ci_low * 100:+.1f}, {r.ci_high * 100:+.1f}]pp, Newcombe), "
        f"McNemar exact p={r.p_value:.4g} ({sig}{caveat}).\n\n"
        f"Discordant pairs: {r.discordant_fermix_only} Fermix-only wins, "
        f"{r.discordant_baseline_only} baseline-only wins.\n\n"
        f"Paired tasks: {', '.join(f'`{t}`' for t in task_ids)}\n"
    )
