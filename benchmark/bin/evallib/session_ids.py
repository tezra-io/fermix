"""Bounded daemon session ids shared by every runner.

One id per (case, trial) is what correlates a driven turn with its Opik trace, so
two different pieces of work must never produce the same id and a retry must never
land in the conversation it exists to independently confirm.
"""

from __future__ import annotations

import hashlib
import re
import secrets

_SESS_RE = re.compile(r"[^A-Za-z0-9_-]")
SESS_LIMIT = 90


def sess(*parts: str, limit: int = SESS_LIMIT) -> str:
    """Join `parts` into a session id no longer than `limit`, keeping the tail.

    A plain `[:limit]` silently cut the trial suffix off every id over the cap (83
    of 449 shipped cases), so trials of one case shared a daemon conversation: a
    fail-retry re-entered the context of the attempt it exists to independently
    confirm, and its turns became indistinguishable from that attempt's in Opik
    correlation. `find_turn_trace` requires a UNIQUE candidate, so an
    identically-worded retry turn resolved to None and the case went INCOMPLETE
    with the real verdict masked. Two long case ids sharing a prefix collided the
    same way.

    Overflow therefore compresses the MIDDLE, never the tail: the readable head
    and the trailing parts survive, and a digest of the full id keeps every
    distinct input distinct. A tail that cannot fit at all raises rather than
    yielding an id that no longer identifies its trial.
    """
    if not parts:
        raise ValueError("sess() needs at least one part")
    if not isinstance(limit, int) or isinstance(limit, bool) or limit < 1:
        raise ValueError(f"sess() limit must be a positive int, got {limit!r}")
    full = _SESS_RE.sub("-", "-".join(parts))
    if len(full) <= limit:
        return full
    tail = _SESS_RE.sub("-", str(parts[-1]))
    suffix = f"-{hashlib.sha256(full.encode()).hexdigest()[:8]}-{tail}"
    head = limit - len(suffix)
    if head < 1:
        raise ValueError(f"session id tail {tail!r} does not fit in {limit} chars")
    return full[:head] + suffix


def eval_marker(run_id: str) -> str:
    """One message's eval marker, `e2e-mark-<run id>-<6 hex>`: what a message the runner
    sends where no session can carry the correlation (the operator's Telegram chat, the
    companion socket, the app's chat) appends as `(eval:<marker>)` for its trace to be
    found by. The model reads it, so it names the run and nothing of the suite or the
    case; a fresh one per message keeps two messages of one run apart."""
    if not isinstance(run_id, str) or not run_id or _SESS_RE.search(run_id):
        raise ValueError(f"eval_marker() needs a run id of [A-Za-z0-9_-], got {run_id!r}")
    return f"e2e-mark-{run_id}-{secrets.token_hex(3)}"
