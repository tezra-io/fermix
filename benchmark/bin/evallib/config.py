"""Runner configuration: load config.yaml, expand paths, apply env overrides."""

from __future__ import annotations

import math
import os
from dataclasses import dataclass, field

import yaml


def _expand(path: str) -> str:
    if not isinstance(path, str) or not path.strip():
        raise ValueError("configuration path must be a non-empty string")
    return os.path.expanduser(os.path.expandvars(path))


def _section(raw: dict, key: str) -> dict:
    value = raw.get(key, {})
    if not isinstance(value, dict):
        raise ValueError(f"config `{key}` must be a map")
    return value


def _positive_int(value, where: str) -> int:
    if isinstance(value, bool):
        raise ValueError(f"config `{where}` must be a positive integer")
    if isinstance(value, int):
        parsed = value
    elif isinstance(value, str) and value.strip().isdigit():
        parsed = int(value.strip())
    else:
        raise ValueError(f"config `{where}` must be a positive integer")
    if parsed <= 0:
        raise ValueError(f"config `{where}` must be a positive integer")
    return parsed


def _positive_float(value, where: str) -> float:
    if isinstance(value, bool):
        raise ValueError(f"config `{where}` must be a positive number")
    try:
        parsed = float(value)
    except (TypeError, ValueError, OverflowError) as exc:
        raise ValueError(f"config `{where}` must be a positive finite number") from exc
    if not math.isfinite(parsed) or parsed <= 0:
        raise ValueError(f"config `{where}` must be a positive number")
    return parsed


def _nonempty_string(value, where: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"config `{where}` must be a non-empty string")
    return value


def _backoff_minutes(raw_value, default: list[int]) -> list[int]:
    """Resolve the usage-limit retry schedule. `EVAL_USAGE_RETRY_BACKOFF_MIN` (a
    comma list like "30,60,120,180", or empty to disable) overrides the yaml list.
    A malformed value raises at load — fail loud rather than silently mis-scheduling."""
    env = os.environ.get("EVAL_USAGE_RETRY_BACKOFF_MIN")
    src = env if env is not None else raw_value
    if src is None:
        return list(default)
    if isinstance(src, str):
        parts = src.split(",")
    elif isinstance(src, (list, tuple)):
        parts = src
    else:
        raise ValueError("usage-limit retry minutes must be a list or comma string")
    return [
        _positive_int(part, "usage_limit.retry_backoff_min[]")
        for part in parts if str(part).strip()
    ]


@dataclass
class DaemonCfg:
    fermix_home: str
    fermix_bin: str
    default_timeout_ms: int


@dataclass
class OpikCfg:
    base_url: str
    project: str
    poll_timeout_s: int
    poll_interval_s: float
    ui_base: str


@dataclass
class JudgeCfg:
    backend: str          # openai | none
    enabled: bool
    model: str | None


@dataclass
class BudgetCfg:
    max_cost_usd: float
    max_duration_ms: int


@dataclass
class UsageLimitCfg:
    # Minutes to wait (in order) before each retry after a usage/rate/quota limit,
    # then give up (abort at the pointer). Escalating backoff rides out a
    # subscription session-limit window (hours long, with an unreliable self-report).
    # Empty list = fail-fast: abort on the first limit without waiting.
    retry_backoff_min: list[int] = field(default_factory=lambda: [30, 60, 120, 180])


@dataclass
class Config:
    daemon: DaemonCfg
    opik: OpikCfg
    judge: JudgeCfg
    budgets: BudgetCfg
    usage_limit: UsageLimitCfg
    report_dir: str
    rubric_failures: str  # warn | fail
    skill_dir: str

    @property
    def env(self) -> dict:
        """Environment for driving `fermix ask` against the Opik-enabled daemon."""
        e = dict(os.environ)
        e["FERMIX_HOME"] = self.daemon.fermix_home
        return e


def load(skill_dir: str, path: str | None = None) -> Config:
    cfg_path = path or os.path.join(skill_dir, "config.yaml")
    try:
        with open(cfg_path, "r", encoding="utf-8") as fh:
            raw = yaml.safe_load(fh) or {}
    except yaml.YAMLError as exc:
        raise ValueError(f"invalid YAML in {cfg_path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise ValueError("config top level must be a map")

    d = _section(raw, "daemon")
    o = _section(raw, "opik")
    j = _section(raw, "judge")
    b = _section(raw, "budgets")
    r = _section(raw, "report")
    p = _section(raw, "policy")

    fermix_bin = _expand(os.environ.get("FERMIX_EVAL_BIN", d.get("fermix_bin", "fermix")))
    # A relative fermix_bin (e.g. the bundled shim "bin/fermix-shim") resolves
    # against the skill dir, so runs work regardless of the caller's CWD.
    if os.sep in fermix_bin and not os.path.isabs(fermix_bin):
        fermix_bin = os.path.join(skill_dir, fermix_bin)
    daemon = DaemonCfg(
        fermix_home=_expand(os.environ.get("FERMIX_EVAL_HOME", d.get("fermix_home", "~/.fermix-dev"))),
        fermix_bin=fermix_bin,
        default_timeout_ms=_positive_int(
            os.environ.get("FERMIX_EVAL_TIMEOUT_MS", d.get("default_timeout_ms", 300000)),
            "daemon.default_timeout_ms"),
    )
    base_url = _nonempty_string(
        os.environ.get("OPIK_BASE_URL", o.get("base_url", "http://localhost:5173/api/v1/private")),
        "opik.base_url")
    project = _nonempty_string(
        os.environ.get("OPIK_PROJECT", o.get("project", "fermix")), "opik.project")
    ui_base = _nonempty_string(o.get("ui_base", "http://localhost:5173"), "opik.ui_base")
    opik = OpikCfg(
        base_url=base_url.rstrip("/"),
        project=project,
        poll_timeout_s=_positive_int(o.get("poll_timeout_s", 90), "opik.poll_timeout_s"),
        poll_interval_s=_positive_float(o.get("poll_interval_s", 2), "opik.poll_interval_s"),
        ui_base=ui_base.rstrip("/"),
    )
    backend = os.environ.get("EVAL_JUDGE_BACKEND", j.get("backend", "openai"))
    if backend not in ("openai", "none"):
        raise ValueError("config `judge.backend` must be openai or none")
    enabled = j.get("enabled", False)
    if not isinstance(enabled, bool):
        raise ValueError("config `judge.enabled` must be a boolean")
    model = None
    if backend == "openai":
        model = os.environ.get("EVAL_JUDGE_MODEL", j.get("model"))
        if not isinstance(model, str) or not model.strip():
            raise ValueError(
                "config `judge.model` must be a non-empty string for openai judging")
        model = model.strip()
    judge = JudgeCfg(backend=backend, enabled=enabled, model=model)
    budgets = BudgetCfg(
        max_cost_usd=_positive_float(b.get("max_cost_usd", 2.0), "budgets.max_cost_usd"),
        max_duration_ms=_positive_int(b.get("max_duration_ms", 300000),
                                      "budgets.max_duration_ms"),
    )
    u = _section(raw, "usage_limit")
    usage_limit = UsageLimitCfg(
        retry_backoff_min=_backoff_minutes(u.get("retry_backoff_min"), [30, 60, 120, 180]),
    )
    report_dir = _nonempty_string(r.get("dir", "reports"), "report.dir")
    rubric_failures = p.get("rubric_failures", "fail")
    if rubric_failures not in ("fail", "warn"):
        raise ValueError("config `policy.rubric_failures` must be fail or warn")
    return Config(
        daemon=daemon,
        opik=opik,
        judge=judge,
        budgets=budgets,
        usage_limit=usage_limit,
        report_dir=os.path.join(skill_dir, report_dir),
        rubric_failures=rubric_failures,
        skill_dir=skill_dir,
    )
