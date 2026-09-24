"""Turn TLC results into a report someone can fix code from.

For every finding (a `violated` check) and every unexpected result, the report
gives the counterexample as a list of steps. Each step names the spec action,
the Elixir function and `path:line` it mirrors (the comment above the action in
the spec), and only the variables that step changed. The finding's write-up
from the spec's README comes with it. Pure functions; check.py does the I/O.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

STATE_HEADER = re.compile(r"^State (\d+): (.*)$")
BACK_TO_LINE = re.compile(r"^Back to state (\d+): (.*)$")
ACTION_NAME = re.compile(r"^<([A-Za-z_][A-Za-z0-9_]*)[ >]")
VARIABLE = re.compile(r"^/\\ ([A-Za-z_][A-Za-z0-9_]*) = (.*)$")
DEFINITION = re.compile(r"^([A-Z][A-Za-z0-9_]*)(?:\([^)]*\))?\s*==")
FINDING_HEADING = re.compile(r"^### ([A-Z][A-Z0-9]*-\d+)\b")
CODE_REF = re.compile(r"[A-Za-z_][\w/]*\.exs?:\d+(?:-\d+)?")

HOW_TO_USE = """\
How to use this report to fix a finding:
1. A counterexample is a path through the spec, not a recording of the daemon.
   Walk each step against the cited code before trusting it.
2. Reproduce the finding as a failing ExUnit test against the real code
   (AGENTS.md: behaviour change, failing test first).
3. Decide the fix. Some findings are product decisions (the README says which
   rules are Fermix's own claims and which are proposed).
4. Change the spec to the fixed design and run `make -C tla check SPECS=<spec>`:
   the finding's check must now fail with "now holds", and nothing else may
   change. Add a `mechanism` check for the new mechanism.
5. Implement, make the test pass, commit, then `make -C tla repin SPECS=<spec>`,
   flip the check to `EXPECT: holds`, and mark the finding fixed.
"""


@dataclass
class Step:
    number: int
    action: str  # "Initial", an action name, or "Stuttering"
    back_to: int | None = None
    variables: dict[str, str] = field(default_factory=dict)


def parse_trace(output: str) -> list[Step]:
    """The counterexample in TLC output, one Step per printed state."""
    steps: list[Step] = []
    current: Step | None = None
    last_var: str | None = None
    for line in output.splitlines():
        header = STATE_HEADER.match(line)
        if header:
            current = Step(int(header.group(1)), step_action(header.group(2)))
            steps.append(current)
            last_var = None
            continue
        back = BACK_TO_LINE.match(line)
        if back:
            # A liveness lasso closes by returning to an earlier state; TLC prints
            # the closing action but no variables, so the step shows that state.
            target = int(back.group(1))
            earlier = next((s.variables for s in steps if s.number == target), {})
            steps.append(Step(len(steps) + 1, step_action(back.group(2)), target, dict(earlier)))
            current, last_var = None, None
            continue
        if current is None:
            continue
        variable = VARIABLE.match(line)
        if variable:
            last_var = variable.group(1)
            current.variables[last_var] = variable.group(2).strip()
        elif last_var and line.startswith(" ") and line.strip():
            current.variables[last_var] += " " + line.strip()
        elif not line.strip():
            last_var = None
    return steps


def step_action(header_rest: str) -> str:
    if header_rest.startswith("<Initial predicate>"):
        return "Initial"
    if "Stuttering" in header_rest:
        return "Stuttering"
    name = ACTION_NAME.match(header_rest.strip())
    return name.group(1) if name else header_rest.strip()


def changed(previous: dict[str, str], current: dict[str, str]) -> dict[str, str]:
    return {k: v for k, v in current.items() if previous.get(k) != v}


def action_comments(tla_text: str) -> dict[str, str]:
    """Each top-level definition's name -> the `\\*` comment lines just above it."""
    comments: dict[str, str] = {}
    lines = tla_text.splitlines()
    for i, line in enumerate(lines):
        definition = DEFINITION.match(line)
        if not definition:
            continue
        above = []
        j = i - 1
        while j >= 0 and lines[j].lstrip().startswith("\\*"):
            above.insert(0, lines[j].lstrip()[2:].strip())
            j -= 1
        comments[definition.group(1)] = " ".join(above)
    return comments


def finding_sections(readme_text: str) -> dict[str, str]:
    """Finding id -> its README section (heading to the next heading of level <= 3)."""
    sections: dict[str, str] = {}
    current_id = None
    buffer: list[str] = []
    for line in readme_text.splitlines():
        heading = FINDING_HEADING.match(line)
        if heading or (current_id and re.match(r"^#{1,3} ", line)):
            if current_id:
                sections[current_id] = "\n".join(buffer).strip()
            current_id = heading.group(1) if heading else None
            buffer = [line] if heading else []
        elif current_id:
            buffer.append(line)
    if current_id:
        sections[current_id] = "\n".join(buffer).strip()
    return sections


def trace_steps(output: str, comments: dict[str, str]) -> list[dict]:
    """JSON-ready steps: action, what it mirrors, code refs, changed variables."""
    result = []
    previous: dict[str, str] = {}
    for step in parse_trace(output):
        comment = comments.get(step.action, "")
        result.append({
            "state": step.number,
            "action": step.action,
            "back_to_state": step.back_to,
            "mirrors": comment,
            "code_refs": CODE_REF.findall(comment),
            "changed": step.variables if step.action == "Initial" else changed(previous, step.variables),
        })
        if step.variables:
            previous = step.variables
    return result


def render_markdown(report: dict) -> str:
    totals = report["totals"]
    out = [
        "# TLA+ report",
        "",
        f"Generated {report['generated_at']}. {totals['checks']} checks: {totals['ok']} ok, "
        f"{totals['fail']} FAIL; {totals['stale']} stale spec(s).",
        "",
        HOW_TO_USE,
    ]
    for spec in report["specs"]:
        out += render_spec(spec)
    return "\n".join(out) + "\n"


def render_spec(spec: dict) -> list[str]:
    out = [f"## {spec['name']}", ""]
    if spec["stale"]:
        out += [f"**STALE**, changed since verified: {', '.join(spec['stale'])}. "
                "Re-read the spec before trusting anything below.", ""]
    out += ["| check | expectation | result | states |", "|---|---|---|---|"]
    for check in spec["checks"]:
        result = "ok" if check["ok"] else f"**FAIL**: {check['message']}"
        out.append(f"| {check['name']} | {check['expectation']} | {result} | {check['states']} |")
    out.append("")
    for check in (c for c in spec["checks"] if not c["ok"]):
        out += render_trace(f"Unexpected: {check['name']}", check)
    for finding_id, finding in spec["findings"].items():
        out += [finding["readme"] or f"### {finding_id}", ""]
        for check in finding["checks"]:
            out += render_trace(f"Counterexample: {check['name']}", check)
    return out


def render_trace(title: str, check: dict) -> list[str]:
    out = [f"#### {title} ({check['summary']})", ""]
    if not check["trace"]:
        return out + ["(no counterexample in the TLC output)", ""]
    for step in check["trace"]:
        out.append(render_step(step))
    return out + [""]


def render_step(step: dict) -> str:
    if step["action"] == "Initial":
        return f"{step['state']}. Initial state."
    if step["action"] == "Stuttering":
        return f"{step['state']}. Nothing else ever happens (stuttering): the rule's promise never arrives."
    loop = f" (loops back to state {step['back_to_state']})" if step["back_to_state"] else ""
    mirrors = f": {step['mirrors']}" if step["mirrors"] else ""
    changes = "; ".join(f"`{k}` = `{v}`" for k, v in step["changed"].items()) or "no variable changed"
    return f"{step['state']}. **{step['action']}**{loop}{mirrors}\n   - changed: {changes}"
