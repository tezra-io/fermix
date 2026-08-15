"""Drive real turns into the configured Opik-enabled daemon via `fermix ask`.

`fermix ask --json --session S --timeout MS <query>` connects to the daemon's
unix socket at `$FERMIX_HOME/daemon.sock`; the caller supplies the configured home
for its eval tier. It runs one real agent turn. Reply envelope:
  {"status":"ok","response":...,"session_id":...}
  {"status":"error","error":...}            # exit 1
  {"status":"error","error":"not_running"}  # exit 3 — daemon down
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

_sleep = time.sleep   # injection seam so tests exercise the backoff without real waits


# A rate-limit / quota turn "succeeds" (status ok) but Fermix hands back a canned
# message instead of doing the work — see `usage_limit_reply`/`provider_error_reply`
# in fermix_core `agents/turn_runner.ex`. Scoring that reply counts Fermix's own
# usage limit as a TASK failure, which is exactly the pollution we must avoid. These
# anchors are Fermix's stable, purpose-built wordings (update here if they change).
_USAGE_LIMIT_RE = re.compile(
    r"usage limit\b.*?\btry again in ~"     # OpenAI/Codex reply when the 429 body carried a reset time
    r"|rate-limited this request"            # :rate_limit with no reset time
    r"|quota or credits are exhausted",      # :quota with no reset time
    re.IGNORECASE | re.DOTALL,
)
_RESET_HINT_RE = re.compile(r"try again in ~\s*(\d+)\s*min", re.IGNORECASE)

# Fermix's auth-failure replies are likewise purpose-built stable wordings
# (`auth_reply/1` in fermix_core `agents/turn_runner.ex`): OAuth reconnect,
# api-key advice, the generic fallback, and the xAI 403 entitlement denial —
# which is worded as an ACCESS denial rather than an authentication failure,
# because re-login cannot fix a plan that does not include API access. Each
# anchors on its verb PLUS the remedy clause, so a task answer that merely
# discusses auth can't match. All four are PERMANENT for the run — a plan does
# not acquire API access mid-sweep, and TokenManager emits the rest only after
# a refresh permanently failed — so every later trial refuses before any model
# call. `test_auth_invalidated_covers_every_reply_clause` pins this set to the
# live source — it ASSEMBLES each clause's reply out of turn_runner.ex and
# requires a match, so a reworded clause fails there rather than silently here.
_AUTH_INVALIDATED_RE = re.compile(
    r"(?:authentication failed — (?:reconnect with `fermix auth login"
    r"|check the .{0,80}API key in `fermix setup`"
    r"|run `fermix auth login`)"
    r"|subscription access denied — the .{0,40}plan may not include API access\."
    r" Switch to an API key in `fermix setup`)",
    re.IGNORECASE | re.DOTALL,
)


def is_usage_limit_reply(text: str | None) -> bool:
    """True iff `text` is a Fermix usage-limit / rate-limit / quota reply."""
    return bool(text) and _USAGE_LIMIT_RE.search(text) is not None


def is_auth_invalidated_reply(text: str | None) -> bool:
    """True iff `text` is a Fermix authentication-failure reply (permanent)."""
    return bool(text) and _AUTH_INVALIDATED_RE.search(text) is not None


def usage_limit_reset_hint(text: str | None) -> str | None:
    """The provider's "~N min" reset window from a usage-limit reply, or None."""
    m = _RESET_HINT_RE.search(text or "")
    return f"~{m.group(1)} min" if m else None


class UsageLimitHit(Exception):
    """A driven turn's reply was a Fermix usage-limit/rate-limit/quota message. The
    capability runner catches this to STOP the sweep at a known pointer instead of
    scoring the rest of the suite as failures and writing a polluted leaderboard row.
    `locate/3` stamps where it happened so the operator knows where to resume."""

    def __init__(self, reply: str | None, reset_hint: str | None = None):
        self.reply = reply or ""
        self.reset_hint = reset_hint
        self.suite: str | None = None
        self.case_id: str | None = None
        self.trial: int | None = None
        self.retries = 0            # backoff retries attempted before giving up
        self.waited_min = 0         # total minutes waited across those retries
        super().__init__(self.reply_excerpt())

    def locate(self, suite: str, case_id: str, trial: int) -> None:
        self.suite, self.case_id, self.trial = suite, case_id, trial

    def reply_excerpt(self, n: int = 160) -> str:
        collapsed = " ".join(self.reply.split())
        return (collapsed[:n] + "…") if len(collapsed) > n else collapsed


class AuthInvalidated(Exception):
    """A driven turn's reply was a Fermix authentication-failure message. The
    condition is permanent for the run — TokenManager emits most of these only
    after a refresh permanently failed, and the xAI 403 entitlement denial is a
    plan tier that will not change mid-sweep — so unlike a usage limit there is
    nothing to wait out:
    every remaining trial would refuse at zero tokens. The capability runner
    catches this to STOP the sweep at a known pointer instead of banking
    meaningless failures into a leaderboard row (the 2026-08-06 sweep scored
    70 such trials into a bogus 0.38 composite)."""

    def __init__(self, reply: str | None):
        self.reply = reply or ""
        self.suite: str | None = None
        self.case_id: str | None = None
        self.trial: int | None = None
        super().__init__(self.reply_excerpt())

    def locate(self, suite: str, case_id: str, trial: int) -> None:
        self.suite, self.case_id, self.trial = suite, case_id, trial

    def reply_excerpt(self, n: int = 160) -> str:
        collapsed = " ".join(self.reply.split())
        return (collapsed[:n] + "…") if len(collapsed) > n else collapsed


@dataclass
class DriveResult:
    ok: bool
    status: str                  # ok | error | not_running | timeout | crashed
    response: str | None
    error: str | None
    session_id: str | None
    exit_code: int | None
    sent_at: datetime            # UTC, just before launch (for trace correlation)
    stdout: str = ""
    stderr: str = ""
    # End-to-end wall-clock of the `fermix ask` subprocess — the honest turn
    # latency (CLI transport + daemon work). The Opik trace's own `duration` is
    # ~0 because the exporter stamps start==end, so capability latency uses this.
    elapsed_ms: float = 0.0
    # True when `response` is a usage-limit/rate-limit/quota reply — the turn ran
    # but Fermix declined the work, so callers should abort rather than score it.
    usage_limited: bool = False
    # True when `response` is a Fermix auth-failure reply — permanently
    # invalidated credentials; callers must abort, retrying can never help.
    auth_invalidated: bool = False


def settled_elapsed_ms(result: DriveResult, settle_started: float,
                       now_monotonic: float | None = None) -> float:
    """End-to-end latency for grading after a server trace settles.

    A normal CLI response already spans the whole turn. When the CLI itself timed
    out, include the additional trace-correlation and settle wait so a late server
    completion cannot pass a latency budget using only the subprocess timeout.
    """
    if result.status != "timeout":
        return result.elapsed_ms
    finished = time.monotonic() if now_monotonic is None else now_monotonic
    return result.elapsed_ms + max(0.0, finished - settle_started) * 1000.0


def _parse_envelope(stdout: str) -> dict | None:
    for line in reversed(stdout.strip().splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return None


def drive_query(cfg, session: str, query: str, timeout_ms: int | None = None,
                attachments: list[str] | None = None) -> DriveResult:
    timeout_ms = timeout_ms or cfg.daemon.default_timeout_ms
    cmd = [cfg.daemon.fermix_bin, "ask", "--json",
           "--session", session, "--timeout", str(timeout_ms)]
    for att in (attachments or []):
        cmd += ["--attach", att]
    cmd.append(query)
    sent_at = datetime.now(timezone.utc)
    t0 = time.monotonic()
    try:
        proc = subprocess.run(
            cmd, env=cfg.env, capture_output=True, text=True,
            timeout=timeout_ms / 1000.0 + 30.0,
        )
    except subprocess.TimeoutExpired as exc:
        return DriveResult(ok=False, status="timeout", response=None,
                           error=f"fermix ask exceeded {timeout_ms}ms + 30s grace",
                           session_id=session, exit_code=None, sent_at=sent_at,
                           stdout=exc.stdout or "", stderr=exc.stderr or "",
                           elapsed_ms=(time.monotonic() - t0) * 1000.0)
    except FileNotFoundError:
        return DriveResult(ok=False, status="crashed", response=None,
                           error=f"binary not found: {cfg.daemon.fermix_bin}",
                           session_id=session, exit_code=None, sent_at=sent_at,
                           elapsed_ms=(time.monotonic() - t0) * 1000.0)

    elapsed_ms = (time.monotonic() - t0) * 1000.0
    env = _parse_envelope(proc.stdout) or {}
    status = env.get("status")
    if status == "ok":
        response = env.get("response")
        return DriveResult(ok=True, status="ok", response=response,
                           error=None, session_id=env.get("session_id") or session,
                           exit_code=proc.returncode, sent_at=sent_at,
                           stdout=proc.stdout, stderr=proc.stderr, elapsed_ms=elapsed_ms,
                           usage_limited=is_usage_limit_reply(response),
                           auth_invalidated=is_auth_invalidated_reply(response))
    err = env.get("error") or (proc.stderr.strip() or "unknown_error")
    norm = "not_running" if (err == "not_running" or proc.returncode == 3) else "error"
    return DriveResult(ok=False, status=norm, response=None, error=err,
                       session_id=env.get("session_id") or session,
                       exit_code=proc.returncode, sent_at=sent_at,
                       stdout=proc.stdout, stderr=proc.stderr, elapsed_ms=elapsed_ms)


def drive_with_usage_retry(cfg, session: str, query: str, timeout_ms: int | None,
                           label: str) -> tuple[DriveResult, str]:
    """Drive a turn; on a usage/rate/quota limit, wait the configured backoff
    (`cfg.usage_limit.retry_backoff_min`, minutes — e.g. 30/60/120/180 to ride out a
    multi-hour subscription session-limit) and retry with a FRESH session so the
    limit reply can't leak into the retry's context. Returns (result, session_used) on
    success; raises `UsageLimitHit` once the schedule is exhausted so the sweep stops
    at a known pointer. An empty schedule = fail-fast (raise on the first limit)."""
    waits_s = [int(m) * 60 for m in cfg.usage_limit.retry_backoff_min]
    attempt = 0
    while True:
        used = session if attempt == 0 else f"{session}-r{attempt}"
        res = drive_query(cfg, used, query, timeout_ms)
        if res.auth_invalidated:
            raise AuthInvalidated(res.response)   # permanent — backoff can't help
        if not res.usage_limited:
            return res, used
        if attempt >= len(waits_s):
            hit = UsageLimitHit(res.response, usage_limit_reset_hint(res.response))
            hit.retries, hit.waited_min = attempt, sum(waits_s) // 60
            raise hit
        _log_and_wait(label, attempt + 1, len(waits_s), waits_s[attempt], res)
        attempt += 1


def _log_and_wait(label: str, n: int, total: int, wait_s: int, res: DriveResult) -> None:
    hint = usage_limit_reset_hint(res.response)
    hint_txt = f"; provider self-reports {hint}" if hint else ""
    resume = (datetime.now(timezone.utc) + timedelta(seconds=wait_s)).astimezone().strftime("%H:%M")
    print(f"    ⏳ usage limit at {label}{hint_txt} — waiting {wait_s // 60} min "
          f"(retry {n}/{total}, ~{resume}) before retrying…", file=sys.stderr)
    _sleep(wait_s)


def daemon_reachable(cfg) -> tuple[bool, str]:
    """True iff the configured Opik-enabled daemon answers its control socket."""
    cmd = [cfg.daemon.fermix_bin, "status", "--json"]
    try:
        proc = subprocess.run(cmd, env=cfg.env, capture_output=True, text=True, timeout=15)
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        return False, str(exc)
    out = (proc.stdout or "").strip()
    if proc.returncode == 3 or "not_running" in out:
        return False, "daemon not running (control socket unreachable)"
    if proc.returncode != 0:
        return False, f"fermix status exit {proc.returncode}: {proc.stderr.strip() or out}"
    return True, out[:200]
