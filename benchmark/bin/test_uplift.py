#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8"]
# ///
"""Unit tests for evallib.uplift — the paired agentic-uplift analysis (tools-ON
Fermix vs a baseline arm on the SAME tasks): McNemar exact test + paired CI on the
difference of correlated proportions. Pure, no scipy. Run: `uv run bin/test_uplift.py`."""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

from evallib import uplift  # noqa: E402


# --- McNemar exact ----------------------------------------------------------

def test_mcnemar_all_discordant_one_way_is_significant():
    # 10 tasks Fermix-only-wins -> p = 2 * 0.5^10
    p = uplift.mcnemar_exact(b=10, c=0)
    assert p == pytest.approx(2 * 0.5 ** 10, rel=1e-9)


def test_mcnemar_symmetric_is_one():
    assert uplift.mcnemar_exact(b=5, c=5) == pytest.approx(1.0)


def test_mcnemar_no_discordant_is_one():
    assert uplift.mcnemar_exact(b=0, c=0) == 1.0


def test_mcnemar_is_symmetric_in_args():
    assert uplift.mcnemar_exact(7, 2) == pytest.approx(uplift.mcnemar_exact(2, 7))


# --- paired uplift ----------------------------------------------------------

def test_paired_uplift_fermix_dominates():
    fermix = {f"t{i}": 1.0 for i in range(10)}
    baseline = {f"t{i}": 0.0 for i in range(10)}
    r = uplift.paired_uplift(fermix, baseline, threshold=1.0)
    assert r.n == 10
    assert r.fermix_pass_rate == 1.0
    assert r.baseline_pass_rate == 0.0
    assert r.uplift == pytest.approx(1.0)
    assert r.discordant_fermix_only == 10
    assert r.discordant_baseline_only == 0
    assert r.p_value < 0.01
    assert r.ci_low <= r.uplift <= r.ci_high
    # Newcombe CI must NOT collapse to [1.0, 1.0] at the boundary (the old Wald bug)
    assert r.ci_low < 1.0
    assert r.ci_high - r.ci_low > 0.05


def test_wilson_score_interval_known_values():
    lo, hi = uplift._wilson(10, 10, uplift._Z95)
    assert hi == pytest.approx(1.0)                    # clamped at the boundary
    assert lo == pytest.approx(0.7225, abs=0.005)      # non-degenerate lower bound
    lo5, hi5 = uplift._wilson(5, 10, uplift._Z95)
    assert lo5 < 0.5 < hi5                             # symmetric around 0.5


def test_newcombe_ci_non_degenerate_at_boundary():
    lo, hi = uplift._newcombe_paired_ci(a=0, b=10, c=0, d=0)   # all fermix-only wins
    assert hi - lo > 0.05 and lo < 1.0                 # real width, not [1,1]
    assert lo <= 1.0 and hi <= 1.0


def test_newcombe_ci_contains_zero_when_no_difference():
    lo, hi = uplift._newcombe_paired_ci(a=0, b=0, c=0, d=10)   # both arms fail all
    assert lo <= 0.0 <= hi


def test_uplift_significance_wording_from_exact_p(capsys):
    # b=4,c=0,n=50: exact p=0.125 (NOT significant) — wording must say so even if
    # the CI looks tight, and flag any disagreement.
    fermix = {f"t{i}": (1.0 if i < 4 else 0.0) for i in range(50)}
    baseline = {f"t{i}": 0.0 for i in range(50)}
    r = uplift.paired_uplift(fermix, baseline, threshold=1.0)
    assert r.discordant_fermix_only == 4 and r.discordant_baseline_only == 0
    assert r.p_value == pytest.approx(2 * 0.5 ** 4)    # 0.125
    md = uplift.render_md(r, label="m", suite="s", k=3)
    assert "not significant" in md


def test_paired_uplift_no_difference():
    fermix = {f"t{i}": 1.0 for i in range(6)}
    baseline = {f"t{i}": 1.0 for i in range(6)}
    r = uplift.paired_uplift(fermix, baseline, threshold=1.0)
    assert r.uplift == 0.0
    assert r.p_value == 1.0
    assert r.discordant_fermix_only == 0 and r.discordant_baseline_only == 0


def test_paired_uplift_aligns_on_common_tasks_only():
    fermix = {"a": 1.0, "b": 1.0, "x": 1.0}
    baseline = {"a": 0.0, "b": 1.0, "y": 0.0}     # x, y not shared
    r = uplift.paired_uplift(fermix, baseline, threshold=1.0)
    assert r.n == 2                                # only a, b
    assert r.discordant_fermix_only == 1           # a: fermix pass, baseline fail
    assert r.discordant_baseline_only == 0


def test_paired_uplift_threshold_binarizes_partial_credit():
    fermix = {"a": 0.8, "b": 0.4}
    baseline = {"a": 0.2, "b": 0.4}
    r = uplift.paired_uplift(fermix, baseline, threshold=0.5)
    # a: fermix 0.8>=.5 pass, baseline 0.2 fail -> discordant fermix-only
    # b: both 0.4 fail -> concordant
    assert r.discordant_fermix_only == 1
    assert r.fermix_pass_rate == pytest.approx(0.5)


def test_paired_uplift_requires_common_tasks():
    with pytest.raises(ValueError):
        uplift.paired_uplift({"a": 1.0}, {"b": 0.0}, threshold=1.0)


def test_render_md_has_claim_template():
    fermix = {f"t{i}": 1.0 for i in range(10)}
    baseline = {f"t{i}": (1.0 if i < 4 else 0.0) for i in range(10)}
    r = uplift.paired_uplift(fermix, baseline, threshold=1.0)
    md = uplift.render_md(r, label="gpt-5.5", suite="cap_core", k=3)
    assert "uplift" in md.lower()
    assert "95% CI" in md
    assert "%" in md


def test_arm_io_roundtrip(tmp_path):
    p = str(tmp_path / "arm.json")
    tasks = {"cap/a": {"mean_success": 1.0, "pass_hat_k": 1.0, "n": 3}}
    uplift.write_arm(p, arm="fermix", config_id="gpt-5.5", suite="cap_core", k=3,
                     threshold=1.0, tasks=tasks)
    payload = uplift.load_arm(p)
    assert payload["arm"] == "fermix"
    assert uplift.tasks_success(payload) == {"cap/a": 1.0}


def test_run_uplift_cli_end_to_end(tmp_path, capsys):
    import run_uplift
    f, b = str(tmp_path / "fermix.json"), str(tmp_path / "baseline.json")
    uplift.write_arm(f, arm="fermix", config_id="gpt-5.5", suite="cap_core", k=3, threshold=1.0,
                     tasks={"cap/a": {"mean_success": 1.0, "pass_hat_k": 1.0, "n": 3},
                            "cap/b": {"mean_success": 1.0, "pass_hat_k": 1.0, "n": 3}})
    uplift.write_arm(b, arm="baseline", config_id="gpt-5.5", suite="cap_core", k=3, threshold=1.0,
                     tasks={"cap/a": {"mean_success": 0.0, "pass_hat_k": 0.0, "n": 3},
                            "cap/b": {"mean_success": 1.0, "pass_hat_k": 1.0, "n": 3}})
    assert run_uplift.main(["--fermix", f, "--baseline", b]) == 0
    assert "uplift" in capsys.readouterr().out.lower()


def test_run_uplift_cli_missing_file():
    import run_uplift
    assert run_uplift.main(["--fermix", "/nope.json", "--baseline", "/nope2.json"]) == 2


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
