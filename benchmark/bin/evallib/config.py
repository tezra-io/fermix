"""Runner configuration: load config.yaml, expand paths, apply env overrides."""

from __future__ import annotations

import os
from dataclasses import dataclass, field

import yaml


def _expand(path: str) -> str:
    return os.path.expanduser(os.path.expandvars(path))


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
    backend: str          # fermix | openai | none
    enabled: bool
    model: str


@dataclass
class BudgetCfg:
    max_cost_usd: float
    max_duration_ms: int


@dataclass
class Config:
    daemon: DaemonCfg
    opik: OpikCfg
    judge: JudgeCfg
    budgets: BudgetCfg
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
    with open(cfg_path, "r", encoding="utf-8") as fh:
        raw = yaml.safe_load(fh) or {}

    d = raw.get("daemon", {})
    o = raw.get("opik", {})
    j = raw.get("judge", {})
    b = raw.get("budgets", {})
    r = raw.get("report", {})
    p = raw.get("policy", {})

    fermix_bin = _expand(os.environ.get("FERMIX_EVAL_BIN", d.get("fermix_bin", "fermix")))
    # A relative fermix_bin (e.g. the bundled shim "bin/fermix-shim") resolves
    # against the skill dir, so runs work regardless of the caller's CWD.
    if os.sep in fermix_bin and not os.path.isabs(fermix_bin):
        fermix_bin = os.path.join(skill_dir, fermix_bin)
    daemon = DaemonCfg(
        fermix_home=_expand(os.environ.get("FERMIX_EVAL_HOME", d.get("fermix_home", "~/.fermix-dev"))),
        fermix_bin=fermix_bin,
        default_timeout_ms=int(os.environ.get("FERMIX_EVAL_TIMEOUT_MS", d.get("default_timeout_ms", 300000))),
    )
    opik = OpikCfg(
        base_url=os.environ.get("OPIK_BASE_URL", o.get("base_url", "http://localhost:5173/api/v1/private")).rstrip("/"),
        project=os.environ.get("OPIK_PROJECT", o.get("project", "fermix")),
        poll_timeout_s=int(o.get("poll_timeout_s", 90)),
        poll_interval_s=float(o.get("poll_interval_s", 2)),
        ui_base=o.get("ui_base", "http://localhost:5173").rstrip("/"),
    )
    judge = JudgeCfg(
        backend=os.environ.get("EVAL_JUDGE_BACKEND", j.get("backend", "fermix")),
        enabled=bool(j.get("enabled", False)),
        model=os.environ.get("EVAL_JUDGE_MODEL", j.get("model", "gpt-5.4-mini")),
    )
    budgets = BudgetCfg(
        max_cost_usd=float(b.get("max_cost_usd", 2.0)),
        max_duration_ms=int(b.get("max_duration_ms", 300000)),
    )
    return Config(
        daemon=daemon,
        opik=opik,
        judge=judge,
        budgets=budgets,
        report_dir=os.path.join(skill_dir, r.get("dir", "reports")),
        rubric_failures=p.get("rubric_failures", "warn"),
        skill_dir=skill_dir,
    )
