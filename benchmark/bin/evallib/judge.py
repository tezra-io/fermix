"""LLM-as-judge for per-case rubrics (the quality half of hybrid grading).

Backends:
  fermix  — drive `fermix ask` on a dedicated e2e-judge-* session (no extra creds;
            always available when the dev daemon is up). Judge turns produce their
            own Opik traces under thread cli:e2e-judge-*, kept out of the graded set.
  openai  — POST an OpenAI-compatible /chat/completions (EVAL_JUDGE_API_KEY,
            EVAL_JUDGE_BASE_URL, judge.model). An independent judge.
  none    — skip; rubrics are reported as not evaluated.

Structural gates remain the hard safety/flow signal; the judge only scores prose.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from dataclasses import dataclass

from .driver import drive_with_usage_retry

_PROMPT = """You are a strict evaluator of an AI assistant's reply.

Decide whether the reply satisfies the RUBRIC. Judge only the rubric; ignore style.
Return ONLY a single-line JSON object, no prose, no code fences:
{{"pass": true or false, "score": 0.0 to 1.0, "rationale": "one sentence"}}

USER QUERY:
{query}

ASSISTANT REPLY:
{reply}

RUBRIC (must hold for pass=true):
{rubric}
"""


@dataclass
class JudgeResult:
    evaluated: bool
    passed: bool | None
    score: float | None
    rationale: str
    error: str | None = None
    backend: str = ""


def _extract_json(text: str) -> dict | None:
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        return None
    try:
        return json.loads(text[start:end + 1])
    except json.JSONDecodeError:
        return None


def _verdict_from(text: str, backend: str) -> JudgeResult:
    data = _extract_json(text or "")
    if not data or "pass" not in data:
        return JudgeResult(evaluated=False, passed=None, score=None, rationale="",
                           error=f"judge returned unparseable verdict: {text[:160]!r}",
                           backend=backend)
    return JudgeResult(
        evaluated=True,
        passed=bool(data.get("pass")),
        score=float(data["score"]) if isinstance(data.get("score"), (int, float)) else None,
        rationale=str(data.get("rationale", "")).strip(),
        backend=backend,
    )


def _judge_fermix(cfg, query: str, reply: str, rubric: str, tag: str) -> JudgeResult:
    prompt = _PROMPT.format(query=query, reply=reply, rubric=rubric)
    # A limit during judging pollutes rubric scores too, so the judge turn rides the
    # same usage-limit backoff (raising UsageLimitHit only once the schedule is spent).
    res, _sess = drive_with_usage_retry(
        cfg, f"e2e-judge-{tag}", prompt, min(cfg.daemon.default_timeout_ms, 120000),
        f"judge {tag}")
    if not res.ok:
        return JudgeResult(evaluated=False, passed=None, score=None, rationale="",
                           error=f"fermix judge turn failed: {res.status}/{res.error}",
                           backend="fermix")
    return _verdict_from(res.response or "", "fermix")


def _judge_openai(cfg, query: str, reply: str, rubric: str) -> JudgeResult:
    api_key = os.environ.get("EVAL_JUDGE_API_KEY")
    if not api_key:
        return JudgeResult(evaluated=False, passed=None, score=None, rationale="",
                           error="openai judge needs EVAL_JUDGE_API_KEY", backend="openai")
    base = os.environ.get("EVAL_JUDGE_BASE_URL", "https://api.openai.com/v1").rstrip("/")
    prompt = _PROMPT.format(query=query, reply=reply, rubric=rubric)
    body = json.dumps({
        "model": cfg.judge.model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0,
    }).encode()
    req = urllib.request.Request(
        base + "/chat/completions", data=body,
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.load(resp)
        content = data["choices"][0]["message"]["content"]
    except (urllib.error.URLError, KeyError, IndexError, json.JSONDecodeError) as exc:
        return JudgeResult(evaluated=False, passed=None, score=None, rationale="",
                           error=f"openai judge error: {exc}", backend="openai")
    return _verdict_from(content, "openai")


def judge_case(cfg, query: str, reply: str, rubric: str, tag: str) -> JudgeResult:
    backend = cfg.judge.backend
    if backend == "none":
        return JudgeResult(evaluated=False, passed=None, score=None, rationale="",
                           error="judge backend is 'none'", backend="none")
    if backend == "openai":
        return _judge_openai(cfg, query, reply, rubric)
    return _judge_fermix(cfg, query, reply, rubric, tag)
