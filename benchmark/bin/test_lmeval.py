#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8"]
# ///
"""Tests for the lm-evaluation-harness Tier-0 wrapper (bin/run_lmeval.py).

The lm_eval invocation is operator-gated (heavy dep + provider key + real spend);
what's tested here is the command builder and the results-JSON parser, which is the
part that can silently misread a score. Run: `uv run bin/test_lmeval.py`."""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

import run_lmeval  # noqa: E402

# A realistic slice of lm-eval's results JSON (metric keys are "name,filter").
_FIXTURE = {
    "results": {
        "ifeval": {
            "prompt_level_strict_acc,none": 0.72,
            "prompt_level_strict_acc_stderr,none": 0.01,
            "inst_level_strict_acc,none": 0.80,
        },
        "gpqa_diamond_zeroshot": {"acc,none": 0.51, "acc_stderr,none": 0.03},
        "gsm8k": {
            "exact_match,strict-match": 0.90,
            "exact_match,flexible-extract": 0.91,
            "exact_match_stderr,strict-match": 0.02,
        },
    }
}


def test_parser_picks_primary_metric_per_task():
    parsed = run_lmeval.parse_lmeval_results(_FIXTURE)
    assert parsed["ifeval"]["metric"] == "prompt_level_strict_acc"
    assert parsed["ifeval"]["value"] == 0.72
    assert parsed["ifeval"]["filter"] == "none"
    assert parsed["gpqa_diamond_zeroshot"]["value"] == 0.51


def test_parser_disambiguates_gsm8k_dual_filter_deterministically():
    # exact_match exists under strict-match (0.90) AND flexible-extract (0.91);
    # the parser must NOT silently keep whichever JSON-orders first.
    parsed = run_lmeval.parse_lmeval_results(_FIXTURE)
    assert parsed["gsm8k"]["metric"] == "exact_match"
    assert parsed["gsm8k"]["filter"] == "flexible-extract"
    assert parsed["gsm8k"]["value"] == 0.91


def test_parser_ignores_stderr_keys():
    parsed = run_lmeval.parse_lmeval_results(_FIXTURE)
    assert "stderr" not in parsed["ifeval"]["metric"]


def test_parser_handles_empty():
    assert run_lmeval.parse_lmeval_results({}) == {}
    assert run_lmeval.parse_lmeval_results({"results": {}}) == {}


def test_command_builder_uses_chat_endpoint_and_no_key():
    cmd = run_lmeval.build_command("gpt-5.5", "https://api.openai.com/v1",
                                   ["ifeval", "gsm8k"], "/tmp/out", limit=5)
    joined = " ".join(cmd)
    assert "local-chat-completions" in joined
    assert "/chat/completions" in joined
    assert "ifeval,gsm8k" in joined
    assert "--limit 5" in joined
    assert "sk-" not in joined           # key never embedded in argv (goes via env)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
