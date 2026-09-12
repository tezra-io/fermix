#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "certifi"]
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
    md = uplift.render_md(r, label="m", baseline_label="raw", suite="s", k=3, trials=5,
                          task_ids=sorted(fermix))
    assert "not significant" in md


def test_partial_uplift_is_erased_at_1_but_significant_at_half():
    # A flaky-but-dramatically-better arm: 0.8 mean_success with Fermix vs 0.0 raw.
    # At the OLD threshold 1.0 BOTH arms binarize to fail (0.8 < 1.0) -> concordant ->
    # p=1.0, a real large gain wrongly reads "not significant". At the new 0.5 default
    # the win is discordant fermix-only -> significant. Regression for the uplift bug.
    fermix = {f"t{i}": 0.8 for i in range(10)}
    baseline = {f"t{i}": 0.0 for i in range(10)}
    erased = uplift.paired_uplift(fermix, baseline, threshold=1.0)
    assert erased.discordant_fermix_only == 0 and erased.p_value == 1.0
    real = uplift.paired_uplift(fermix, baseline, threshold=0.5)
    assert real.discordant_fermix_only == 10 and real.p_value < 0.01
    assert real.uplift == pytest.approx(1.0)


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
    md = uplift.render_md(r, label="gpt-5.5", baseline_label="gpt-5.5-raw",
                          suite="cap_web_research", k=3, trials=5, task_ids=sorted(fermix))
    assert "uplift" in md.lower()
    assert "95% CI" in md
    assert "%" in md


def test_arm_io_roundtrip(tmp_path):
    p = str(tmp_path / "arm.json")
    tasks = {"cap/a": {"mean_success": 1.0, "pass_hat_k": 1.0, "n": 3}}
    uplift.write_arm(p, arm="fermix", config_id="gpt-5.5", suite="cap_web_research", k=3,
                     threshold=1.0, tasks=tasks, valid=True)
    payload = uplift.load_arm(p)
    assert payload["arm"] == "fermix"
    assert uplift.tasks_success(payload) == {"cap/a": 1.0}


def test_run_uplift_cli_end_to_end(tmp_path, capsys):
    import run_uplift
    f, b = str(tmp_path / "fermix.json"), str(tmp_path / "baseline.json")
    uplift.write_arm(f, arm="fermix", config_id="gpt-5.5", suite="cap_web_research", k=3, threshold=1.0,
                     valid=True,
                     tasks={"cap/a": {"mean_success": 1.0, "pass_hat_k": 1.0, "n": 3},
                            "cap/b": {"mean_success": 1.0, "pass_hat_k": 1.0, "n": 3}})
    uplift.write_arm(b, arm="baseline", config_id="gpt-5.5", suite="cap_web_research", k=3, threshold=1.0,
                     valid=True,
                     tasks={"cap/a": {"mean_success": 0.0, "pass_hat_k": 0.0, "n": 3},
                            "cap/b": {"mean_success": 1.0, "pass_hat_k": 1.0, "n": 3}})
    assert run_uplift.main(["--fermix", f, "--baseline", b]) == 0
    assert "uplift" in capsys.readouterr().out.lower()


def test_run_uplift_cli_missing_file():
    import run_uplift
    assert run_uplift.main(["--fermix", "/nope.json", "--baseline", "/nope2.json"]) == 2


# --- majority bar -----------------------------------------------------------

def test_majority_threshold_is_strictly_more_than_half():
    # The defect: a 0.5 bar compared with >= called a 2-of-4 tie a "majority".
    assert uplift.majority_threshold(5) == pytest.approx(3 / 5)
    assert uplift.majority_threshold(4) == pytest.approx(3 / 4)
    assert uplift.majority_threshold(1) == pytest.approx(1.0)
    with pytest.raises(ValueError):
        uplift.majority_threshold(0)


def test_a_two_of_four_tie_is_not_a_majority_pass():
    bar = uplift.majority_threshold(4)
    r = uplift.paired_uplift({"a": 0.5}, {"a": 0.75}, threshold=bar)
    assert r.fermix_pass_rate == 0.0        # 2/4 does not clear the bar
    assert r.baseline_pass_rate == 1.0      # 3/4 does


# --- arm compatibility ------------------------------------------------------

def _arm(k=5, threshold=1.0, n=5, ids=("cap/a", "cap/b"), valid=True):
    return {"arm": "fermix", "config_id": "m", "suite": "cap", "k": k, "threshold": threshold,
            "valid": valid,
            "tasks": {i: {"mean_success": 1.0, "pass_hat_k": 1.0, "n": n} for i in ids}}


def test_compare_arms_accepts_matched_arms():
    assert uplift.compare_arms(_arm(), _arm()) == []


def test_compare_arms_refuses_a_k_mismatch():
    problems = uplift.compare_arms(_arm(k=5), _arm(k=3))
    assert any("k" in p for p in problems)


def test_compare_arms_refuses_a_threshold_mismatch():
    assert any("threshold" in p for p in uplift.compare_arms(_arm(), _arm(threshold=0.5)))


def test_compare_arms_refuses_a_trial_count_mismatch():
    assert any("trial" in p for p in uplift.compare_arms(_arm(n=5), _arm(n=3)))


def test_compare_arms_refuses_a_ragged_arm():
    ragged = _arm()
    ragged["tasks"]["cap/b"]["n"] = 2      # tasks ran different trial counts
    assert any("trial" in p for p in uplift.compare_arms(ragged, _arm()))


def test_compare_arms_names_the_excluded_task_ids():
    problems = uplift.compare_arms(_arm(ids=("cap/a", "cap/b")), _arm(ids=("cap/a", "cap/c")))
    joined = " ".join(problems)
    assert "cap/b" in joined and "cap/c" in joined


def test_compare_arms_refuses_an_empty_arm():
    empty = _arm()
    empty["tasks"] = {}
    assert uplift.compare_arms(empty, _arm())


# --- the rendered claim -----------------------------------------------------

def test_render_md_names_only_the_paired_tasks_and_the_real_k_and_n():
    fermix = {"cap/a": 1.0, "cap/b": 1.0}
    baseline = {"cap/a": 0.0, "cap/b": 1.0}
    r = uplift.paired_uplift(fermix, baseline, threshold=1.0)
    md = uplift.render_md(r, label="fermix/m", baseline_label="raw/m", suite="cap",
                          k=5, trials=5, task_ids=sorted(fermix))
    assert "2 paired task" in md
    assert "k=5" in md and "5 trials" in md
    assert "cap/a" in md and "cap/b" in md
    assert "raw/m" in md


# --- CLI refusals -----------------------------------------------------------

def _write_arm(path, *, k=5, threshold=1.0, n=5, tasks=("cap/a", "cap/b"), arm="fermix",
               valid=True):
    uplift.write_arm(path, arm=arm, config_id="m", suite="cap", k=k, threshold=threshold,
                     valid=valid,
                     tasks={t: {"mean_success": 1.0 if arm == "fermix" else 0.0,
                                "pass_hat_k": 1.0, "n": n} for t in tasks})


def test_run_uplift_cli_refuses_mismatched_arms(tmp_path, capsys):
    import run_uplift
    f, b = str(tmp_path / "f.json"), str(tmp_path / "b.json")
    _write_arm(f, tasks=("cap/a", "cap/b"))
    _write_arm(b, k=3, tasks=("cap/a", "cap/c"), arm="baseline")
    assert run_uplift.main(["--fermix", f, "--baseline", b]) == 2
    err = capsys.readouterr().err
    assert "cap/b" in err and "cap/c" in err        # exclusions are published
    assert "k" in err


def test_run_uplift_cli_pairs_matched_arms(tmp_path, capsys):
    import run_uplift
    f, b = str(tmp_path / "f.json"), str(tmp_path / "b.json")
    _write_arm(f)
    _write_arm(b, arm="baseline")
    assert run_uplift.main(["--fermix", f, "--baseline", b]) == 0
    out = capsys.readouterr().out
    assert "2 paired task" in out


def test_run_uplift_cli_refuses_an_invalid_fermix_arm(tmp_path, capsys):
    import run_uplift
    f, b = str(tmp_path / "f.json"), str(tmp_path / "b.json")
    _write_arm(f, valid=False)
    _write_arm(b, arm="baseline")
    assert run_uplift.main(["--fermix", f, "--baseline", b]) == 2
    assert "INVALID measurement" in capsys.readouterr().err


def test_compare_arms_refuses_an_arm_that_never_recorded_its_validity():
    thin = _arm()
    del thin["valid"]
    assert any("records no measurement validity" in p for p in uplift.compare_arms(thin, _arm()))


def test_write_arm_requires_the_validity_answer():
    with pytest.raises(TypeError):
        uplift.write_arm("/dev/null", arm="fermix", config_id="m", suite="cap", k=1,
                         threshold=1.0, tasks={}, valid="yes")


def test_a_true_majority_clears_the_bar_at_every_trial_count():
    # Both arms store mean_success rounded to 4 dp; an exact fractional bar sat just
    # above the stored value at 7/12/14/15/17/19/21 trials and failed a real majority.
    for trials in range(1, 26):
        wins = trials // 2 + 1
        stored = round(wins / trials, 4)
        bar = uplift.majority_threshold(trials)
        result = uplift.paired_uplift({"t": stored}, {"t": 0.0}, threshold=bar)
        assert result.fermix_pass_rate == 1.0, (trials, stored, bar)
        # One short of a majority must still fail.
        short = round((wins - 1) / trials, 4)
        assert uplift.paired_uplift({"t": short}, {"t": 0.0},
                                    threshold=bar).fermix_pass_rate == 0.0, trials


def test_compare_arms_refuses_an_arm_that_never_recorded_its_identity():
    thin = _arm()
    del thin["k"]
    assert any("k missing" in p for p in uplift.compare_arms(thin, _arm()))


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
