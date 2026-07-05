#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Tier-0 raw-intelligence baseline via EleutherAI lm-evaluation-harness.

This is the SEPARATE raw-model calibration tier (EVAL_CAPABILITY_SCORING.md §0):
it benchmarks the bare model on static datasets (IFEval / GPQA / GSM8K) via the
model's own generations — it does NOT exercise Fermix's tools or loop, and its
score is NOT subtracted from the agentic uplift (different tasks + metrics). Run it
on the SAME model the Fermix arm serves so the two tiers are comparable.

The lm_eval run is operator-gated (heavy dep + provider key + real spend); this
wrapper builds the command and parses the results JSON. Three modes:

    --dry-run                 print the lm_eval command to run yourself
    --results <lm_eval.json>  parse an existing lm_eval results file -> baseline
    (default)                 run lm_eval via subprocess (must be installed), then parse

Env: EVAL_BASELINE_MODEL (required), EVAL_BASELINE_BASE_URL (default OpenAI),
     EVAL_BASELINE_API_KEY (exported to OPENAI_API_KEY for the local-chat backend).
Exit: 0 ok · 2 usage · 3 lm_eval not installed.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)

DEFAULT_TASKS = ["ifeval", "gpqa_diamond_zeroshot", "gsm8k"]
# Order = preference: the first hint present is the task's primary metric.
_PRIMARY_METRIC_HINTS = ("prompt_level_strict_acc", "exact_match", "acc_norm", "acc")


def build_command(model: str, base_url: str, tasks: list[str], output_path: str,
                  limit: int | None = None) -> list[str]:
    """lm_eval against an OpenAI-compatible CHAT endpoint. The API key is NOT in
    argv — lm_eval's local-chat-completions reads it from OPENAI_API_KEY."""
    cmd = [
        "lm_eval", "--model", "local-chat-completions",
        "--model_args",
        f"model={model},base_url={base_url.rstrip('/')}/chat/completions,num_concurrent=1,max_retries=3",
        "--tasks", ",".join(tasks),
        "--apply_chat_template",
        "--output_path", output_path,
    ]
    if limit:
        cmd += ["--limit", str(limit)]
    return cmd


def parse_lmeval_results(data: dict) -> dict:
    """lm_eval results JSON -> {task: {metric, filter, value}}. Picks one primary
    metric per task (prompt_level_strict_acc / exact_match / acc_norm / acc),
    ignoring *_stderr and non-scalar entries. Metric keys are 'name,filter'.

    The filter is KEPT and recorded: GSM8K emits exact_match under both
    'strict-match' and 'flexible-extract' with different values, so collapsing on
    name alone silently picked whichever came first in JSON order. We deterministically
    prefer a 'flexible-extract' filter (lm_eval's headline for gsm8k) and record which."""
    out = {}
    for task, metrics in (data.get("results") or {}).items():
        scalars = []
        for key, val in metrics.items():
            name, _sep, filt = key.partition(",")
            if name.endswith("_stderr") or not isinstance(val, (int, float)):
                continue
            scalars.append((name, filt, float(val)))
        chosen = _choose_metric(scalars)
        if chosen:
            out[task] = {"metric": chosen[0], "filter": chosen[1], "value": chosen[2]}
    return out


def _choose_metric(scalars: list) -> tuple | None:
    """Pick (name, filter, value): first hint that matches, preferring a
    flexible-extract filter when a name has several, else the first scalar."""
    for hint in _PRIMARY_METRIC_HINTS:
        candidates = [s for s in scalars if s[0] == hint]
        if candidates:
            flex = [s for s in candidates if "flexible" in s[1]]
            return flex[0] if flex else candidates[0]
    return scalars[0] if scalars else None


def _write_baseline(parsed: dict, model: str, out: str) -> None:
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump({"tier": "raw-lm-eval", "model": model, "tasks": parsed}, fh, indent=2)
    print(f"baseline written: {out}")
    for task, m in parsed.items():
        filt = f"[{m['filter']}]" if m.get("filter") else ""
        print(f"  {task:28} {m['metric']}{filt}={m['value']:.4f}")


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Tier-0 raw-model baseline via lm-evaluation-harness")
    p.add_argument("--tasks", default=",".join(DEFAULT_TASKS), help="comma-separated lm_eval tasks")
    p.add_argument("--limit", type=int, default=None, help="cap items/task (bound spend)")
    p.add_argument("--dry-run", action="store_true", help="print the lm_eval command, run nothing")
    p.add_argument("--results", help="parse an existing lm_eval results JSON instead of running")
    p.add_argument("--out", default=os.path.join(SKILL_DIR, "reports", "capability", "baseline", "lmeval.json"))
    args = p.parse_args(argv)

    if args.results:
        if not os.path.isfile(args.results):
            print(f"results file not found: {args.results}", file=sys.stderr)
            return 2
        with open(args.results, "r", encoding="utf-8") as fh:
            _write_baseline(parse_lmeval_results(json.load(fh)),
                            os.environ.get("EVAL_BASELINE_MODEL", "unknown"), args.out)
        return 0

    model = os.environ.get("EVAL_BASELINE_MODEL")
    base = os.environ.get("EVAL_BASELINE_BASE_URL", "https://api.openai.com/v1")
    if not model:
        print("set EVAL_BASELINE_MODEL (the SAME model the Fermix arm served)", file=sys.stderr)
        return 2

    raw_out = os.path.join(os.path.dirname(args.out), "lmeval_raw")
    cmd = build_command(model, base, args.tasks.split(","), raw_out, args.limit)
    if args.dry_run:
        print("OPENAI_API_KEY=$EVAL_BASELINE_API_KEY \\\n  " + " ".join(cmd))
        return 0

    if not shutil.which("lm_eval"):
        print("lm_eval not installed — `pip install lm-eval`, or use --dry-run / --results.",
              file=sys.stderr)
        return 3
    env = dict(os.environ)
    if os.environ.get("EVAL_BASELINE_API_KEY"):
        env["OPENAI_API_KEY"] = os.environ["EVAL_BASELINE_API_KEY"]
    print("running: " + " ".join(cmd))
    proc = subprocess.run(cmd, env=env)
    if proc.returncode != 0:
        print(f"lm_eval exited {proc.returncode}", file=sys.stderr)
        return proc.returncode
    # lm_eval writes <output_path>/<model>/results_*.json — find the newest.
    found = _newest_results(raw_out)
    if not found:
        print(f"no results JSON under {raw_out}", file=sys.stderr)
        return 2
    with open(found, "r", encoding="utf-8") as fh:
        _write_baseline(parse_lmeval_results(json.load(fh)), model, args.out)
    return 0


def _newest_results(root: str) -> str | None:
    hits = []
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            if f.startswith("results") and f.endswith(".json"):
                hits.append(os.path.join(dirpath, f))
    return max(hits, key=os.path.getmtime) if hits else None


if __name__ == "__main__":
    sys.exit(main())
