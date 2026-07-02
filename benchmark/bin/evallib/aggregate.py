"""Capability aggregation: trials -> per-task stats -> per-config score -> ranking.

Pure and deterministic — no daemon, no Opik, no I/O. Turns a flat list of trial
outcomes into the numbers the capability eval reports (docs/design/
EVAL_CAPABILITY_SCORING.md §4):

  * pass@1   — raw capability (success rate)
  * pass^k   — reliability: ALL k trials pass (tau-bench convention); the honest
               headline for an always-on agent. pass^k < pass@1 is the gap.
  * $/success, p95 latency — efficiency, straight off the traces
  * composite + rank — CAPABILITY-first: success dominates, then pass^k, and
    efficiency only breaks a genuine near-tie (it can never buy back a real
    capability gap)

Safety is a HARD gate: a trial that trips a safety boundary scores 0 regardless of
task success (folded in at `score_trial`, never averaged away).
"""

from __future__ import annotations

import math
from dataclasses import dataclass


@dataclass
class TrialResult:
    task_id: str
    effective_success: float    # raw_success, zeroed on a safety violation
    raw_success: float
    safety_ok: bool
    cost: float
    duration_ms: float
    tokens: int
    tool_calls: int
    status: str
    trace_id: str | None = None


@dataclass
class TaskStats:
    task_id: str
    n_trials: int
    successes: int              # trials clearing `threshold` (after safety zeroing)
    k: int                      # the k used for pass^k (clamped to n_trials)
    pass_at_1: float
    pass_hat_k: float
    mean_success: float         # mean effective_success (keeps partial credit)
    mean_cost: float
    total_cost: float
    total_tokens: int
    p95_latency_ms: float
    mean_tokens: float
    safety_violations: int


@dataclass
class ConfigScore:
    config_id: str
    n_tasks: int
    n_trials: int
    mean_task_success: float    # mean over tasks of each task's mean_success
    mean_pass_hat_k: float      # mean over tasks of pass^k (reliability)
    total_cost: float
    total_tokens: int
    total_successes: int
    cost_per_success: float     # total_cost / total_successes (inf if none)
    tokens_per_success: float   # total_tokens / total_successes (inf if none)
    p95_latency_ms: float       # tail proxy: max over tasks of per-task p95
    safety_violations: int


@dataclass
class RankedConfig:
    config: ConfigScore
    composite: float
    efficiency_norm: float
    rank: int


def score_trial(task_id: str, *, task_success: float, safety_ok: bool, cost: float,
                duration_ms: float, tokens: int, tool_calls: int, status: str,
                trace_id: str | None = None) -> TrialResult:
    """Build one trial's result, applying the safety hard-gate: a safety
    violation zeroes effective success while preserving the raw score for audit."""
    raw = float(task_success)
    eff = 0.0 if not safety_ok else raw
    return TrialResult(task_id=task_id, effective_success=eff, raw_success=raw,
                       safety_ok=bool(safety_ok), cost=float(cost),
                       duration_ms=float(duration_ms), tokens=int(tokens),
                       tool_calls=int(tool_calls), status=status, trace_id=trace_id)


def pass_at_k(n: int, c: int, k: int) -> float:
    """Unbiased P(at least one of k sampled trials passes) = 1 - C(n-c,k)/C(n,k)."""
    _check(n, c, k)
    if c == 0:
        return 0.0
    if n - c < k:
        return 1.0
    return 1.0 - math.comb(n - c, k) / math.comb(n, k)


def pass_hat_k(n: int, c: int, k: int) -> float:
    """Unbiased P(ALL k sampled trials pass) = C(c,k)/C(n,k) (tau-bench reliability)."""
    _check(n, c, k)
    if c < k:
        return 0.0
    return math.comb(c, k) / math.comb(n, k)


def _check(n: int, c: int, k: int) -> None:
    if not (0 <= c <= n) or not (1 <= k <= n):
        raise ValueError(f"bad estimator args: n={n} c={c} k={k} (need 0<=c<=n, 1<=k<=n)")


def aggregate_task(trials: list[TrialResult], k: int, threshold: float) -> TaskStats:
    """Fold k trials of ONE task into stats. A trial 'passes' when its effective
    success >= threshold (binary scorers use 1.0; partial-credit f1/judge can use
    a lower bar). pass^k uses k clamped to the trial count."""
    if not trials:
        raise ValueError("aggregate_task: no trials")
    if not 0 < threshold <= 1:
        # A threshold <= 0 would count safety-zeroed (effective_success == 0)
        # trials as passes, silently defeating the hard safety gate. Fail loud.
        raise ValueError(f"threshold must be in (0, 1], got {threshold}")
    n = len(trials)
    successes = sum(1 for t in trials if t.effective_success >= threshold)
    eff_k = max(1, min(k, n))
    costs = [t.cost for t in trials]
    return TaskStats(
        task_id=trials[0].task_id,
        n_trials=n,
        successes=successes,
        k=eff_k,
        pass_at_1=pass_at_k(n, successes, 1),
        pass_hat_k=pass_hat_k(n, successes, eff_k),
        mean_success=sum(t.effective_success for t in trials) / n,
        mean_cost=sum(costs) / n,
        total_cost=sum(costs),
        total_tokens=sum(t.tokens for t in trials),
        p95_latency_ms=_p95([t.duration_ms for t in trials]),
        mean_tokens=sum(t.tokens for t in trials) / n,
        safety_violations=sum(1 for t in trials if not t.safety_ok),
    )


def aggregate_config(config_id: str, task_stats: list[TaskStats]) -> ConfigScore:
    """Fold every task's stats into one config-level score."""
    if not task_stats:
        raise ValueError("aggregate_config: no task stats")
    n_tasks = len(task_stats)
    n_trials = sum(st.n_trials for st in task_stats)
    total_cost = sum(st.total_cost for st in task_stats)
    total_tokens = sum(st.total_tokens for st in task_stats)
    total_successes = sum(st.successes for st in task_stats)
    return ConfigScore(
        config_id=config_id,
        n_tasks=n_tasks,
        n_trials=n_trials,
        mean_task_success=sum(st.mean_success for st in task_stats) / n_tasks,
        mean_pass_hat_k=sum(st.pass_hat_k for st in task_stats) / n_tasks,
        total_cost=total_cost,
        total_tokens=total_tokens,
        total_successes=total_successes,
        cost_per_success=(total_cost / total_successes) if total_successes else math.inf,
        tokens_per_success=(total_tokens / total_successes) if total_successes else math.inf,
        p95_latency_ms=max(st.p95_latency_ms for st in task_stats),
        safety_violations=sum(st.safety_violations for st in task_stats),
    )


# Efficiency axis for ranking. "tokens" is the DEFAULT because token usage is
# captured for every provider, while Opik self-hosted only auto-prices OpenAI +
# Google — so a "$/success" ranking would read $0 (= maximally efficient) for
# Anthropic/xAI/Mistral/Ollama, which is exactly the comparison we care about.
EFFICIENCY_AXES = ("tokens", "cost")


def rank_configs(configs: list[ConfigScore], axis: str = "tokens") -> list[RankedConfig]:
    """Rank configs CAPABILITY-FIRST: task success is the headline, pass^k
    reliability breaks a success tie, and efficiency only breaks a further tie.
    A more-capable-but-chattier model ALWAYS outranks a cheaper-but-weaker one —
    efficiency can never buy back a real capability gap (the old 0.7·success +
    0.3·efficiency blend let a ~0.43 capability gap be reversed on token count,
    the exact mis-ranking this prevents). Efficiency is normalized against the
    most-efficient config that actually resolved something.

    `axis` selects the efficiency metric: "tokens" (default, provider-neutral) or
    "cost" (only meaningful where Opik priced the trace)."""
    if axis not in EFFICIENCY_AXES:
        raise ValueError(f"unknown efficiency axis {axis!r}; expected one of {EFFICIENCY_AXES}")
    per_success = (lambda c: c.tokens_per_success) if axis == "tokens" else (lambda c: c.cost_per_success)

    positive = [per_success(c) for c in configs if per_success(c) != math.inf and per_success(c) > 0]
    best = min(positive) if positive else None

    ranked: list[RankedConfig] = []
    for c in configs:
        eff = _efficiency_norm(per_success(c), best)
        # Capability-dominant scalar: success is the integer-and-hundredths headline;
        # pass^k and efficiency live in the sub-milli decimals so they order true
        # ties without reversing any success difference we care to resolve.
        composite = c.mean_task_success + c.mean_pass_hat_k * 1e-3 + eff * 1e-6
        ranked.append(RankedConfig(config=c, composite=composite, efficiency_norm=eff, rank=0))

    ranked.sort(key=lambda r: r.composite, reverse=True)
    for i, r in enumerate(ranked, start=1):
        r.rank = i
    return ranked


def _efficiency_norm(per_success: float, best: float | None) -> float:
    """1.0 = most efficient; ->0 as usage/success rises; 0 if nothing resolved
    (per_success == inf) OR there is no positive signal on this axis.

    A per_success of exactly 0 is treated as NO SIGNAL (0.0), not "free=best":
    on the cost axis, $0 almost always means Opik never priced the trace
    (Anthropic/xAI/Mistral/Ollama all read $0), so rewarding it would let an
    unpriced model out-rank a genuinely cheap measured one. On the tokens axis a
    real turn always spends >0 tokens, so this branch is never hit there."""
    if per_success == math.inf or per_success <= 0:
        return 0.0
    if best is None:
        return 1.0
    return min(1.0, best / per_success)


def _p95(values: list[float]) -> float:
    """Nearest-rank 95th percentile (small-n friendly: n=1 -> the value)."""
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = math.ceil(0.95 * len(ordered)) - 1
    return ordered[max(0, min(idx, len(ordered) - 1))]
