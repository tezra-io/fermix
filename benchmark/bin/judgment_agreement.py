#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""How far Fermix's open-loop judgment agrees with the owner's labels (M83 §06).

  uv run bin/judgment_agreement.py <run>/results.json [--baseline <run>/results.json]

Reads one capability run of cap_open_loop_judgment (run_capability.py's results.json,
whose `trial_records` carry each trial's checker detail) and prints:

  * per moment, the majority of its valid trials ("split" when no label has more than
    half): agreement overall and per owner label, Cohen's kappa, the confusion table
    (rows: the owner; columns: Fermix), and a 95% Wilson interval on the agreement;
  * the costliest error on its own line: check in where the owner said let it go;
  * the same agreement, kappa and costliest error over every valid trial, with no
    interval: the trials of one moment are not independent draws, so a binomial
    interval over them would claim more certainty than the run has;
  * the trials in which code refused an open_loop_note call (the checker's `refused`
    token), counted on their own line with how many of them disagree with the owner,
    so a code limit is not read as a judgment miss; a call whose result was not
    recorded (`refused=unread`) is counted beside them;
  * the trials that failed the suite's declared constraint (the schedule_job ban), and
    the misses, moment by moment, each trial marked with the refusal it met.

With --baseline, a paired McNemar comparison on the moments both runs measured with
the same label: how many moments regressed and improved, the exact two-sided p, and
the costliest error in each. A drop counts only beyond the measured noise floor (M83
§06); this script reports, it does not decide.

A run graded on keep-or-let-go only (the checker's `stage=0`, before the reach column
exists) is read that way: the owner's two kept labels collapse to `keep`, and the
costliest error becomes "kept where the owner said let it go", an upper bound. A
comparison where either run is stage 0 is made on keep-or-let-go for both.

Exit 0: printed. Exit 2: the input is not a judgment run this script can read.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import Counter
from dataclasses import dataclass, field

SUITE = "cap_open_loop_judgment"
LABELS = ("let_go", "when_around", "check_in")
KEEP_LABELS = ("let_go", "keep")
PREDICTIONS = {*LABELS, "keep", "other"}
TOKEN = re.compile(r"(\w+)=(\S+)")
Z95 = 1.959964


class InputError(ValueError):
    pass


@dataclass
class Moment:
    want: str
    preds: list[str] = field(default_factory=list)
    refusals: list[str] = field(default_factory=list)   # per valid trial: a token or "none"
    invalid: int = 0
    constraint_failed: int = 0


@dataclass
class Run:
    path: str
    stage: int
    moments: dict[str, Moment]


# --- reading a run ------------------------------------------------------------

def parse_detail(detail: str) -> dict[str, str]:
    """The checker's `key=value` tokens, before the ` | ` that starts the intention."""
    head = detail.split(" | ", 1)[0]
    return dict(TOKEN.findall(head))


def load_run(path: str, suite: str = SUITE) -> Run:
    with open(path, encoding="utf-8") as fh:
        payload = json.load(fh)
    tasks = payload.get("tasks") if isinstance(payload, dict) else None
    if not isinstance(tasks, dict):
        raise InputError(f"{path}: not a results.json (no `tasks` map)")
    prefix = f"{suite}/"
    mine = {key[len(prefix):]: value for key, value in tasks.items() if key.startswith(prefix)}
    if not mine:
        raise InputError(f"{path}: no {suite} task in this run")
    moments: dict[str, Moment] = {}
    stages: set[int] = set()
    for moment_id, task in sorted(mine.items()):
        moments[moment_id] = _moment(path, moment_id, task, stages)
    if len(stages) > 1:
        raise InputError(f"{path}: trials graded at both stage 0 and stage 1; a run is one "
                         "schema, so this is two runs merged")
    return Run(path=path, stage=stages.pop() if stages else 1, moments=moments)


def _moment(path: str, moment_id: str, task: dict, stages: set[int]) -> Moment:
    records = task.get("trial_records")
    if not isinstance(records, list):
        raise InputError(f"{path}: task {moment_id} has no trial_records; the run predates "
                         "per-trial records or was not written by run_capability.py")
    moment: Moment | None = None
    invalid = 0
    for record in records:
        if not record.get("valid"):
            invalid += 1
            continue
        tokens = parse_detail(str(record.get("detail") or ""))
        pred, want, stage = tokens.get("pred"), tokens.get("want"), tokens.get("stage")
        if not _consistent(pred, want, stage) or not _notes_read(tokens):
            raise InputError(f"{path}: task {moment_id} has a valid trial whose detail is "
                             f"not open_loop_judgment.py's: {record.get('detail')!r}")
        stages.add(int(stage))
        if moment is None:
            moment = Moment(want=want)
        elif moment.want != want:
            raise InputError(f"{path}: task {moment_id} was graded against two labels")
        moment.preds.append(pred)
        moment.refusals.append(tokens["refused"])
        moment.constraint_failed += record.get("status") == "constraint_fail"
    if moment is None:
        moment = Moment(want="")          # no valid trial: reported, never scored
    moment.invalid = invalid
    return moment


def _consistent(pred, want, stage) -> bool:
    """A detail this checker could have written: stage 0 names `keep` for a kept moment
    and never a reach; stage 1 names the reach and never `keep`."""
    if pred not in PREDICTIONS or want not in LABELS or stage not in ("0", "1"):
        return False
    kept_names = ("keep",) if stage == "0" else ("when_around", "check_in")
    return pred in ("let_go", "other", *kept_names)


def _notes_read(tokens: dict[str, str]) -> bool:
    """The checker always names the trial's open_loop_note calls: how many, and the last
    refusal (or `none`)."""
    return "refused" in tokens and tokens.get("noted", "").isdigit()


# --- statistics (pure) --------------------------------------------------------

def collapse(label: str) -> str:
    return label if label in ("let_go", "other", "split") else "keep"


def majority(preds: list[str]) -> str:
    if not preds:
        return "split"
    label, count = Counter(preds).most_common(1)[0]
    return label if count * 2 > len(preds) else "split"


def wilson(agreed: int, n: int, z: float = Z95) -> tuple[float, float] | None:
    if n <= 0:
        return None
    p = agreed / n
    denominator = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denominator
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denominator
    return max(0.0, centre - half), min(1.0, centre + half)


def kappa(pairs: list[tuple[str, str]]) -> float | None:
    """Cohen's kappa over (owner, Fermix) pairs; None when chance agreement is total."""
    n = len(pairs)
    if n == 0:
        return None
    observed = sum(1 for want, pred in pairs if want == pred) / n
    wants, preds = Counter(w for w, _p in pairs), Counter(p for _w, p in pairs)
    chance = sum(wants[c] * preds[c] for c in set(wants) | set(preds)) / (n * n)
    if chance >= 1.0:
        return None
    return (observed - chance) / (1 - chance)


def mcnemar_exact(regressed: int, improved: int) -> float:
    """Two-sided exact McNemar p over the discordant moments."""
    n = regressed + improved
    if n == 0:
        return 1.0
    tail = sum(math.comb(n, i) for i in range(min(regressed, improved) + 1)) / 2 ** n
    return min(1.0, 2 * tail)


# --- the report ---------------------------------------------------------------

def owner_labels(stage: int) -> tuple[str, ...]:
    return LABELS if stage == 1 else KEEP_LABELS


def view(want: str, pred: str, stage: int) -> tuple[str, str]:
    return (want, pred) if stage == 1 else (collapse(want), collapse(pred))


def moment_pairs(run: Run) -> dict[str, tuple[str, str]]:
    return {mid: view(m.want, majority(m.preds), run.stage)
            for mid, m in run.moments.items() if m.preds}


def trial_pairs(run: Run) -> list[tuple[str, str]]:
    return [view(m.want, pred, run.stage) for m in run.moments.values() for pred in m.preds]


def worst_pair(stage: int) -> tuple[str, str]:
    return ("let_go", "check_in") if stage == 1 else ("let_go", "keep")


def costliest(pairs, stage: int) -> int:
    return sum(1 for pair in pairs if pair == worst_pair(stage))


def costliest_label(stage: int) -> str:
    if stage == 1:
        return "costliest error (check in where the owner said let it go)"
    return ("costliest error, upper bound (kept where the owner said let it go; reach "
            "is not graded at stage 0)")


def percent(agreed: int, n: int) -> str:
    return f"{agreed}/{n} = {100.0 * agreed / n:.1f}%" if n else "0/0"


def agreement_lines(pairs: list[tuple[str, str]], stage: int, unit: str,
                    with_interval: bool) -> list[str]:
    n = len(pairs)
    agreed = sum(1 for want, pred in pairs if want == pred)
    interval = wilson(agreed, n) if with_interval else None
    k = kappa(pairs)
    lines = [f"  overall agreement: {percent(agreed, n)}"
             + (f"  95% Wilson {100 * interval[0]:.1f}–{100 * interval[1]:.1f}%"
                if interval else ""),
             f"  Cohen's kappa: {'undefined' if k is None else f'{k:.2f}'}"]
    per_label = []
    for label in owner_labels(stage):
        row = [pred for want, pred in pairs if want == label]
        per_label.append(f"{label} {percent(sum(1 for p in row if p == label), len(row))}")
    lines.append("  per label: " + " · ".join(per_label))
    lines.append(f"  {costliest_label(stage)}: {costliest(pairs, stage)} {unit}(s)")
    return lines


def confusion_lines(pairs: list[tuple[str, str]], stage: int) -> list[str]:
    rows = owner_labels(stage)
    columns = [*rows, "other", "split"]
    counts = Counter(pairs)
    width = max(len(c) for c in [*columns, *rows]) + 2
    lines = ["  confusion (rows: the owner; columns: Fermix)",
             "    " + " " * width + "".join(c.rjust(width) for c in columns)]
    for row in rows:
        lines.append("    " + row.ljust(width)
                     + "".join(str(counts[(row, c)]).rjust(width) for c in columns))
    return lines


def report(run: Run) -> list[str]:
    measured = moment_pairs(run)
    unmeasured = sorted(mid for mid, m in run.moments.items() if not m.preds)
    trials = trial_pairs(run)
    invalid = sum(m.invalid for m in run.moments.values())
    stage_text = ("stage 1 (reach graded)" if run.stage == 1
                  else "stage 0 (keep or let go only; no reach column)")
    lines = [f"judgment agreement · {run.path} · {stage_text}",
             f"moments: {len(measured)} measured"
             + (f", {len(unmeasured)} with no valid trial ({', '.join(unmeasured)})"
                if unmeasured else "")
             + f" · trials: {len(trials)} valid, {invalid} invalid (excluded)",
             "", "per moment (majority of its valid trials)"]
    lines += agreement_lines(list(measured.values()), run.stage, "moment",
                             with_interval=True)
    worst = [mid for mid, pair in measured.items() if pair == worst_pair(run.stage)]
    if worst:
        lines.append(f"    at: {', '.join(worst)}")
    lines += confusion_lines(list(measured.values()), run.stage)
    lines += ["", "per trial"]
    lines += agreement_lines(trials, run.stage, "trial", with_interval=False)
    lines += refusal_lines(run)
    failed = sum(m.constraint_failed for m in run.moments.values())
    lines.append(f"  trials that failed the declared constraint (schedule_job ban): {failed}")
    lines += miss_lines(run, measured)
    return lines


def refusal_lines(run: Run) -> list[str]:
    """Trials in which code turned down a note, apart from the model's judgment."""
    refused = unread = refused_misses = 0
    for moment in run.moments.values():
        for pred, token in zip(moment.preds, moment.refusals):
            if token == "none":
                continue
            if token == "unread":
                unread += 1
                continue
            refused += 1
            want, seen = view(moment.want, pred, run.stage)
            refused_misses += want != seen
    lines = [f"  trials where code refused an open_loop_note call: {refused}, "
             f"{refused_misses} of them disagreeing with the owner (a code limit, not a "
             "judgment miss)"]
    if unread:
        lines.append(f"  trials with an open_loop_note call whose result was not recorded: "
                     f"{unread} (refusal unknown; is tool content capture on?)")
    return lines


def trial_text(moment: Moment, pred: str, token: str, stage: int) -> str:
    seen = view(moment.want, pred, stage)[1]
    return seen if token == "none" else f"{seen} (refused: {token})"


def miss_lines(run: Run, measured: dict[str, tuple[str, str]]) -> list[str]:
    misses = [mid for mid, (want, pred) in measured.items() if want != pred]
    if not misses:
        return ["", "misses: none"]
    lines = ["", f"misses ({len(misses)})"]
    for mid in misses:
        moment = run.moments[mid]
        want, _pred = measured[mid]
        trials = ", ".join(trial_text(moment, p, t, run.stage)
                           for p, t in zip(moment.preds, moment.refusals))
        lines.append(f"  {mid}: owner {want} · Fermix {trials}")
    return lines


def compare(run: Run, baseline: Run) -> list[str]:
    stage = min(run.stage, baseline.stage)
    current = _agreement_by_moment(run, stage)
    before = _agreement_by_moment(baseline, stage)
    shared = sorted(set(current) & set(before))
    relabelled = [mid for mid in shared if current[mid][0] != before[mid][0]]
    paired = [mid for mid in shared if mid not in relabelled]
    regressed = [mid for mid in paired if before[mid][1] and not current[mid][1]]
    improved = [mid for mid in paired if current[mid][1] and not before[mid][1]]
    scope = "full labels" if stage == 1 else "keep or let go (a run is stage 0)"
    lines = ["", f"paired comparison with {baseline.path} on {len(paired)} moment(s), {scope}",
             f"  regressed {len(regressed)}"
             + (f" ({', '.join(regressed)})" if regressed else "")
             + f" · improved {len(improved)}"
             + (f" ({', '.join(improved)})" if improved else "")
             + f" · exact McNemar p = {mcnemar_exact(len(regressed), len(improved)):.3f}"]
    if relabelled:
        lines.append(f"  left out, relabelled between the runs: {', '.join(relabelled)}")
    lines.append(f"  {costliest_label(stage)}: baseline "
                 f"{costliest([before[m][2] for m in paired], stage)} → this run "
                 f"{costliest([current[m][2] for m in paired], stage)} moment(s)")
    return lines


def _agreement_by_moment(run: Run, stage: int) -> dict[str, tuple[str, bool, tuple]]:
    out = {}
    for mid, moment in run.moments.items():
        if moment.preds:
            pair = view(moment.want, majority(moment.preds), stage)
            out[mid] = (pair[0], pair[0] == pair[1], pair)
    return out


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("results", help="the run's results.json")
    parser.add_argument("--baseline", help="an earlier run's results.json to pair against")
    parser.add_argument("--suite", default=SUITE, help=f"the suite name (default {SUITE})")
    args = parser.parse_args(argv)
    try:
        run = load_run(args.results, args.suite)
        lines = report(run)
        if args.baseline:
            lines += compare(run, load_run(args.baseline, args.suite))
    except (InputError, OSError, ValueError) as exc:
        print(f"judgment_agreement: {exc}", file=sys.stderr)
        return 2
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
