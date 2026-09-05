"""Capability aggregation: trials -> per-task stats -> per-config score -> ranking.

Pure and deterministic — no daemon, no Opik, no I/O. Turns a flat list of trial
outcomes into the numbers the capability eval reports
(benchmark/docs/EVAL_CAPABILITY_SCORING.md §4):

  * pass@1   — raw capability (success rate)
  * pass^k   — reliability: ALL k trials pass (tau-bench convention); the honest
               headline for an always-on agent. pass^k < pass@1 is the gap.
  * $/success, p95 latency — efficiency, REPORTED BESIDE the score, never folded
    into it
  * composite + rank — capability ONLY: success dominates, pass^k breaks a success
    tie, and an exact tie falls to config_id so the order is a function of the data

Three quantities are kept apart deliberately, because collapsing them is how a
benchmark starts lying (PERSONAL_ASSISTANT_AND_CHIEF_OF_STAFF_BENCHMARK_REVIEW.md §7):

  * MEASUREMENT VALIDITY — did we observe the episode at all? A trial whose trace
    or evaluator was missing is `valid == False` and counted in `n_invalid`; it is
    evidence about the harness, never evidence about the model.
  * TASK OUTCOME — effective success, partial credit preserved in `mean_success`
    and binarized at `threshold` for pass@1 / pass^k.
  * SAFETY — a hard gate, but only where a gate was actually graded. `safety_ok=None`
    means NOT EVALUATED: it never zeroes a score and never counts toward the
    denominator, so a suite with no safety gates reports "not evaluated" rather
    than a reassuring zero-violation checkmark.

Cost is tri-state for the same reason: an unpriced trace stores `cost=None` with
`cost_known=False`, never $0.00. Opik's auto-cost keys on the MODEL SLUG — not on the
provider, not on the auth mode: gpt-5.4-mini is priced on every span while gpt-5.6-sol,
gpt-5.6-terra and gpt-6-astra are priced on none, and all four are provider=openai;
claude-sonnet-4-6 is priced, claude-opus-4-8 is not. A $0 therefore means "this slug is
missing from Opik's price table", never "this model is free". Where a slug IS priced,
Opik applies published API rates to runs that went out over a subscription/OAuth route,
so even that figure is a counterfactual rather than measured spend.

The per-model rate card that replaces it is applied in the REPORTING layer and arrives
here already priced. This module only carries the result up — the `total_*_tokens` and
`pricing_*` columns, tri-state like everything else — and never writes it onto the
Opik-sourced `cost` columns beside it.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

# Statuses that mean "we could not measure this episode" — either the evidence never
# arrived or the EVALUATOR failed. Both are invalid measurements, regardless of the 0.0
# recorded for them: an evaluator failure is never a model failure. Kept as data so the
# runner, the leaderboard and the release gate all read one list.
INVALID_STATUSES = ("no_trace", "opik_error", "incomplete", "not_running", "crashed",
                    "checker_error")

# How a dollar figure was arrived at, as the reporting layer's rate card reports it.
# Ordered weakest-evidence-first for the rollup (see _weakest_basis):
#   unpriced          — some route has no card entry, so there is NO number to publish
#   not_token_billed  — every route was local/self-hosted: never token-billed at all
#   ceiling           — priced, but some span carried no cache detail, so the total is
#                       an upper bound (list price on tokens that may have been cached)
#   cache_aware       — priced with every span's cache split known
PRICING_BASES = ("unpriced", "not_token_billed", "ceiling", "cache_aware")
# The two that carry an actual dollar figure. The other two are an honest "no number":
# an unpriced route has no rate to apply, a local model was never token-billed.
COSTED_BASES = ("ceiling", "cache_aware")


@dataclass
class TrialResult:
    task_id: str
    effective_success: float    # raw_success, zeroed on a GRADED safety violation
    raw_success: float
    cost: float | None          # None when the provider/trace was never priced
    duration_ms: float
    tokens: int
    tool_calls: int
    status: str
    trace_id: str | None = None
    # What the CLI/evaluator called the failure when `status` had to be normalized
    # (a no-trace capture keeps the CLI's "timeout"/"error" here; a checker error
    # keeps its message). Diagnosis only — never read as the status.
    status_detail: str = ""
    # TRI-STATE, stored once and read through the two named properties below:
    # True = every declared gate passed · False = a graded gate failed · None = no gate
    # was graded (NOT EVALUATED). Keeping None rather than collapsing it to True is the
    # whole point: a truthiness test on this field treats "not evaluated" as not-ok,
    # which is the safe direction, and no reader can mistake it for a clean bill.
    # The DEFAULT is None for the same reason: a construction that forgot to say
    # must not record "every declared gate passed".
    safety_ok: bool | None = None
    cost_known: bool = True
    # --- per-model pricing, all TRI-STATE: None = never reported, never 0. ---
    # The split of this trial's llm-span usage. `total_input_tokens` is the span
    # contract's `prompt_tokens` and keeps its BLENDED semantics (Anthropic folds
    # cache_creation + cache_read into it); the two cache columns ride ALONGSIDE it, so
    # a consumer that wants the uncached remainder subtracts. `total_output_tokens` is
    # `completion_tokens`. Input and output are reported together or not at all; the
    # cache columns are separately optional, because a vendor that reports no cache
    # detail must stay distinguishable from one that reported a cache hit of 0.
    total_input_tokens: int | None = None
    total_output_tokens: int | None = None
    total_cached_input_tokens: int | None = None
    total_cache_write_tokens: int | None = None
    # The rate card's verdict on this trial's spans (one rolled-up PricedUsage).
    # `pricing_basis is None` means pricing was never attempted — distinct from the
    # "unpriced" basis, which means it was attempted and a route had no card entry.
    priced_cost_usd: float | None = None
    pricing_basis: str | None = None          # one of PRICING_BASES
    pricing_card_version: str | None = None   # which rate card produced the figure
    unpriced_routes: list[str] | None = None  # "<provider_route>/<model>" needing an entry
    spans_without_usage: int | None = None    # errored spans: real spend, unrecoverable

    @property
    def valid(self) -> bool:
        """False when the trial's own evidence is missing — an invalid measurement,
        not a model failure. See INVALID_STATUSES."""
        return self.status not in INVALID_STATUSES

    @property
    def safety_evaluated(self) -> bool:
        """Was any safety gate actually graded for this trial? Only these count toward
        the reported denominator."""
        return self.safety_ok is not None

    @property
    def safety_violation(self) -> bool:
        """A graded gate FAILED. An ungraded trial is never a violation — and never a pass."""
        return self.safety_ok is False


@dataclass
class TaskStats:
    task_id: str
    n_trials: int
    successes: int              # trials clearing `threshold` (after safety zeroing)
    k: int                      # the k used for pass^k (REFUSED when k > n_trials)
    pass_at_1: float            # strict: fraction of trials clearing `threshold`
    pass_hat_k: float
    mean_success: float         # mean effective_success (keeps partial credit)
    mean_cost: float
    total_cost: float
    total_tokens: int
    p95_latency_ms: float
    mean_tokens: float
    safety_violations: int
    family: str | None = None       # independent world this task belongs to (bootstrap unit)
    safety_trials_evaluated: int = 0  # denominator: trials where a gate was actually graded
    n_invalid: int = 0              # trials whose evidence was missing (INVALID_STATUSES)
    durations_ms: list[float] = field(default_factory=list)  # trial-level, for a pooled p95
    cost_known: bool = True
    # --- per-model pricing, folded from this task's trials. See _pricing_columns. ---
    total_input_tokens: int | None = None
    total_output_tokens: int | None = None
    total_cached_input_tokens: int | None = None
    total_cache_write_tokens: int | None = None
    priced_cost_usd: float | None = None
    pricing_basis: str | None = None
    pricing_card_version: str | None = None
    unpriced_routes: list[str] | None = None
    spans_without_usage: int | None = None


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
    p95_latency_ms: float       # pooled over trials; see latency_stat
    safety_violations: int
    # 95% percentile-bootstrap CI on mean_task_success. The honest uncertainty band on
    # the headline. None for rows scored before the CI existed (they render "—" and
    # simply predate the signal).
    mean_task_success_ci_lo: float | None = None
    mean_task_success_ci_hi: float | None = None
    # --- v2 columns. All default so a legacy (v1) leaderboard row still loads. ---
    mean_pass_at_1: float | None = None       # STRICT pass@1, not partial credit
    safety_trials_evaluated: int | None = None  # None = pre-v2 row; 0 = nothing graded
    n_invalid_trials: int | None = None
    cost_known: bool | None = None
    latency_stat: str = "max_task_p95"        # "pooled_p95" once trial durations exist
    n_families: int | None = None             # independent worlds behind the CI
    ci_resampled: str | None = None           # "families" | "cases" | None (pre-v2)
    # --- per-model pricing columns. All default, for the same reason as the v2 block
    # above: `leaderboard._config_from_dict` is `ConfigScore(**row)`, which raises on a
    # missing argument, so a row stored before these existed must still load. ---
    total_input_tokens: int | None = None       # blended prompt tokens (cache included)
    total_output_tokens: int | None = None
    total_cached_input_tokens: int | None = None
    total_cache_write_tokens: int | None = None
    priced_cost_usd: float | None = None        # the rate card's figure, NOT Opik's
    pricing_basis: str | None = None            # one of PRICING_BASES; None = not attempted
    pricing_card_version: str | None = None
    unpriced_routes: list[str] | None = None    # routes the operator must add to the card
    spans_without_usage: int | None = None

    @property
    def priced_cost_per_success(self) -> float | None:
        """The rate card's $/success — None when there is no dollar figure to divide
        (unpriced, not token-billed, or pricing never attempted), inf when nothing
        succeeded, mirroring `cost_per_success`.

        A PROPERTY, not a stored column, and deliberately: `leaderboard.upsert`
        serializes this dataclass with `asdict` and its `_sanitize` rewrites inf to
        null, so a stored ratio would reload as a silent None for exactly the configs
        that resolved nothing. Derived live from the two stored totals instead."""
        if self.priced_cost_usd is None:
            return None
        return (self.priced_cost_usd / self.total_successes) if self.total_successes else math.inf


# A row written BEFORE the rate card existed. Its dollars are Opik's auto-cost, which
# is a different accounting from the card's and is named as such wherever the two could
# be read against each other.
OPIK_BASIS = "opik"


def pricing_provenance(config: ConfigScore) -> str:
    """What accounting produced this config's dollars, card version INCLUDED.

    Two rows both reading `ceiling` are still not comparable if one was priced under
    July's rates and the other under today's — the same defect one level down from the
    basis itself, and the stored `pricing_card_version` is the only thing that catches
    it. ONE definition, because two readers act on it: the leaderboard warns when a
    cohort holds more than one of these, and `rank_configs` refuses to normalize the
    cost axis across them. Keyed on different things, the warning and the refusal would
    drift apart."""
    if config.pricing_basis is None:
        return OPIK_BASIS
    if config.pricing_basis not in COSTED_BASES:
        return config.pricing_basis      # no dollar figure, so no card produced it
    return f"{config.pricing_basis}@{config.pricing_card_version}"


@dataclass
class RankedConfig:
    config: ConfigScore
    composite: float
    # None = this axis carries no comparable signal for the whole cohort, so there is
    # no ratio to publish (cost axis only; see _cost_efficiency_column). Rendered "—",
    # the same cell a pre-fix task-set hash already earns.
    efficiency_norm: float | None
    rank: int


def score_trial(task_id: str, *, task_success: float, safety_ok: bool | None, cost: float,
                duration_ms: float, tokens: int, tool_calls: int, status: str,
                trace_id: str | None = None, cost_known: bool = True,
                status_detail: str = "",
                total_input_tokens: int | None = None,
                total_output_tokens: int | None = None,
                total_cached_input_tokens: int | None = None,
                total_cache_write_tokens: int | None = None,
                priced_cost_usd: float | None = None, pricing_basis: str | None = None,
                pricing_card_version: str | None = None,
                unpriced_routes: list[str] | tuple[str, ...] | None = None,
                spans_without_usage: int | None = None) -> TrialResult:
    """Build one trial's result.

    `safety_ok` is TRI-STATE: True = every declared gate passed · False = a graded
    gate failed (hard-gate: effective success is zeroed, raw kept for audit) ·
    None = NO gate was graded, so there is nothing to zero and nothing to credit —
    the trial stays out of the safety denominator and reports "not evaluated".

    `cost_known=False` records an unpriced trace as unknown (cost None), never $0.00.

    The `total_*_tokens` and pricing arguments carry the reporting layer's rate-card
    result for this trial's llm spans. They are OPTIONAL as a group: omitted, the trial
    records "pricing not attempted" (every column None) and nothing downstream invents a
    number. They never touch `cost`/`cost_known`, which stay Opik's own figure.
    """
    if not task_id:
        raise ValueError("score_trial: task_id is required")
    if safety_ok is not None and not isinstance(safety_ok, bool):
        raise ValueError(f"score_trial: safety_ok must be True/False/None, got {safety_ok!r}")
    if not status:
        raise ValueError("score_trial: status is required")
    _check_token_split(total_input_tokens, total_output_tokens,
                       total_cached_input_tokens, total_cache_write_tokens)
    _check_pricing(pricing_basis, priced_cost_usd, pricing_card_version, unpriced_routes,
                   spans_without_usage)
    raw = float(task_success)
    violation = safety_ok is False
    return TrialResult(task_id=task_id, effective_success=0.0 if violation else raw,
                       raw_success=raw, cost=(float(cost) if cost_known else None),
                       duration_ms=float(duration_ms), tokens=int(tokens),
                       tool_calls=int(tool_calls), status=status, trace_id=trace_id,
                       safety_ok=safety_ok, cost_known=bool(cost_known),
                       status_detail=str(status_detail),
                       total_input_tokens=total_input_tokens,
                       total_output_tokens=total_output_tokens,
                       total_cached_input_tokens=total_cached_input_tokens,
                       total_cache_write_tokens=total_cache_write_tokens,
                       priced_cost_usd=priced_cost_usd, pricing_basis=pricing_basis,
                       pricing_card_version=pricing_card_version,
                       unpriced_routes=(None if unpriced_routes is None
                                        else list(unpriced_routes)),
                       spans_without_usage=spans_without_usage)


def _check_token_split(inp: int | None, out: int | None, cached: int | None,
                       cache_write: int | None) -> None:
    """One trial's four token columns. Input and output are reported together or not at
    all — a span either carried usage or it did not — and cache detail with no split to
    subtract it from is a wiring bug, not a partial report."""
    counts = {"total_input_tokens": inp, "total_output_tokens": out,
              "total_cached_input_tokens": cached, "total_cache_write_tokens": cache_write}
    negative = sorted(name for name, v in counts.items() if v is not None and v < 0)
    if negative:
        raise ValueError(f"score_trial: {', '.join(negative)} cannot be negative")
    if (inp is None) != (out is None):
        raise ValueError("score_trial: total_input_tokens and total_output_tokens are "
                         f"reported together or not at all; got input={inp!r} output={out!r}")
    if inp is None and (cached is not None or cache_write is not None):
        raise ValueError("score_trial: cache counts ride ALONGSIDE the token split; there "
                         "is no split here for them to qualify")


def _check_pricing(basis: str | None, cost: float | None, card_version: str | None,
                   routes: list[str] | tuple[str, ...] | None,
                   spans_without_usage: int | None) -> None:
    """One trial's rate-card result. `basis is None` means pricing was never attempted;
    then nothing else may be set, or the row would carry a dollar figure whose
    provenance nobody can state."""
    if basis is None:
        stated = {"priced_cost_usd": cost, "pricing_card_version": card_version,
                  "unpriced_routes": routes, "spans_without_usage": spans_without_usage}
        given = sorted(name for name, v in stated.items() if v is not None)
        if given:
            raise ValueError(f"score_trial: {', '.join(given)} given with no pricing_basis; "
                             f"a priced column with no stated basis cannot be read")
        return
    if basis not in PRICING_BASES:
        raise ValueError(f"score_trial: unknown pricing_basis {basis!r}; "
                         f"expected one of {PRICING_BASES}")
    if not card_version:
        raise ValueError(f"score_trial: pricing_basis {basis!r} needs its pricing_card_version "
                         f"— a price nobody can attribute to a card cannot be re-checked")
    if spans_without_usage is None or spans_without_usage < 0:
        raise ValueError(f"score_trial: pricing_basis {basis!r} needs spans_without_usage "
                         f"(0 when every span reported), got {spans_without_usage!r}")
    _check_basis_agrees(basis, cost, routes)


def _check_basis_agrees(basis: str, cost: float | None,
                        routes: list[str] | tuple[str, ...] | None) -> None:
    """The cost and the route list are DETERMINED by the basis. A disagreement is a bug
    in whatever priced the spans, and carrying it up would publish a number the basis
    itself denies."""
    costed = basis in COSTED_BASES
    if costed and cost is None:
        raise ValueError(f"score_trial: pricing_basis {basis!r} must carry the cost it computed")
    if not costed and cost is not None:
        raise ValueError(f"score_trial: pricing_basis {basis!r} carries no dollar figure, "
                         f"got priced_cost_usd={cost!r}")
    if basis == "unpriced" and not routes:
        raise ValueError("score_trial: an 'unpriced' basis must name the routes missing from "
                         "the card; naming none tells the operator nothing to add")
    if basis != "unpriced" and routes:
        raise ValueError(f"score_trial: unpriced_routes {list(routes)} given with basis "
                         f"{basis!r}; a route with no card entry forces basis 'unpriced'")


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


def bootstrap_ci(values: list[float], *, iters: int = 2000, confidence: float = 0.95,
                 seed: int = 1729) -> tuple[float, float]:
    """Percentile-bootstrap CI for the MEAN of `values`, resampling with replacement.
    Fed the per-task mean-success list, it answers "how much does this config's headline
    depend on which tasks happened to be in the suite" — the between-task variance a bare
    point estimate hides. DETERMINISTIC: a fixed seed makes the interval a reproducible
    function of the inputs (a benchmark number must not wander run to run for identical
    data). A single value yields a degenerate point interval."""
    if not values:
        raise ValueError("bootstrap_ci: no values")
    n = len(values)
    if n == 1:
        return (values[0], values[0])
    rng = random.Random(seed)
    means = sorted(sum(values[rng.randrange(n)] for _ in range(n)) / n for _ in range(iters))
    return _percentile_band(means, confidence)


def bootstrap_ci_clustered(clusters: list[list[float]], *, iters: int = 2000,
                           confidence: float = 0.95, seed: int = 1729) -> tuple[float, float]:
    """Percentile bootstrap resampling CLUSTERS (independent worlds), not cases.

    Four paraphrases of one scenario are not four independent observations; resampling
    them as if they were reports a band far tighter than the evidence supports. Each
    cluster is one family's per-task scores: we resample families with replacement and
    pool the tasks of whichever families were drawn. Deterministic, same seed contract
    as `bootstrap_ci`."""
    if not clusters:
        raise ValueError("bootstrap_ci_clustered: no clusters")
    if any(not c for c in clusters):
        raise ValueError("bootstrap_ci_clustered: every cluster needs at least one value")
    # One cluster is resampled like any other: every draw returns that same family, so
    # the band collapses to (mean, mean). That degenerate band is the honest report —
    # a single world carries no between-world information. Falling back to case-level
    # resampling here produced a wide band from correlated paraphrases while the row
    # still said "families", which is the label lying about its own unit.
    rng = random.Random(seed)
    m = len(clusters)
    means = []
    for _ in range(iters):
        pooled = [v for _ in range(m) for v in clusters[rng.randrange(m)]]
        means.append(sum(pooled) / len(pooled))
    means.sort()
    return _percentile_band(means, confidence)


def _percentile_band(sorted_means: list[float], confidence: float) -> tuple[float, float]:
    iters = len(sorted_means)
    lo = sorted_means[int(math.floor((1 - confidence) / 2 * iters))]
    hi = sorted_means[min(iters - 1, int(math.ceil((1 + confidence) / 2 * iters)) - 1)]
    return (lo, hi)


def aggregate_task(trials: list[TrialResult], k: int, threshold: float,
                   family: str | None = None) -> TaskStats:
    """Fold k trials of ONE task into stats. A trial 'passes' when its effective
    success >= threshold (binary scorers use 1.0; partial-credit f1/judge can use a
    lower bar).

    `k` is REFUSED, not clamped, when it exceeds the trial count: silently reporting a
    pass^3 in a column headed pass^5 is how two incomparable reliability numbers end up
    ranked against each other."""
    if not trials:
        raise ValueError("aggregate_task: no trials")
    if not 0 < threshold <= 1:
        # A threshold <= 0 would count safety-zeroed (effective_success == 0)
        # trials as passes, silently defeating the hard safety gate. Fail loud.
        raise ValueError(f"threshold must be in (0, 1], got {threshold}")
    n = len(trials)
    if not 1 <= k <= n:
        raise ValueError(f"aggregate_task: k={k} needs 1 <= k <= n_trials ({n}); "
                         f"run more trials or publish the smaller k explicitly")
    successes = sum(1 for t in trials if t.effective_success >= threshold)
    priced = [t.cost for t in trials if t.cost is not None]
    durations = [t.duration_ms for t in trials]
    total_cost = sum(priced)
    return TaskStats(
        task_id=trials[0].task_id,
        n_trials=n,
        successes=successes,
        k=k,
        pass_at_1=pass_at_k(n, successes, 1),
        pass_hat_k=pass_hat_k(n, successes, k),
        mean_success=sum(t.effective_success for t in trials) / n,
        mean_cost=total_cost / n,
        total_cost=total_cost,
        total_tokens=sum(t.tokens for t in trials),
        p95_latency_ms=_p95(durations),
        mean_tokens=sum(t.tokens for t in trials) / n,
        safety_violations=sum(1 for t in trials if t.safety_violation),
        family=family,
        safety_trials_evaluated=sum(1 for t in trials if t.safety_evaluated),
        n_invalid=sum(1 for t in trials if not t.valid),
        durations_ms=durations,
        cost_known=all(t.cost_known for t in trials),
        **_pricing_columns(trials),
    )


def aggregate_config(config_id: str, task_stats: list[TaskStats]) -> ConfigScore:
    """Fold every task's stats into one config-level score."""
    if not task_stats:
        raise ValueError("aggregate_config: no task stats")
    if not config_id:
        raise ValueError("aggregate_config: config_id is required")
    n_tasks = len(task_stats)
    total_cost = sum(st.total_cost for st in task_stats)
    total_tokens = sum(st.total_tokens for st in task_stats)
    total_successes = sum(st.successes for st in task_stats)
    (ci_lo, ci_hi), resampled, n_families = _success_ci(task_stats)
    p95, latency_stat = _config_latency(task_stats)
    return ConfigScore(
        config_id=config_id,
        n_tasks=n_tasks,
        n_trials=sum(st.n_trials for st in task_stats),
        mean_task_success=sum(st.mean_success for st in task_stats) / n_tasks,
        mean_pass_hat_k=sum(st.pass_hat_k for st in task_stats) / n_tasks,
        total_cost=total_cost,
        total_tokens=total_tokens,
        total_successes=total_successes,
        cost_per_success=(total_cost / total_successes) if total_successes else math.inf,
        tokens_per_success=(total_tokens / total_successes) if total_successes else math.inf,
        p95_latency_ms=p95,
        safety_violations=sum(st.safety_violations for st in task_stats),
        mean_task_success_ci_lo=ci_lo,
        mean_task_success_ci_hi=ci_hi,
        mean_pass_at_1=sum(st.pass_at_1 for st in task_stats) / n_tasks,
        safety_trials_evaluated=sum(st.safety_trials_evaluated for st in task_stats),
        n_invalid_trials=sum(st.n_invalid for st in task_stats),
        cost_known=all(st.cost_known for st in task_stats),
        latency_stat=latency_stat,
        n_families=n_families,
        ci_resampled=resampled,
        **_pricing_columns(task_stats),
    )


def _pricing_columns(units: list[TrialResult] | list[TaskStats]) -> dict:
    """The per-model-pricing columns, folded IDENTICALLY from a task's trials or from a
    config's tasks — both levels carry these nine names, so one fold serves both. Every
    column stays tri-state: None means "never reported", never 0 and never a partial
    sum dressed up as a total."""
    if not units:
        raise ValueError("_pricing_columns: no units to fold; an empty rollup has no "
                         "total, and summing nothing to 0 would report one")
    cost, basis, card_version, routes, spans_without_usage = _fold_pricing(units)
    return {
        "total_input_tokens": _sum_reported([u.total_input_tokens for u in units]),
        "total_output_tokens": _sum_reported([u.total_output_tokens for u in units]),
        "total_cached_input_tokens": _sum_reported([u.total_cached_input_tokens
                                                    for u in units]),
        "total_cache_write_tokens": _sum_reported([u.total_cache_write_tokens
                                                   for u in units]),
        "priced_cost_usd": cost,
        "pricing_basis": basis,
        "pricing_card_version": card_version,
        "unpriced_routes": routes,
        "spans_without_usage": spans_without_usage,
    }


def _sum_reported(values: list[int | None]) -> int | None:
    """Sum only when EVERY unit reported. One silent gap makes the total unknown: a
    partial sum published under a total's heading is precisely the lie this layer
    exists to refuse."""
    if any(v is None for v in values):
        return None
    return sum(values)


def _fold_pricing(units: list[TrialResult] | list[TaskStats]) -> tuple[
        float | None, str | None, str | None, list[str] | None, int | None]:
    """Roll one level's rate-card results into (cost, basis, card_version, routes,
    spans_without_usage). Returns all-None the moment ANY unit was never priced —
    summing the rest would publish a partial dollar figure as the row's total."""
    bases = [u.pricing_basis for u in units]
    if any(b is None for b in bases):
        return (None, None, None, None, None)
    basis = _weakest_basis(bases)
    cost = (sum(u.priced_cost_usd for u in units if u.priced_cost_usd is not None)
            if basis in COSTED_BASES else None)
    routes = sorted({r for u in units for r in (u.unpriced_routes or [])})
    return (cost, basis, _one_card_version(units), routes,
            _sum_reported([u.spans_without_usage for u in units]))


def _weakest_basis(bases: list[str]) -> str:
    """A rollup reports the WEAKEST evidence inside it: one route missing from the card
    makes the whole figure unavailable, and one span without cache detail makes the
    total an upper bound. "not_token_billed" survives only when EVERY unit was — mixed
    with a metered unit it contributes a genuine $0 and the metered basis governs."""
    if "unpriced" in bases:
        return "unpriced"
    if all(b == "not_token_billed" for b in bases):
        return "not_token_billed"
    return "ceiling" if "ceiling" in bases else "cache_aware"


def _one_card_version(units: list[TrialResult] | list[TaskStats]) -> str | None:
    """Two rate cards cannot be added together. Refuse rather than publish a dollar
    figure that is half July's prices and half today's."""
    versions = {u.pricing_card_version for u in units}
    if len(versions) > 1:
        raise ValueError(f"pricing rollup mixes rate cards {sorted(map(str, versions))}; two "
                         f"price tables cannot be summed into one figure — re-price the run")
    return versions.pop()


def _success_ci(task_stats: list[TaskStats]) -> tuple[tuple[float, float], str, int | None]:
    """The CI on mean task success, resampling the largest INDEPENDENT unit available.

    Families are independent worlds; cases within one family are correlated variants of
    the same world, so resampling them as independent overstates the precision. Falls
    back to case resampling only when the tasks do not all declare a family — and says
    which it did via the returned label, so a reader never has to guess."""
    values = [st.mean_success for st in task_stats]
    if any(st.family is None for st in task_stats):
        return bootstrap_ci(values), "cases", None
    clusters: dict[str, list[float]] = {}
    for st in task_stats:
        clusters.setdefault(st.family, []).append(st.mean_success)
    ordered = [clusters[name] for name in sorted(clusters)]
    return bootstrap_ci_clustered(ordered), "families", len(ordered)


def _config_latency(task_stats: list[TaskStats]) -> tuple[float, str]:
    """Pooled trial-level p95 when the trial durations survived, else the older
    max-of-per-task-p95. The two are different statistics and the label says which
    one this row carries — a max-of-p95 reads like a tail number but tracks the
    single slowest task."""
    pooled = [d for st in task_stats for d in st.durations_ms]
    if all(st.durations_ms for st in task_stats):
        return _p95(pooled), "pooled_p95"
    return max(st.p95_latency_ms for st in task_stats), "max_task_p95"


# Efficiency axis for the DISPLAY column — rank does not read it (see rank_configs).
# "tokens" is the DEFAULT because token usage is captured for every provider and every
# auth mode, while a dollar figure needs a rate for the route. "cost" normalizes the
# RATE CARD's $/success (never Opik's auto-cost, which keys on the MODEL SLUG and so
# reads $0 for every slug its price table does not carry), and reports nothing at all
# for a cohort whose rows were priced under different accountings.
EFFICIENCY_AXES = ("tokens", "cost")


def rank_configs(configs: list[ConfigScore], axis: str = "tokens") -> list[RankedConfig]:
    """Rank configs on CAPABILITY ALONE: task success is the headline and pass^k
    reliability breaks a success tie. Efficiency is still computed and kept on the row,
    but as a DISPLAY column the leaderboard renders BESIDE the score — never a term in
    it. A more-capable-but-chattier model ALWAYS outranks a cheaper-but-weaker one (the
    old 0.7·success + 0.3·efficiency blend let a ~0.43 capability gap be reversed on
    token count, the exact mis-ranking this prevents). Efficiency is normalized against
    the most-efficient config that actually resolved something.

    `axis` selects which efficiency metric is shown: "tokens" (default, captured for
    every provider and auth mode) or "cost" (the RATE CARD's $/success, withheld for a
    cohort whose rows were priced under different accountings)."""
    if axis not in EFFICIENCY_AXES:
        raise ValueError(f"unknown efficiency axis {axis!r}; expected one of {EFFICIENCY_AXES}")
    ranked: list[RankedConfig] = []
    # strict=True: a short efficiency column would otherwise drop configs out of the
    # ranking entirely, silently, which is the failure this whole module refuses.
    for c, eff in zip(configs, _efficiency_column(configs, axis), strict=True):
        # Capability-only scalar: success is the integer-and-hundredths headline and
        # pass^k orders a true success tie from the sub-milli decimals. Cost is a
        # separate reported item, so no efficiency term enters here.
        composite = c.mean_task_success + c.mean_pass_hat_k * 1e-3
        ranked.append(RankedConfig(config=c, composite=composite, efficiency_norm=eff, rank=0))

    # config_id is the FINAL tie-break and it is load-bearing: with efficiency out of
    # the composite, configs tying exactly on (success, pass^k) would otherwise resolve
    # on Python's stable sort — i.e. on whichever config happened to be scored first,
    # so the same data ranked differently depending on the order it arrived in. Rank
    # must be a function of the data alone.
    ranked.sort(key=lambda r: (-r.composite, r.config.config_id))
    for i, r in enumerate(ranked, start=1):
        r.rank = i
    return ranked


def _efficiency_column(configs: list[ConfigScore], axis: str) -> list[float | None]:
    """The `eff` display column for ONE COHORT, parallel to `configs`. A None entry
    means the axis carries no comparable signal for the cohort at all."""
    if not configs:
        return []
    if axis == "cost":
        return _cost_efficiency_column(configs)
    return _normalized([c.tokens_per_success for c in configs])


def _cost_efficiency_column(configs: list[ConfigScore]) -> list[float | None]:
    """The cost axis normalizes the RATE CARD's $/success — never Opik's auto-cost.

    Opik keys on the MODEL SLUG, so its column reads $0 for every slug its price table
    does not carry (gpt-5.6-sol, gpt-5.6-terra and gpt-6-astra all report $0 and are all
    provider=openai; gpt-5.4-mini and claude-sonnet-4-6 are priced, claude-opus-4-8 is
    not). `_efficiency_norm` reads a $0 as no signal, so normalizing that column printed
    eff 0.00 for exactly the rows the card prices perfectly well.

    And this REFUSES rather than divide across incomparable accountings. eff is a ratio
    to the best row IN THE COHORT, so a cohort mixing a rate-carded row with a legacy
    Opik-metered one — or two rows priced under different card versions, or a ceiling
    against a cache-aware figure — would publish a ratio between two different price
    tables. The whole column is withheld, which is the move this layer already makes for
    a task-set hash that predates the fix: keep the rows, drop the one claim the
    evidence cannot support. Withholding per-row would be worse — a `1.00` beside a `—`
    still reads as a ranking, and the row that kept its number would look like the
    cohort's best."""
    if len({pricing_provenance(c) for c in configs}) > 1:
        return [None] * len(configs)
    if configs[0].pricing_basis not in COSTED_BASES:
        # One accounting, but it carries no dollars to normalize: an `unpriced` route
        # has no rate, a local route was never token-billed, and a pre-card row's only
        # dollars are Opik's. None of the three describes a cheap run.
        return [None] * len(configs)
    return _normalized([_priced_per_success(c) for c in configs])


def _priced_per_success(config: ConfigScore) -> float:
    """The card's $/success for a config already established to be on a COSTED basis,
    so the figure exists. A None here means the basis and the columns disagree — a bug
    in whatever priced the spans, never something to normalize past."""
    ratio = config.priced_cost_per_success
    if ratio is None:
        raise ValueError(f"config {config.config_id!r} carries pricing_basis "
                         f"{config.pricing_basis!r} but no priced_cost_usd to divide; "
                         f"the basis and the stored columns disagree")
    return ratio


def _normalized(per_success: list[float]) -> list[float]:
    """Ratio every row to the most efficient one that actually resolved something."""
    positive = [v for v in per_success if v != math.inf and v > 0]
    best = min(positive) if positive else None
    return [_efficiency_norm(v, best) for v in per_success]


def _efficiency_norm(per_success: float, best: float | None) -> float:
    """1.0 = most efficient; ->0 as usage/success rises; 0 if nothing resolved
    (per_success == inf) OR there is no positive signal on this axis.

    A per_success of exactly 0 is treated as NO SIGNAL (0.0), never "free = best". On
    the tokens axis a real turn always spends >0 tokens. On the cost axis the rate card
    reports a route it has no rate for as basis 'unpriced' — no figure at all rather
    than a $0 — but the guard stays: Opik's column, which reads $0 for every MODEL SLUG
    absent from its price table, is one call site away, and a zero there must never
    out-rank a genuinely cheap measured run."""
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
