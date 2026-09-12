#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Compute agentic uplift from a Fermix-arm and a baseline-arm results.json.

    uv run bin/run_uplift.py \\
        --fermix   reports/capability/<run>/results.json \\
        --baseline reports/capability/baseline/<model>.json

Pairs the two arms and prints the defensible claim line (success-with-Fermix vs the
baseline, uplift in pp, 95% CI, McNemar exact p). The Fermix arm comes from
run_capability.py; the baseline from run_baseline.py (same model, same tasks, same
scorer). The two must be the SAME experiment — identical task set, k, pass threshold
and trial count; a mismatch is refused with the excluded task ids named, because
pairing whatever ids happen to intersect compares two different runs.

Exit: 0 ok · 2 usage/pairing error.
"""
from __future__ import annotations

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from evallib import uplift


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Agentic uplift: Fermix arm vs baseline arm")
    p.add_argument("--fermix", required=True, help="run_capability.py results.json (tools-on arm)")
    p.add_argument("--baseline", required=True, help="run_baseline.py results.json (raw arm)")
    p.add_argument("--threshold", type=float, default=None,
                   help="per-task pass bar for binarizing each arm (default: a STRICT "
                        "majority of the arms' trials — 3/5 at k=5 — not the capability "
                        "arm's all-perfect 1.0, which erases real partial uplift)")
    p.add_argument("--out", default=None, help="also write the claim markdown here")
    args = p.parse_args(argv)

    for path in (args.fermix, args.baseline):
        if not os.path.isfile(path):
            print(f"results file not found: {path}", file=sys.stderr)
            return 2

    fermix = uplift.load_arm(args.fermix)
    baseline = uplift.load_arm(args.baseline)
    problems = uplift.compare_arms(fermix, baseline)
    if problems:
        print("the two arms are not a paired experiment — refusing to publish a "
              "comparison of two different runs:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        print("re-run both arms with the same task selection, --trials and --threshold.",
              file=sys.stderr)
        return 2

    trials = uplift.arm_trial_counts(fermix).pop()
    threshold = args.threshold if args.threshold is not None else uplift.majority_threshold(trials)
    if not 0 < threshold <= 1:
        print(f"--threshold must be in (0, 1], got {threshold}", file=sys.stderr)
        return 2

    result = uplift.paired_uplift(uplift.tasks_success(fermix),
                                  uplift.tasks_success(baseline), threshold=threshold)
    md = uplift.render_md(result, label=fermix.get("config_id", "fermix"),
                          baseline_label=baseline.get("config_id", "baseline"),
                          suite=fermix.get("suite", "?"), k=int(fermix["k"]), trials=trials,
                          task_ids=sorted(fermix.get("tasks", {})))
    print(md)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(md)
        print(f"written: {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
