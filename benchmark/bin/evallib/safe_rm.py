"""Fail-closed recursive-removal guard, ported from
`FermixCore.Plugins.Dist.SafeRm` (apps/.../plugins/dist/safe_rm.ex).

A target is removable only when it contains no `..`, is STRICTLY under `root`, and
sits at least `min_below` path components below it — so root itself, a parent, or a
root-ish path is always rejected. Used for per-trial sandbox teardown: a
computed-path delete once wiped a host (CLAUDE.md), so every checker teardown
routes through here.
"""

from __future__ import annotations

import os
import shutil


class SafeRmError(Exception):
    pass


def check(path: str, root: str, min_below: int = 1) -> str:
    """Return the resolved absolute path iff it is a safe removal target under
    `root`, else raise SafeRmError. Resolves symlinks (so a symlink can't escape)."""
    if not path or not root:
        raise SafeRmError("empty path or root")
    if ".." in path:                                  # reject before normalization eats it
        raise SafeRmError(f"traversal in path: {path!r}")
    p = os.path.realpath(os.path.expanduser(path))
    r = os.path.realpath(os.path.expanduser(root))
    if not p.startswith(r + os.sep):                  # strictly under (never equal)
        raise SafeRmError(f"outside root: {p} not under {r}")
    below = [c for c in p[len(r):].split(os.sep) if c]
    if len(below) < min_below:
        raise SafeRmError(f"too shallow: {p} is fewer than {min_below} levels below {r}")
    return p


def rm_rf(path: str, root: str, min_below: int = 1) -> None:
    shutil.rmtree(check(path, root, min_below))
