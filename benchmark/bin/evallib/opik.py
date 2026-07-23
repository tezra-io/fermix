"""Read-only client for the local Opik REST API.

Fermix's `fermix_opik` plugin only POSTs traces; nothing reads them back. This is
the read side the eval needs. Verified endpoints (Opik local, no auth):

    GET {base}/projects
    GET {base}/traces?project_name=NAME&page=1&size=N      -> {content:[trace,...]}
    GET {base}/traces/{id}                                  -> trace
    GET {base}/spans?project_name=NAME&trace_id=ID&size=N   -> {content:[span,...]}

Trace fields used: thread_id, name, input.text, output.text, metadata,
usage.total_tokens, total_estimated_cost, duration, span_count, llm_span_count,
has_tool_spans, error_info (present only on failure), start_time.
Span fields used: type (llm|tool|general), name, parent_span_id, metadata.status,
error_info, total_estimated_cost, start_time.
"""

from __future__ import annotations

import http.client
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime


class OpikError(Exception):
    pass


_CORRELATION_KEYS = ("eval_run_id", "case_id", "turn_index")
_GET_RETRY_DELAYS_S = (0.5, 1.0)
_RUN_ID_RE = re.compile(r"^\d{8}T\d{6}Z(?:[a-f0-9]{8})?$")


def valid_run_id(run_id: str) -> bool:
    """Accept current entropy-suffixed ids and legacy timestamp-only ids for purge."""
    return isinstance(run_id, str) and _RUN_ID_RE.fullmatch(run_id) is not None


def parse_ts(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def trace_status(trace: dict) -> str:
    """Derive ok/error: Opik omits a top-level status; failure carries error_info."""
    if trace.get("status") in ("ok", "error"):
        return trace["status"]
    return "error" if trace.get("error_info") else "ok"


def text_of(field) -> str:
    """input/output may be {'text': ...} or {'value': ...} or a bare string."""
    if isinstance(field, dict):
        return str(field.get("text", field.get("value", "")))
    if field is None:
        return ""
    return str(field)


def _chat_id(thread_id: str | None) -> str | None:
    if not thread_id or ":" not in thread_id:
        return thread_id
    return thread_id.split(":", 1)[1]


def _session_has_run_id(session: str, run_id: str) -> bool:
    return run_id in session.split("-")


def _operator_trace_has_run_id(trace: dict, run_id: str) -> bool:
    """True only for the exact marker format printed by an operator eval run."""
    if not isinstance(run_id, str):
        return False
    text = " ".join(text_of(trace.get("input")).split())
    pattern = rf"\(eval:e2e-mark-{re.escape(run_id)}-[A-Fa-f0-9]{{6}}\)"
    return re.search(pattern, text) is not None


def _matches_correlation(trace: dict, correlation: dict | None) -> bool:
    if correlation is None:
        return True
    metadata = trace.get("metadata") or {}
    return all(metadata.get(key) == correlation[key] for key in _CORRELATION_KEYS)


def _validate_correlation(correlation: dict | None) -> None:
    if correlation is None:
        return
    missing = [key for key in _CORRELATION_KEYS if key not in correlation]
    if missing:
        raise ValueError(f"correlation missing required keys: {missing}")


def _completion_issues(trace: dict, spans: list[dict], stable: bool) -> list[str]:
    issues: list[str] = []
    count = trace.get("span_count")
    if trace.get("end_time") is None:
        issues.append("trace end_time missing")
    if isinstance(count, bool) or not isinstance(count, int) or count < 1:
        issues.append("trace span_count missing or invalid")
    elif len(spans) < count:
        issues.append(f"only {len(spans)} of {count} spans retrievable")
    unfinished = [span.get("id") or span.get("name") or "unknown"
                  for span in spans if span.get("end_time") is None]
    if unfinished:
        issues.append(f"span end_time missing: {unfinished[:5]}")
    if not stable:
        issues.append("span_count not stable across consecutive reads")
    return issues


def _annotate_completion(trace: dict, complete: bool, issues: list[str]) -> dict:
    annotated = dict(trace)
    annotated["_eval_trace_complete"] = complete
    annotated["_eval_trace_issues"] = list(issues)
    return annotated


class OpikClient:
    def __init__(self, base_url: str, project: str, timeout_s: float = 8.0,
                 api_key: str | None = None, workspace: str | None = None):
        self.base = base_url.rstrip("/")
        self.project = project
        self.timeout = timeout_s
        self.api_key = api_key or None
        self.workspace = workspace or None

    def _headers(self, headers: dict) -> dict:
        """Hosted Opik (Comet cloud) auth; a local unauthenticated Opik adds none."""
        if self.api_key:
            headers["authorization"] = self.api_key
        if self.workspace:
            headers["Comet-Workspace"] = self.workspace
        return headers

    def _get(self, path: str, params: dict | None = None) -> dict:
        url = self.base + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        headers = self._headers({"Accept": "application/json"})
        attempts = len(_GET_RETRY_DELAYS_S) + 1
        for attempt in range(attempts):
            req = urllib.request.Request(url, headers=headers)
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    return json.load(resp)
            except urllib.error.HTTPError as exc:
                raise OpikError(f"GET {url}: HTTP {exc.code}: {exc.reason}") from exc
            except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                raise OpikError(f"GET {url}: bad JSON: {exc}") from exc
            except (OSError, http.client.HTTPException) as exc:
                if attempt + 1 == attempts:
                    raise OpikError(
                        f"GET {url} failed after {attempts} attempts: {exc}") from exc
                time.sleep(_GET_RETRY_DELAYS_S[attempt])

    def _post(self, path: str, body: dict) -> int:
        req = urllib.request.Request(
            self.base + path, data=json.dumps(body).encode(),
            headers=self._headers({"Content-Type": "application/json"}), method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.status
        except urllib.error.HTTPError as exc:
            raise OpikError(f"POST {path}: HTTP {exc.code}: {exc.read(200)!r}") from exc
        except urllib.error.URLError as exc:
            raise OpikError(f"POST {path}: {exc}") from exc

    # --- health ---------------------------------------------------------------

    def ping(self) -> bool:
        self._get("/projects", {"page": 1, "size": 1})
        return True

    def project_exists(self) -> bool:
        data = self._get("/projects", {"page": 1, "size": 100})
        return any(p.get("name") == self.project for p in data.get("content", []))

    # --- traces / spans -------------------------------------------------------

    def recent_traces(self, size: int = 100) -> list[dict]:
        data = self._get("/traces", {"project_name": self.project, "page": 1, "size": size})
        return data.get("content", [])

    def get_trace(self, trace_id: str) -> dict:
        return self._get(f"/traces/{trace_id}")

    def get_spans(self, trace_id: str, size: int = 200) -> list[dict]:
        data = self._get("/spans", {"project_name": self.project, "trace_id": trace_id,
                                     "page": 1, "size": size})
        return data.get("content", [])

    # --- correlation ----------------------------------------------------------

    def find_turn_trace(self, session: str, query: str, after: datetime | None,
                        seen_ids: set[str], correlation: dict | None = None) -> dict | None:
        """Unique unseen main trace with exact session, query, and optional metadata.

        Each `fermix ask --session S` turn becomes one `agent:main` trace under
        thread_id `<channel>:S`. Multi-turn cases reuse S. A match is accepted only
        when the normalized input is exact; a sole or merely-containing candidate
        is not enough. Once Fermix exports eval metadata, `correlation` must contain
        exact `eval_run_id`, `case_id`, and `turn_index` values.
        """
        _validate_correlation(correlation)
        qn = " ".join(query.split()).strip().lower()
        if not session or not qn:
            raise ValueError("session and query must be non-empty")
        candidates = []
        for t in self.recent_traces():
            if t.get("id") in seen_ids:
                continue
            # Grade ONLY the main turn. Background sub-traces that share the
            # thread_id — `memory_review:*`, `soul_curation:*` — are not the turn;
            # they run after it (so they're newer) and carry no/other input, so
            # without this filter the recency tiebreaker can mis-select them.
            if t.get("name") != "agent:main":
                continue
            if _chat_id(t.get("thread_id")) != session:
                continue
            ts = parse_ts(t.get("start_time"))
            if after is not None and (ts is None or ts < after):
                continue
            if not _matches_correlation(t, correlation):
                continue
            inp = " ".join(text_of(t.get("input")).split()).strip().lower()
            if inp == qn:
                candidates.append(t)

        return candidates[0] if len(candidates) == 1 else None

    def poll_for_turn(self, session: str, query: str, after: datetime | None,
                      seen_ids: set[str], timeout_s: float, interval_s: float,
                      correlation: dict | None = None) -> dict | None:
        """Block until the turn's trace appears in Opik or timeout elapses."""
        if timeout_s < 0 or interval_s <= 0:
            raise ValueError("timeout_s must be non-negative and interval_s must be positive")
        deadline = time.monotonic() + timeout_s
        while True:
            hit = self.find_turn_trace(session, query, after, seen_ids, correlation)
            if hit is not None:
                return hit
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            time.sleep(min(interval_s, remaining))

    def find_marker_trace(self, thread_prefix: str, marker: str, after: datetime | None,
                          seen_ids: set[str]) -> dict | None:
        """Unique unseen trace on a `<thread_prefix>*` thread containing `marker`.

        Operator-assisted cases (e.g. a real Telegram message for the streaming
        suite) can't be correlated by session — the operator's chat owns the
        thread_id. The runner embeds a unique marker in the message text instead.
        """
        mk = marker.lower()
        if not thread_prefix or not mk:
            raise ValueError("thread_prefix and marker must be non-empty")
        candidates = []
        for t in self.recent_traces():
            if t.get("id") in seen_ids:
                continue
            if not (t.get("thread_id") or "").startswith(thread_prefix):
                continue
            ts = parse_ts(t.get("start_time"))
            if after is not None and (ts is None or ts < after):
                continue
            if mk in " ".join(text_of(t.get("input")).split()).lower():
                candidates.append(t)
        return candidates[0] if len(candidates) == 1 else None

    def poll_for_marker(self, thread_prefix: str, marker: str, after: datetime | None,
                        seen_ids: set[str], timeout_s: float, interval_s: float) -> dict | None:
        """Block until a marker-bearing trace appears on the thread prefix, or timeout."""
        if timeout_s < 0 or interval_s <= 0:
            raise ValueError("timeout_s must be non-negative and interval_s must be positive")
        deadline = time.monotonic() + timeout_s
        while True:
            hit = self.find_marker_trace(thread_prefix, marker, after, seen_ids)
            if hit is not None:
                return hit
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            time.sleep(min(interval_s, remaining))

    def await_complete(self, trace: dict, settle_s: float = 60.0,
                       interval_s: float = 2.0) -> tuple[dict, list[dict]]:
        """Wait until a found trace is fully flushed before grading it.

        Opik POSTs the trace and its spans in separate batches, so a trace can be
        discoverable (even with its final reply text) while its spans, usage, and
        cost are still landing — grading then would see 0 tools / $0 (a false fail).
        Re-fetch until the turn has closed (`end_time` set), `span_count >= 1`, all
        spans are retrievable, and `span_count` is stable across two reads. The
        returned trace is annotated with `_eval_trace_complete`; timing out returns
        explicit incomplete evidence, never an unmarked best-effort success.
        """
        if not trace.get("id"):
            raise ValueError("trace must contain an id")
        if settle_s < 0 or interval_s <= 0:
            raise ValueError("settle_s must be non-negative and interval_s must be positive")
        tid = trace["id"]
        deadline = time.monotonic() + settle_s
        max_polls = max(2, int(settle_s / interval_s) + 2)
        prev_count: int | None = None
        full, spans = trace, []
        for _attempt in range(max_polls):
            full = self.get_trace(tid)
            spans = self.get_spans(tid, size=2000)
            count = full.get("span_count")
            stable = isinstance(count, int) and count == prev_count
            issues = _completion_issues(full, spans, stable)
            if not issues:
                return _annotate_completion(full, True, []), spans
            prev_count = count if isinstance(count, int) else None
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return _annotate_completion(full, False, issues), spans
            time.sleep(min(interval_s, remaining))
        issues = _completion_issues(full, spans, False)
        issues.append("trace settlement poll cap reached")
        return _annotate_completion(full, False, issues), spans

    # --- cleanup --------------------------------------------------------------

    def eval_trace_ids(self, prefixes: tuple[str, ...] = ("e2e-",),
                       page_size: int = 100, max_pages: int = 500) -> list[str]:
        """Ids of traces whose thread chat_id starts with one of `prefixes`.

        The skill's own turns use sessions `e2e-<suite>-…` and `e2e-judge-…`, so
        `("e2e-",)` selects exactly what this skill created — never your real
        Telegram/CLI/job traces.
        """
        ids: list[str] = []
        for page in range(1, max_pages + 1):
            data = self._get("/traces", {"project_name": self.project,
                                         "page": page, "size": page_size})
            content = data.get("content", [])
            for t in content:
                chat = _chat_id(t.get("thread_id")) or ""
                if any(chat.startswith(p) for p in prefixes):
                    ids.append(t["id"])
            if len(content) < page_size:
                break
        return ids

    def eval_trace_ids_for_run(self, run_id: str,
                               page_size: int = 100, max_pages: int = 500) -> list[str]:
        """Ids of eval-owned CLI/judge sessions and exact-marked operator turns."""
        if not valid_run_id(run_id):
            raise ValueError(
                "run_id must look like 20260715T151102Z01234567 "
                "(legacy timestamp-only ids are also accepted)")
        ids: list[str] = []
        for page in range(1, max_pages + 1):
            data = self._get("/traces", {"project_name": self.project,
                                         "page": page, "size": page_size})
            content = data.get("content", [])
            for trace in content:
                chat = _chat_id(trace.get("thread_id")) or ""
                session_owned = chat.startswith("e2e-") and _session_has_run_id(chat, run_id)
                if session_owned or _operator_trace_has_run_id(trace, run_id):
                    ids.append(trace["id"])
            if len(content) < page_size:
                break
        return ids

    def delete_traces(self, ids: list[str]) -> int:
        """Batch-delete traces (Opik caps a batch at 1000). Returns count deleted."""
        for start in range(0, len(ids), 1000):
            self._post("/traces/delete", {"ids": ids[start:start + 1000]})
        return len(ids)
