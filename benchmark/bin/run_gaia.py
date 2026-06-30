#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6,<7"]
# ///
"""GAIA (General AI Assistants) runner — the flagship general-assistant benchmark.

Drives each GAIA question through the live Fermix daemon (Fermix uses its OWN
web/file tools to reach the answer), extracts the FINAL ANSWER, and scores it with
GAIA's quasi-exact-match. Reports per-level accuracy and writes an HF-submission
JSONL for the held-out test split (EVAL_CAPABILITY_SCORING.md §6).

The dataset is GATED on Hugging Face — download the GAIA validation/test JSONL
yourself (accept the terms) and pass it with --data. Run the validation split for
an internal number; submit the test split's JSONL to the HF leaderboard for the
public figure. Only the final string is graded, so Fermix's toolset is fully
exercised without the benchmark dictating tools.

    uv run bin/run_gaia.py --data path/to/gaia_validation.jsonl --limit 20

Exit: 0 ok · 2 usage · 3 preconditions (daemon down).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import string
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from evallib import config as cfgmod, driver

_ANSWER_INSTRUCTION = (
    "\n\nReport your thinking, then finish with a single line exactly of the form:\n"
    "FINAL ANSWER: <your answer>\n"
    "Your answer should be a number, as few words as possible, or a comma-separated "
    "list — no units or extra words unless asked."
)


# --- pure core --------------------------------------------------------------

def extract_final_answer(reply: str) -> str:
    """Pull the text after the last 'FINAL ANSWER:' marker (GAIA's output
    contract). No marker -> the whole reply (so a bare answer still scores)."""
    matches = list(re.finditer(r"final answer\s*:\s*(.+)", reply or "", re.IGNORECASE))
    return matches[-1].group(1).strip() if matches else (reply or "").strip()


# --- GAIA's OFFICIAL scorer, vendored verbatim (gaia-benchmark/GAIA scorer.py) ---
# Vendored rather than re-derived because the number/list/string gating and the
# whitespace/punctuation rules are subtle (e.g. "seagull" == "sea gull"; a comma
# in the gold forces the LIST path even for "1,234") — any paraphrase silently
# diverges from the published number.

def _is_float(element) -> bool:
    try:
        float(element)
        return True
    except (ValueError, TypeError):
        return False


def normalize_number_str(number_str: str) -> float:
    for ch in ["$", "%", ","]:
        number_str = number_str.replace(ch, "")
    try:
        return float(number_str)
    except ValueError:
        return float("inf")


def split_string(s: str, char_list=(",", ";")) -> list[str]:
    return re.split(f"[{''.join(char_list)}]", s)


def normalize_str(input_str: str, remove_punct: bool = True) -> str:
    no_spaces = re.sub(r"\s", "", input_str)
    if remove_punct:
        return no_spaces.lower().translate(str.maketrans("", "", string.punctuation))
    return no_spaces.lower()


def question_scorer(model_answer: str, ground_truth: str) -> bool:
    if _is_float(ground_truth):
        return normalize_number_str(model_answer) == float(ground_truth)
    if any(ch in ground_truth for ch in [",", ";"]):
        gt_elems = split_string(ground_truth)
        ma_elems = split_string(model_answer)
        if len(gt_elems) != len(ma_elems):
            return False
        out = []
        for ma_elem, gt_elem in zip(ma_elems, gt_elems):
            if _is_float(gt_elem):
                out.append(normalize_number_str(ma_elem) == float(gt_elem))
            else:
                out.append(normalize_str(ma_elem, remove_punct=False)
                           == normalize_str(gt_elem, remove_punct=False))
        return all(out)
    return normalize_str(model_answer) == normalize_str(ground_truth)


def gaia_score(reply: str, gold) -> bool:
    """GAIA quasi-exact-match on the extracted FINAL ANSWER, via the vendored
    official scorer (so it can never drift from the published leaderboard's grading)."""
    return question_scorer(extract_final_answer(reply), str(gold))


def load_gaia(path: str) -> list[dict]:
    """Parse a GAIA JSONL into {task_id, question, answer (None on test split),
    level}. Tolerates the official 'Question'/'Final answer'/'Level' casing and
    lowercase variants."""
    items = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            items.append({
                "task_id": str(row.get("task_id") or row.get("id") or len(items)),
                "question": row.get("Question") or row.get("question") or "",
                "answer": row.get("Final answer") or row.get("final_answer") or row.get("answer"),
                "level": row.get("Level") or row.get("level"),
            })
    return items


def submission_row(task_id: str, reply: str, reasoning: str) -> dict:
    return {"task_id": task_id, "model_answer": extract_final_answer(reply),
            "reasoning_trace": reasoning}


# --- driving (live) ---------------------------------------------------------

def _sess(run_id: str, task_id: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]+", "-", f"e2e-gaia-{run_id}-{task_id}")[:90]


def run(cfg, items, run_id, timeout_ms):
    rows, graded = [], []
    for item in items:
        res = driver.drive_query(cfg, _sess(run_id, item["task_id"]),
                                 item["question"] + _ANSWER_INSTRUCTION, timeout_ms)
        reply = res.response or "" if res.ok else ""
        rows.append(submission_row(item["task_id"], reply, reply))
        if item["answer"] is not None:                 # validation split: we can grade
            ok = bool(res.ok) and gaia_score(reply, item["answer"])
            graded.append((item["level"], ok))
            print(f"  L{item['level']} {item['task_id'][:12]:12} "
                  f"{'✓' if ok else '✗'}  {extract_final_answer(reply)[:40]!r}")
        else:
            print(f"  L{item['level']} {item['task_id'][:12]:12} (test — no gold) "
                  f"{extract_final_answer(reply)[:40]!r}")
    return rows, graded


def _report(graded) -> str:
    if not graded:
        return "test split (no gold) — submit the JSONL to the HF leaderboard for the score.\n"
    overall = sum(1 for _l, ok in graded if ok) / len(graded)
    lines = [f"GAIA accuracy: {overall * 100:.1f}% ({sum(ok for _l, ok in graded)}/{len(graded)})"]
    by_level: dict = {}
    for level, ok in graded:
        by_level.setdefault(level, []).append(ok)
    for level in sorted(by_level, key=lambda x: (x is None, x)):
        oks = by_level[level]
        lines.append(f"  Level {level}: {sum(oks) / len(oks) * 100:.1f}% ({sum(oks)}/{len(oks)})")
    return "\n".join(lines) + "\n"


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="GAIA runner (drives Fermix, scores quasi-exact-match)")
    p.add_argument("--data", required=True, help="GAIA JSONL (download from HF — gated)")
    p.add_argument("--limit", type=int, default=None, help="cap questions (bound spend)")
    p.add_argument("--timeout-ms", type=int, default=None)
    p.add_argument("--out", default=None, help="dir for submission.jsonl + report.txt")
    args = p.parse_args(argv)

    if not os.path.isfile(args.data):
        print(f"GAIA data not found: {args.data} (download from huggingface.co/datasets/gaia-benchmark/GAIA)",
              file=sys.stderr)
        return 2
    cfg = cfgmod.load(SKILL_DIR)
    ok, detail = driver.daemon_reachable(cfg)
    if not ok:
        print(f"dev daemon not reachable (FERMIX_HOME={cfg.daemon.fermix_home}): {detail}", file=sys.stderr)
        return 3

    items = load_gaia(args.data)
    if args.limit:
        items = items[:args.limit]
    if not items:
        print("no GAIA items loaded", file=sys.stderr)
        return 2

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    timeout_ms = args.timeout_ms or cfg.daemon.default_timeout_ms
    print(f"GAIA · {len(items)} question(s) · FERMIX_HOME={cfg.daemon.fermix_home}")
    rows, graded = run(cfg, items, run_id, timeout_ms)

    out_dir = args.out or os.path.join(cfg.report_dir, "gaia", run_id)
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "submission.jsonl"), "w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row) + "\n")
    report = _report(graded)
    with open(os.path.join(out_dir, "report.txt"), "w", encoding="utf-8") as fh:
        fh.write(report)
    print("\n" + report + f"submission + report: {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
