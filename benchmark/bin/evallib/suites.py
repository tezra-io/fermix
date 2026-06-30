"""Load, validate, and normalize YAML eval suites into typed objects.

Validation is strict: `run_eval.py --dry-run` surfaces every problem at once with
a `file: location` prefix, so a malformed suite never reaches the daemon.
"""

from __future__ import annotations

import glob
import os
import re
from dataclasses import dataclass, field

import yaml

from .scoring import MATCH_METHODS, _parse_number

_SCORE_KEYS = {"match", "expected", "tolerance"}

# expect-key -> accepted python type(s). Drives schema validation + is the single
# source of truth for the vocabulary documented in suites/SCHEMA.md.
EXPECT_SPEC: dict[str, tuple] = {
    "tools_any": (list,),
    "tools_all": (list,),
    "tools_none": (list,),
    "tools_in_order": (list,),
    "min_tool_calls": (int,),
    "max_tool_calls": (int,),
    "min_subagent_spawns": (int,),
    "reply_matches": (str,),
    "reply_not_matches": (str,),
    "main_model_matches": (str,),
    "subagent_model_matches": (str,),
    "status": (str,),
    "no_tool_errors": (bool,),
    "llm_status_ok": (bool,),
    "min_llm_calls": (int,),
    "max_llm_calls": (int,),
    "max_iterations": (int,),
    "max_cost_usd": (int, float),
    "max_duration_ms": (int,),
    "max_tokens": (int,),
}

_ID_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_\-]*$")


class SuiteError(Exception):
    """Aggregates all validation problems found across the loaded suites."""

    def __init__(self, problems: list[str]):
        self.problems = problems
        super().__init__(f"{len(problems)} suite validation problem(s)")


@dataclass
class Turn:
    query: str
    expect: dict = field(default_factory=dict)


@dataclass
class Case:
    id: str
    turns: list[Turn]
    expect: dict                    # case-level gates (graded on final turn)
    rubric: str | None
    judge: bool                     # rubric graded when --judge is on
    timeout_ms: int | None          # per-turn drive timeout (None => cfg default)
    drive: str = "ask"              # ask | telegram_operator (operator-assisted)
    images: list[str] = field(default_factory=list)  # ask-only: absolute paths to --attach
    score_spec: dict | None = None  # capability tier: ground-truth answer scoring (scoring.py)
    checker_spec: dict | None = None  # capability tier: end-state checker scoring (checker.py)


@dataclass
class Scenario:
    id: str
    title: str
    severity: str                   # critical | normal
    tags: list[str]
    cases: list[Case]


@dataclass
class Suite:
    name: str
    title: str
    description: str
    path: str
    scenarios: list[Scenario]

    def turn_count(self) -> int:
        return sum(len(c.turns) for s in self.scenarios for c in s.cases)


# --- validation helpers -----------------------------------------------------

def _validate_expect(expect, where: str, problems: list[str]) -> None:
    if not isinstance(expect, dict):
        problems.append(f"{where}: `expect` must be a map, got {type(expect).__name__}")
        return
    for key, val in expect.items():
        if key not in EXPECT_SPEC:
            problems.append(f"{where}: unknown expect key `{key}` (see suites/SCHEMA.md)")
            continue
        if not isinstance(val, EXPECT_SPEC[key]) or isinstance(val, bool) and EXPECT_SPEC[key] == (int,):
            problems.append(f"{where}: expect `{key}` must be {EXPECT_SPEC[key]}, got {type(val).__name__}")
            continue
        if key in ("tools_any", "tools_all", "tools_none", "tools_in_order"):
            if not all(isinstance(t, str) for t in val):
                problems.append(f"{where}: expect `{key}` must be a list of tool-name strings")
        if key in ("reply_matches", "reply_not_matches", "main_model_matches", "subagent_model_matches"):
            try:
                re.compile(val)
            except re.error as exc:
                problems.append(f"{where}: expect `{key}` is not a valid regex: {exc}")
        if key == "status" and val not in ("ok", "error"):
            problems.append(f"{where}: expect `status` must be 'ok' or 'error', got {val!r}")


def _merge_expect(base: dict, override: dict) -> dict:
    out = dict(base or {})
    out.update(override or {})
    return out


def _validate_score(score, where: str, problems: list[str]) -> None:
    """Validate a case-level `score:` block (capability tier ground-truth scoring).

    A `score:` block declares objective task success: `match` (one of
    MATCH_METHODS) against `expected`. Behavioral suites omit it entirely; the
    capability sweep reads it via scoring.score_answer/2.
    """
    if not isinstance(score, dict):
        problems.append(f"{where}: `score` must be a map, got {type(score).__name__}")
        return
    for key in score:
        if key not in _SCORE_KEYS:
            problems.append(f"{where}: unknown score key `{key}` (allowed: {sorted(_SCORE_KEYS)})")
    method = score.get("match")
    if method not in MATCH_METHODS:
        problems.append(f"{where}: `score.match` must be one of {list(MATCH_METHODS)}, got {method!r}")
    if "expected" not in score:
        problems.append(f"{where}: `score.expected` is required")
    elif method == "numeric" and _parse_number(str(score["expected"])) is None:
        problems.append(f"{where}: `score.expected` must be a number for `match: numeric`, got {score['expected']!r}")
    if "tolerance" in score:
        tol = score["tolerance"]
        if method != "numeric":
            problems.append(f"{where}: `score.tolerance` is only valid for `match: numeric`")
        elif isinstance(tol, bool) or not isinstance(tol, (int, float)) or tol < 0:
            problems.append(f"{where}: `score.tolerance` must be a non-negative number")
    if method == "regex" and isinstance(score.get("expected"), str):
        try:
            re.compile(score["expected"])
        except re.error as exc:
            problems.append(f"{where}: `score.expected` is not a valid regex: {exc}")


_CHECKER_KEYS = {"script", "mode", "seed", "timeout_ms"}


def _validate_checker(chk, where: str, problems: list[str]) -> None:
    """Validate a case-level `checker:` block (capability tier end-state scoring).

    A `checker:` runs a verification script over the sandbox after the turn:
    `{script, mode: exit|json, seed?, timeout_ms?}`. `script`/`seed` are paths
    relative to the harness root; the runner seeds `seed/` into the trial's scoped
    workspace before the turn and runs `script` over it after (checker.py)."""
    if not isinstance(chk, dict):
        problems.append(f"{where}: `checker` must be a map, got {type(chk).__name__}")
        return
    for key in chk:
        if key not in _CHECKER_KEYS:
            problems.append(f"{where}: unknown checker key `{key}` (allowed: {sorted(_CHECKER_KEYS)})")
    if not isinstance(chk.get("script"), str) or not chk.get("script"):
        problems.append(f"{where}: `checker.script` (string path) is required")
    if chk.get("mode") not in ("exit", "json"):
        problems.append(f"{where}: `checker.mode` must be 'exit' or 'json'")
    if "seed" in chk and not isinstance(chk["seed"], str):
        problems.append(f"{where}: `checker.seed` must be a string path")
    if "timeout_ms" in chk:
        t = chk["timeout_ms"]
        if isinstance(t, bool) or not isinstance(t, int) or t <= 0:
            problems.append(f"{where}: `checker.timeout_ms` must be a positive integer")


def _load_one(path: str, problems: list[str]) -> Suite | None:
    fname = os.path.basename(path)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = yaml.safe_load(fh)
    except yaml.YAMLError as exc:
        problems.append(f"{fname}: YAML parse error: {exc}")
        return None
    if not isinstance(raw, dict):
        problems.append(f"{fname}: top level must be a map")
        return None

    name = raw.get("suite")
    title = raw.get("title")
    if not isinstance(name, str) or not _ID_RE.match(name or ""):
        problems.append(f"{fname}: `suite` must be an id-like string")
        name = name or fname
    if not isinstance(title, str) or not title.strip():
        problems.append(f"{fname}: `title` is required")
        title = title or name

    defaults = raw.get("defaults") or {}
    default_expect = defaults.get("expect") or {}
    default_judge = defaults.get("judge", True)
    _validate_expect(default_expect, f"{fname}: defaults.expect", problems)

    def _timeout(val, where):
        if val is None:
            return None
        if isinstance(val, bool) or not isinstance(val, int) or val <= 0:
            problems.append(f"{where}: timeout_ms must be a positive integer")
            return None
        return val

    default_timeout = _timeout(defaults.get("timeout_ms"), f"{fname}: defaults")

    scenarios_raw = raw.get("scenarios")
    if not isinstance(scenarios_raw, list) or not scenarios_raw:
        problems.append(f"{fname}: `scenarios` must be a non-empty list")
        scenarios_raw = []

    scenarios: list[Scenario] = []
    seen_scn: set[str] = set()
    for si, sc in enumerate(scenarios_raw):
        loc = f"{fname}: scenario[{si}]"
        if not isinstance(sc, dict):
            problems.append(f"{loc}: must be a map")
            continue
        sid = sc.get("id")
        if not isinstance(sid, str) or not _ID_RE.match(sid or ""):
            problems.append(f"{loc}: `id` must be an id-like string")
            sid = sid or f"scenario_{si}"
        if sid in seen_scn:
            problems.append(f"{loc}: duplicate scenario id `{sid}`")
        seen_scn.add(sid)
        loc = f"{fname}: {sid}"

        stitle = sc.get("title") or sid
        severity = sc.get("severity", "normal")
        if severity not in ("critical", "normal"):
            problems.append(f"{loc}: `severity` must be 'critical' or 'normal', got {severity!r}")
            severity = "normal"
        tags = sc.get("tags") or []
        if not isinstance(tags, list) or not all(isinstance(t, str) for t in tags):
            problems.append(f"{loc}: `tags` must be a list of strings")
            tags = []

        cases_raw = sc.get("cases")
        if not isinstance(cases_raw, list) or len(cases_raw) < 2:
            problems.append(f"{loc}: needs at least 2 cases (got {len(cases_raw) if isinstance(cases_raw, list) else 0})")
            cases_raw = cases_raw if isinstance(cases_raw, list) else []

        cases: list[Case] = []
        seen_case: set[str] = set()
        for ci, cs in enumerate(cases_raw):
            cloc = f"{loc}.case[{ci}]"
            if not isinstance(cs, dict):
                problems.append(f"{cloc}: must be a map")
                continue
            cid = cs.get("id")
            if not isinstance(cid, str) or not _ID_RE.match(cid or ""):
                problems.append(f"{cloc}: `id` must be an id-like string")
                cid = cid or f"case_{ci}"
            if cid in seen_case:
                problems.append(f"{cloc}: duplicate case id `{cid}`")
            seen_case.add(cid)
            cloc = f"{loc}/{cid}"

            has_query = "query" in cs
            has_turns = "turns" in cs
            if has_query == has_turns:
                problems.append(f"{cloc}: provide exactly one of `query` or `turns`")
            case_expect = _merge_expect(default_expect, cs.get("expect") or {})
            _validate_expect(cs.get("expect") or {}, f"{cloc}.expect", problems)

            turns: list[Turn] = []
            if has_query:
                q = cs.get("query")
                if not isinstance(q, str) or not q.strip():
                    problems.append(f"{cloc}: `query` must be a non-empty string")
                    q = q or ""
                turns = [Turn(query=q, expect={})]
            elif has_turns:
                tr = cs.get("turns")
                if not isinstance(tr, list) or not tr:
                    problems.append(f"{cloc}: `turns` must be a non-empty list")
                    tr = []
                for ti, tt in enumerate(tr):
                    tloc = f"{cloc}.turns[{ti}]"
                    if not isinstance(tt, dict):
                        problems.append(f"{tloc}: must be a map")
                        continue
                    q = tt.get("query")
                    if not isinstance(q, str) or not q.strip():
                        problems.append(f"{tloc}: `query` must be a non-empty string")
                        q = q or ""
                    texp = tt.get("expect") or {}
                    _validate_expect(texp, f"{tloc}.expect", problems)
                    turns.append(Turn(query=q, expect=texp))

            rubric = cs.get("rubric")
            if rubric is not None and not isinstance(rubric, str):
                problems.append(f"{cloc}: `rubric` must be a string")
                rubric = None
            score_spec = cs.get("score")
            if score_spec is not None:
                _validate_score(score_spec, f"{cloc}.score", problems)
            checker_spec = cs.get("checker")
            if checker_spec is not None:
                _validate_checker(checker_spec, f"{cloc}.checker", problems)
            # one scorer per case: score | checker | rubric are mutually exclusive
            present = [k for k in ("score", "checker", "rubric") if cs.get(k) is not None]
            if len(present) > 1:
                problems.append(f"{cloc}: a case may carry only one of score/checker/rubric, got {present}")
            judge = bool(cs.get("judge", default_judge))
            ctimeout = _timeout(cs["timeout_ms"], cloc) if "timeout_ms" in cs else default_timeout

            drive = cs.get("drive", "ask")
            if drive not in ("ask", "telegram_operator"):
                problems.append(f"{cloc}: `drive` must be 'ask' or 'telegram_operator', got {drive!r}")
                drive = "ask"
            if drive == "telegram_operator" and has_turns:
                problems.append(f"{cloc}: `drive: telegram_operator` supports only single-turn `query` cases")

            # `image: <path>` (single) or `images: [<path>...]` (multi-image /
            # album) attach local image(s) via `fermix ask --attach` (automated,
            # no operator) — each path becomes its own --attach. Paths are
            # relative to the suite file's dir; resolved to absolute and
            # existence-checked here so --dry-run fails loud on a missing fixture.
            if "images" in cs:
                raw_images = cs["images"] if isinstance(cs["images"], list) else [cs["images"]]
            elif "image" in cs:
                raw_images = [cs["image"]]
            else:
                raw_images = None

            images = []
            if raw_images is not None:
                if raw_images == []:
                    problems.append(f"{cloc}: `images` must be a non-empty list of paths")
                elif drive != "ask":
                    problems.append(f"{cloc}: `image`/`images` is only supported with drive: ask")
                elif has_turns:
                    problems.append(f"{cloc}: `image`/`images` supports only single-turn `query` cases")
                else:
                    for img in raw_images:
                        if not isinstance(img, str) or not img:
                            problems.append(f"{cloc}: each image path must be a non-empty string")
                            continue

                        resolved = os.path.normpath(os.path.join(os.path.dirname(path), img))
                        if os.path.isfile(resolved):
                            images.append(resolved)
                        else:
                            problems.append(f"{cloc}: image file not found: {img} (resolved {resolved})")

            cases.append(Case(id=cid, turns=turns, expect=case_expect, rubric=rubric,
                              judge=judge, timeout_ms=ctimeout, drive=drive, images=images,
                              score_spec=score_spec, checker_spec=checker_spec))

        scenarios.append(Scenario(id=sid, title=stitle, severity=severity, tags=tags, cases=cases))

    return Suite(name=name, title=title, description=raw.get("description", "") or "",
                 path=path, scenarios=scenarios)


def load_all(suites_dir: str, include_dangerous: bool = False) -> list[Suite]:
    """Load + validate suites/*.yaml.

    Suites under suites/dangerous/ are intentionally excluded from normal runs
    (--all, --dry-run) and only loaded when include_dangerous=True (--dangerous
    flag).  They exercise the sandbox by issuing commands that would cause real
    harm if the sandbox failed — never run in a shared or production environment.
    """
    patterns = [os.path.join(suites_dir, "*.yaml")]
    if include_dangerous:
        patterns.append(os.path.join(suites_dir, "dangerous", "*.yaml"))

    problems: list[str] = []
    suites: list[Suite] = []
    seen_names: dict[str, str] = {}
    for pattern in patterns:
        for path in sorted(glob.glob(pattern)):
            suite = _load_one(path, problems)
            if suite is None:
                continue
            if suite.name in seen_names:
                problems.append(f"{os.path.basename(path)}: duplicate suite name `{suite.name}` "
                                f"(also in {os.path.basename(seen_names[suite.name])})")
            seen_names[suite.name] = path
            suites.append(suite)
    if problems:
        raise SuiteError(problems)
    if not suites:
        raise SuiteError([f"no *.yaml suites found in {suites_dir}"])
    return suites
