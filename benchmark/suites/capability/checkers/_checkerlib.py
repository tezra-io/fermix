"""Shared contract helpers for the capability checkers.

Not a checker itself: `run_checker` only ever executes the `script:` a case
declares, and this module is imported by those scripts (they add their own
directory to `sys.path`). It holds the three things more than one checker needs
and that must not drift between them:

  * `emit` / `refuse` — the json-mode result protocol (last stdout line).
  * the ONLY/EXACTLY artifact contract (`sole_line`) — a prompt that says
    "write ONLY the number" or "EXACTLY one line" is graded as written: one
    non-empty line, no preamble, no trailing "Done.".
  * evidence access (`evidence`, `spans`, `span_text`, `span_output`, `span_start`,
    `shell_command`) — the per-trial correlation record the runner writes outside the
    workspace at FERMIX_EVAL_EVIDENCE. Absent evidence is refused, never assumed empty.

INPUT AND OUTPUT ARE NOT INTERCHANGEABLE, and neither is JSON. A tool routed through
`FermixCore.Tools.Support.run/3` (schedule_job, run_job_now, skill_create, skill_reload)
records NO input at all, so a checker correlating on input matched nothing on every real
trial. A tool that does record one records `FermixCore.Telemetry.preview/1`'s Elixir
`inspect` rendering — `%{"command" => "cat job_out.txt"}` — wrapped as `{"text": …}`,
which contains `=>` and therefore the `">"` shell-write marker. Use `span_output` for the
first family and `shell_command` for the second; `span_text` stays the raw-input reader.

Kept 3.9-compatible: these scripts run under whatever `python3` the checker's
PATH resolves, which is not the uv-managed interpreter the harness tests use.
"""

from __future__ import annotations

import datetime
import json
import os
import re
import sys

WRITE_TOOLS = ("file_write", "file_edit")
# A shell span counts as a direct write only when it both names the artifact and
# carries a write construct; `cat`-ing the file is legitimate verification and
# must not fail a trial that did the work properly.
SHELL_WRITE_MARKERS = (">", ">>", "tee ", "cp ", "mv ", "sed -i", "printf ", "touch ")


def emit(score, detail):
    """Print the json-mode result. The checker's ONLY output contract."""
    print(json.dumps({"score": round(float(score), 3), "detail": str(detail)[:200]}))


def refuse(detail):
    """Emit a 0 with a reason and stop. Used for both "the model failed" and
    "the evidence needed to grade is missing" — the caller's detail says which,
    and the runner records the detail verbatim."""
    emit(0.0, detail)
    raise SystemExit(0)


def workspace():
    return os.environ["FERMIX_EVAL_WORKSPACE"]


def repo_path(*parts):
    """A path under benchmark/suites/capability/, resolved from this file so a
    checker can compare the seeded copy against the repo's own fixture."""
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", *parts))


def read_text(path, what):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError as exc:
        refuse(f"cannot read {what}: {exc}")


def sole_line(path, what):
    """The ONLY/EXACTLY artifact contract: exactly one non-empty line, returned
    stripped. Anything else (preamble, a second line, a trailing "Done.", an
    empty file) is a contract violation, not partial credit."""
    text = read_text(path, what)
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    if len(lines) != 1:
        refuse(f"{what} must be exactly one non-empty line, got {len(lines)}: {text[:80]!r}")
    return lines[0]


# --- evidence ---------------------------------------------------------------

def evidence():
    """This trial's correlation record, or a refusal. Never returns a synthetic
    empty record: "no spans were recorded" and "the runner passed no evidence"
    grade identically only if we pretend, and pretending scores a working
    product 0."""
    path = os.environ.get("FERMIX_EVAL_EVIDENCE")
    if not path or not os.path.isfile(path):
        refuse("no evidence file (FERMIX_EVAL_EVIDENCE absent or missing)")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        refuse(f"unreadable evidence file: {exc}")
    if not isinstance(data, dict) or not isinstance(data.get("tool_spans"), list):
        refuse("evidence file has no tool_spans list")
    return data


def spans(ev, name, status="ok"):
    """Tool spans recorded under the name the MODEL used, filtered by status
    (pass status=None for every span regardless of outcome)."""
    out = []
    for span in ev["tool_spans"]:
        if not isinstance(span, dict) or span.get("name") != name:
            continue
        if status is None or span.get("status") == status:
            out.append(span)
    return out


def span_text(span):
    """A span's input as searchable text; dict inputs are serialized so a nested
    task string is still matched."""
    value = span.get("input")
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return json.dumps(value)


def span_output(span):
    """A span's output as searchable text. This is the ONLY correlation surface for a
    tool that records no input (every `Support.run` tool): a successful skill_create
    reports `{"path":"/…/skills/eval-echo","created":true}` and a successful
    run_job_now reports the run's job id, session and status."""
    value = span.get("output")
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return json.dumps(value)


_SHELL_COMMAND_RE = re.compile(r'"command"\s*=>\s*"((?:[^"\\]|\\.)*)"')


def shell_command(span):
    """The command a shell span actually ran, or None when it was not recorded.

    The recorded input is an Elixir map rendering, not JSON, so it must be unwrapped
    (`{"text": …}` or a bare string) and read with a regex before any marker matching.
    Returning None rather than a best guess is the point: a caller must not decide
    "this did not write the file" from evidence it could not read."""
    raw = span.get("input")
    if isinstance(raw, dict):
        raw = raw.get("text", raw.get("value"))
    if not isinstance(raw, str):
        return None
    found = _SHELL_COMMAND_RE.search(raw)
    if found is None:
        return None
    return re.sub(r"\\(.)", r"\1", found.group(1))


def span_start(span):
    """A span's start_time as epoch seconds, or None when it was not recorded."""
    raw = span.get("start_time")
    if not isinstance(raw, str) or not raw:
        return None
    text = raw[:-1] + "+00:00" if raw.endswith("Z") else raw
    try:
        parsed = datetime.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:                       # Opik records UTC
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    return parsed.timestamp()


def path_variants(path):
    """The spellings the same absolute path can take in a recorded tool input:
    the workspace as the checker sees it, and macOS's /private-prefixed realpath
    of it. Not a fallback — one path, two renderings of the same string."""
    resolved = os.path.realpath(path)
    out = {path, resolved}
    for value in (path, resolved):
        if value.startswith("/private/"):
            out.add(value[len("/private"):])
    return out


def references(text, artifact_path):
    """True when a recorded tool input names THIS trial's artifact: the file name
    plus enough of its directory to distinguish this trial from any other. The
    workspace-relative spelling (`<task>/t<i>/…`, which the sandbox resolves to
    the same file) counts — one path, several renderings — while a bare
    "job_out.txt" does not."""
    base = os.path.basename(artifact_path)
    directory = os.path.dirname(artifact_path)
    trial_tail = "/".join(directory.rstrip("/").split("/")[-2:])
    return base in text and (trial_tail in text
                             or any(v in text for v in path_variants(directory)))


def direct_write_spans(ev, artifact_path):
    """Spans that wrote the artifact directly instead of letting the mechanism
    under test produce it."""
    hits = []
    for span in ev["tool_spans"]:
        if not isinstance(span, dict):
            continue
        name = span.get("name")
        if name in WRITE_TOOLS and references(span_text(span), artifact_path):
            hits.append(name)
        elif name == "shell":
            hits += _shell_write_hits(span, artifact_path)
    return hits


def _shell_write_hits(span, artifact_path):
    """A shell span is a direct write only when its COMMAND both names the artifact and
    carries a write construct. Matching the markers against the whole recorded input
    flagged every `cat job_out.txt` verification, because the Elixir rendering's `=>`
    contains the `">"` marker."""
    command = shell_command(span)
    if command is None:
        # It may name the artifact, and we cannot read what it did with it. Say so
        # rather than guess in either direction.
        return ["shell (command not recorded)"] if references(span_text(span),
                                                              artifact_path) else []
    if not references(command, artifact_path):
        return []
    return ["shell"] if any(m in command for m in SHELL_WRITE_MARKERS) else []


if __name__ == "__main__":                          # not a checker; never run directly
    print("_checkerlib is a helper module, not a checker", file=sys.stderr)
    raise SystemExit(2)
