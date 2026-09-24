#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Run the TLA+ specs under tla/specs/ and compare each verdict with its expectation.

A spec is a hand-written description of Fermix code. Its `.tla` file pins every
source file it describes by content hash:

    \\* SOURCE: apps/.../queue.ex @ 3f2a9c1b7e44
    \\* SOURCE: apps/.../memory/repo.ex#claim_due_job,@harness_active_status_sql @ 9b1e...

A `#name,...` suffix pins only those functions (every clause) and module
attributes instead of the whole file, for large shared files. When a pinned file
or function changes, the spec is STALE: its results describe code that no longer
exists. Re-read the spec against the code, update it, then `--repin` it. Re-pin
only against committed code: `--repin` refuses a SOURCE file with uncommitted
changes.

Every check is one TLC config (`specs/<name>/checks/NN_<what>.cfg`) whose header
says what TLC must find:

    \\* EXPECT: holds                           the property holds within the bounds
    \\* EXPECT: violated <ID> [len=<N>]         a recorded finding: TLC breaks the
                                               property (an invariant's shortest
                                               counterexample has exactly N states)
    \\* EXPECT: mechanism <Const> covers <chk>  with the code's mechanism <Const> switched
                                               off, the property <chk> relies on breaks
    \\* EXPECT: reachable                       a witness: a scenario is explored
    \\* CHECKS: one sentence saying what the check means

Every property a `holds` check proves must be covered by a `mechanism` check, so no
pass is vacuous. A check whose verdict matches prints `ok`; anything else prints
`FAIL`. Full TLC output (counterexamples included) goes to `tla/out/<spec>/`.

Usage:
    tla/bin/check.py [SPEC ...]         run every spec, or the named ones
    tla/bin/check.py --list [SPEC ...]  list checks and staleness (no Java)
    tla/bin/check.py --repin SPEC ...   re-pin SOURCE hashes after re-reading the code
    tla/bin/check.py --report [SPEC ...] run, then write tla/out/report.md and report.json:
                                        each finding's counterexample as code-referenced
                                        steps, for whoever fixes it

Exit status: 0 all ok and nothing stale, 1 a FAIL or a stale spec, 2 a malformed
spec or a missing tool. TLC is pinned (TOOLS_*) and cached under
$XDG_CACHE_HOME/fermix (default ~/.cache/fermix), verified by sha256 on every run.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import trace_report

TOOLS_VERSION = "v1.7.4"
TOOLS_URL = f"https://github.com/tlaplus/tlaplus/releases/download/{TOOLS_VERSION}/tla2tools.jar"
TOOLS_SHA256 = "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
MIN_JAVA_MAJOR = 11
DEFAULT_TIMEOUT_S = 120
PIN_LENGTH = 12
FINGERPRINT_INDEX = 0

TLA_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = TLA_DIR.parent
SPECS_DIR = TLA_DIR / "specs"
OUT_DIR = TLA_DIR / "out"

TYPE_INVARIANT = "TypeOK"
CFG_KEYWORDS = {
    "SPECIFICATION", "INIT", "NEXT", "CONSTANT", "CONSTANTS", "INVARIANT", "INVARIANTS",
    "PROPERTY", "PROPERTIES", "CHECK_DEADLOCK", "SYMMETRY", "VIEW", "CONSTRAINT",
    "CONSTRAINTS", "ACTION_CONSTRAINT", "ACTION_CONSTRAINTS", "ALIAS", "POSTCONDITION",
}
KEYWORD_ALIASES = {
    "CONSTANTS": "CONSTANT", "INVARIANTS": "INVARIANT", "PROPERTIES": "PROPERTY",
    "CONSTRAINTS": "CONSTRAINT", "ACTION_CONSTRAINTS": "ACTION_CONSTRAINT",
}
SOURCE_LINE = re.compile(r"^\\\*[ \t]*SOURCE:[ \t]*(\S+)(?:[ \t]*@[ \t]*(\S+))?[ \t]*$", re.M)


class CheckError(Exception):
    """A malformed spec or check, or a missing tool: the run cannot be trusted."""


@dataclass(frozen=True)
class Expectation:
    kind: str  # holds | violated | mechanism | reachable
    finding: str | None = None
    length: int | None = None
    mechanism: str | None = None
    covers: str | None = None


@dataclass(frozen=True)
class Check:
    spec: str
    name: str
    cfg: Path
    expect: Expectation
    summary: str
    invariants: tuple[str, ...]
    properties: tuple[str, ...]
    constants: dict[str, str]
    deadlock_off: bool
    symmetry: bool

    @property
    def targets(self) -> tuple[str, ...]:
        return tuple(p for p in self.invariants + self.properties if p != TYPE_INVARIANT)


@dataclass(frozen=True)
class Source:
    path: str
    functions: tuple[str, ...]
    pin: str | None

    @property
    def label(self) -> str:
        return f"{self.path}#{','.join(self.functions)}" if self.functions else self.path


@dataclass(frozen=True)
class Spec:
    name: str
    tla: Path
    sources: tuple[Source, ...]
    checks: tuple[Check, ...]

    def stale(self) -> list[str]:
        return [s.label for s in self.sources if s.pin != source_pin(s)]


@dataclass(frozen=True)
class Verdict:
    kind: str  # holds | invariant | temporal | deadlock | error | timeout
    detail: str = ""
    states: str = ""
    length: int | None = None


# --- parsing (pure) ---------------------------------------------------------


def cfg_tokens(text: str) -> list[str]:
    text = re.sub(r"\(\*.*?\*\)", " ", text, flags=re.S)
    text = re.sub(r"\\\*.*", "", text)
    return re.findall(r"\{[^}]*\}|<-|=|[^\s=]+", text)


def parse_cfg(text: str) -> tuple[dict[str, tuple[str, ...]], dict[str, str]]:
    """TLC config -> ({keyword: names}, {constant: value})."""
    sections: dict[str, list[str]] = {}
    constants: dict[str, str] = {}
    tokens = cfg_tokens(text)
    keyword = None
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token in CFG_KEYWORDS:
            keyword = KEYWORD_ALIASES.get(token, token)
            sections.setdefault(keyword, [])
        elif keyword == "CONSTANT" and i + 2 < len(tokens) and tokens[i + 1] in ("=", "<-"):
            constants[token] = " ".join(tokens[i + 2].split())
            i += 2
        elif keyword is not None:
            sections[keyword].append(token)
        i += 1
    return {k: tuple(v) for k, v in sections.items()}, constants


def parse_expectation(line: str, where: str) -> Expectation:
    words = line.split()
    kind = words[0] if words else ""
    if kind in ("holds", "reachable") and len(words) == 1:
        return Expectation(kind)
    finding_ok = len(words) > 1 and re.fullmatch(r"[A-Z][A-Z0-9]*-\d+", words[1]) is not None
    if kind == "violated" and finding_ok and len(words) == 2:
        return Expectation(kind, finding=words[1])
    if kind == "violated" and finding_ok and len(words) == 3 and re.fullmatch(r"len=\d+", words[2]):
        return Expectation(kind, finding=words[1], length=int(words[2][4:]))
    if kind == "mechanism" and len(words) == 4 and words[2] == "covers":
        return Expectation(kind, mechanism=words[1], covers=words[3])
    raise CheckError(
        f"{where}: EXPECT must be 'holds', 'reachable', 'violated <ID> [len=<N>]' "
        f"or 'mechanism <Const> covers <check>', got '{line}'"
    )


def parse_check(spec: str, cfg: Path) -> Check:
    text = cfg.read_text()
    where = f"{spec}/{cfg.name}"
    expect_line = re.search(r"^\\\*\s*EXPECT:\s*(.+?)\s*$", text, re.M)
    checks_line = re.search(r"^\\\*\s*CHECKS:\s*(.+?)\s*$", text, re.M)
    if not expect_line or not checks_line:
        raise CheckError(f"{where}: missing '\\* EXPECT:' or '\\* CHECKS:' header line")
    sections, constants = parse_cfg(text)
    check = Check(
        spec=spec,
        name=cfg.stem,
        cfg=cfg,
        expect=parse_expectation(expect_line.group(1), where),
        summary=checks_line.group(1),
        invariants=sections.get("INVARIANT", ()),
        properties=sections.get("PROPERTY", ()),
        constants=constants,
        deadlock_off=sections.get("CHECK_DEADLOCK", ()) == ("FALSE",),
        symmetry="SYMMETRY" in sections,
    )
    validate_check(check, where)
    return check


def validate_check(check: Check, where: str) -> None:
    if check.deadlock_off:
        raise CheckError(f"{where}: CHECK_DEADLOCK FALSE hides wedges; give the spec a Done step instead")
    if check.symmetry and check.properties:
        raise CheckError(f"{where}: SYMMETRY with a temporal PROPERTY is unsound in TLC")
    if check.expect.kind != "holds" and len(check.targets) != 1:
        raise CheckError(f"{where}: a '{check.expect.kind}' check names exactly one property besides {TYPE_INVARIANT}")
    if check.expect.kind == "holds" and not check.targets:
        raise CheckError(f"{where}: a 'holds' check names at least one property besides {TYPE_INVARIANT}")
    if check.expect.kind == "violated":
        validate_length_pin(check, where)


def validate_length_pin(check: Check, where: str) -> None:
    """Breadth-first search finds an invariant's shortest counterexample, so its
    length is stable and pinned. A temporal property's lasso is not the shortest
    and varies with the fingerprint, so pinning it would only raise false alarms."""
    temporal = check.targets[0] in check.properties
    if temporal and check.expect.length is not None:
        raise CheckError(f"{where}: do not pin len= for a temporal property; TLC's lasso is not the shortest")
    if not temporal and check.expect.length is None:
        raise CheckError(f"{where}: pin len=<N> for an invariant violation (its shortest counterexample)")


def validate_mechanisms(spec: str, checks: tuple[Check, ...]) -> None:
    """Each mechanism check differs from the holds check it covers only in its
    mechanism switch, and every property a holds check proves is covered."""
    by_name = {c.name: c for c in checks}
    covered: set[tuple[str, str]] = set()
    for check in (c for c in checks if c.expect.kind == "mechanism"):
        where = f"{spec}/{check.name}"
        base = by_name.get(check.expect.covers)
        if base is None or base.expect.kind != "holds":
            raise CheckError(f"{where}: covers '{check.expect.covers}', which is not a holds check in this spec")
        switch = check.expect.mechanism
        if check.constants.get(switch) != "FALSE" or base.constants.get(switch) != "TRUE":
            raise CheckError(f"{where}: must set {switch} = FALSE, and {base.name} must set it TRUE")
        others = {k: v for k, v in check.constants.items() if k != switch}
        if others != {k: v for k, v in base.constants.items() if k != switch}:
            raise CheckError(f"{where}: constants other than {switch} must equal {base.name}'s")
        target = check.targets[0]
        if target not in base.targets:
            raise CheckError(f"{where}: {target} is not a property of {base.name}")
        covered.add((base.name, target))
    for check in (c for c in checks if c.expect.kind == "holds"):
        missing = [t for t in check.targets if (check.name, t) not in covered]
        if missing:
            raise CheckError(f"{spec}/{check.name}: no mechanism check covers {', '.join(missing)}")


def validate_findings_documented(spec_dir: Path, checks: tuple[Check, ...]) -> None:
    """Every finding a check expects has its write-up (`### <ID>:`) in the README,
    so a report never hands someone a counterexample with no explanation."""
    readme = spec_dir / "README.md"
    sections = trace_report.finding_sections(readme.read_text()) if readme.is_file() else {}
    missing = sorted({c.expect.finding for c in checks if c.expect.finding and c.expect.finding not in sections})
    if missing:
        raise CheckError(f"{spec_dir.name}: README.md has no '### <ID>:' section for {', '.join(missing)}")


def parse_sources(tla_text: str) -> tuple[Source, ...]:
    sources = []
    for token, pin in SOURCE_LINE.findall(tla_text):
        path, _, names = token.partition("#")
        functions = tuple(n for n in names.split(",") if n)
        sources.append(Source(path, functions, pin or None))
    return tuple(sources)


def pin_of(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:PIN_LENGTH]


def source_pin(source: Source) -> str:
    """Content pin of a whole file, or of just the named definitions in it."""
    text = (REPO_ROOT / source.path).read_text()
    if not source.functions:
        return pin_of(text.encode())
    parts = []
    for name in source.functions:
        found = elixir_definition(text, name)
        if not found:
            raise CheckError(f"{source.path} no longer defines {name}; update the spec's SOURCE line")
        parts.append(found)
    return pin_of("\n\0\n".join(parts).encode())


DEF_KEYWORDS = ("def", "defp", "defmacro", "defmacrop")
BLOCK_CONTINUATIONS = {"rescue", "catch", "else", "after"}


def elixir_definition(text: str, name: str) -> str:
    """Every clause of function `name`, or the module attribute `@name`, as text.
    A clause runs from its `def` line through its `end` at the same indentation
    (or, for a `, do:` one-liner, through its deeper-indented continuation lines);
    `rescue`/`catch`/`else`/`after` at that indentation continue the block."""
    lines = text.splitlines()
    if name.startswith("@"):
        head = re.compile(rf"^(\s*){re.escape(name)}\b")
    else:
        head = re.compile(rf"^(\s*)(?:{'|'.join(DEF_KEYWORDS)})\s+{re.escape(name)}(?=[\s(,]|$)")
    clauses = []
    for i, line in enumerate(lines):
        match = head.match(line)
        if match:
            clauses.append("\n".join(definition_lines(lines, i, len(match.group(1)))))
    return "\n".join(clauses)


def definition_lines(lines: list[str], start: int, indent: int) -> list[str]:
    """Lines of one definition. Inside a `\"\"\"` heredoc every line belongs to it,
    whatever its indentation (heredoc content often sits at the def's own level)."""
    taken = [lines[start]]
    in_heredoc = lines[start].count('"""') % 2 == 1
    for line in lines[start + 1:]:
        stripped = line.strip()
        depth = len(line) - len(line.lstrip())
        if in_heredoc or not stripped or depth > indent:
            taken.append(line)
            if line.count('"""') % 2 == 1:
                in_heredoc = not in_heredoc
        elif stripped == "end":
            taken.append(line)
            break
        elif stripped in BLOCK_CONTINUATIONS:
            taken.append(line)
        else:
            break
    while taken and not taken[-1].strip():
        taken.pop()
    return taken


def repin_text(tla_text: str, pins: dict[str, str]) -> str:
    return SOURCE_LINE.sub(lambda m: f"\\* SOURCE: {m.group(1)} @ {pins[m.group(1)]}", tla_text)


def load_spec(spec_dir: Path) -> Spec:
    tlas = sorted(spec_dir.glob("*.tla"))
    if len(tlas) != 1:
        raise CheckError(f"{spec_dir.name}: expected exactly one .tla file, found {len(tlas)}")
    sources = parse_sources(tlas[0].read_text())
    if not sources:
        raise CheckError(f"{spec_dir.name}: the spec lists no '\\* SOURCE:' lines")
    missing = [s.path for s in sources if not (REPO_ROOT / s.path).is_file()]
    if missing:
        raise CheckError(f"{spec_dir.name}: SOURCE files no longer exist: {', '.join(missing)}")
    for source in sources:
        source_pin(source)  # fails loud if a pinned function no longer exists
    cfgs = sorted((spec_dir / "checks").glob("*.cfg"))
    if not cfgs:
        raise CheckError(f"{spec_dir.name}: no checks/*.cfg files")
    checks = tuple(parse_check(spec_dir.name, cfg) for cfg in cfgs)
    validate_mechanisms(spec_dir.name, checks)
    validate_findings_documented(spec_dir, checks)
    return Spec(name=spec_dir.name, tla=tlas[0], sources=sources, checks=checks)


def parse_tlc_output(output: str) -> Verdict:
    # TLC prints running "Progress(...)" lines before the final count; the last
    # "distinct states found" is the total.
    counts = re.findall(r"([\d,]+) distinct states found", output)
    states = counts[-1] if counts else ""
    length = len(re.findall(r"^State \d+:", output, re.M)) or None
    invariant = re.search(r"^Error: Invariant (\S+) is violated", output, re.M)
    if invariant:
        return Verdict("invariant", invariant.group(1), states, length)
    if re.search(r"^Error: (Temporal properties were violated|Action property \S+ is violated)", output, re.M):
        return Verdict("temporal", "", states, length)
    if re.search(r"^Error: Deadlock reached", output, re.M):
        return Verdict("deadlock", "", states, length)
    if "Model checking completed. No error has been found." in output:
        return Verdict("holds", "", states)
    error = re.search(r"^(?:Error:|\*\*\*).*$", output, re.M)
    return Verdict("error", error.group(0) if error else "TLC produced no verdict", states)


def judge(check: Check, verdict: Verdict) -> tuple[bool, str]:
    """Compare a verdict with the check's expectation: (ok?, message)."""
    if verdict.kind in ("error", "timeout"):
        return False, f"TLC {verdict.kind}: {verdict.detail}"
    if verdict.kind == "deadlock":
        return False, "deadlock: a state where nothing can happen and the spec's Done does not hold (a wedge, or a missing step)"
    if check.expect.kind == "holds":
        return judge_holds(verdict)
    return judge_broken(check, verdict)


def judge_holds(verdict: Verdict) -> tuple[bool, str]:
    if verdict.kind == "holds":
        return True, ""
    broken = verdict.detail or "a temporal property"
    return False, f"expected to hold, but TLC broke {broken}: read the counterexample"


def judge_broken(check: Check, verdict: Verdict) -> tuple[bool, str]:
    expect, target = check.expect, check.targets[0]
    if verdict.kind == "holds":
        return False, holds_instead_message(expect, target)
    matched = (verdict.kind == "invariant" and verdict.detail == target) or (
        verdict.kind == "temporal" and target in check.properties
    )
    if not matched:
        broken = verdict.detail or "a temporal property"
        return False, f"TLC broke {broken}, not the target {target}: the spec is wrong"
    if expect.length is not None and verdict.length != expect.length:
        return False, (
            f"{expect.finding} now has a {verdict.length}-state counterexample, not {expect.length}: "
            "a different path breaks it; re-walk it in the code before updating len="
        )
    return True, expect.finding or ""


def holds_instead_message(expect: Expectation, target: str) -> str:
    if expect.kind == "reachable":
        return f"witness {target} unreachable: the spec no longer explores this scenario"
    if expect.kind == "mechanism":
        return f"{target} holds without {expect.mechanism}: the covered pass does not depend on it"
    return f"{target} now holds: was {expect.finding} fixed? flip EXPECT and mark it fixed"


def java_major(version_output: str) -> int | None:
    match = re.search(r'version "(\d+)(?:\.(\d+))?', version_output)
    if not match:
        return None
    return int(match.group(2)) if match.group(1) == "1" else int(match.group(1))


# --- effects ----------------------------------------------------------------


def discover(names: list[str]) -> list[Spec]:
    dirs = sorted(p for p in SPECS_DIR.iterdir() if p.is_dir())
    if names:
        known = {d.name for d in dirs}
        unknown = [n for n in names if n not in known]
        if unknown:
            raise CheckError(f"unknown spec(s): {', '.join(unknown)}; known: {', '.join(sorted(known))}")
        dirs = [d for d in dirs if d.name in names]
    return [load_spec(d) for d in dirs]


def cache_dir() -> Path:
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "fermix"


def tools_jar() -> Path:
    jar = cache_dir() / f"tla2tools-{TOOLS_VERSION}.jar"
    if not jar.exists():
        download_jar(jar)
    digest = hashlib.sha256(jar.read_bytes()).hexdigest()
    if digest != TOOLS_SHA256:
        raise CheckError(f"{jar} has sha256 {digest}, expected {TOOLS_SHA256}; delete it and re-run")
    return jar


def download_jar(jar: Path) -> None:
    jar.parent.mkdir(parents=True, exist_ok=True)
    print(f"downloading TLA+ tools {TOOLS_VERSION} to {jar}", file=sys.stderr)
    fd, tmp = tempfile.mkstemp(dir=jar.parent, suffix=".part")
    try:
        with os.fdopen(fd, "wb") as out, urllib.request.urlopen(TOOLS_URL, timeout=60) as response:
            shutil.copyfileobj(response, out)
        os.replace(tmp, jar)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def require_java() -> str:
    hint = "install Java 11+ (macOS: brew install openjdk) and put it on PATH"
    java = shutil.which("java")
    if java is None:
        raise CheckError(f"java not found on PATH; {hint}")
    result = subprocess.run([java, "-version"], capture_output=True, text=True)
    output = result.stdout + result.stderr
    if result.returncode != 0 or "Unable to locate a Java Runtime" in output:
        raise CheckError(f"{java} is not a working Java runtime; {hint}")
    major = java_major(output)
    if major is None:
        raise CheckError(f"cannot read the Java version from: {output.strip()}")
    if major < MIN_JAVA_MAJOR:
        raise CheckError(f"Java {major} found; TLC needs Java {MIN_JAVA_MAJOR}+")
    return java


def run_tlc(java: str, jar: Path, spec: Spec, check: Check, timeout_s: int) -> tuple[Verdict, float]:
    """One TLC run in its own temporary directory: its metadir, and its own
    java.io.tmpdir, because TLC extracts its standard modules there and parallel
    runs sharing the system temp dir collide. One worker and a fixed fingerprint
    polynomial make every run reproducible."""
    with tempfile.TemporaryDirectory(prefix="fermix-tlc-") as workdir:
        java_tmp = Path(workdir) / "java-tmp"
        java_tmp.mkdir()
        cmd = [
            java, f"-Djava.io.tmpdir={java_tmp}", "-XX:+UseParallelGC", "-cp", str(jar), "tlc2.TLC",
            "-workers", "1", "-fp", str(FINGERPRINT_INDEX), "-metadir", str(Path(workdir) / "meta"),
            "-config", str(check.cfg), spec.tla.name,
        ]
        started = time.monotonic()
        try:
            result = subprocess.run(cmd, cwd=spec.tla.parent, capture_output=True, text=True, timeout=timeout_s)
        except subprocess.TimeoutExpired:
            return Verdict("timeout", f"no verdict within {timeout_s}s"), time.monotonic() - started
        elapsed = time.monotonic() - started
    output = result.stdout + result.stderr
    out = OUT_DIR / spec.name / f"{check.name}.txt"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(output)
    return parse_tlc_output(output), elapsed


# --- commands ---------------------------------------------------------------


def label(check: Check) -> str:
    e = check.expect
    if e.kind == "violated":
        return f"violated {e.finding}"
    if e.kind == "mechanism":
        return f"needs {e.mechanism}"
    return e.kind


def print_stale(spec: Spec, stale: list[str]) -> None:
    print(f"  STALE: changed since this spec was verified: {', '.join(stale)}")
    print(f"         re-read the spec against the code, update it, then: make -C tla repin SPECS={spec.name}")


def list_checks(specs: list[Spec]) -> int:
    for spec in specs:
        print(spec.name)
        stale = spec.stale()
        if stale:
            print_stale(spec, stale)
        for check in spec.checks:
            print(f"  {check.name:<40} {label(check):<32} {check.summary}")
    return 0


def run_specs(specs: list[Spec], timeout_s: int, report: bool = False) -> int:
    jar = tools_jar()
    java = require_java()
    runs = []
    for spec in specs:
        print(spec.name)
        stale = spec.stale()
        if stale:
            print_stale(spec, stale)
        results = []
        for check in spec.checks:
            verdict, elapsed = run_tlc(java, jar, spec, check, timeout_s)
            ok, message = judge(check, verdict)
            results.append((check, verdict, ok, message))
            print_result(spec, check, verdict, elapsed, ok, message)
        runs.append((spec, stale, results))
    totals = run_totals(runs)
    print(
        f"\n{totals['checks']} checks: {totals['ok']} ok, {totals['fail']} FAIL; "
        f"{totals['stale']} stale spec(s). Output: {OUT_DIR}"
    )
    if report:
        write_report(runs, totals)
    return 1 if totals["fail"] or totals["stale"] else 0


def run_totals(runs: list) -> dict:
    results = [r for _spec, _stale, spec_results in runs for r in spec_results]
    failures = sum(1 for _c, _v, ok, _m in results if not ok)
    stale = sum(1 for _spec, stale, _r in runs if stale)
    return {"checks": len(results), "ok": len(results) - failures, "fail": failures, "stale": stale}


def write_report(runs: list, totals: dict) -> None:
    report = {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "totals": totals,
        "specs": [spec_report(spec, stale, results) for spec, stale, results in runs],
    }
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUT_DIR / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    (OUT_DIR / "report.md").write_text(trace_report.render_markdown(report))
    print(f"report: {OUT_DIR / 'report.md'} (and report.json)")


def spec_report(spec: Spec, stale: list[str], results: list) -> dict:
    comments = trace_report.action_comments(spec.tla.read_text())
    readme = spec.tla.parent / "README.md"
    sections = trace_report.finding_sections(readme.read_text()) if readme.is_file() else {}
    checks = [check_report(spec, check, verdict, ok, message, comments) for check, verdict, ok, message in results]
    findings: dict[str, dict] = {}
    for entry in checks:
        if entry["finding"]:
            readme_text = sections.get(entry["finding"], "")
            finding = findings.setdefault(entry["finding"], {"readme": readme_text, "checks": []})
            finding["checks"].append(entry)
    return {"name": spec.name, "stale": stale, "checks": checks, "findings": findings}


def check_report(spec: Spec, check: Check, verdict: Verdict, ok: bool, message: str, comments: dict) -> dict:
    """One check's result; findings and unexpected results carry their trace."""
    output = OUT_DIR / spec.name / f"{check.name}.txt"
    wants_trace = (check.expect.kind == "violated" or not ok) and output.is_file()
    return {
        "name": check.name,
        "expectation": label(check),
        "finding": check.expect.finding,
        "summary": check.summary,
        "ok": ok,
        "message": message,
        "states": verdict.states,
        "trace": trace_report.trace_steps(output.read_text(), comments) if wants_trace else [],
    }


def print_result(spec: Spec, check: Check, verdict: Verdict, elapsed: float, ok: bool, message: str) -> None:
    status = "ok  " if ok else "FAIL"
    states = f"{verdict.states} states" if verdict.states else ""
    print(f"  {status} {check.name:<40} {label(check):<32} {states:>16} {elapsed:6.1f}s")
    if not ok:
        print(f"       {message}")
        print(f"       output: {OUT_DIR / spec.name / (check.name + '.txt')}")


def repin(specs: list[Spec]) -> int:
    for spec in specs:
        dirty = uncommitted([s.path for s in spec.sources])
        if dirty:
            raise CheckError(
                f"{spec.name}: commit these first, a spec pins committed code: {', '.join(dirty)}"
            )
    for spec in specs:
        pins = {s.label: source_pin(s) for s in spec.sources}
        changed = [s.label for s in spec.sources if s.pin != pins[s.label]]
        spec.tla.write_text(repin_text(spec.tla.read_text(), pins))
        print(f"{spec.name}: {'re-pinned ' + ', '.join(changed) if changed else 'already current'}")
    return 0


def uncommitted(paths: list[str]) -> list[str]:
    """Paths (repo-relative) that differ from HEAD or are not tracked."""
    result = subprocess.run(
        ["git", "status", "--porcelain", "--", *paths], cwd=REPO_ROOT, capture_output=True, text=True
    )
    if result.returncode != 0:
        raise CheckError(f"git status failed: {result.stderr.strip()}")
    return sorted({line[3:].strip() for line in result.stdout.splitlines() if line.strip()})


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("specs", nargs="*", help="spec names (directories under tla/specs)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--list", action="store_true", help="list checks and staleness without running")
    mode.add_argument("--repin", action="store_true", help="re-pin the named specs' SOURCE hashes")
    mode.add_argument("--report", action="store_true",
                      help="run, then write tla/out/report.md and report.json for whoever fixes a finding")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT_S, help="seconds per check")
    args = parser.parse_args(argv)
    try:
        if args.repin and not args.specs:
            raise CheckError("--repin needs spec names: re-pin only what you re-read")
        specs = discover(args.specs)
        if args.list:
            return list_checks(specs)
        if args.repin:
            return repin(specs)
        return run_specs(specs, args.timeout, report=args.report)
    except CheckError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
