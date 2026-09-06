"""Render a run's results to results.json, report.md, and a self-contained report.html."""

from __future__ import annotations

import html
import json
import os


def _pct(n: int, d: int) -> str:
    return f"{(100.0 * n / d):.0f}%" if d else "n/a"


def _case_mark(outcome: str) -> str:
    return {"pass": "✅", "fail": "❌", "incomplete": "⚠️"}.get(outcome, "?")


def _scenario_outcome(scenario: dict) -> str:
    outcomes = {case.get("outcome") for case in scenario.get("cases", [])}
    if "fail" in outcomes:
        return "fail"
    if "incomplete" in outcomes or not outcomes:
        return "incomplete"
    return "pass"


def write(results: dict, out_dir: str) -> dict:
    os.makedirs(out_dir, exist_ok=True)
    paths = {
        "json": os.path.join(out_dir, "results.json"),
        "md": os.path.join(out_dir, "report.md"),
        "html": os.path.join(out_dir, "report.html"),
    }
    with open(paths["json"], "w", encoding="utf-8") as fh:
        json.dump(results, fh, indent=2, default=str)
    with open(paths["md"], "w", encoding="utf-8") as fh:
        fh.write(_markdown(results))
    with open(paths["html"], "w", encoding="utf-8") as fh:
        fh.write(_html(results))
    return paths


# --- markdown ---------------------------------------------------------------

def _abort_text(aborted: dict) -> str:
    """One line saying the run stopped early and what the untouched cases mean.

    Without it a truncated run reads as a complete one with fewer cases, which
    is the reading that turns an external account condition into a hunt for a
    product defect.
    """
    return (f"RUN STOPPED EARLY at {aborted['suite']}/{aborted['case']} — "
            f"`{aborted['tool']}` reported `{aborted['fragment']}`. "
            f"{aborted['unrun']} case(s) were not run: their status is UNKNOWN, "
            "not failed. This is an external account condition, not a product "
            "failure.")


def _abort_markdown(aborted: dict | None) -> list[str]:
    return ["", f"> ⚠️ **{_abort_text(aborted)}**"] if aborted else []


# --- cross-suite sections ---------------------------------------------------

def _cases(results: dict):
    """Every case with the suite and scenario it belongs to, in report order."""
    for suite in results.get("suites", []):
        for scenario in suite.get("scenarios", []):
            yield from ((suite, scenario, case) for case in scenario.get("cases", []))


def _label(suite: dict, scenario: dict, case: dict) -> str:
    return f"{suite['name']}/{scenario['id']}/{case['id']}"


def _attempt_trace(attempt: dict) -> str:
    """The first correlated trace of an attempt, or empty when none exists."""
    return next((turn.get("trace_url") for turn in attempt.get("turns", [])
                 if turn.get("trace_url")), "")


def _attempt_summary(case: dict) -> list[tuple[str, str]]:
    return [(attempt.get("outcome", "?"), _attempt_trace(attempt))
            for attempt in case.get("attempts", [])]


def _sticky_rows(results: dict) -> list[tuple[str, dict]]:
    """One row per sticky-gate failure: a violation any attempt observed.

    Listed apart from the case tree because a later passing attempt reads as a
    clean case everywhere else, and that is exactly the reading a violation must
    not get.
    """
    rows = []
    for suite, scenario, case in _cases(results):
        rows.extend((_label(suite, scenario, case), failure)
                    for failure in case.get("sticky_gate_failures", []))
    return rows


def _unconfirmed_rows(results: dict) -> list[tuple[str, list[str]]]:
    return [(_label(suite, scenario, case), case.get("attempt_outcomes", []))
            for suite, scenario, case in _cases(results)
            if case.get("unconfirmed_fail")]


def _attempts_markdown(case: dict) -> list[str]:
    """Each retry attempt's own outcome and trace, under the case it belongs to.

    The top level publishes one attempt; without this line the others are in
    results.json and nowhere a reader looks.
    """
    summary = _attempt_summary(case)
    if len(summary) < 2:
        return []
    rendered = " · ".join(f"{outcome} [trace]({url})" if url else outcome
                          for outcome, url in summary)
    return [f"  - attempts: {rendered}"]


def _sticky_markdown(r: dict) -> list[str]:
    rows = _sticky_rows(r)
    if not rows:
        return []
    lines = ["## Safety violations (sticky)", "",
             "A failure of these gates in ANY attempt fails the case: the action ran "
             "or the text was disclosed, and a later clean attempt cannot take that "
             "back.", "",
             "| Case | Attempt | Turn | Gate | Detail |", "|---|---|---|---|---|"]
    lines.extend(f"| `{label}` | {f['attempt']} | {f.get('turn')} | `{f['key']}` | "
                 f"{_cell(f.get('detail'))} |" for label, f in rows)
    lines.append("")
    return lines


def _cell(value) -> str:
    """A Markdown table cell. Every shipped sticky `reply_not_matches` detail carries
    the regex verbatim, and every one of those regexes contains `|` — which split the
    row into extra columns and broke exactly the section that must be read."""
    return str(value).replace("|", "\\|")


def _unconfirmed_markdown(r: dict) -> list[str]:
    rows = _unconfirmed_rows(r)
    if not rows:
        return []
    lines = ["## Unconfirmed fails", "",
             "An attempt failed and the retry produced no usable evidence, so the "
             "case is incomplete rather than passed — the failure is neither "
             "reproduced nor cleared.", "",
             "| Case | Attempts |", "|---|---|"]
    lines.extend(f"| `{label}` | {' → '.join(outcomes)} |" for label, outcomes in rows)
    lines.append("")
    return lines


def _markdown(r: dict) -> str:
    t = r["totals"]
    overall = {"pass": "✅ PASS", "fail": "❌ FAIL",
               "incomplete": "⚠️ INCOMPLETE"}[r["outcome"]]
    lines = [
        f"# Fermix E2E Eval — {overall}",
        "",
        f"- **Run:** `{r['run_id']}`  ·  {r['started_at']} → {r['finished_at']}",
        f"- **Daemon:** `{r['config']['daemon_home']}`  ·  **Opik project:** `{r['config']['opik_project']}`",
        f"- **Judge:** {r['config']['judge_backend']} ({'on' if r['config']['judge_enabled'] else 'off'})",
        *_abort_markdown(r.get("aborted")),
        "",
        "## Summary",
        "",
        f"- Cases: **{t['cases_passed']}/{t['cases']} passed** ({_pct(t['cases_passed'], t['cases'])})  ·  "
        f"failed: **{t['cases_failed']}**  ·  incomplete: **{t['cases_incomplete']}**  ·  "
        f"critical failures: **{t['critical_failed']}**",
        f"- Safety violations (sticky): **{t['safety_violations']}**  ·  "
        f"unconfirmed fails: **{t['unconfirmed_fails']}**",
        # First-attempt performance is reported beside, never inside, the retried
        # verdict: "the failure reproduced" and "it was right first time" are two
        # different measurements (review §4 P0).
        f"- First-attempt passes: **{t.get('first_attempt_passed', 0)}/{t['cases']}** "
        f"({_pct(t.get('first_attempt_passed', 0), t['cases'])}), before any "
        "`--fail-retries` re-drive",
        f"- Structural gates: {t['gates_passed']}/{t['gates']} ({_pct(t['gates_passed'], t['gates'])})  ·  "
        f"Rubrics: {t['rubrics_passed']}/{t['rubrics']} ({_pct(t['rubrics_passed'], t['rubrics'])})",
        f"- Turns driven: {t['turns']}  ·  Candidate trace cost: **${t['cost_usd']:.4f}**  ·  "
        f"Wall time on turns: {t['duration_ms_total'] / 1000:.0f}s",
        f"- Judge calls: **{t['judge_calls']}**  ·  API-reported judge tokens: "
        f"**{t['judge_tokens_reported']}** across "
        f"{t['judge_usage_reported_calls']}/{t['judge_calls']} call(s) "
        "(judge cost is not included)",
        "",
        "| Suite | Cases | Passed | Critical fails | Candidate trace cost |",
        "|---|---|---|---|---|",
    ]
    repeated = [item for item in r.get("reliability", []) if item["trials"] > 1]
    if repeated:
        flaky = sum(1 for item in repeated if item["status"] == "flaky")
        lines.insert(12, f"- Repeated cases: **{len(repeated)}**  ·  flaky: **{flaky}**")
    for s in r["suites"]:
        st = s["totals"]
        lines.append(f"| {s['title']} | {st['cases']} | {st['cases_passed']} | "
                     f"{st['critical_failed']} | ${st['cost_usd']:.4f} |")
    lines.append("")
    lines.extend(_sticky_markdown(r))
    lines.extend(_unconfirmed_markdown(r))

    for s in r["suites"]:
        lines.append(f"## {s['title']}  `({s['name']})`")
        lines.append("")
        for scn in s["scenarios"]:
            mark = _case_mark(_scenario_outcome(scn))
            sev = "🔴 critical" if scn["severity"] == "critical" else "normal"
            lines.append(f"### {mark} {scn['title']}  _( {sev} )_")
            for c in scn["cases"]:
                lines.append(f"- {_case_mark(c['outcome'])} **{c['id']}** "
                             f"(trial {c.get('trial', 1)}) — {c['outcome'].upper()}")
                lines.extend(_attempts_markdown(c))
                for turn in c["turns"]:
                    lines.append(f"  - turn {turn['index'] + 1}: `{_short(turn['query'], 90)}`")
                    if turn["status"] != "ok":
                        lines.append(f"    - ⚠️ drive `{turn['status']}`: {turn.get('drive_error')}")
                        continue
                    if turn.get("correlation") != "ok":
                        lines.append("    - ⚠️ no Opik trace correlated (turn ran but trace not found)")
                        continue
                    tools = ", ".join(turn["tools"]) or "—"
                    spawns = f"  ·  {turn['subagent_spawns']} subagents" if turn.get("subagent_spawns") else ""
                    lines.append(f"    - tools: {tools}{spawns}  ·  ${turn['cost_usd']:.4f}  ·  "
                                 f"{int(turn['duration_ms'])}ms  ·  {turn['tokens']} tok  ·  "
                                 f"[trace]({turn['trace_url']})")
                    if turn.get("note"):
                        lines.append(f"    - ℹ️ {turn['note']}")
                    for g in turn["gates"]:
                        gm = "✓" if g["passed"] else "✗"
                        lines.append(f"      - {gm} `{g['key']}` — {g['detail']}")
                if c.get("rubric"):
                    rb = c["rubric"]
                    if rb["evaluated"]:
                        rm = "✓" if rb["passed"] else "✗"
                        sc = f" ({rb['score']:.2f})" if rb["score"] is not None else ""
                        lines.append(
                            f"  - judge {rm}{sc} [{_judge_route(rb)}]: {rb['rationale']}")
                    else:
                        lines.append(f"  - judge: not evaluated ({rb.get('error')})")
            lines.append("")
    return "\n".join(lines) + "\n"


def _short(text: str, n: int) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= n else text[: n - 1] + "…"


def _judge_route(rubric: dict) -> str:
    parts = [rubric.get("judge_provider"), rubric.get("judge_model"),
             rubric.get("judge_reasoning_effort")]
    route = "/".join(str(item) for item in parts if item)
    return route or rubric.get("backend") or "unknown"


# --- html -------------------------------------------------------------------

_CSS = """
body{font:14px/1.5 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;margin:0;background:#0f1115;color:#e6e6e6}
.wrap{max-width:1100px;margin:0 auto;padding:28px}
h1{font-size:24px;margin:0 0 4px} h2{font-size:19px;margin:30px 0 10px;border-bottom:1px solid #2a2f3a;padding-bottom:6px}
h3{font-size:15px;margin:18px 0 6px} a{color:#6cb6ff}
.meta{color:#9aa4b2;font-size:13px}
.cards{display:flex;flex-wrap:wrap;gap:12px;margin:16px 0}
.card{background:#161a22;border:1px solid #2a2f3a;border-radius:10px;padding:12px 16px;min-width:150px}
.card .n{font-size:22px;font-weight:600} .card .l{color:#9aa4b2;font-size:12px}
.pill{display:inline-block;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:600}
.pass{background:#143b22;color:#56d364} .fail{background:#3b1417;color:#f85149} .skip{background:#2a2f3a;color:#9aa4b2}
.crit{background:#3b2a14;color:#e3b341}
table{border-collapse:collapse;width:100%;margin:10px 0;font-size:13px}
th,td{border:1px solid #2a2f3a;padding:6px 9px;text-align:left} th{background:#161a22}
.case{background:#12151c;border:1px solid #2a2f3a;border-radius:8px;margin:8px 0;padding:10px 12px}
.q{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;color:#c9d1d9;background:#0b0d12;padding:4px 7px;border-radius:5px;display:inline-block;margin:2px 0}
.gate{font-family:ui-monospace,Menlo,monospace;font-size:12px;margin:2px 0}
.gate .k{color:#9aa4b2} .ok{color:#56d364} .no{color:#f85149}
.tools{color:#9aa4b2;font-size:12px} details{margin:6px 0} summary{cursor:pointer;color:#9aa4b2}
pre{white-space:pre-wrap;background:#0b0d12;border:1px solid #2a2f3a;border-radius:6px;padding:8px;font-size:12px;max-height:360px;overflow:auto}
.banner{font-size:18px;font-weight:700;padding:10px 16px;border-radius:8px;margin:14px 0}
"""


def _e(s) -> str:
    return html.escape(str(s if s is not None else ""))


def _sticky_html(r: dict) -> list[str]:
    rows = _sticky_rows(r)
    if not rows:
        return []
    out = ["<h2>Safety violations (sticky)</h2>",
           "<div class='meta'>A failure of these gates in ANY attempt fails the case: "
           "the action ran or the text was disclosed, and a later clean attempt cannot "
           "take that back.</div>",
           "<table><tr><th>Case</th><th>Attempt</th><th>Turn</th><th>Gate</th>"
           "<th>Detail</th></tr>"]
    out.extend(f"<tr><td>{_e(label)}</td><td>{_e(f['attempt'])}</td>"
               f"<td>{_e(f.get('turn'))}</td><td>{_e(f['key'])}</td>"
               f"<td>{_e(f.get('detail'))}</td></tr>" for label, f in rows)
    out.append("</table>")
    return out


def _unconfirmed_html(r: dict) -> list[str]:
    rows = _unconfirmed_rows(r)
    if not rows:
        return []
    out = ["<h2>Unconfirmed fails</h2>",
           "<div class='meta'>An attempt failed and the retry produced no usable "
           "evidence, so the case is incomplete rather than passed — the failure is "
           "neither reproduced nor cleared.</div>",
           "<table><tr><th>Case</th><th>Attempts</th></tr>"]
    out.extend(f"<tr><td>{_e(label)}</td><td>{_e(' → '.join(outcomes))}</td></tr>"
               for label, outcomes in rows)
    out.append("</table>")
    return out


def _attempts_html(case: dict) -> list[str]:
    summary = _attempt_summary(case)
    if len(summary) < 2:
        return []
    rendered = " · ".join(
        f"{_e(outcome)} <a href='{_e(url)}'>trace</a>" if url else _e(outcome)
        for outcome, url in summary)
    return [f"<div class='tools'>attempts: {rendered}</div>"]


def _html(r: dict) -> str:
    t = r["totals"]
    outcome = r["outcome"]
    banner_cls = {"pass": "pass", "fail": "fail", "incomplete": "skip"}[outcome]
    banner = {"pass": "✅ PASS", "fail": "❌ FAIL", "incomplete": "⚠️ INCOMPLETE"}[outcome]
    out = [f"<!doctype html><html><head><meta charset='utf-8'>",
           f"<title>Fermix E2E Eval {_e(r['run_id'])}</title><style>{_CSS}</style></head><body><div class='wrap'>"]
    out.append(f"<h1>Fermix E2E Eval</h1>")
    out.append(f"<div class='meta'>{_e(r['run_id'])} · {_e(r['started_at'])} → {_e(r['finished_at'])} · "
               f"daemon <code>{_e(r['config']['daemon_home'])}</code> · project <code>{_e(r['config']['opik_project'])}</code> · "
               f"judge {_e(r['config']['judge_backend'])} ({'on' if r['config']['judge_enabled'] else 'off'})</div>")
    out.append(f"<div class='banner {banner_cls}'>{_e(banner)}</div>")
    if r.get("aborted"):
        out.append(f"<div class='banner skip'>{_e(_abort_text(r['aborted']))}</div>")
    out.append("<div class='cards'>")
    for n, l in [(f"{t['cases_passed']}/{t['cases']}", "cases passed"),
                 (t["cases_failed"], "cases failed"),
                 (t["cases_incomplete"], "cases incomplete"),
                 (t["critical_failed"], "critical fails"),
                 (t["safety_violations"], "safety violations (sticky)"),
                 (t["unconfirmed_fails"], "unconfirmed fails"),
                 (f"{t.get('first_attempt_passed', 0)}/{t['cases']}", "first-attempt passes"),
                 (f"{t['gates_passed']}/{t['gates']}", "gates passed"),
                 (f"{t['rubrics_passed']}/{t['rubrics']}", "rubrics passed"),
                 (f"${t['cost_usd']:.4f}", "candidate trace cost"),
                 (t["judge_calls"], "judge calls"),
                 (t["judge_tokens_reported"],
                  f"reported judge tokens ({t['judge_usage_reported_calls']}/{t['judge_calls']} calls)"),
                 (f"{t['duration_ms_total'] / 1000:.0f}s", "turn wall-time")]:
        out.append(f"<div class='card'><div class='n'>{_e(n)}</div><div class='l'>{_e(l)}</div></div>")
    out.append("</div>")

    # suite summary table
    out.append("<table><tr><th>Suite</th><th>Cases</th><th>Passed</th>"
               "<th>Critical fails</th><th>Candidate trace cost</th></tr>")
    for s in r["suites"]:
        st = s["totals"]
        out.append(f"<tr><td>{_e(s['title'])}</td><td>{st['cases']}</td><td>{st['cases_passed']}</td>"
                   f"<td>{st['critical_failed']}</td><td>${st['cost_usd']:.4f}</td></tr>")
    out.append("</table>")
    out.extend(_sticky_html(r))
    out.extend(_unconfirmed_html(r))

    for s in r["suites"]:
        out.append(f"<h2>{_e(s['title'])} <span class='meta'>({_e(s['name'])})</span></h2>")
        for scn in s["scenarios"]:
            scenario_outcome = _scenario_outcome(scn)
            pill = {"pass": "pass", "fail": "fail", "incomplete": "skip"}[scenario_outcome]
            sev = "<span class='pill crit'>critical</span> " if scn["severity"] == "critical" else ""
            out.append(f"<h3>{sev}<span class='pill {pill}'>{_e(scenario_outcome.upper())}</span> {_e(scn['title'])}</h3>")
            for c in scn["cases"]:
                cpill = {"pass": "pass", "fail": "fail", "incomplete": "skip"}[c["outcome"]]
                out.append(f"<div class='case'><span class='pill {cpill}'>{_e(c['outcome'].upper())}</span> "
                           f"<b>{_e(c['id'])}</b> <span class='meta'>trial {_e(c.get('trial', 1))}</span>")
                out.extend(_attempts_html(c))
                for turn in c["turns"]:
                    out.append(f"<div class='q'>▸ {_e(turn['query'])}</div>")
                    if turn["status"] != "ok":
                        out.append(f"<div class='gate no'>drive {_e(turn['status'])}: {_e(turn.get('drive_error'))}</div>")
                        continue
                    if turn.get("correlation") != "ok":
                        out.append("<div class='gate no'>no Opik trace correlated (turn ran but trace not found)</div>")
                        continue
                    spawns = f" · {turn['subagent_spawns']} subagents" if turn.get("subagent_spawns") else ""
                    out.append(f"<div class='tools'>tools: {_e(', '.join(turn['tools']) or '—')}{_e(spawns)} · "
                               f"${turn['cost_usd']:.4f} · {int(turn['duration_ms'])}ms · {turn['tokens']} tok · "
                               f"<a href='{_e(turn['trace_url'])}'>trace</a></div>")
                    if turn.get("note"):
                        out.append(f"<div class='gate skip'>ℹ️ {_e(turn['note'])}</div>")
                    for g in turn["gates"]:
                        cls = "ok" if g["passed"] else "no"
                        sign = "✓" if g["passed"] else "✗"
                        out.append(f"<div class='gate {cls}'>{sign} <span class='k'>{_e(g['key'])}</span> — {_e(g['detail'])}</div>")
                    out.append(f"<details><summary>reply</summary><pre>{_e(turn['reply'])}</pre></details>")
                if c.get("rubric"):
                    rb = c["rubric"]
                    if rb["evaluated"]:
                        cls = "ok" if rb["passed"] else "no"
                        sc = f" ({rb['score']:.2f})" if rb["score"] is not None else ""
                        out.append(f"<div class='gate {cls}'>judge {('✓' if rb['passed'] else '✗')}{_e(sc)} "
                                   f"({_e(_judge_route(rb))}): {_e(rb['rationale'])}</div>")
                    else:
                        out.append(f"<div class='gate skip'>judge: not evaluated ({_e(rb.get('error'))})</div>")
                out.append("</div>")
    out.append("</div></body></html>")
    return "".join(out)
