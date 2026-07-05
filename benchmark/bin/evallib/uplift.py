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

    f_pass = {t: fermix[t] >= threshold for t in shared}
    b_pass = {t: baseline[t] >= threshold for t in shared}
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


# --- arm results I/O (the shared pairing surface) ---------------------------

def write_arm(path: str, *, arm: str, config_id: str, suite: str, k: int,
              threshold: float, tasks: dict) -> None:
    """Persist one arm's per-task results. `tasks` maps "<suite>/<case>" ->
    {mean_success, pass_hat_k, n}. Both the Fermix arm (run_capability.py) and the
    baseline arm (run_baseline.py) write this identical shape so they pair cleanly."""
    payload = {"arm": arm, "config_id": config_id, "suite": suite,
               "k": k, "threshold": threshold, "tasks": tasks}
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)


def load_arm(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def tasks_success(payload: dict) -> dict:
    """task_id -> mean_success (0..1), the input paired_uplift expects."""
    return {key: float(v["mean_success"]) for key, v in payload.get("tasks", {}).items()}


def render_md(r: UpliftResult, label: str, suite: str, k: int) -> str:
    """The defensible claim line (§6 marketing discipline) — scope always attached.

    Significance wording is driven by the EXACT McNemar p (the authoritative test),
    never by whether the CI visually excludes 0; if the Newcombe CI and the exact
    test disagree (possible at tiny samples), that's flagged rather than silently
    contradicting."""
    significant = r.p_value < 0.05
    sig = "significant" if significant else "not significant"
    ci_excludes_zero = r.ci_low > 0 or r.ci_high < 0
    caveat = (" — note: at this sample the CI and exact test mildly disagree; trust the exact p"
              if ci_excludes_zero != significant else "")
    return (
        f"## Agentic uplift — `{label}` on suite `{suite}`\n\n"
        f"On {r.n} paired tasks (k={k} trials each, programmatic scorer): "
        f"**{r.fermix_pass_rate * 100:.1f}% with Fermix vs {r.baseline_pass_rate * 100:.1f}% raw** "
        f"— uplift **{r.uplift * 100:+.1f}pp** "
        f"(95% CI [{r.ci_low * 100:+.1f}, {r.ci_high * 100:+.1f}]pp, Newcombe), "
        f"McNemar exact p={r.p_value:.4g} ({sig}{caveat}).\n\n"
        f"Discordant pairs: {r.discordant_fermix_only} Fermix-only wins, "
        f"{r.discordant_baseline_only} baseline-only wins.\n"
    )
