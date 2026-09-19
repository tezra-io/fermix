#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6,<7"]
# ///
"""Run one capability selection against several CONFIGURATIONS of the daemon.

An arm is a name, seeder arguments and an optional TOML fragment
(`seed_capability_home.py --extra-config`). Each arm gets its own disposable
FERMIX_HOME and its own Opik project, is brought up, scored on the same task
selection, torn down, and compared with the FIRST arm — the control — through the
same paired machinery `run_uplift.py` uses (`evallib/uplift.py`), which refuses
arms whose k, threshold, validity or task set differ rather than pairing whatever
intersects.

    uv run bin/run_arms.py --arms arms/model_choice.example.yaml --dry-run
    uv run bin/run_arms.py --arms arms/model_choice.example.yaml

ARMS RUN ONE AFTER ANOTHER, never together: they share the machine and the
provider's rate limit, and latency here is the driver's wall clock, so a second
daemon competing for both would be measured as the product being slower.

Comparing two CODE REVISIONS is the same mechanism with two checkouts rather than
a second mode in this runner — see benchmark/README.md.

An arm's sweep exits 0 (valid, release gate green) or 5 (VALID and recorded,
release gate RED) — both are measurements, and 5 is what every shipped capability
suite produces today, none of them declaring a safety gate. 2, 3 and 4 are not
measurements and fail the arm.

Exit codes: 0 every arm ran and every comparison was publishable · 2 usage or
arms-file error (nothing was driven) · 3 an arm did not produce a measurement
(daemon, preconditions, a refused selection, or an invalid sweep) · 4 every arm
ran but a comparison was refused as unpairable.
"""
from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
from dataclasses import dataclass, field

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from evallib import uplift  # noqa: E402

EXIT_OK, EXIT_USAGE, EXIT_ARM_FAILED, EXIT_UNPAIRABLE = 0, 2, 3, 4
# The capability runner's exit codes that mean it MEASURED this arm: 0 (valid,
# gate green) and 5 (valid and recorded, release gate RED). A capability sweep
# exits 5 by design — no shipped suite declares a safety gate, so "safety not
# evaluated" fails the gate every time — and reading that as a failed arm
# discarded every arm, which no comparison survives.
MEASURED_EXITS = (0, 5)
DAEMON_SCRIPT = os.path.join(HERE, "capability-daemon.sh")
CAPABILITY_RUNNER = os.path.join(HERE, "run_capability.py")
_PLAN_KEYS = {"title", "description", "suites", "trials", "threshold", "arms"}
_ARM_KEYS = {"name", "description", "seed_args", "extra_config"}
# An arm name becomes a home leaf, an Opik project and a report column, so it is
# kept to one obvious shape rather than sanitized into something else.
_NAME_CHARS = set("abcdefghijklmnopqrstuvwxyz0123456789-")
MAX_ARMS = 6


class PlanError(Exception):
    """Every problem in the arms file, together."""

    def __init__(self, problems: list[str]):
        self.problems = problems
        super().__init__(f"{len(problems)} arms-file problem(s)")


@dataclass(frozen=True)
class Arm:
    name: str
    description: str
    seed_args: tuple[str, ...]
    extra_config: str | None      # absolute path, or None
    home: str                     # disposable FERMIX_HOME (leaf carries 'eval')
    project: str                  # its own Opik project
    results_path: str             # where this arm's per-task results land


@dataclass(frozen=True)
class Plan:
    title: str
    suites: tuple[str, ...]
    trials: int
    threshold: float
    arms: tuple[Arm, ...]
    out_dir: str

    @property
    def control(self) -> Arm:
        return self.arms[0]


@dataclass(frozen=True)
class Step:
    """One shelled-out command. The ONLY thing this runner executes, so a test
    drives the whole flow with a fake that records these."""
    label: str
    argv: tuple[str, ...]
    env: dict[str, str]
    cwd: str


@dataclass
class ArmRun:
    arm: Arm
    steps: list[tuple[str, int]] = field(default_factory=list)   # (label, exit code)
    results: dict | None = None
    error: str | None = None


# --- the arms file ----------------------------------------------------------

def load_plan(path: str, out_dir: str) -> Plan:
    """Parse and validate an arms file into a Plan, or raise with every problem.

    Validated before anything is brought up: an arms run is several daemons and
    several sweeps, and discovering a typo in the third arm's name after two
    metered sweeps is the expensive way to find it."""
    with open(path, "r", encoding="utf-8") as handle:
        doc = yaml.safe_load(handle)
    problems: list[str] = []
    if not isinstance(doc, dict):
        raise PlanError([f"{os.path.basename(path)}: top level must be a map"])
    unknown = sorted(set(doc) - _PLAN_KEYS)
    if unknown:
        problems.append(f"unknown top-level key(s) {unknown} (allowed: {sorted(_PLAN_KEYS)})")
    title = doc.get("title") or os.path.splitext(os.path.basename(path))[0]
    suites = doc.get("suites")
    if not isinstance(suites, list) or not suites or not all(
            isinstance(name, str) and name for name in suites):
        problems.append("`suites` must be a non-empty list of capability suite names")
        suites = []
    trials = doc.get("trials", 5)
    if isinstance(trials, bool) or not isinstance(trials, int) or trials < 1:
        problems.append(f"`trials` must be a positive integer, got {trials!r}")
        trials = 5
    threshold = doc.get("threshold", 1.0)
    if isinstance(threshold, bool) or not isinstance(
            threshold, (int, float)) or not 0 < threshold <= 1:
        problems.append(f"`threshold` must be in (0, 1], got {threshold!r}")
        threshold = 1.0
    arms = _load_arms(doc.get("arms"), os.path.dirname(os.path.abspath(path)),
                      out_dir, problems)
    if problems:
        raise PlanError([f"{os.path.basename(path)}: {problem}" for problem in problems])
    return Plan(title=str(title), suites=tuple(suites), trials=trials,
                threshold=float(threshold), arms=tuple(arms), out_dir=out_dir)


def _load_arms(raw, base_dir: str, out_dir: str, problems: list[str]) -> list[Arm]:
    if not isinstance(raw, list) or len(raw) < 2:
        problems.append("`arms` must be a list of at least 2 arms; the FIRST is the "
                        "control every other arm is compared with")
        return []
    if len(raw) > MAX_ARMS:
        problems.append(f"`arms` holds {len(raw)} arms; at most {MAX_ARMS} run in one "
                        "pass, because they run sequentially and each is a full sweep")
    arms: list[Arm] = []
    seen: set[str] = set()
    for index, entry in enumerate(raw[:MAX_ARMS]):
        arm = _load_arm(entry, index, base_dir, out_dir, seen, problems)
        if arm is not None:
            arms.append(arm)
            seen.add(arm.name)
    return arms


def _load_arm(entry, index: int, base_dir: str, out_dir: str, seen: set[str],
              problems: list[str]) -> Arm | None:
    where = f"arms[{index}]"
    if not isinstance(entry, dict):
        problems.append(f"{where}: must be a map")
        return None
    unknown = sorted(set(entry) - _ARM_KEYS)
    if unknown:
        problems.append(f"{where}: unknown key(s) {unknown} (allowed: {sorted(_ARM_KEYS)})")
    name = entry.get("name")
    if not isinstance(name, str) or not name or set(name) - _NAME_CHARS:
        problems.append(f"{where}: `name` must be lower-case letters, digits and dashes")
        return None
    if name in seen:
        problems.append(f"{where}: duplicate arm name {name!r}")
        return None
    seed_args = entry.get("seed_args", [])
    if not isinstance(seed_args, list) or not all(
            isinstance(item, str) and item and not _has_space(item) for item in seed_args):
        # `capability-daemon.sh` carries them through FERMIX_CAP_SEED_ARGS, which is
        # whitespace-split: an argument with a space would silently become two.
        problems.append(f"{where}: `seed_args` must be whitespace-free strings")
        seed_args = []
    extra = _arm_extra_config(entry.get("extra_config"), base_dir, where, problems)
    return Arm(name=name, description=str(entry.get("description") or ""),
               seed_args=tuple(seed_args), extra_config=extra,
               home=arm_home(name), project=arm_project(name),
               results_path=os.path.join(out_dir, f"{name}.results.json"))


def _arm_extra_config(value, base_dir: str, where: str, problems: list[str]) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value:
        problems.append(f"{where}: `extra_config` must be a path relative to the arms file")
        return None
    resolved = os.path.abspath(os.path.join(base_dir, value))
    if _has_space(resolved):
        problems.append(f"{where}: `extra_config` path must be whitespace-free "
                        "(it travels through FERMIX_CAP_SEED_ARGS): " + resolved)
        return None
    if not os.path.isfile(resolved):
        problems.append(f"{where}: `extra_config` not found: {resolved}")
        return None
    return resolved


def _has_space(text: str) -> bool:
    return any(char.isspace() for char in text)


def arm_home(name: str) -> str:
    """This arm's disposable FERMIX_HOME. The leaf carries `eval`, which every
    runner and the seeder require before they will write to or reset a home."""
    return os.path.expanduser(f"~/.fermix-arm-{name}-eval")


def arm_project(name: str) -> str:
    """Its own Opik project, so one arm's traces are never read as another's."""
    return f"fermix-arm-{name}-eval"


# --- execution --------------------------------------------------------------

def arm_steps(plan: Plan, arm: Arm) -> list[Step]:
    """The three commands one arm runs: seed+start, score, stop."""
    seed_args = list(arm.seed_args)
    if arm.extra_config:
        seed_args += ["--extra-config", arm.extra_config]
    daemon_env = {"FERMIX_CAP_HOME": arm.home, "FERMIX_CAP_PROJECT": arm.project,
                  "FERMIX_CAP_SEED_ARGS": " ".join(seed_args)}
    score_argv = ["uv", "run", CAPABILITY_RUNNER, "--trials", str(plan.trials),
                  "--threshold", str(plan.threshold),
                  "--config-id", f"arm:{arm.name}",
                  "--results-out", arm.results_path,
                  # An arms comparison always names its suites, so loading the
                  # parked ones only makes them selectable — it cannot widen this
                  # run's task set, and the browser corpus lives there precisely
                  # because it must not join the ranking sweep.
                  "--candidates",
                  "--confirm-daemon-isolated", "--confirm-isolated-env", "--confirm-cost"]
    for suite in plan.suites:
        score_argv += ["--suite", suite]
    return [
        Step("up", (DAEMON_SCRIPT, "up"), daemon_env, SKILL_DIR),
        Step("score", tuple(score_argv),
             {"FERMIX_EVAL_HOME": arm.home, "OPIK_PROJECT": arm.project}, SKILL_DIR),
        Step("down", (DAEMON_SCRIPT, "down"), daemon_env, SKILL_DIR),
    ]


def subprocess_runner(step: Step) -> int:
    """The ONE place this runner touches the machine. Injected, so every other
    part of an arms run is exercised without a daemon."""
    env = dict(os.environ)
    env.update(step.env)
    return subprocess.run(step.argv, cwd=step.cwd, env=env, check=False).returncode


def execute_arm(plan: Plan, arm: Arm, runner=subprocess_runner) -> ArmRun:
    """Bring one arm up, score it, and ALWAYS bring it down.

    A daemon left running would answer for the next arm's home probe and quietly
    score the next configuration against this one's process, so teardown runs on
    every path — including the one where the sweep refused to start."""
    run = ArmRun(arm=arm)
    up, score, down = arm_steps(plan, arm)
    try:
        code = runner(up)
        run.steps.append((up.label, code))
        if code != 0:
            run.error = f"daemon did not come up (exit {code})"
            return run
        code = runner(score)
        run.steps.append((score.label, code))
        if code not in MEASURED_EXITS:
            run.error = f"capability sweep exited {code}; no comparable measurement"
            return run
        run.results = _read_results(arm, run)
    finally:
        run.steps.append((down.label, runner(down)))
    return run


def _read_results(arm: Arm, run: ArmRun) -> dict | None:
    """This arm's results, or None with the reason.

    Two things have to hold: the sweep wrote the file (an invalid measurement
    deliberately writes none), and the file says it measured something. `valid`
    travels with the numbers so an arm can never be paired without the pairing
    seeing what the run itself concluded — checked here as well, so a failed arm
    is named where it happened rather than at the comparison."""
    if not os.path.isfile(arm.results_path):
        run.error = (f"the sweep reported a measurement but wrote no results at "
                     f"{arm.results_path}")
        return None
    payload = uplift.load_arm(arm.results_path)
    if payload.get("valid") is not True:
        run.error = (f"the sweep recorded an INVALID measurement "
                     f"(valid={payload.get('valid')!r}); its numbers are evidence "
                     "about the harness")
        return None
    return payload


# --- comparison + report ----------------------------------------------------

@dataclass
class ArmRow:
    """One arm's line in the report. `uplift` is None for the control (nothing to
    compare it with) and for an arm the pairing refused."""
    arm: Arm
    success: float | None
    p50_ms: float | None
    p95_ms: float | None
    main_llm_calls: float | None
    uplift: uplift.UpliftResult | None = None
    problems: list[str] = field(default_factory=list)


def compare_runs(plan: Plan, runs: list[ArmRun]) -> list[ArmRow]:
    """Every arm's row, each compared with the control's measurement."""
    by_name = {run.arm.name: run for run in runs}
    control = by_name.get(plan.control.name)
    rows = []
    for run in runs:
        row = _row(run)
        if run.results is None or control is None or control.results is None:
            rows.append(row)
            continue
        if run.arm.name != plan.control.name:
            _pair(row, run.results, control.results)
        rows.append(row)
    return rows


def _row(run: ArmRun) -> ArmRow:
    payload = run.results
    if payload is None:
        return ArmRow(arm=run.arm, success=None, p50_ms=None, p95_ms=None,
                      main_llm_calls=None,
                      problems=[run.error or "this arm produced no measurement"])
    durations = uplift.pooled_durations_ms(payload)
    tasks = uplift.tasks_success(payload)
    return ArmRow(
        arm=run.arm,
        success=(sum(tasks.values()) / len(tasks)) if tasks else None,
        p50_ms=percentile(durations, 50),
        p95_ms=percentile(durations, 95),
        main_llm_calls=uplift.mean_main_llm_calls(payload),
    )


def _pair(row: ArmRow, arm_payload: dict, control_payload: dict) -> None:
    problems = uplift.compare_arms(arm_payload, control_payload)
    if problems:
        row.problems = problems
        return
    trials = uplift.arm_trial_counts(arm_payload).pop()
    row.uplift = uplift.paired_uplift(uplift.tasks_success(arm_payload),
                                      uplift.tasks_success(control_payload),
                                      threshold=uplift.majority_threshold(trials))


def percentile(values: list[float], pct: int) -> float | None:
    """Nearest-rank percentile over the pooled trial durations; None when the arm
    recorded none (an older arm file), never 0."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, -(-len(ordered) * pct // 100))
    return ordered[rank - 1]


def render_report(plan: Plan, rows: list[ArmRow]) -> str:
    """One markdown report: what each arm scored, and what changed against the
    control. Latency is the DRIVER's wall clock pooled over trials, never a span
    duration, and the turn-economy column is main-model calls per task."""
    lines = [f"# Configuration arms — {plan.title}", "",
             f"Suites: {', '.join(plan.suites)} · {plan.trials} trial(s) per task · "
             f"per-trial pass threshold {plan.threshold}.",
             f"Control: `{plan.control.name}`. Arms ran one after another, on their own "
             "disposable home and Opik project.", "",
             "| arm | success | uplift vs control (95% CI) | McNemar p | p50 ms | p95 ms | "
             "main-model calls/task |", "|---|---|---|---|---|---|---|"]
    for row in rows:
        lines.append("| `{}` | {} | {} | {} | {} | {} | {} |".format(
            row.arm.name, _pct(row.success), _uplift_cell(row), _p_cell(row),
            _num(row.p50_ms), _num(row.p95_ms), _num(row.main_llm_calls, digits=2)))
    lines.append("")
    for row in rows:
        if row.problems:
            lines.append(f"**`{row.arm.name}` is not comparable:**")
            lines += [f"- {problem}" for problem in row.problems]
            lines.append("")
    lines.append("Success is the mean per-task mean_success each arm recorded. The uplift "
                 "column is the paired difference on the tasks BOTH arms ran, with "
                 "Newcombe's interval and the exact McNemar p; a refused pairing is "
                 "listed above rather than reported as a number.")
    return "\n".join(lines) + "\n"


def _pct(value: float | None) -> str:
    return "—" if value is None else f"{value * 100:.1f}%"


def _num(value: float | None, digits: int = 0) -> str:
    return "—" if value is None else f"{value:.{digits}f}"


def _uplift_cell(row: ArmRow) -> str:
    if row.uplift is None:
        return "control" if not row.problems else "refused"
    result = row.uplift
    return (f"{result.uplift * 100:+.1f}pp "
            f"[{result.ci_low * 100:+.1f}, {result.ci_high * 100:+.1f}]")


def _p_cell(row: ArmRow) -> str:
    return "—" if row.uplift is None else f"{row.uplift.p_value:.4g}"


# --- main -------------------------------------------------------------------

def render_plan(plan: Plan) -> str:
    """What a run would do, command by command. `--dry-run` prints exactly this
    and spends nothing: no daemon is started and no provider is called."""
    lines = [f"arms plan: {plan.title}",
             f"  suites: {', '.join(plan.suites)} · trials {plan.trials} · "
             f"threshold {plan.threshold}",
             f"  control: {plan.control.name}",
             f"  reports: {plan.out_dir}"]
    for arm in plan.arms:
        lines.append(f"  - {arm.name}: home={arm.home} project={arm.project}"
                     + (f" extra_config={arm.extra_config}" if arm.extra_config else ""))
        for step in arm_steps(plan, arm):
            env = " ".join(f"{key}={shlex.quote(value)}"
                           for key, value in sorted(step.env.items()))
            lines.append(f"      [{step.label}] {env} "
                         + " ".join(shlex.quote(part) for part in step.argv))
    return "\n".join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Run one capability selection against several daemon configurations")
    parser.add_argument("--arms", required=True, help="arms file (benchmark/arms/<name>.yaml)")
    parser.add_argument("--out", default=None,
                        help="report directory (default: reports/arms/<arms file name>)")
    parser.add_argument("--dry-run", action="store_true",
                        help="plan every arm and spend nothing")
    args = parser.parse_args(argv)

    if not os.path.isfile(args.arms):
        print(f"arms file not found: {args.arms}", file=sys.stderr)
        return EXIT_USAGE
    stem = os.path.splitext(os.path.basename(args.arms))[0]
    out_dir = args.out or os.path.join(SKILL_DIR, "reports", "arms", stem)
    try:
        plan = load_plan(args.arms, out_dir)
    except (OSError, yaml.YAMLError) as exc:
        print(f"arms file unreadable: {exc}", file=sys.stderr)
        return EXIT_USAGE
    except PlanError as exc:
        print("arms file invalid:", file=sys.stderr)
        for problem in exc.problems:
            print(f"  - {problem}", file=sys.stderr)
        return EXIT_USAGE

    if args.dry_run:
        print(render_plan(plan))
        print("\ndry-run OK — nothing was started and nothing was spent.")
        return EXIT_OK
    return _run(plan)


def _run(plan: Plan) -> int:
    os.makedirs(plan.out_dir, exist_ok=True)
    runs = []
    for arm in plan.arms:
        print(f"\n=== arm {arm.name} ({arm.home}) ===", flush=True)
        run = execute_arm(plan, arm)
        if run.error:
            print(f"  arm {arm.name}: {run.error}", file=sys.stderr)
        runs.append(run)
    rows = compare_runs(plan, runs)
    report_path = os.path.join(plan.out_dir, "arms.md")
    with open(report_path, "w", encoding="utf-8") as handle:
        handle.write(render_report(plan, rows))
    print(f"\nreport: {report_path}")
    if any(run.results is None for run in runs):
        print("at least one arm produced no measurement; the report says which.",
              file=sys.stderr)
        return EXIT_ARM_FAILED
    if any(row.problems for row in rows):
        print("every arm ran, but a comparison was refused as unpairable.",
              file=sys.stderr)
        return EXIT_UNPAIRABLE
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
