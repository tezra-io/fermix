#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Compute agentic uplift from a Fermix-arm and a baseline-arm results.json.

    uv run bin/run_uplift.py \\
        --fermix   reports/capability/<run>/results.json \\
        --baseline reports/capability/baseline/<model>.json

Pairs the two arms on their shared tasks and prints the defensible claim line
(success-with-Fermix vs raw, uplift in pp, 95% CI, McNemar exact p). The Fermix
arm comes from run_capability.py; the baseline from run_baseline.py (same model,
same tasks, same scorer). Exit: 0 ok · 2 usage/pairing error.
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
                   help="per-task pass bar (default: the Fermix arm's recorded threshold)")
    p.add_argument("--out", default=None, help="also write the claim markdown here")
    args = p.parse_args(argv)

    for path in (args.fermix, args.baseline):
        if not os.path.isfile(path):
            print(f"results file not found: {path}", file=sys.stderr)
            return 2

    fermix = uplift.load_arm(args.fermix)
    baseline = uplift.load_arm(args.baseline)
    threshold = args.threshold if args.threshold is not None else float(fermix.get("threshold", 1.0))
    if not 0 < threshold <= 1:
        print(f"--threshold must be in (0, 1], got {threshold}", file=sys.stderr)
        return 2

    try:
        result = uplift.paired_uplift(uplift.tasks_success(fermix),
                                      uplift.tasks_success(baseline), threshold=threshold)
    except ValueError as exc:
        print(f"cannot pair the two arms: {exc}", file=sys.stderr)
        return 2

    md = uplift.render_md(result, label=fermix.get("config_id", "fermix"),
                          suite=fermix.get("suite", "?"), k=int(fermix.get("k", 1)))
    print(md)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(md)
        print(f"written: {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
