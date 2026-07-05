"""Drive real turns into the Opik-enabled dev daemon via `fermix ask`.

`fermix ask --json --session S --timeout MS <query>` connects to the daemon's
unix socket at `$FERMIX_HOME/daemon.sock` (we point FERMIX_HOME at ~/.fermix-dev,
the Opik-enabled daemon) and runs one real agent turn. Reply envelope:
  {"status":"ok","response":...,"session_id":...}
  {"status":"error","error":...}            # exit 1
  {"status":"error","error":"not_running"}  # exit 3 — daemon down
"""

from __future__ import annotations

import json
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime, timezone


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
        return DriveResult(ok=True, status="ok", response=env.get("response"),
                           error=None, session_id=env.get("session_id") or session,
                           exit_code=proc.returncode, sent_at=sent_at,
                           stdout=proc.stdout, stderr=proc.stderr, elapsed_ms=elapsed_ms)
    err = env.get("error") or (proc.stderr.strip() or "unknown_error")
    norm = "not_running" if (err == "not_running" or proc.returncode == 3) else "error"
    return DriveResult(ok=False, status=norm, response=None, error=err,
                       session_id=env.get("session_id") or session,
                       exit_code=proc.returncode, sent_at=sent_at,
                       stdout=proc.stdout, stderr=proc.stderr, elapsed_ms=elapsed_ms)


def daemon_reachable(cfg) -> tuple[bool, str]:
    """True iff the Opik-enabled dev daemon answers its control socket."""
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
