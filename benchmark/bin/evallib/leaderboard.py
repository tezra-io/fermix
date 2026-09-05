"""Persist + render the cross-config capability leaderboard.

Each capability run scores ONE config (the model the dev daemon currently serves)
and upserts its result into a JSON store. The row key is `config_id@cohort`, where
the cohort is the measurement identity of the run: task-set hash, hash VERSION, k,
and the pass threshold. That key is the whole point of store v2 — under v1 a row was
keyed by config alone, so a `--max-tasks 3` spot-check or a `--k 3` re-run silently
replaced the config's real full-set row, and the board then ranked a 3-task number
against a 24-task one. Different cohort, different row, ranked separately.

Ranking happens WITHIN a cohort only. There is no global rank and no global
efficiency normalization: comparing two configs that ran different tasks is not a
comparison. A v1 store loads (migrated in memory, hash_version 1); it never gains
identity it did not record, so its rows stay in their own legacy cohorts and their
safety column reads "not evaluated", not a checkmark.

The dollar column carries a BASIS, and the basis is deliberately NOT part of cohort
identity. A cohort is the measurement identity of the SCORE, and the score is capability
only; splitting a cohort on how its dollars were computed would un-rank a genuine
head-to-head capability comparison over a column that is reported beside it. Instead the
non-comparability is rendered where it lives — every `$/✓` cell names the basis that
produced it (`ceiling`, `cache-aware`, `not token billed`, `unpriced`, or `opik` for a
row written before the rate card), and a cohort holding more than one basis says so above
the table. This is the same move the file already makes for a legacy task-set hash: keep
the row in its cohort, withhold the specific claim the evidence cannot support.

Pure (the runner does the actual file I/O via load_store/save_store). inf
(`*_per_success` when a config resolved nothing) is sanitized to null on
serialization and recomputed from the stored totals on load, so the JSON is always
valid and ranking never sees a None.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
from dataclasses import asdict, dataclass

from .aggregate import (OPIK_BASIS, PRICING_BASES, ConfigScore, RankedConfig,
                        pricing_provenance, rank_configs)

STORE_VERSION = 2
# The version of the task-set hash itself, and the ONE definition of it: the capability
# runner stamps rows with this, and the board decides comparability from it. They were
# two constants that happened to hold the same number, so bumping the hash scheme would
# have left the newly-legacy rows flagged as current.
CURRENT_HASH_VERSION = 2
# v1 hashed only part of the episode definition (last query, score/rubric, tool
# requirements), so two materially different task sets could share a hash. Rows carrying
# it are NOT comparable with each other either — a shared v1 digest is not evidence of a
# shared task set — so a legacy cohort is described but never ranked (review §7).
LEGACY_HASH_VERSION = 1
_IDENTITY_KEYS = ("tasks_hash", "hash_version", "k", "threshold")
# The one column the markdown table adds beyond the numbers: it splits the SCORE block
# from the block reported beside it. Markdown has no column groups, and the ordering
# alone was not legible at a glance — a reader scanning left to right could not see
# where the ranked quantity stopped and the decision inputs began.
COLUMN_DIVIDER = "‖"
# How a rate-carded dollar figure is spelled in the cell. Only the two COSTED bases
# appear here; the other two carry no dollar figure at all.
_BASIS_LABEL = {"ceiling": "ceiling", "cache_aware": "cache-aware"}
# Bound on the unpriced-route list in one cell; the count of the rest is still stated.
_MAX_SHOWN_ROUTES = 2


@dataclass
class Cohort:
    """One comparable world: the same tasks, hashed the same way, at the same k and
    pass bar. Rows inside it are ranked head-to-head; rows across cohorts are not."""
    key: str
    tasks_hash: str
    hash_version: int
    k: int
    threshold: float
    ranked: list[RankedConfig]
    metas: dict

    @property
    def comparable(self) -> bool:
        """Whether rows in this cohort may be ranked head-to-head. A pre-`CURRENT_HASH_VERSION`
        digest does not pin the task set, so equal hashes do not mean equal tasks: the rows
        are listed for history and left unranked, with no efficiency normalization between
        them."""
        return self.hash_version >= CURRENT_HASH_VERSION


def store_path(report_dir: str) -> str:
    return os.path.join(report_dir, "capability", "leaderboard.json")


def cohort_key(tasks_hash: str, hash_version: int, k: int, threshold: float) -> str:
    """Deterministic short id for a measurement identity."""
    if not tasks_hash or not isinstance(tasks_hash, str):
        raise ValueError(f"cohort_key: tasks_hash must be a non-empty string, got {tasks_hash!r}")
    raw = f"{tasks_hash}|{int(hash_version)}|{int(k)}|{float(threshold):.6f}"
    return hashlib.sha256(raw.encode()).hexdigest()[:12]


def load_store(path: str) -> dict:
    """Load the store, migrating a v1 file IN MEMORY (the caller's next save writes
    v2). A v1 row that never recorded its task set cannot be placed in a cohort at
    all — refuse loudly rather than invent one."""
    if not os.path.exists(path):
        return {"store_version": STORE_VERSION, "rows": {}}
    with open(path, "r", encoding="utf-8") as fh:
        raw = json.load(fh)
    if raw.get("store_version") == STORE_VERSION:
        return raw
    if "store_version" in raw:
        raise ValueError(f"{path}: unsupported store_version {raw['store_version']!r} "
                         f"(this harness writes v{STORE_VERSION})")
    return {"store_version": STORE_VERSION, "rows": _migrate_v1_rows(raw, path)}


def _migrate_v1_rows(raw: dict, path: str) -> dict:
    rows = {}
    for config_id, row in raw.items():
        meta = dict(row.get("meta") or {})
        missing = [k for k in ("tasks_hash", "k", "threshold") if meta.get(k) is None]
        if missing:
            raise ValueError(f"{path}: legacy row {config_id!r} has no {', '.join(missing)} — "
                             f"it cannot be placed in a cohort; delete the row or re-run it")
        meta["hash_version"] = LEGACY_HASH_VERSION
        key = cohort_key(meta["tasks_hash"], LEGACY_HASH_VERSION, meta["k"], meta["threshold"])
        rows[f"{config_id}@{key}"] = {"score": row.get("score", {}), "meta": meta}
    return rows


def save_store(path: str, store: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    payload = {"store_version": STORE_VERSION, "rows": store.get("rows", {})}
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(_sanitize(payload), fh, indent=2)


def upsert(store: dict, score: ConfigScore, meta: dict) -> dict:
    """Replace this config's row FOR THIS COHORT. `meta` must carry the full
    measurement identity; without it the row cannot be placed and the run's number
    would land on top of an unrelated one."""
    missing = [k for k in _IDENTITY_KEYS if meta.get(k) is None]
    if missing:
        raise ValueError(f"upsert: meta is missing {', '.join(missing)} — a row cannot be "
                         f"keyed without its measurement identity ({', '.join(_IDENTITY_KEYS)})")
    key = cohort_key(meta["tasks_hash"], meta["hash_version"], meta["k"], meta["threshold"])
    rows = dict(store.get("rows", {}))
    rows[f"{score.config_id}@{key}"] = {"score": asdict(score), "meta": dict(meta)}
    return {"store_version": STORE_VERSION, "rows": rows}


def cohorts(store: dict, axis: str = "tokens") -> list[Cohort]:
    """Group rows by cohort and rank WITHIN each. Efficiency is normalized inside the
    cohort, so a lean config in another world cannot deflate this one's eff column.
    Ordered largest cohort first, then by best success — deterministic."""
    grouped: dict = {}
    for key, row in store.get("rows", {}).items():
        config_id, cohort = _split_row_key(key)
        _require_identity(row.get("meta") or {}, key)
        grouped.setdefault(cohort, []).append((config_id, row))
    out = []
    for cohort, members in grouped.items():
        configs = [_config_from_dict(row["score"]) for _cid, row in members]
        metas = {cid: (row.get("meta") or {}) for cid, row in members}
        first = members[0][1].get("meta") or {}
        out.append(Cohort(key=cohort, tasks_hash=first.get("tasks_hash", "—"),
                          hash_version=int(first.get("hash_version", LEGACY_HASH_VERSION)),
                          k=int(first.get("k", 0)), threshold=float(first.get("threshold", 0.0)),
                          ranked=rank_configs(configs, axis=axis), metas=metas))
    out.sort(key=lambda c: (-len(c.ranked), -c.ranked[0].config.mean_task_success, c.key))
    return out


def _split_row_key(key: str) -> tuple[str, str]:
    """A v2 row key is `<config_id>@<cohort>`. Anything else is a hand-edited store, and
    guessing which half is which would put a row in the wrong comparison."""
    config_id, sep, cohort = key.rpartition("@")
    if not sep or not config_id or not cohort:
        raise ValueError(f"malformed leaderboard row key {key!r}; expected <config_id>@<cohort>")
    return config_id, cohort


def _require_identity(meta: dict, key: str) -> None:
    missing = [k for k in _IDENTITY_KEYS if meta.get(k) is None]
    if missing:
        raise ValueError(f"leaderboard row {key!r} is missing {', '.join(missing)} — "
                         f"its cohort cannot be described; re-run the config")


def render_json(store: dict, axis: str = "tokens") -> dict:
    return {"axis": axis,
            "cohorts": [{"cohort": c.key, "tasks_hash": c.tasks_hash,
                         "hash_version": c.hash_version, "k": c.k, "threshold": c.threshold,
                         "rows": [_json_row(r, c) for r in c.ranked]}
                        for c in cohorts(store, axis)]}


def _json_row(r: RankedConfig, cohort: Cohort) -> dict:
    c = r.config
    # A legacy cohort publishes NO rank and no relative efficiency: both are claims
    # that these rows measured the same tasks, which a v1 digest cannot support.
    return {
        "rank": r.rank if cohort.comparable else None,
        "config_id": c.config_id,
        "composite": round(r.composite, 4),
        "efficiency_norm": _eff_value(r, cohort),
        "mean_task_success": round(c.mean_task_success, 4),
        "mean_pass_at_1": None if c.mean_pass_at_1 is None else round(c.mean_pass_at_1, 4),
        "mean_task_success_ci": (None if c.mean_task_success_ci_lo is None
                                 else [round(c.mean_task_success_ci_lo, 4),
                                       round(c.mean_task_success_ci_hi, 4)]),
        "ci_resampled": c.ci_resampled,
        "n_families": c.n_families,
        "mean_pass_hat_k": round(c.mean_pass_hat_k, 4),
        "tokens_per_success": _finite(c.tokens_per_success),
        # OPIK's auto-cost, and it STAYS. It is the same quantity the declared
        # `max_cost_usd` gates read in grade.py — hundreds of them across the suites,
        # plus the default `behavioral_config.yaml` injects into every behavioral turn
        # — and that path is deliberately vacuous today, because an uncarded slug
        # reports no cost at all. Deleting this column in favour of the card's, or
        # writing either one from the other, would arm every one of those gates at once
        # against ceilings calibrated months ago: a wall of reds that reads as a model
        # regression when it is a suite-calibration failure. Two columns, two
        # accountings, never assigned across.
        "cost_per_success": _finite(c.cost_per_success),
        "cost_known": c.cost_known,
        # The rate card's own figure, kept strictly apart from Opik's above it. A
        # `None` here with a COSTED basis is the sanitized inf — nothing succeeded to
        # divide by — never "no price".
        "priced_cost_per_success": _finite(c.priced_cost_per_success),
        "priced_cost_usd": c.priced_cost_usd,
        "pricing_basis": c.pricing_basis,
        "pricing_card_version": c.pricing_card_version,
        "unpriced_routes": list(c.unpriced_routes or []),
        "spans_without_usage": c.spans_without_usage,
        "total_input_tokens": c.total_input_tokens,
        "total_output_tokens": c.total_output_tokens,
        "total_cached_input_tokens": c.total_cached_input_tokens,
        "total_cache_write_tokens": c.total_cache_write_tokens,
        "p95_latency_ms": round(c.p95_latency_ms, 1),
        "latency_stat": c.latency_stat,
        "safety_violations": c.safety_violations,
        "safety_trials_evaluated": c.safety_trials_evaluated,
        "n_invalid_trials": c.n_invalid_trials,
        "n_tasks": c.n_tasks,
        "n_trials": c.n_trials,
        "meta": cohort.metas.get(c.config_id, {}),
    }


def _eff_value(r: RankedConfig, cohort: Cohort) -> float | None:
    """`None` — rendered `—` — has TWO readings, and both are the same refusal: there is
    no cohort-relative ratio the evidence supports. Either the cohort's hash predates
    the task-set fix (the rows may not have run the same tasks), or the selected axis
    found no comparable signal across the cohort (`rank_configs`, cost axis)."""
    if not cohort.comparable or r.efficiency_norm is None:
        return None
    return round(r.efficiency_norm, 4)


# --- markdown ---------------------------------------------------------------

_FOOTER = (
    "_Lower tok/✓ and $/✓ is better; higher success/pass^k/composite is better._\n\n"
    "- **`$/✓` always names its BASIS**, because two dollar figures computed under "
    "different rules are not comparable. `$x ceiling` — ONE rate card of published API "
    "prices, charged against tokens that may have been served from cache, so the figure "
    "is an upper bound. `$x cache-aware` — the same card with every span's cache split "
    "known. The card is applied UNIFORMLY, including subscription and OAuth routes, "
    "where the number is an explicit counterfactual (what the run would have cost at "
    "API rates), never measured spend. `not token billed` — every route was local or "
    "self-hosted and was never token-billed at all. `unpriced — no card entry for "
    "<route>` — that route has no rate, so there is no number to publish; add it to the "
    "card (an unpriced run is not a cheap one). `$x opik` / `unknown (opik)` — a row "
    "written BEFORE the rate card, carrying Opik's auto-cost, which keys on the MODEL "
    "SLUG: its $0 means \"this slug is absent from Opik's price table\", never \"free\". "
    "Re-run the config to put it on the card.\n"
    "- **`—` and `n/a`** in `$/✓` or `tok/✓` are about SUCCESSES, not about price: `—` "
    "means the config cleared no task at the pass bar, so there is no success to divide "
    "by; `n/a` means it earned partial credit but never a full pass.\n"
    "- **`safety`** — `✓ n/N` / `✗ v/N` state the DENOMINATOR: N trials actually had a "
    "safety gate graded. `n/e` = **not evaluated**: no gate was graded, which is an "
    "absence of evidence and never a pass. `n/e (pre-v2)` marks rows scored before the "
    "denominator was recorded.\n"
    "- **`95% CI`** is this config's own marginal bootstrap interval. Two configs whose "
    "intervals overlap have NOT been shown to be equal — overlapping marginal intervals "
    "are not a paired test, and they neither prove nor refute a difference. For a real "
    "comparison run the paired analysis (`bin/run_uplift.py`), which tests the same "
    "tasks head-to-head. `n=1` marks a single-task row, where the interval is degenerate."
)


def render_md(store: dict, axis: str = "tokens") -> str:
    groups = cohorts(store, axis)
    lines = _preamble(axis)
    if not groups:
        return "\n".join(lines + ["| # | config | success |", "|--:|--------|--------:|",
                                  "| — | _(no configs scored yet)_ | |"]) + "\n"
    for c in groups:
        lines += [""] + _cohort_caption(c) + _pricing_note(c) + ["", _header(c), _rule()]
        lines += [_md_row(_rank_cell(r.rank, c), _json_row(r, c)) for r in c.ranked]
    return "\n".join(lines + ["", _FOOTER]) + "\n"


def _preamble(axis: str) -> list[str]:
    return [
        f"# Fermix capability leaderboard (efficiency axis: {axis})",
        "",
        "Ranked on **capability alone**: task-success is the headline and **pass^k** "
        "(reliability — ALL k trials pass; pass^k < success is the consistency gap) "
        "breaks a success tie. Efficiency and cost are NOT terms in `composite` and "
        "cannot move a rank; they are reported beside it as decision inputs.",
        "",
        f"**Two blocks, split by `{COLUMN_DIVIDER}`.** LEFT of the divider is the SCORE — "
        "task success, strict pass@1, its CI, pass^k reliability, the safety gate, and "
        "the capability-only `composite` the rank is a function of. RIGHT of it "
        "(`eff`, `tok/✓`, `$/✓`, latency) is reported BESIDE the score as a decision "
        "input and never enters the rank: a more-capable, chattier config always "
        "outranks a cheaper, weaker one.",
        "",
        "**Rows are ranked only inside a cohort.** A cohort is one measurement identity: "
        "the same task set (`set`), hashed the same way, at the same `k` and pass bar. A "
        "subset run, a different `k`, or a task set edited since the row was written all "
        "land in their own cohort — the board never ranks them against each other, and "
        "there is no cross-cohort rank.",
        "",
        _eff_sentence(axis),
    ]


def _eff_sentence(axis: str) -> str:
    """`eff` normalizes whichever axis the run selected, so the sentence must name that
    axis — and, on the cost axis, which of the two dollar columns it read. Saying
    "tok/✓" there described a column the board was not showing."""
    if axis == "cost":
        return ("**`eff` is RELATIVE and per-cohort:** eff = (the cohort's cheapest $/✓) "
                "÷ (this row's $/✓), capped at 1.0 — computed on the RATE CARD's $/✓, "
                "never on Opik's auto-cost. Whenever a cohort's rows were priced under "
                "different accountings — a carded row beside a pre-card `opik` one, two "
                "different card versions, or a `ceiling` against a `cache-aware` figure "
                "— the whole column reads `—`: a ratio across two price tables is not a "
                "comparison. So does a cohort with no dollar figure at all (`unpriced` "
                "or `not token billed`). A cohort with ONE config trivially shows "
                "eff = 1.0 regardless of what it spent.")
    return ("**`eff` is RELATIVE and per-cohort:** eff = (the cohort's leanest tok/✓) ÷ "
            "(this row's tok/✓), capped at 1.0. A cohort with ONE config trivially shows "
            "eff = 1.0 regardless of what it spent.")


def _cohort_caption(c: Cohort) -> list[str]:
    legacy = ("" if c.comparable else
              f" **(hash v{c.hash_version}, pre-fix — task set not pinned)**")
    scope = _cohort_scope(c)
    return [f"_Cohort `{c.key}` · set `{c.tasks_hash[:8]}` · k={c.k} · pass bar "
            f"{c.threshold:g} · {scope}._{legacy}"]


def _cohort_scope(c: Cohort) -> str:
    if not c.comparable:
        return (f"{len(c.ranked)} row(s) — the hash predates the fix that pins the task "
                "set, so equal digests are not evidence of equal tasks: listed for "
                "history, never ranked (`·`)")
    if len(c.ranked) > 1:
        return f"{len(c.ranked)} configs — same task set, ranked head-to-head"
    return "1 config — nothing to compare against, so the row is unranked (`·`)"


def _pricing_note(c: Cohort) -> list[str]:
    """Say it out loud when one cohort's `$/✓` column holds figures computed under
    different rules — today's store does exactly that, with an Opik-metered $0.3745/✓
    sitting beside rows the rate card will price. The per-cell suffix already makes any
    two of them unmistakable; this stops a reader scanning the column from ranking on it
    by eye. Cohort identity is deliberately left alone (see the module docstring)."""
    bases = sorted({pricing_provenance(r.config) for r in c.ranked})
    if len(bases) < 2:
        return []
    return [f"_⚠ `$/✓` mixes {len(bases)} pricing bases here ({', '.join(bases)}). A "
            "dollar figure is comparable only against another on the SAME basis AND the "
            "same rate card — read the suffix on each cell, and re-run a row to move it "
            "onto the current card._"]


def _header(c: Cohort) -> str:
    return (f"| # | config | success | pass@1 | 95% CI | pass^{c.k} | safety | n | "
            f"composite | {COLUMN_DIVIDER} | eff | tok/✓ | $/✓ | {_latency_label(c)} |")


def _rule() -> str:
    return ("|--:|--------|--------:|-------:|:------:|-------:|-------:|--:|"
            "----------:|:-:|----:|------:|----:|-------:|")


def _latency_label(c: Cohort) -> str:
    stats = {r.config.latency_stat for r in c.ranked}
    if len(stats) > 1:
        return "latency ms (mixed stats)"
    return "p95 pooled ms" if stats == {"pooled_p95"} else "max task p95 ms"


def _rank_cell(rank: int, cohort: Cohort) -> int | str:
    return rank if cohort.comparable and len(cohort.ranked) > 1 else "·"


def _md_row(rank: int | str, c: dict) -> str:
    """Score block, divider, then the quantities reported beside it. The order is the
    grouping: nothing right of `COLUMN_DIVIDER` is a term in `composite` or the rank."""
    return (f"| {rank} | `{c['config_id']}` | {c['mean_task_success']:.2f} | "
            f"{_pass_at_1(c)} | {_ci_cell(c)} | {c['mean_pass_hat_k']:.2f} | "
            f"{_safety_cell(c)} | {c['n_tasks']} | {c['composite']:.3f} | "
            f"{COLUMN_DIVIDER} | {_eff_cell(c)} | {_tok_cell(c)} | {_cost_cell(c)} | "
            f"{c['p95_latency_ms']:.0f} |")


def _eff_cell(c: dict) -> str:
    """`—` means there is no cohort-relative ratio to publish: either the hash does not
    establish that these rows ran the same tasks, or the selected axis found no
    comparable signal across the cohort (see `_eff_value`)."""
    value = c["efficiency_norm"]
    return "—" if value is None else f"{value:.2f}"


def _tok_cell(c: dict) -> str:
    value = c["tokens_per_success"]
    return _no_full_pass(c) if not value else f"{value:.0f}"


def _cost_cell(c: dict) -> str:
    """The `$/✓` cell, which always says WHERE its number came from.

    Five readings, never collapsed into one `unknown`: the rate card's `ceiling` (list
    price charged against tokens that may have been cached — an upper bound) and
    `cache-aware` prices; `not token billed` for a route that has no per-token rate at
    all; `unpriced` naming the route the card is missing; and `opik` for a row written
    before the card existed. An unpriced run is not a cheap one, and a local run is not
    an unpriced one."""
    basis = c["pricing_basis"]
    if basis is None:
        return _opik_cost_cell(c)
    if basis not in PRICING_BASES:
        raise ValueError(f"leaderboard row {c['config_id']!r} carries unknown "
                         f"pricing_basis {basis!r}; expected one of {PRICING_BASES}")
    if basis == "unpriced":
        return f"unpriced — no card entry for {_unpriced_routes(c)}"
    if basis == "not_token_billed":
        return "not token billed"
    # A COSTED basis always carries the total it computed, so a None ratio here is the
    # sanitized inf: there was no full pass to divide by, not "no price".
    value = c["priced_cost_per_success"]
    return _no_full_pass(c) if value is None else f"${value:.4f} {_BASIS_LABEL[basis]}"


def _opik_cost_cell(c: dict) -> str:
    """A row written BEFORE the rate card. Its dollars are Opik's auto-cost, which keys
    on the MODEL SLUG — not the provider and not the auth mode — so a $0 means "this
    slug is absent from Opik's price table", never "free". Labelled so it can never be
    read against a rate-carded figure in the same column, and so a legacy row does not
    silently start displaying a computed price once the card ships."""
    value = c["cost_per_success"]
    if value is None:                       # inf on the way out: no full pass to divide by
        return _no_full_pass(c)
    if c["cost_known"] is False or not value:
        return f"unknown ({OPIK_BASIS})"
    return f"${value:.4f} {OPIK_BASIS}"


def _unpriced_routes(c: dict) -> str:
    """Name the routes an operator has to add. Bounded so one cell cannot swallow the
    row, but the count of the remainder is always stated — a silently truncated list
    would understate how much of the run has no price."""
    routes = list(c["unpriced_routes"] or [])
    if not routes:
        raise ValueError(f"leaderboard row {c['config_id']!r} has pricing_basis "
                         f"'unpriced' but names no route; there is nothing to add")
    extra = len(routes) - _MAX_SHOWN_ROUTES
    shown = ", ".join(routes[:_MAX_SHOWN_ROUTES])
    return shown if extra <= 0 else f"{shown} (+{extra} more)"


def _no_full_pass(c: dict) -> str:
    """No strict pass to divide by. `—` only when the config truly resolved nothing;
    partial credit with no full pass is its own reading."""
    return "n/a" if c["mean_task_success"] > 0 else "—"


def _pass_at_1(c: dict) -> str:
    return "—" if c["mean_pass_at_1"] is None else f"{c['mean_pass_at_1']:.2f}"


def _ci_cell(c: dict) -> str:
    ci = c.get("mean_task_success_ci")
    if not ci:
        return "—"
    return "n=1" if c["n_tasks"] == 1 else f"[{ci[0]:.2f}, {ci[1]:.2f}]"


def _safety_cell(c: dict) -> str:
    evaluated = c["safety_trials_evaluated"]
    if evaluated is None:
        return "n/e (pre-v2)"
    if evaluated == 0:
        return "n/e"
    violations = c["safety_violations"]
    if violations:
        return f"✗ {violations}/{evaluated}"
    return f"✓ {evaluated}/{evaluated}"


# --- helpers ----------------------------------------------------------------

def _config_from_dict(d: dict) -> ConfigScore:
    c = ConfigScore(**d)
    # Recompute the per-success ratios from totals so a null-serialized inf
    # (no successes) comes back as inf, never None.
    c.cost_per_success = (c.total_cost / c.total_successes) if c.total_successes else math.inf
    c.tokens_per_success = (c.total_tokens / c.total_successes) if c.total_successes else math.inf
    return c


def _finite(x: float) -> float | None:
    return None if (x is None or math.isinf(x) or math.isnan(x)) else x


def _sanitize(obj):
    if isinstance(obj, dict):
        return {k: _sanitize(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_sanitize(v) for v in obj]
    if isinstance(obj, float) and (math.isinf(obj) or math.isnan(obj)):
        return None
    return obj
