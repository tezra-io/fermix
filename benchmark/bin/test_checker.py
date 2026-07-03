#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7"]
# ///
"""Tests for the checker scoring tier — the SafeRm teardown guard, the
`run_checker` mechanism (exit/json modes + recorded errors), and the suite
`checker:` block validation. Pure / temp-dir; no daemon. Run: `uv run bin/test_checker.py`."""
from __future__ import annotations

import os
import stat
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

from evallib import checker, safe_rm, suites  # noqa: E402


# --- SafeRm teardown guard --------------------------------------------------

def test_safe_rm_rejects_traversal():
    with pytest.raises(safe_rm.SafeRmError):
        safe_rm.check("/root/eval/../../etc", "/root/eval")


def test_safe_rm_rejects_outside_root():
    with pytest.raises(safe_rm.SafeRmError):
        safe_rm.check("/other/place", "/root/eval")


def test_safe_rm_rejects_root_itself_and_too_shallow(tmp_path):
    root = os.path.join(str(tmp_path), "ws", "eval")
    os.makedirs(root)
    with pytest.raises(safe_rm.SafeRmError):
        safe_rm.check(root, root, min_below=2)            # root itself
    with pytest.raises(safe_rm.SafeRmError):
        safe_rm.check(os.path.join(root, "task"), root, min_below=2)  # only 1 below


def test_safe_rm_accepts_and_removes_scoped_dir(tmp_path):
    root = os.path.join(str(tmp_path), "ws", "eval")
    scoped = os.path.join(root, "task", "t0")
    os.makedirs(scoped)
    open(os.path.join(scoped, "f.txt"), "w").close()
    safe_rm.rm_rf(scoped, root, min_below=2)
    assert not os.path.exists(scoped)


# --- run_checker ------------------------------------------------------------

def _script(tmp_path, name, body):
    p = os.path.join(str(tmp_path), name)
    with open(p, "w") as fh:
        fh.write(body)
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
    return p


def test_checker_exit_mode_pass(tmp_path):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/ok.sh", "#!/bin/sh\nexit 0\n")
    r = checker.run_checker(str(tmp_path), {"script": "checkers/ok.sh", "mode": "exit"},
                            scoped_dir=str(tmp_path), reply="")
    assert r.score == 1.0 and r.error is None


def test_checker_exit_mode_fail(tmp_path):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/no.sh", "#!/bin/sh\nexit 3\n")
    r = checker.run_checker(str(tmp_path), {"script": "checkers/no.sh", "mode": "exit"},
                            scoped_dir=str(tmp_path), reply="")
    assert r.score == 0.0 and r.error is None


def test_checker_json_mode_parses_score(tmp_path):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/j.sh", '#!/bin/sh\necho \'{"score": 0.5, "detail": "half"}\'\n')
    r = checker.run_checker(str(tmp_path), {"script": "checkers/j.sh", "mode": "json"},
                            scoped_dir=str(tmp_path), reply="")
    assert r.score == 0.5 and "half" in r.detail


def test_checker_sees_workspace_and_reply_env(tmp_path):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    # passes only if both env vars are wired through
    _script(tmp_path, "checkers/env.sh",
            '#!/bin/sh\n[ -n "$FERMIX_EVAL_WORKSPACE" ] && [ "$FERMIX_EVAL_REPLY" = "hi" ] && exit 0 || exit 1\n')
    r = checker.run_checker(str(tmp_path), {"script": "checkers/env.sh", "mode": "exit"},
                            scoped_dir=str(tmp_path), reply="hi")
    assert r.score == 1.0


def test_checker_missing_script_records_error(tmp_path):
    r = checker.run_checker(str(tmp_path), {"script": "checkers/nope.sh", "mode": "exit"},
                            scoped_dir=str(tmp_path), reply="")
    assert r.score == 0.0 and r.error and "not found" in r.error.lower()


def test_checker_bad_json_records_error(tmp_path):
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/garbage.sh", "#!/bin/sh\necho not-json\n")
    r = checker.run_checker(str(tmp_path), {"script": "checkers/garbage.sh", "mode": "json"},
                            scoped_dir=str(tmp_path), reply="")
    assert r.score == 0.0 and r.error


@pytest.mark.parametrize("line", ["0.5", "null", "[1, 2]", '"done"'])
def test_checker_non_object_json_records_error_not_crash(tmp_path, line):
    # Valid JSON that isn't a {score,...} object must be a recorded 0-score, NOT an
    # uncaught TypeError that discards the whole (expensive) sweep. Regression for
    # the crash where `float(data["score"])` on a bare number/null/list raised.
    os.makedirs(os.path.join(str(tmp_path), "checkers"), exist_ok=True)
    _script(tmp_path, "checkers/bare.sh", f"#!/bin/sh\necho '{line}'\n")
    r = checker.run_checker(str(tmp_path), {"script": "checkers/bare.sh", "mode": "json"},
                            scoped_dir=str(tmp_path), reply="")
    assert r.score == 0.0 and r.error and "parse failed" in r.error


# --- suite `checker:` validation --------------------------------------------

def test_validate_checker_ok():
    problems: list[str] = []
    suites._validate_checker({"script": "checkers/x.py", "mode": "exit"}, "x", problems)
    assert problems == []


def test_validate_checker_requires_script_and_mode():
    problems: list[str] = []
    suites._validate_checker({"mode": "exit"}, "x", problems)
    suites._validate_checker({"script": "x", "mode": "bogus"}, "y", problems)
    assert any("script" in p for p in problems)
    assert any("mode" in p for p in problems)


def test_checker_and_score_mutually_exclusive():
    # a case can't carry both `score:` and `checker:` — validated in _load_one
    problems: list[str] = []
    suites._validate_checker("not-a-map", "x", problems)
    assert any("map" in p for p in problems)


# --- anchor-task oracle/negative proofs (check passes IFF solved; no daemon) -----

import json as _json  # noqa: E402

BENCH = os.path.dirname(HERE)                       # HERE = bin/ -> benchmark/


def _seed(tmp_path, fixture_rel):
    scoped = os.path.join(str(tmp_path), "ws")
    checker.seed_workspace(scoped, os.path.join(BENCH, fixture_rel) if fixture_rel else None)
    return scoped


def test_anchor_pytest_bugfix_oracle_accepts_bug_rejects(tmp_path):
    spec = {"script": "suites/capability/checkers/pytest_business_days.sh", "mode": "exit"}
    scoped = _seed(tmp_path, "suites/capability/fixtures/code/business_days")
    # negative: the seeded module still has the planted bug -> tests fail
    assert checker.run_checker(BENCH, spec, scoped, "").score == 0.0
    # oracle: apply the correct fix -> all tests pass
    mod = os.path.join(scoped, "business_days.py")
    with open(mod) as fh:
        fixed = fh.read().replace("cur.weekday() <= 5", "cur.weekday() <= 4")
    with open(mod, "w") as fh:
        fh.write(fixed)
    assert checker.run_checker(BENCH, spec, scoped, "").score == 1.0


def test_anchor_csv_to_json_oracle_accepts_wrong_rejects(tmp_path):
    spec = {"script": "suites/capability/checkers/csv_to_json.py", "mode": "json"}
    scoped = _seed(tmp_path, "suites/capability/fixtures/code/sales_csv")
    out = os.path.join(scoped, "sales_by_region.json")
    with open(out, "w") as fh:                       # oracle: correct values, descending
        _json.dump({"South": 89.96, "North": 67.47, "West": 47.50, "East": 0.0}, fh)
    assert checker.run_checker(BENCH, spec, scoped, "").score == 1.0
    with open(out, "w") as fh:                       # negative: drops East + wrong order
        _json.dump({"North": 67.47, "South": 89.96, "West": 47.50}, fh)
    assert checker.run_checker(BENCH, spec, scoped, "").score < 1.0


def test_anchor_landlord_email_oracle_accepts_sparse_rejects(tmp_path):
    spec = {"script": "suites/capability/checkers/landlord_email.py", "mode": "json"}
    scoped = _seed(tmp_path, None)
    good = ("Dear Mr. Adeyemi,\n\nI am writing to request repair of the heating, which has "
            "not worked since November 3. Per lease clause 14.2, please arrange a fix within "
            "14 days.\n\nSincerely,\nSam")
    with open(os.path.join(scoped, "email.txt"), "w") as fh:
        fh.write(good)
    assert checker.run_checker(BENCH, spec, scoped, "").score == 1.0
    with open(os.path.join(scoped, "email.txt"), "w") as fh:
        fh.write("fix the heat")                     # negative: misses ~all constraints
    assert checker.run_checker(BENCH, spec, scoped, "").score < 1.0


def test_landlord_keyword_stuffing_is_gated(tmp_path):
    # A blob that name-drops every constraint token but is NOT an email must score far
    # below a real email — regression for the structure gate (this used to score 1.0).
    spec = {"script": "suites/capability/checkers/landlord_email.py", "mode": "json"}
    scoped = _seed(tmp_path, None)
    with open(os.path.join(scoped, "email.txt"), "w") as fh:
        fh.write("heating november 3 clause 14.2 dear mr adeyemi 14 days sincerely please")
    assert checker.run_checker(BENCH, spec, scoped, "").score < 0.5


def test_landlord_accepts_idiomatic_phrasing(tmp_path):
    # "November 3rd" and "14-day deadline" are correct phrasings the old regexes wrongly
    # rejected (biasing against models that write naturally). They must now count.
    spec = {"script": "suites/capability/checkers/landlord_email.py", "mode": "json"}
    scoped = _seed(tmp_path, None)
    good = ("Dear Mr. Adeyemi,\n\nI am writing to request that the broken heating be repaired; "
            "it has not worked since November 3rd. As set out in lease clause 14.2, please "
            "arrange a fix within a 14-day deadline. I would appreciate your prompt "
            "attention.\n\nSincerely,\nSam")
    with open(os.path.join(scoped, "email.txt"), "w") as fh:
        fh.write(good)
    assert checker.run_checker(BENCH, spec, scoped, "").score == 1.0


def test_expense_total_checker_oracle_and_negative(tmp_path):
    spec = {"script": "suites/capability/checkers/expense_total.py", "mode": "json"}
    scoped = _seed(tmp_path, None)
    with open(os.path.join(scoped, "answer.txt"), "w") as fh:
        fh.write("1419.35")
    assert checker.run_checker(BENCH, spec, scoped, "").score == 1.0
    with open(os.path.join(scoped, "answer.txt"), "w") as fh:
        fh.write("1438.10")                          # forgot the refund is negative
    assert checker.run_checker(BENCH, spec, scoped, "").score == 0.0


def test_order_extract_checker_oracle_and_negative(tmp_path):
    spec = {"script": "suites/capability/checkers/order_extract.py", "mode": "json"}
    scoped = _seed(tmp_path, None)
    with open(os.path.join(scoped, "answer.txt"), "w") as fh:
        fh.write("NW-48213|94.74|6|2026-03-03")
    assert checker.run_checker(BENCH, spec, scoped, "").score == 1.0
    with open(os.path.join(scoped, "answer.txt"), "w") as fh:
        fh.write("NW-48213|80.50|3|2026-03-03")      # subtotal + line-count traps
    assert checker.run_checker(BENCH, spec, scoped, "").score == 0.0


def test_anchor_invoice_bug_oracle_accepts_bug_rejects(tmp_path):
    spec = {"script": "suites/capability/checkers/pytest_invoice.sh", "mode": "exit"}
    scoped = _seed(tmp_path, "suites/capability/fixtures/code/invoice")
    # negative: the planted discount-dropping bug -> visible + hidden tests fail
    assert checker.run_checker(BENCH, spec, scoped, "").score == 0.0
    # oracle: route the subtotal through line_total (applies the discount) -> all pass
    mod = os.path.join(scoped, "invoice.py")
    with open(mod) as fh:
        fixed = fh.read().replace(
            'subtotal = sum(ln["qty"] * ln["unit_price"] for ln in lines)',
            'subtotal = sum(line_total(ln["qty"], ln["unit_price"], ln["discount_pct"]) for ln in lines)')
    with open(mod, "w") as fh:
        fh.write(fixed)
    assert checker.run_checker(BENCH, spec, scoped, "").score == 1.0


def test_anchor_order_pipeline_oracle_accepts_bug_rejects(tmp_path):
    spec = {"script": "suites/capability/checkers/pytest_order.sh", "mode": "exit"}
    scoped = _seed(tmp_path, "suites/capability/fixtures/code/order_pipeline")
    # negative: the `>` boundary bug -> visible + hidden boundary tests fail
    assert checker.run_checker(BENCH, spec, scoped, "").score == 0.0
    # oracle: fix the tier boundaries in catalog (> -> >=) -> all pass, incl. hidden
    cat = os.path.join(scoped, "catalog.py")
    with open(cat) as fh:
        fixed = (fh.read().replace("if qty > 100:", "if qty >= 100:")
                 .replace("elif qty > 50:", "elif qty >= 50:")
                 .replace("elif qty > 10:", "elif qty >= 10:"))
    with open(cat, "w") as fh:
        fh.write(fixed)
    assert checker.run_checker(BENCH, spec, scoped, "").score == 1.0


def test_order_pipeline_symptom_patch_still_fails_hidden(tmp_path):
    # a symptom-level "fix" (special-case the failing qty=50 in report) must NOT pass —
    # the hidden boundary tests (10/100) catch it. Guards the anti-shortcut discipline.
    spec = {"script": "suites/capability/checkers/pytest_order.sh", "mode": "exit"}
    scoped = _seed(tmp_path, "suites/capability/fixtures/code/order_pipeline")
    rep = os.path.join(scoped, "report.py")
    with open(rep) as fh:
        body = fh.read()
    hack = body.replace(
        "    subtotal_cents = sum(line_total_cents(sku, qty) for sku, qty in lines)",
        "    if lines == [(\"A\", 50)] and tax_percent == 0:\n        return 450.00\n"
        "    subtotal_cents = sum(line_total_cents(sku, qty) for sku, qty in lines)")
    with open(rep, "w") as fh:
        fh.write(hack)
    assert checker.run_checker(BENCH, spec, scoped, "").score == 0.0   # hidden tests still fail


def test_subagent_synthesis_checker_grades_coverage(tmp_path):
    spec = {"script": "suites/capability/checkers/subagent_synthesis.py", "mode": "json"}
    scoped = _seed(tmp_path, None)
    sp = os.path.join(scoped, "summary.txt")
    with open(sp, "w") as fh:
        fh.write("FALCON-G7 OTTER-M3 HERON-S9 BADGER-X2 — all four covered")
    assert checker.run_checker(BENCH, spec, scoped, "").score == 1.0
    with open(sp, "w") as fh:
        fh.write("FALCON-G7 OTTER-M3 HERON-S9")   # dropped one branch
    assert checker.run_checker(BENCH, spec, scoped, "").score == 0.75


def test_cron_job_output_checker(tmp_path):
    spec = {"script": "suites/capability/checkers/cron_job_output.py", "mode": "json"}
    scoped = _seed(tmp_path, None)
    fp = os.path.join(scoped, "job_out.txt")
    with open(fp, "w") as fh:
        fh.write("CRON-OK-7731\n")
    assert checker.run_checker(BENCH, spec, scoped, "").score == 1.0
    os.remove(fp)                                  # job didn't run / agent didn't wait
    assert checker.run_checker(BENCH, spec, scoped, "").score == 0.0


def test_skill_created_checker(tmp_path):
    spec = {"script": "suites/capability/checkers/skill_created.py", "mode": "json"}
    scoped = _seed(tmp_path, None)
    sp = os.path.join(scoped, "skills.txt")
    with open(sp, "w") as fh:
        fh.write("self-knowledge\nbrowser-guidance\neval-echo\n")
    assert checker.run_checker(BENCH, spec, scoped, "").score == 1.0
    with open(sp, "w") as fh:
        fh.write("self-knowledge\nbrowser-guidance\n")   # skill not created
    assert checker.run_checker(BENCH, spec, scoped, "").score == 0.0


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
