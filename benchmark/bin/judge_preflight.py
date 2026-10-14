#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6,<7", "anthropic>=1.13,<2"]
# ///
"""One real Claude judge verdict on a canned case, before a judged tier runs.

It goes through the judge's own code (evallib.judge.preflight), with the judge
settings a runner loads, so it proves what the tier will meet: which credential
the SDK selects, that the request shape is accepted, and which model answers.
The eval box runs it right after the Workload Identity Federation sign-in.

  uv run bin/judge_preflight.py --config behavioral_config.yaml \\
      --expect-source "profile fermix-eval (oidc_federation)"

Prints the credential source and the model, never a credential. Exit 0: the
configured model answered through the expected credential. Exit 1: it did not,
and the last line says why. Exit 2: usage or configuration error."""
from __future__ import annotations

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from evallib import config as cfgmod  # noqa: E402
from evallib import judge  # noqa: E402


def _parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", required=True,
                    help="runner config whose judge section to use "
                         "(behavioral_config.yaml or config.yaml)")
    ap.add_argument("--expect-source", default=None,
                    help="the credential source the SDK must select, as the judge "
                         "names it, e.g. \"profile fermix-eval (oidc_federation)\"")
    return ap


def _problem(cfg, source: str | None, result, expect: str | None) -> str | None:
    if not result.evaluated:
        return f"the judge did not answer: {result.error}"
    if expect is not None and source != expect:
        return f"the judge signed in with {source}, not {expect}"
    if result.model != cfg.judge.model:
        return f"the judge was answered by {result.model}, not the configured {cfg.judge.model}"
    return None


def main(argv=None) -> int:
    args = _parser().parse_args(argv)
    config_path = os.path.join(SKILL_DIR, args.config)
    try:
        cfg = cfgmod.load(SKILL_DIR, config_path)
    except (OSError, ValueError) as exc:
        print(f"judge configuration invalid: {exc}")
        return 2
    source, result = judge.preflight(cfg)
    problem = _problem(cfg, source, result, args.expect_source)
    if problem:
        print(problem)
        return 1
    verdict = "pass" if result.passed else "fail"
    print(f"judge {cfg.judge.backend}/{result.model} answered through {source}: {verdict} "
          f"({result.input_tokens} input / {result.output_tokens} output tokens)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
