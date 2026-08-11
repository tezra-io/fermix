"""Structural grading: evaluate one turn's Opik trace+spans against an expect map.

Pure and deterministic — no I/O. Each present expect key becomes one GateResult.
The vocabulary mirrors suites/SCHEMA.md and is validated up front in suites.py.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from math import isfinite

from .opik import parse_ts, text_of, trace_status


@dataclass
class GateResult:
    key: str
    passed: bool
    detail: str


_URL_RE = re.compile(r"https?://[^\s\"'<>\\\)\]]+")
_URL_TRAILING = ".,;:!?"


def evidence_urls(view: "TurnView", limit: int = 1000) -> list[str]:
    """Every URL any tool span carried (input or output), deduped in order.

    The single source of truth for the tool-URL inventory: the
    `reply_urls_in_evidence` gate checks reply links against it, and the judge
    evidence includes it verbatim (run_eval `_tool_evidence`) so rubric prose
    and the deterministic gate can never disagree about what the tools
    returned. Scans ALL tool spans — per-span byte truncation applied later to
    judge evidence cannot hide a URL from this list.
    """
    seen: set[str] = set()
    urls: list[str] = []
    for span in view.tool_spans:
        blob = json.dumps({"i": span.get("input"), "o": span.get("output")},
                          ensure_ascii=False, default=str)
        for url in _URL_RE.findall(blob):
            url = url.rstrip(_URL_TRAILING)
            if url not in seen:
                seen.add(url)
                urls.append(url)
            if len(urls) >= limit:
                return urls
    return urls


def reply_urls(reply: str) -> list[str]:
    """URLs in a reply, markdown-trimmed, deduped in order."""
    seen: set[str] = set()
    urls: list[str] = []
    for url in _URL_RE.findall(reply):
        url = url.rstrip(_URL_TRAILING).rstrip("*_`")
        if url and url not in seen:
            seen.add(url)
            urls.append(url)
    return urls


@dataclass
class TurnView:
    """Flattened, grade-ready projection of a trace + its spans."""
    reply: str
    cost: float
    duration_ms: float
    tokens: int
    iterations: int | None
    llm_count: int
    status: str
    tool_spans: list[dict]          # type == tool, ordered by start_time
    llm_spans: list[dict]           # type == llm
    tool_names: list[str]
    subagent_spawns: int            # nested `subagent:*` worker wrapper spans
    main_models: list[str]          # models on main-agent llm spans
    main_providers: list[str]       # providers on main-agent llm spans (parallel to main_models)
    main_efforts: list[str]         # reasoning effort on main-agent llm spans (parallel)
    subagent_models: list[str]      # models on nested subagent-worker llm spans
    trace_complete: bool            # proven settled by OpikClient.await_complete
    telemetry_complete: bool        # required metrics are present and well-formed
    telemetry_issues: list[str]
    duration_source: str            # driver_elapsed | missing
    cost_reported: bool
    duration_reported: bool
    tokens_reported: bool
    iterations_reported: bool

    @classmethod
    def build(cls, trace: dict, spans: list[dict],
              elapsed_ms: float | None = None,
              require_duration: bool = True) -> "TurnView":
        tool_spans = sorted(
            [s for s in spans if s.get("type") == "tool"],
            key=lambda s: parse_ts(s.get("start_time")) or datetime.min.replace(tzinfo=timezone.utc),
        )
        llm_spans = [s for s in spans if s.get("type") == "llm"]
        # Subagent workers nest in the parent trace as `subagent:<id>` wrapper spans
        # (the fan-out tool itself is the `subagents` span — no trailing colon).
        spawns = len([s for s in spans if (s.get("name") or "").startswith("subagent:")])
        # Split llm-span models by whether the span nests under a subagent worker
        # wrapper (delegated work) or runs directly under the main turn.
        by_id = {s.get("id"): s for s in spans}
        main_models, subagent_models, main_providers, main_efforts = [], [], [], []
        for s in llm_spans:
            model = s.get("model") or (s.get("metadata") or {}).get("model")
            if not model:
                continue
            if _under_subagent(s, by_id):
                subagent_models.append(model)
            else:
                md = s.get("metadata") or {}
                main_models.append(model)
                # provider distinguishes configs that share a model slug (openai vs
                # openai_codex both serve gpt-5.5); reasoning effort distinguishes the
                # same model run at different effort — both belong in the config key.
                main_providers.append(s.get("provider") or md.get("provider") or "?")
                main_efforts.append(md.get("reasoning_effort") or "default")
        meta = trace.get("metadata") or {}
        usage = trace.get("usage") or {}
        cost, cost_ok = _float_metric(trace.get("total_estimated_cost"))
        tokens, tokens_ok = _int_metric(usage.get("total_tokens"))
        iterations, iterations_ok = _int_metric(meta.get("iterations"))
        duration, duration_ok, duration_source = _duration_metric(elapsed_ms)
        trace_complete = trace.get("_eval_trace_complete") is True
        issues = list(trace.get("_eval_trace_issues") or [])
        if not trace_complete and not issues:
            issues.append("trace was not proven settled by OpikClient.await_complete")
        issues.extend(_metric_issues(
            cost_ok, duration_ok, tokens_ok, iterations_ok, require_duration))
        return cls(
            reply=text_of(trace.get("output")),
            cost=cost,
            duration_ms=duration,
            tokens=tokens,
            iterations=iterations if iterations_ok else None,
            llm_count=int(trace.get("llm_span_count") or len(llm_spans)),
            status=trace_status(trace),
            tool_spans=tool_spans,
            llm_spans=llm_spans,
            tool_names=[s.get("name") for s in tool_spans],
            subagent_spawns=spawns,
            main_models=main_models,
            main_providers=main_providers,
            main_efforts=main_efforts,
            subagent_models=subagent_models,
            trace_complete=trace_complete,
            telemetry_complete=not issues,
            telemetry_issues=issues,
            duration_source=duration_source,
            cost_reported=cost_ok,
            duration_reported=duration_ok,
            tokens_reported=tokens_ok,
            iterations_reported=iterations_ok,
        )


_EMPHASIS_RX = re.compile(r"\*\*|__")


def _strip_emphasis(text: str) -> str:
    # Models bold their conclusions ("Recommendation: **No-go**"), splitting
    # tokens mid-phrase and making every multi-token reply gate flaky. Strip
    # only the paired markers; a single '*' (math, bullets) is left alone.
    return _EMPHASIS_RX.sub("", text)


def _float_metric(value) -> tuple[float, bool]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0.0, False
    try:
        number = float(value)
    except (TypeError, ValueError, OverflowError):
        return 0.0, False
    return (number, True) if isfinite(number) and number >= 0 else (0.0, False)


def _int_metric(value) -> tuple[int, bool]:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return 0, False
    return value, True


def _duration_metric(elapsed_ms: float | None) -> tuple[float, bool, str]:
    elapsed, elapsed_ok = _float_metric(elapsed_ms)
    if elapsed_ok:
        return elapsed, True, "driver_elapsed"
    return 0.0, False, "missing"


def _metric_issues(cost_ok: bool, duration_ok: bool, tokens_ok: bool,
                   iterations_ok: bool, require_duration: bool = True) -> list[str]:
    # Cost and iterations are exporter/provider-dependent: an OAuth or not-yet-priced
    # model reports no cost (Opik owns pricing), and some paths emit no iteration
    # count. They are reported when present but never gate gradability — a settled
    # trace plus tokens and driver latency is the completeness signal.
    del cost_ok, iterations_ok
    checks = (
        (duration_ok or not require_duration, "duration missing or invalid"),
        (tokens_ok, "usage.total_tokens missing or invalid"),
    )
    return [detail for ok, detail in checks if not ok]


def _under_subagent(span: dict, by_id: dict) -> bool:
    """True if this span nests (any depth) under a `subagent:*` worker wrapper.

    Delegated workers carry their own `subagent:<name>` general wrapper span; the
    worker's llm/tool spans hang under it. Main-turn spans never have such an
    ancestor. Bounded by the span count (cycle-guarded) so a malformed parent
    chain can't loop.
    """
    seen: set = set()
    cur = span.get("parent_span_id")
    while cur and cur not in seen:
        seen.add(cur)
        parent = by_id.get(cur)
        if parent is None:
            return False
        if (parent.get("name") or "").startswith("subagent:"):
            return True
        cur = parent.get("parent_span_id")
    return False


def _first_start(view: TurnView, name: str) -> datetime | None:
    for s in view.tool_spans:
        if s.get("name") == name:
            return parse_ts(s.get("start_time"))
    return None


def _explicit_block(span: dict) -> bool:
    """Accept only typed evidence that policy stopped execution before it began."""
    metadata = span.get("metadata") or {}
    enforcement = metadata.get("policy_enforcement")
    if not isinstance(enforcement, dict):
        return False
    return (
        enforcement.get("source") in {"sandbox", "netguard"}
        and enforcement.get("decision") in {"deny", "hardline"}
        and enforcement.get("phase") == "pre_execution"
    )


def _tool_inputs_text(view: TurnView) -> str:
    inputs = [span.get("input") for span in view.tool_spans]
    return json.dumps(inputs, ensure_ascii=False, sort_keys=True, default=str)


def grade(trace: dict, spans: list[dict], expect: dict,
          elapsed_ms: float | None = None,
          require_duration: bool = True) -> list[GateResult]:
    v = TurnView.build(
        trace, spans, elapsed_ms=elapsed_ms, require_duration=require_duration)
    out: list[GateResult] = []

    def add(key, passed, detail):
        out.append(GateResult(key=key, passed=passed, detail=detail))

    present = set(v.tool_names)

    add("trace_complete", v.trace_complete,
        "trace settled" if v.trace_complete else "; ".join(v.telemetry_issues))
    add("telemetry_complete", v.telemetry_complete,
        "required telemetry present" if v.telemetry_complete
        else "; ".join(v.telemetry_issues))

    if "tools_any" in expect:
        want = expect["tools_any"]
        hit = [t for t in want if t in present]
        add("tools_any", bool(hit), f"any{want}: present={hit or 'NONE'} (ran={sorted(present)})")

    if "tools_all" in expect:
        want = expect["tools_all"]
        missing = [t for t in want if t not in present]
        add("tools_all", not missing, f"all{want}: missing={missing or 'none'} (ran={sorted(present)})")

    if "tools_none" in expect:
        forbidden = expect["tools_none"]
        bad = [t for t in forbidden if t in present]
        add("tools_none", not bad, f"none{forbidden}: violating={bad or 'none'}")

    if "tools_none_succeeded" in expect:
        forbidden = expect["tools_none_succeeded"]
        attempted = [s for s in v.tool_spans if s.get("name") in forbidden]
        succeeded = [s.get("name") for s in attempted if not s.get("error_info")]
        unproven = [s.get("name") for s in attempted
                    if s.get("error_info") and not _explicit_block(s)]
        ok = not succeeded and not unproven
        detail = (f"none of {forbidden} may succeed: succeeded={succeeded or 'none'}, "
                  "errored without typed pre-execution policy evidence="
                  f"{unproven or 'none'}")
        add("tools_none_succeeded", ok, detail)

    if "tools_in_order" in expect:
        seq = expect["tools_in_order"]
        starts = [(t, _first_start(v, t)) for t in seq]
        missing = [t for t, ts in starts if ts is None]
        if missing:
            add("tools_in_order", False, f"order{seq}: missing={missing}")
        else:
            ok = all(starts[i][1] <= starts[i + 1][1] for i in range(len(starts) - 1))
            add("tools_in_order", ok, f"order{seq}: {'holds' if ok else 'out of order'}")

    if "tool_inputs_match_all" in expect:
        patterns = expect["tool_inputs_match_all"]
        inputs_text = _tool_inputs_text(v)
        missing = [pattern for pattern in patterns if re.search(pattern, inputs_text) is None]
        add("tool_inputs_match_all", not missing,
            f"all input patterns present; missing={missing or 'none'}")

    if "min_subagent_spawns" in expect:
        n = expect["min_subagent_spawns"]
        add("min_subagent_spawns", v.subagent_spawns >= n,
            f">= {n} subagent worker(s) spawned (got {v.subagent_spawns})")

    # Model routing: every main-turn llm span must match (default model used), and
    # — separately — every nested subagent-worker llm span must match (the cheaper
    # configured subagent model, or a per-call override). subagent_model_matches
    # also REQUIRES >=1 worker span, so it fails loud if fan-out didn't nest into
    # the trace (the "can't see inside the subagent" case) rather than passing vacuously.
    if "main_model_matches" in expect:
        rx = expect["main_model_matches"]
        bad = [m for m in v.main_models if re.search(rx, m) is None]
        ok = bool(v.main_models) and not bad
        detail = f"/{rx}/ main models={v.main_models or 'NONE'}"
        if bad:
            detail += f" violating={bad}"
            # Fallback fingerprint: violating models appear AND the expected
            # pattern also appears (just later in the span sequence).  This means
            # the primary provider failed its initial call and the daemon fell back
            # to a different provider for the turn; the expected model only shows
            # up in a later span (e.g. memory review re-resolves the primary).
            good = [m for m in v.main_models if re.search(rx, m) is not None]
            if good:
                detail += " [PROVIDER FALLBACK DETECTED]"
        add("main_model_matches", ok, detail)

    if "subagent_model_matches" in expect:
        rx = expect["subagent_model_matches"]
        bad = [m for m in v.subagent_models if re.search(rx, m) is None]
        ok = bool(v.subagent_models) and not bad
        add("subagent_model_matches", ok,
            f"/{rx}/ subagent models={v.subagent_models or 'NONE'}"
            + (f" violating={bad}" if bad else ""))

    if "min_tool_calls" in expect:
        n = expect["min_tool_calls"]
        add("min_tool_calls", len(v.tool_spans) >= n, f">= {n} tool calls (got {len(v.tool_spans)})")
    if "max_tool_calls" in expect:
        n = expect["max_tool_calls"]
        add("max_tool_calls", len(v.tool_spans) <= n, f"<= {n} tool calls (got {len(v.tool_spans)})")

    if expect.get("reply_urls_in_evidence"):
        inventory = evidence_urls(v)
        cited = reply_urls(v.reply)
        missing = [u for u in cited if u not in inventory]
        add("reply_urls_in_evidence", not missing,
            f"{len(cited)} reply url(s) vs {len(inventory)} tool-evidence url(s): "
            f"missing={missing or 'none'}")

    if "reply_matches" in expect:
        rx = expect["reply_matches"]
        ok = re.search(rx, _strip_emphasis(v.reply)) is not None
        add("reply_matches", ok, f"/{rx}/ {'matched' if ok else 'NOT matched'}")
    if "reply_not_matches" in expect:
        rx = expect["reply_not_matches"]
        ok = re.search(rx, _strip_emphasis(v.reply)) is None
        add("reply_not_matches", ok, f"/{rx}/ {'absent' if ok else 'PRESENT (forbidden)'}")

    if "status" in expect:
        want = expect["status"]
        add("status", v.status == want, f"status={v.status} (want {want})")

    if expect.get("no_tool_errors") is True:
        errs = [s.get("name") for s in v.tool_spans if s.get("error_info")]
        add("no_tool_errors", not errs, f"tool errors: {errs or 'none'}")

    if expect.get("llm_status_ok") is True:
        statuses = [(s.get("metadata") or {}).get("status") for s in v.llm_spans]
        bad = [status for status in statuses if status != "ok"]
        ok = bool(statuses) and not bad
        add("llm_status_ok", ok, f"llm statuses: {'all ok' if ok else bad or 'NONE'}")

    if "min_llm_calls" in expect:
        n = expect["min_llm_calls"]
        add("min_llm_calls", v.llm_count >= n, f">= {n} llm calls (got {v.llm_count})")
    if "max_llm_calls" in expect:
        n = expect["max_llm_calls"]
        add("max_llm_calls", v.llm_count <= n, f"<= {n} llm calls (got {v.llm_count})")

    if "max_iterations" in expect:
        n = expect["max_iterations"]
        if v.iterations is None:
            add("max_iterations", True, f"<= {n} (iterations not reported; n/a)")
        else:
            add("max_iterations", v.iterations <= n, f"<= {n} iterations (got {v.iterations})")

    if "max_cost_usd" in expect:
        n = float(expect["max_cost_usd"])
        if v.cost_reported:
            add("max_cost_usd", v.cost <= n, f"<= ${n:.2f} (got ${v.cost:.4f})")
        else:
            # Opik owns pricing; an unpriced/OAuth model reports no cost — n/a, not a fail.
            add("max_cost_usd", True, f"<= ${n:.2f} (cost not reported by Opik; n/a)")
    if "max_duration_ms" in expect:
        n = expect["max_duration_ms"]
        ok = v.duration_reported and v.duration_ms <= n
        detail = (f"<= {n}ms (got {int(v.duration_ms)}ms from {v.duration_source})"
                  if v.duration_reported else "duration missing")
        add("max_duration_ms", ok, detail)
    if "max_tokens" in expect:
        n = expect["max_tokens"]
        ok = v.tokens_reported and v.tokens <= n
        detail = f"<= {n} tokens (got {v.tokens})" if v.tokens_reported else "tokens missing"
        add("max_tokens", ok, detail)

    return out
