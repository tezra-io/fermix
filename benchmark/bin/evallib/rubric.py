"""The two forms of a judge rubric.

A NUMBERED rubric lists its requirements on lines that start "1. ", "2. ", …,
numbered 1..N in order. The judge decides each one and the harness computes pass
(every one met) and score (the fraction met), so a report can say which one
failed. A line indented under a requirement continues it; a line that is not
(such as a closing "Not required: …" line) is guidance, never a requirement.

Any other rubric is PROSE and gets one whole verdict from the judge.

Dependency-free on purpose: the suite loader validates the numbering at load,
and runners that never judge import the loader without the judge's SDK.
"""

from __future__ import annotations

import re

_ITEM = re.compile(r"^(\s*)(\d+)\.\s+(.*)$")


def numbered_requirements(text: str) -> tuple[list[str] | None, str | None]:
    """(requirement texts, None) for a numbered rubric, (None, None) for a prose
    one, and (None, a sentence naming the defect) for a malformed numbering."""
    if not isinstance(text, str):
        raise TypeError(f"rubric must be a string, got {type(text).__name__}")
    lines = text.splitlines()
    starts = [index for index, line in enumerate(lines) if _ITEM.match(line)]
    if not starts:
        return None, None
    numbers = [int(_ITEM.match(lines[index]).group(2)) for index in starts]
    if numbers != list(range(1, len(numbers) + 1)):
        found = ", ".join(str(number) for number in numbers)
        return None, (f"numbers its requirements {found}; a numbered rubric must "
                      "number them 1..N in order, each once")
    ends = starts[1:] + [None]
    texts = []
    for start, end in zip(starts, ends):
        body, error = _requirement_text(lines, start, end)
        if error:
            return None, error
        texts.append(body)
    return texts, None


def _requirement_text(lines: list[str], start: int,
                      end: int | None) -> tuple[str | None, str | None]:
    """One requirement: its numbered line and the lines indented under it.

    Between two requirements every non-blank line must be indented under the
    first: any other line would be read by the judge and shown by no report. The
    last requirement ends at its first blank or unindented line (`end` is None),
    where the rubric's closing guidance begins.
    """
    match = _ITEM.match(lines[start])
    number, indent = int(match.group(2)), len(match.group(1))
    parts = [match.group(3).strip()]
    for row in range(start + 1, len(lines) if end is None else end):
        line = lines[row]
        indented = len(line) - len(line.lstrip()) > indent
        if line.strip() and indented:
            parts.append(line.strip())
        elif end is None:
            break
        elif line.strip():
            return None, (f"line {row + 1} sits between requirements {number} and "
                          f"{number + 1} without being indented under requirement {number}")
    body = " ".join(part for part in parts if part)
    if not body:
        return None, f"requirement {number} has no text"
    return body, None
