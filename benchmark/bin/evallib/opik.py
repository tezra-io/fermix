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

import json
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone


class OpikError(Exception):
    pass


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


class OpikClient:
    def __init__(self, base_url: str, project: str, timeout_s: float = 8.0):
        self.base = base_url.rstrip("/")
        self.project = project
        self.timeout = timeout_s

    def _get(self, path: str, params: dict | None = None) -> dict:
        url = self.base + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return json.load(resp)
        except urllib.error.URLError as exc:
            raise OpikError(f"GET {url}: {exc}") from exc
        except json.JSONDecodeError as exc:
            raise OpikError(f"GET {url}: bad JSON: {exc}") from exc

    def _post(self, path: str, body: dict) -> int:
        req = urllib.request.Request(
            self.base + path, data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"}, method="POST",
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
                        seen_ids: set[str]) -> dict | None:
        """Newest unseen trace whose thread chat_id == session, matching the query.

        Each `fermix ask --session S` turn becomes one `agent:main` trace under
        thread_id `<channel>:S`. Multi-turn cases reuse S, so disambiguate by
        unseen-id + start_time + input-text match.
        """
        qn = " ".join(query.split()).strip().lower()
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
            if after is not None and ts is not None and ts < after:
                continue
            candidates.append(t)
        if not candidates:
            return None
        if len(candidates) == 1:
            return candidates[0]

        # Several turns share the thread: prefer an exact input match, else contains.
        def score(t: dict) -> tuple:
            inp = " ".join(text_of(t.get("input")).split()).strip().lower()
            exact = inp == qn
            # Guard against an empty input matching everything (`"" in qn`).
            contains = bool(inp) and (qn in inp or inp in qn)
            ts = parse_ts(t.get("start_time")) or datetime.min.replace(tzinfo=timezone.utc)
            return (exact, contains, ts)

        return max(candidates, key=score)

    def poll_for_turn(self, session: str, query: str, after: datetime | None,
                      seen_ids: set[str], timeout_s: float, interval_s: float) -> dict | None:
        """Block until the turn's trace appears in Opik or timeout elapses."""
        deadline = time.monotonic() + timeout_s
        while True:
            hit = self.find_turn_trace(session, query, after, seen_ids)
            if hit is not None:
                return hit
            if time.monotonic() >= deadline:
                return None
            time.sleep(interval_s)

    def find_marker_trace(self, thread_prefix: str, marker: str, after: datetime | None,
                          seen_ids: set[str]) -> dict | None:
        """Newest unseen trace on a `<thread_prefix>*` thread whose input contains `marker`.

        Operator-assisted cases (e.g. a real Telegram message for the streaming
        suite) can't be correlated by session — the operator's chat owns the
        thread_id. The runner embeds a unique marker in the message text instead.
        """
        mk = marker.lower()
        for t in self.recent_traces():
            if t.get("id") in seen_ids:
                continue
            if not (t.get("thread_id") or "").startswith(thread_prefix):
                continue
            ts = parse_ts(t.get("start_time"))
            if after is not None and ts is not None and ts < after:
                continue
            if mk in " ".join(text_of(t.get("input")).split()).lower():
                return t
        return None

    def poll_for_marker(self, thread_prefix: str, marker: str, after: datetime | None,
                        seen_ids: set[str], timeout_s: float, interval_s: float) -> dict | None:
        """Block until a marker-bearing trace appears on the thread prefix, or timeout."""
        deadline = time.monotonic() + timeout_s
        while True:
            hit = self.find_marker_trace(thread_prefix, marker, after, seen_ids)
            if hit is not None:
                return hit
            if time.monotonic() >= deadline:
                return None
            time.sleep(interval_s)

    def await_complete(self, trace: dict, settle_s: float = 60.0,
                       interval_s: float = 2.0) -> tuple[dict, list[dict]]:
        """Wait until a found trace is fully flushed before grading it.

        Opik POSTs the trace and its spans in separate batches, so a trace can be
        discoverable (even with its final reply text) while its spans, usage, and
        cost are still landing — grading then would see 0 tools / $0 (a false fail).
        Re-fetch until the turn has closed (`end_time` set), `span_count >= 1`, all
        spans are retrievable, and `span_count` is stable across two reads. Returns
        the settled (trace, spans); best-effort if it never fully settles.
        """
        tid = trace["id"]
        deadline = time.monotonic() + settle_s
        prev_count = -1
        full, spans = trace, self.get_spans(tid, size=2000)
        while True:
            full = self.get_trace(tid)
            sc = full.get("span_count") or 0
            spans = self.get_spans(tid, size=2000)
            settled = (full.get("end_time") is not None and sc >= 1
                       and len(spans) >= sc and sc == prev_count)
            if settled or time.monotonic() >= deadline:
                return full, spans
            prev_count = sc
            time.sleep(interval_s)

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

    def delete_traces(self, ids: list[str]) -> int:
        """Batch-delete traces (Opik caps a batch at 1000). Returns count deleted."""
        for start in range(0, len(ids), 1000):
            self._post("/traces/delete", {"ids": ids[start:start + 1000]})
        return len(ids)
