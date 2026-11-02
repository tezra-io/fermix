"""The desktop corpus file (`suites/desktop/*.yaml`): load, validate, render.

One task list serves every fixture. A task's query may name `{toolkit}` and
`{window}`, the labels that fixture shows; its oracle clauses name controls as
`{tk}.<family>`, `{tk}` being the fixture's prefix (`gtk3`, `qt`, `appkit`), or
by a shared name such as `document.save`. `load` renders every task for every
fixture before it returns, so a clause naming a control some fixture does not
record fails at load (and in `--dry-run`) on any host, not mid-run on one. A
task with `platforms` is for those platforms' fixtures alone: a refusal only
one platform's fixtures can produce is never planned on the other.

Every task carries `risk: desktop_input`, the suite's, and nothing else is
accepted: this corpus injects real input and captures the screen, and a lower
risk class would let some other runner select it.
"""

from __future__ import annotations

import string
from dataclasses import dataclass, field

import yaml

from desktoplib import cu_trace, oracle

RISK = "desktop_input"
MIN_TASKS = 24
REQUIRED_VERBS = frozenset({
    "press", "set_value", "type", "select", "toggle", "expand", "collapse", "scroll_to",
    "focus", "wait_for", "dialog", "menu", "ambiguity", "refusal", "secure"})
VERBS = REQUIRED_VERBS | {"form"}
PLATFORMS = ("linux", "macos")
QUERY_FIELDS = frozenset({"toolkit", "window"})
CONTROL_FIELDS = frozenset({"tk"})
LAUNCH_FIELDS = frozenset({"fixture_dir", "fixture_app", "state_file"})
_SUITE_KEYS = {"suite", "title", "risk", "description", "defaults", "fixtures", "controls",
               "tasks"}
_TASK_KEYS = {"id", "verb", "query", "oracle", "expect_refusal", "timeout_ms", "risk",
              "platforms", "sanity_route"}
_FIXTURE_KEYS = {"platform", "prefix", "toolkit", "window", "launch", "env"}


class CorpusError(ValueError):
    """Every problem found in a corpus file, reported together."""

    def __init__(self, problems: list[str]):
        self.problems = list(problems)
        super().__init__("; ".join(self.problems))


@dataclass(frozen=True)
class Fixture:
    name: str
    platform: str
    prefix: str
    toolkit: str
    window: str
    launch: tuple[str, ...]
    env: dict = field(default_factory=dict)

    def controls(self, families: tuple[str, ...], shared: tuple[str, ...]) -> frozenset[str]:
        return frozenset({f"{self.prefix}.{family}" for family in families} | set(shared))


@dataclass(frozen=True)
class Task:
    id: str
    verb: str
    query: str
    oracle: tuple[dict, ...]
    expect_refusal: str | None
    timeout_ms: int
    risk: str
    # The platforms whose fixtures can produce this task; every platform unless
    # the task says otherwise (a refusal only one platform's fixtures answer).
    platforms: tuple[str, ...] = PLATFORMS
    # A labelled sanity case: the route (`cu_trace.ROUTES`) a computer-use row in
    # the turn must take, for a task whose fixture state any route could produce.
    sanity_route: str | None = None


@dataclass(frozen=True)
class Corpus:
    path: str
    suite: str
    title: str
    risk: str
    fixtures: dict
    families: tuple[str, ...]
    shared: tuple[str, ...]
    tasks: tuple[Task, ...]


@dataclass(frozen=True)
class RenderedTask:
    task: Task
    fixture: str
    query: str
    clauses: tuple[oracle.Clause, ...]


# --- loading -------------------------------------------------------------------

def load(path: str) -> Corpus:
    raw = _read(path)
    problems: list[str] = []
    unknown = set(raw) - _SUITE_KEYS
    if unknown:
        problems.append(f"unknown top-level key(s) {sorted(unknown)}")
    risk = raw.get("risk")
    if risk != RISK:
        problems.append(f"`risk` must be {RISK} (a desktop task injects input and captures "
                        f"the screen); it is {risk!r}")
    fixtures = _fixtures(raw.get("fixtures"), problems)
    families, shared = _controls(raw.get("controls"), problems)
    tasks = _tasks(raw.get("tasks"), _default_timeout(raw, problems), problems)
    _coverage(tasks, problems)
    if problems:
        raise CorpusError(problems)
    corpus = Corpus(path=path, suite=str(raw.get("suite") or ""), title=str(raw.get("title") or ""),
                    risk=RISK, fixtures=fixtures, families=families, shared=shared,
                    tasks=tuple(tasks))
    render_all(corpus, sorted(fixtures))
    return corpus


def _read(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            raw = yaml.safe_load(handle)
    except (OSError, yaml.YAMLError) as exc:
        raise CorpusError([f"cannot read {path}: {exc}"]) from exc
    if not isinstance(raw, dict):
        raise CorpusError([f"{path}: the top level must be a map"])
    return raw


def _default_timeout(raw: dict, problems: list[str]) -> int:
    value = (raw.get("defaults") or {}).get("timeout_ms", 600_000)
    if not _positive_whole(value):
        problems.append("`defaults.timeout_ms` must be a positive whole number")
        return 1
    return value


def _positive_whole(value) -> bool:
    return not isinstance(value, bool) and isinstance(value, int) and value > 0


def _fields(template: str) -> set[str]:
    return {name for _text, name, _spec, _conv in string.Formatter().parse(template) if name}


def _fixtures(raw, problems: list[str]) -> dict:
    if not isinstance(raw, dict) or not raw:
        problems.append("`fixtures` must name at least one fixture")
        return {}
    fixtures = {}
    for name, spec in raw.items():
        fixture = _fixture(str(name), spec, problems)
        if fixture is not None:
            fixtures[fixture.name] = fixture
    return fixtures


def _fixture(name: str, spec, problems: list[str]) -> Fixture | None:
    where = f"fixture {name}"
    if not isinstance(spec, dict):
        problems.append(f"{where}: must be a map")
        return None
    unknown = set(spec) - _FIXTURE_KEYS
    missing = [key for key in ("platform", "prefix", "toolkit", "window", "launch")
               if not spec.get(key)]
    if unknown or missing:
        problems.append(f"{where}: unknown key(s) {sorted(unknown)}, missing {missing}")
        return None
    if spec["platform"] not in PLATFORMS:
        problems.append(f"{where}: platform must be one of {', '.join(PLATFORMS)}")
    launch = spec["launch"]
    if not isinstance(launch, list) or not all(isinstance(part, str) for part in launch):
        problems.append(f"{where}: `launch` must be a list of strings")
        return None
    used = set().union(*(_fields(part) for part in launch))
    if not used <= LAUNCH_FIELDS or "state_file" not in used:
        problems.append(f"{where}: `launch` may name only {sorted(LAUNCH_FIELDS)} and must "
                        "pass {state_file}")
    env = spec.get("env") or {}
    if not all(isinstance(k, str) and isinstance(v, str) for k, v in env.items()):
        problems.append(f"{where}: `env` must map names to quoted strings")
    return Fixture(name=name, platform=spec["platform"], prefix=str(spec["prefix"]),
                   toolkit=str(spec["toolkit"]), window=str(spec["window"]),
                   launch=tuple(launch), env=dict(env))


def _controls(raw, problems: list[str]) -> tuple[tuple[str, ...], tuple[str, ...]]:
    if not isinstance(raw, dict):
        problems.append("`controls` must list `families` and `shared`")
        return (), ()
    families, shared = raw.get("families") or [], raw.get("shared") or []
    if not all(isinstance(n, str) and n for n in [*families, *shared]) or not families:
        problems.append("`controls.families` and `controls.shared` must be lists of names")
    return tuple(families), tuple(shared)


def _tasks(raw, timeout_ms: int, problems: list[str]) -> list[Task]:
    if not isinstance(raw, list):
        problems.append("`tasks` must be a list")
        return []
    tasks, seen = [], set()
    for index, spec in enumerate(raw, start=1):
        task = _task(index, spec, timeout_ms, problems)
        if task is None:
            continue
        if task.id in seen:
            problems.append(f"duplicate task id {task.id!r}")
        seen.add(task.id)
        tasks.append(task)
    return tasks


def _task(index: int, spec, timeout_ms: int, problems: list[str]) -> Task | None:
    if not isinstance(spec, dict) or not isinstance(spec.get("id"), str):
        problems.append(f"task {index}: must be a map with an `id`")
        return None
    where = f"task {spec['id']}"
    before = len(problems)
    unknown = set(spec) - _TASK_KEYS
    if unknown:
        problems.append(f"{where}: unknown key(s) {sorted(unknown)}")
    if spec.get("risk", RISK) != RISK:
        problems.append(f"{where}: every desktop task carries risk {RISK}, not "
                        f"{spec.get('risk')!r}")
    if spec.get("verb") not in VERBS:
        problems.append(f"{where}: verb {spec.get('verb')!r} is not one of {sorted(VERBS)}")
    query = spec.get("query")
    if not isinstance(query, str) or not query.strip():
        problems.append(f"{where}: needs a `query`")
    elif not _fields(query) <= QUERY_FIELDS:
        problems.append(f"{where}: query placeholder(s) {sorted(_fields(query) - QUERY_FIELDS)} "
                        f"are not one of {sorted(QUERY_FIELDS)}")
    if not _positive_whole(spec.get("timeout_ms", timeout_ms)):
        problems.append(f"{where}: `timeout_ms` must be a positive whole number")
    refusal = spec.get("expect_refusal")
    if refusal is not None and refusal not in cu_trace.TYPED_CODE_ANCHORS:
        problems.append(f"{where}: `expect_refusal` names {refusal!r}, which is not one of "
                        f"the codes the classifier recognises on a row "
                        f"{sorted(cu_trace.TYPED_CODE_ANCHORS)}")
    _check_oracle(where, spec.get("oracle"), problems)
    route = spec.get("sanity_route")
    if route is not None and route not in cu_trace.ROUTES:
        problems.append(f"{where}: `sanity_route` names {route!r}, which is not one of "
                        f"{', '.join(cu_trace.ROUTES)}")
    platforms = spec.get("platforms", list(PLATFORMS))
    if (not isinstance(platforms, list) or not platforms
            or not set(platforms) <= set(PLATFORMS)):
        problems.append(f"{where}: `platforms` must be a non-empty list of "
                        f"{', '.join(PLATFORMS)}; it is {platforms!r}")
    if len(problems) > before:
        return None
    return Task(id=spec["id"], verb=spec["verb"], query=" ".join(query.split()),
                oracle=tuple(spec["oracle"]), expect_refusal=spec.get("expect_refusal"),
                timeout_ms=spec.get("timeout_ms", timeout_ms), risk=RISK,
                platforms=tuple(p for p in PLATFORMS if p in platforms), sanity_route=route)


def _check_oracle(where: str, clauses, problems: list[str]) -> None:
    if not isinstance(clauses, list) or not clauses:
        problems.append(f"{where}: needs a non-empty `oracle`")
        return
    for number, raw in enumerate(clauses, start=1):
        try:
            parsed = oracle.parse_clause(raw, f"{where} oracle clause {number}")
        except ValueError as exc:
            problems.append(str(exc))
            continue
        if not _fields(parsed.control) <= CONTROL_FIELDS:
            problems.append(f"{where} oracle clause {number}: a control may name only {{tk}}")


def _coverage(tasks: list[Task], problems: list[str]) -> None:
    if len(tasks) < MIN_TASKS:
        problems.append(f"the corpus needs at least {MIN_TASKS} tasks; it has {len(tasks)}")
    missing = REQUIRED_VERBS - {task.verb for task in tasks}
    if missing:
        problems.append(f"no task covers verb(s) {', '.join(sorted(missing))}")


# --- rendering -------------------------------------------------------------------

def render(corpus: Corpus, task: Task, fixture_name: str) -> RenderedTask:
    """The task as asked of one fixture. Raises CorpusError when the task is not
    for that fixture's platform, or a clause names a control it does not record."""
    fixture = corpus.fixtures[fixture_name]
    if fixture.platform not in task.platforms:
        raise CorpusError([f"task {task.id} is for {', '.join(task.platforms)}; the "
                           f"{fixture_name} fixture runs on {fixture.platform}"])
    allowed = fixture.controls(corpus.families, corpus.shared)
    clauses, problems = [], []
    for number, raw in enumerate(task.oracle, start=1):
        control = raw["control"].format(tk=fixture.prefix)
        if control not in allowed:
            problems.append(f"task {task.id} on {fixture_name}: oracle clause {number} names "
                            f"{control!r}, which the {fixture_name} fixture does not record")
            continue
        clauses.append(oracle.parse_clause({**raw, "control": control}, f"task {task.id}"))
    if problems:
        raise CorpusError(problems)
    query = task.query.format(toolkit=fixture.toolkit, window=fixture.window)
    return RenderedTask(task=task, fixture=fixture_name, query=query, clauses=tuple(clauses))


def render_all(corpus: Corpus, fixture_names: list[str]) -> list[RenderedTask]:
    """Every task for every named fixture on that task's platforms (a task for
    another platform is not planned there); every problem reported together."""
    rendered, problems = [], []
    pairs = ((name, task) for name in fixture_names for task in corpus.tasks
             if corpus.fixtures[name].platform in task.platforms)
    for name, task in pairs:
        try:
            rendered.append(render(corpus, task, name))
        except CorpusError as exc:
            problems.extend(exc.problems)
    if problems:
        raise CorpusError(problems)
    return rendered


def launch_argv(fixture: Fixture, *, fixture_dir: str, fixture_app: str,
                state_file: str) -> list[str]:
    values = {"fixture_dir": fixture_dir, "fixture_app": fixture_app, "state_file": state_file}
    return [part.format(**values) for part in fixture.launch]
