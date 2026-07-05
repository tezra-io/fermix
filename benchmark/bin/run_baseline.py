#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6,<7"]
# ///
"""Raw-model baseline arm for agentic uplift.

Runs the SAME capability tasks (suites/capability/*.yaml) directly against a raw
OpenAI-compatible /chat/completions endpoint — NO Fermix, NO tools, NO agent loop —
k trials each, scored with the SAME scoring.py. Writes a per-task results.json that
run_uplift.py pairs against the Fermix arm's results.json (from run_capability.py)
to compute the uplift (EVAL_CAPABILITY_SCORING.md §0/§4).

This is the tools-OFF / raw-model arm: it isolates everything Fermix's scaffold and
tools add. Only closed-form (`score:`) tasks are scored — a no-scaffold baseline
has no judge. The key is operator-provided, NEVER extracted from the daemon:

    EVAL_BASELINE_API_KEY    (required)
    EVAL_BASELINE_MODEL      (required — the SAME model the Fermix arm served)
    EVAL_BASELINE_BASE_URL   (default https://api.openai.com/v1)

Exit: 0 ok · 2 usage/selection · 3 missing key/model.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from evallib import aggregate, scoring, uplift
from evallib.suites import SuiteError, load_all

CAP_DIR = os.path.join(SKILL_DIR, "suites", "capability")


class BaselineError(Exception):
    pass


def make_chat(base: str, api_key: str, model: str, timeout_s: float = 120.0):
    """Return a chat(query) -> (reply, total_tokens) bound to an OpenAI-compatible
    endpoint. Temperature 0 for the most reproducible baseline."""
    url = base.rstrip("/") + "/chat/completions"

    def chat(query: str) -> tuple[str, int]:
        body = json.dumps({"model": model, "temperature": 0,
                           "messages": [{"role": "user", "content": query}]}).encode()
        req = urllib.request.Request(url, data=body, headers={
            "Authorization": f"Bearer {api_key}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout_s) as resp:
                data = json.load(resp)
            reply = data["choices"][0]["message"]["content"]
        except (OSError, KeyError, IndexError, ValueError) as exc:
            raise BaselineError(f"chat call failed: {exc}") from exc
        return reply, int((data.get("usage") or {}).get("total_tokens") or 0)

    return chat


def score_case(case, trials: int, k: int, threshold: float, chat) -> aggregate.TaskStats:
    """`trials` raw-model attempts of one closed-form task -> TaskStats, with pass^k
    computed at `k` (k<=trials). Separating the two matters: the Fermix arm drives
    `trials` turns, so the baseline must drive the SAME `trials` (not `k`), or a
    paired uplift compares arms of different sample size. A failed API call is a
    zero trial (recorded, not raised), mirroring the Fermix arm."""
    results = []
    for _ in range(trials):
        try:
            reply, tokens = chat(case.turns[-1].query)
        except BaselineError:
            results.append(aggregate.score_trial(case.id, task_success=0.0, safety_ok=True,
                cost=0.0, duration_ms=0.0, tokens=0, tool_calls=0, status="api_error"))
            continue
        succ = scoring.score_answer(reply, case.score_spec).score
        results.append(aggregate.score_trial(case.id, task_success=succ, safety_ok=True,
            cost=0.0, duration_ms=0.0, tokens=tokens, tool_calls=0, status="ok"))
    return aggregate.aggregate_task(results, k=k, threshold=threshold)


def baseline_cases(suites, want_suites, want_tags, max_tasks):
    out = []
    for s in suites:
        if want_suites and s.name not in want_suites:
            continue
        for scn in s.scenarios:
            if want_tags and not (set(want_tags) & set(scn.tags)):
                continue
            for case in scn.cases:
                if case.score_spec:        # closed-form only — no judge in the baseline
                    out.append((s, scn, case))
    return out[:max_tasks] if max_tasks else out


def build_args(argv):
    p = argparse.ArgumentParser(description="Raw-model baseline arm for agentic uplift")
    p.add_argument("--suite", action="append")
    p.add_argument("--tag", action="append")
    p.add_argument("--trials", type=int, default=3)
    p.add_argument("--k", type=int, default=None)
    p.add_argument("--threshold", type=float, default=1.0)
    p.add_argument("--max-tasks", type=int, default=None)
    p.add_argument("--out", default=None, help="results.json path (default reports/capability/baseline/<model>.json)")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = build_args(argv)
    api_key = os.environ.get("EVAL_BASELINE_API_KEY")
    model = os.environ.get("EVAL_BASELINE_MODEL")
    base = os.environ.get("EVAL_BASELINE_BASE_URL", "https://api.openai.com/v1")
    if not api_key or not model:
        print("set EVAL_BASELINE_API_KEY and EVAL_BASELINE_MODEL (the SAME model the "
              "Fermix arm served)", file=sys.stderr)
        return 3
    if not 0 < args.threshold <= 1:
        print(f"--threshold must be in (0, 1], got {args.threshold}", file=sys.stderr)
        return 2

    try:
        suites = load_all(CAP_DIR)
    except SuiteError as exc:
        print("capability suites invalid:\n  - " + "\n  - ".join(exc.problems), file=sys.stderr)
        return 2
    cases = baseline_cases(suites, args.suite, args.tag, args.max_tasks)
    if not cases:
        print("no closed-form capability tasks selected", file=sys.stderr)
        return 2

    trials = max(1, args.trials)
    k = args.k or trials
    chat = make_chat(base, api_key, model)
    print(f"raw baseline · {len(cases)} task(s) × {trials} trial(s) · model={model} "
          f"(no Fermix, no tools)")
    tasks = {}
    for s, _scn, case in cases:
        st = score_case(case, trials, k, args.threshold, chat)
        tasks[f"{s.name}/{case.id}"] = {"mean_success": round(st.mean_success, 4),
                                        "pass_hat_k": round(st.pass_hat_k, 4), "n": st.n_trials}
        print(f"  {s.name}/{case.id:24} success={st.mean_success:.2f} pass^{st.k}={st.pass_hat_k:.2f}")

    out = args.out or os.path.join(SKILL_DIR, "reports", "capability", "baseline",
                                   f"{model.replace('/', '_')}.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    uplift.write_arm(out, arm="baseline", config_id=model,
                     suite=",".join(sorted({s.name for s, _c, _o in cases})),
                     k=k, threshold=args.threshold, tasks=tasks)
    print(f"\nbaseline results: {out}\n"
          f"compare with the Fermix arm: uv run bin/run_uplift.py --fermix <results.json> --baseline {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
