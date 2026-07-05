"""Persist + render the cross-config capability leaderboard.

Each capability run scores ONE config (the model the dev daemon currently serves)
and upserts its result into a JSON store keyed by config_id; the leaderboard
re-ranks every config seen so far (latest score per config wins). So a cross-model
sweep is just: cycle the daemon, run again — the board accumulates and re-ranks.

Pure (the runner does the actual file I/O via load_store/save_store). inf
(`*_per_success` when a config resolved nothing) is sanitized to null on
serialization and recomputed from the stored totals on load, so the JSON is always
valid and ranking never sees a None.
"""

from __future__ import annotations

import json
import math
import os
from collections import Counter
from dataclasses import asdict

from .aggregate import ConfigScore, RankedConfig, rank_configs


def store_path(report_dir: str) -> str:
    return os.path.join(report_dir, "capability", "leaderboard.json")


def load_store(path: str) -> dict:
    if not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def save_store(path: str, store: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(_sanitize(store), fh, indent=2)


def upsert(store: dict, score: ConfigScore, meta: dict) -> dict:
    out = dict(store)
    out[score.config_id] = {"score": asdict(score), "meta": meta}
    return out


def ranked(store: dict, axis: str = "tokens") -> list[RankedConfig]:
    configs = [_config_from_dict(v["score"]) for v in store.values()]
    return rank_configs(configs, axis=axis)


def render_json(store: dict, axis: str = "tokens") -> dict:
    rows = []
    for r in ranked(store, axis):
        c = r.config
        rows.append({
            "rank": r.rank,
            "config_id": c.config_id,
            "composite": round(r.composite, 4),
            "efficiency_norm": round(r.efficiency_norm, 4),
            "mean_task_success": round(c.mean_task_success, 4),
            "mean_task_success_ci": (None if c.mean_task_success_ci_lo is None
                                     else [round(c.mean_task_success_ci_lo, 4),
                                           round(c.mean_task_success_ci_hi, 4)]),
            "mean_pass_hat_k": round(c.mean_pass_hat_k, 4),
            "tokens_per_success": _finite(c.tokens_per_success),
            "cost_per_success": _finite(c.cost_per_success),
            "p95_latency_ms": round(c.p95_latency_ms, 1),
            "safety_violations": c.safety_violations,
            "n_tasks": c.n_tasks,
            "n_trials": c.n_trials,
            "meta": store[c.config_id].get("meta", {}),
        })
    return {"axis": axis, "configs": rows}


_HEADER = "| # | config | success | 95% CI | pass^k | eff | tok/✓ | $/✓ | n | set | p95 ms | safety | composite |"
_RULE = "|--:|--------|--------:|:------:|-------:|----:|------:|----:|--:|-----|-------:|-------:|----------:|"


def render_md(store: dict, axis: str = "tokens") -> str:
    data = render_json(store, axis)
    rows = data["configs"]
    preamble = [
        f"# Fermix capability leaderboard (efficiency axis: {axis})",
        "",
        "Ranked **capability-first**: task-success dominates, then **pass^k** "
        "(reliability — ALL k trials pass; pass^k < success is the consistency gap), "
        "then efficiency as a tie-breaker only. `composite` never lets efficiency "
        "reverse a real success gap.",
        "",
        "**`eff` is RELATIVE, not absolute:** eff = (most-efficient config's tok/✓) ÷ "
        "(this config's tok/✓), capped at 1.0 — so the leanest config on the board is "
        "1.0 and the rest are fractions of it. A board with ONE config trivially shows "
        "eff = 1.0 regardless of how many tokens it spent; efficiency only becomes a "
        "real comparison with ≥2 configs.",
        "",
        "**`n` = task count, `set` = task-set hash.** Only rows sharing the modal `set` "
        "are directly comparable; a row that ran a different task set (e.g. a `--suite` "
        "/ `--max-tasks` subset) is listed separately below and must NOT be read as a "
        "head-to-head result.",
        "",
        "**`95% CI`** is a percentile bootstrap over TASKS on the `success` column — the "
        "honest uncertainty band on the headline. Two configs whose CIs OVERLAP are a "
        "statistical tie on this task sample: the point gap between them is noise, not a "
        "real capability difference, so don't rank on it. A wide CI means too few or too "
        "heterogeneous tasks to separate models confidently. `—` = scored before the CI "
        "existed (re-run to populate).",
        "",
    ]
    if not rows:
        return "\n".join(preamble + [_HEADER, _RULE,
                                     "| — | _(no configs scored yet)_ | | | | | | | | | | | |"]) + "\n"

    modal = _modal_hash(rows)
    comparable = [c for c in rows if _row_hash(c) == modal]
    others = [c for c in rows if _row_hash(c) != modal]

    lines = preamble + [f"_Comparable set `{(modal or '—')[:8]}` · {len(comparable)} config(s)._",
                        "", _HEADER, _RULE]
    for i, c in enumerate(comparable, start=1):
        lines.append(_md_row(i, c))
    if others:
        lines += ["",
                  "**⚠️ Different task set — NOT comparable to the board above** "
                  "(ran a different suite/subset, so success and rank are not head-to-head):",
                  "", "| config | success | pass^k | n | set |", "|--------|--------:|-------:|--:|-----|"]
        for c in others:
            lines.append(f"| `{c['config_id']}` | {c['mean_task_success']:.2f} | "
                         f"{c['mean_pass_hat_k']:.2f} | {c['n_tasks']} | `{(_row_hash(c) or '—')[:8]}` |")
    lines += ["", "_Lower tok/✓ and $/✓ is better; higher success/pass^k/composite is better. "
              "A config that resolved nothing shows tok/✓ = —._"]
    return "\n".join(lines) + "\n"


def _row_hash(row: dict) -> str | None:
    return (row.get("meta") or {}).get("tasks_hash")


def _modal_hash(rows: list[dict]) -> str | None:
    """The task-set hash shared by the most rows — the 'comparable' cohort. Rows
    predating the hash (meta without tasks_hash) group together under None."""
    hashes = [h for h in (_row_hash(r) for r in rows) if h]
    return Counter(hashes).most_common(1)[0][0] if hashes else None


def _md_row(rank: int, c: dict) -> str:
    tok = "—" if c["tokens_per_success"] is None else f"{c['tokens_per_success']:.0f}"
    dol = "—" if not c["cost_per_success"] else f"${c['cost_per_success']:.4f}"
    safety = "✓" if c["safety_violations"] == 0 else f"⚠️{c['safety_violations']}"
    ci = c.get("mean_task_success_ci")
    ci_txt = "—" if not ci else f"[{ci[0]:.2f}, {ci[1]:.2f}]"
    return (f"| {rank} | `{c['config_id']}` | {c['mean_task_success']:.2f} | {ci_txt} | "
            f"{c['mean_pass_hat_k']:.2f} | {c['efficiency_norm']:.2f} | {tok} | {dol} | "
            f"{c['n_tasks']} | `{(_row_hash(c) or '—')[:8]}` | "
            f"{c['p95_latency_ms']:.0f} | {safety} | {c['composite']:.3f} |")


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
