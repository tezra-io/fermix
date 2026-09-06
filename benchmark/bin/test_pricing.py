#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "certifi"]
# ///
"""Unit tests for the published-list-price rate card (`evallib.pricing`).

Pure and hermetic apart from two reads of checked-in repo sources: the product's
model catalog (an Elixir file) and, when a run has produced one, the local
leaderboard store. Both are read-only. Run: `uv run bin/test_pricing.py`.

The load-bearing tests here are the two coverage invariants at the bottom. A
rate table rots by ADDITION — someone ships a model, nothing fails, and the
dollar column silently goes blank for that config — so the case sets are derived
from live sources rather than hand-listed, the way `Realtime.CostTracker`'s
`@rates` is pinned to `Config.valid_models/0`.
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import sys
from dataclasses import dataclass

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

from evallib import leaderboard, pricing  # noqa: E402

REPO_ROOT = pathlib.Path(HERE).resolve().parents[1]
BENCHMARK_DIR = pathlib.Path(HERE).resolve().parents[0]


@dataclass(frozen=True)
class Span:
    """Structural stand-in for `grade.LlmSpanUsage`.

    Declared here rather than imported: the card must never depend on the
    grading layer (a rate card that can reach `TurnView.cost` would arm 261
    dormant `max_cost_usd` gates). If these attributes and `grade`'s ever
    diverge, `price/1`'s own validation raises rather than mispricing.
    """
    model: str
    provider: str
    adapter: str | None = None
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    cached_input_tokens: int | None = None
    cache_write_tokens: int | None = None
    errored: bool = False
    under_subagent: bool = False


# --- provider_route ---------------------------------------------------------

def test_codex_adapter_is_its_own_route():
    assert pricing.provider_route("openai", "codex") == "openai_codex"


def test_non_codex_adapters_leave_the_provider_as_the_route():
    # Only the literal "codex" selects a route. An adapter that reads like a
    # provider token must not promote a span onto some other route.
    assert pricing.provider_route("openai", "responses") == "openai"
    assert pricing.provider_route("openai", "openai") == "openai"
    assert pricing.provider_route("openai", "openai_codex") == "openai"
    assert pricing.provider_route("anthropic", "messages") == "anthropic"


def test_adapter_less_spans_keep_their_provider():
    # A census found 852 adapter-less Fermix llm spans (realtime + legacy
    # modules). They route by provider; nothing infers a metered API path from
    # a missing field.
    assert pricing.provider_route("openai", None) == "openai"
    assert pricing.provider_route("ollama", None) == "ollama"


def test_provider_route_rejects_a_missing_provider():
    with pytest.raises(ValueError):
        pricing.provider_route("", "codex")
    with pytest.raises(ValueError):
        pricing.provider_route(None, None)
    with pytest.raises(TypeError):
        pricing.provider_route("openai", 7)


# --- basis rules ------------------------------------------------------------

def test_local_only_spans_are_not_token_billed():
    result = pricing.price([Span("qwen3:32b", "ollama", prompt_tokens=9_000,
                                 completion_tokens=500)])
    assert result.basis == "not_token_billed"
    assert result.cost_usd is None
    assert result.card_version == pricing.CARD_VERSION


def test_no_spans_yields_no_dollar_figure():
    result = pricing.price([])
    assert result.cost_usd is None
    assert result.basis == "not_token_billed"


def test_an_unknown_model_is_unpriced_with_an_actionable_route_name():
    result = pricing.price([Span("gpt-9-nova", "openai", "responses",
                                 prompt_tokens=1_000, completion_tokens=10)])
    assert result.basis == "unpriced"
    assert result.cost_usd is None
    assert result.unpriced_routes == ("openai/gpt-9-nova",)


def test_a_route_with_a_known_rate_gap_is_unpriced_too():
    # UNPRICED_PENDING_RATE records WHY a rate is missing; it never prices.
    result = pricing.price([Span("qwen3:32b", "openrouter", "chat_completions",
                                 prompt_tokens=1_000, completion_tokens=10)])
    assert result.basis == "unpriced"
    assert result.unpriced_routes == ("openrouter/qwen3:32b",)


def test_one_unpriced_span_withholds_the_whole_figure():
    # A partial sum presented as the turn's cost is a wrong number, not a
    # smaller one.
    spans = [Span("gpt-5.5", "openai", "responses", prompt_tokens=1_000_000,
                  completion_tokens=0),
             Span("gpt-9-nova", "openai", "responses", prompt_tokens=1_000,
                  completion_tokens=10)]
    result = pricing.price(spans)
    assert result.cost_usd is None
    assert result.unpriced_routes == ("openai/gpt-9-nova",)


def test_without_cache_counts_the_basis_is_ceiling():
    # The expected state TODAY: no adapter emits cache counts yet, so every run
    # bills cached input at the full input rate and the card is a ceiling.
    result = pricing.price([Span("gpt-5.5", "openai", "responses",
                                 prompt_tokens=1_000_000, completion_tokens=100_000)])
    assert result.basis == "ceiling"
    assert result.cost_usd == pytest.approx(8.00)


def test_with_cache_counts_on_every_span_the_basis_is_cache_aware():
    result = pricing.price([Span("gpt-5.5", "openai", "responses",
                                 prompt_tokens=1_000_000, completion_tokens=100_000,
                                 cached_input_tokens=800_000)])
    assert result.basis == "cache_aware"
    # 200k uncached @ $5 + 800k cached @ $0.50 + 100k out @ $30
    assert result.cost_usd == pytest.approx(1.00 + 0.40 + 3.00)


def test_one_cache_blind_span_drops_the_whole_turn_to_ceiling():
    spans = [Span("gpt-5.5", "openai", "responses", prompt_tokens=1_000_000,
                  completion_tokens=0, cached_input_tokens=0),
             Span("gpt-5.5", "openai", "responses", prompt_tokens=1_000_000,
                  completion_tokens=0)]
    assert pricing.price(spans).basis == "ceiling"


def test_a_write_premium_model_is_not_cache_aware_on_the_read_leg_alone():
    """Half a cache split is not a known cache split.

    `cache_aware` is the strongest label the vocabulary has — aggregate.py spells
    it "priced with every span's cache split known". A GPT-5.6+ span reporting
    only its READ count has half of one: its written tokens stay folded into
    uncached input and bill at 1.00x instead of the vendor's 1.25x, a permanent
    20% understatement on that leg. Granting the label anyway is the module's own
    opening defect — a figure that reads as trustworthy and is not.
    """
    span = Span("gpt-5.6-sol", "openai", "codex", prompt_tokens=1_000_000,
                completion_tokens=1_000, cached_input_tokens=400_000)
    assert pricing.price([span]).basis == "ceiling"


def test_the_same_span_carrying_its_write_count_is_cache_aware():
    span = Span("gpt-5.6-sol", "openai", "codex", prompt_tokens=1_000_000,
                completion_tokens=1_000, cached_input_tokens=400_000,
                cache_write_tokens=100_000)
    assert pricing.price([span]).basis == "cache_aware"


def test_a_model_that_bills_writes_as_input_is_cache_aware_on_the_read_leg_alone():
    # BILLS_AT_INPUT_RATE is the exemption, and the only one: a written token
    # costs exactly what the uncached input it is folded into costs, so nothing
    # is approximated by its absence. Without the exemption every pre-5.6 slug
    # would sit at "ceiling" forever waiting for a count that changes no dollar.
    assert pricing.CARD[("openai", "gpt-5.5")].cache_write_per_mtok \
        is pricing.BILLS_AT_INPUT_RATE
    span = Span("gpt-5.5", "openai", "responses", prompt_tokens=1_000_000,
                completion_tokens=1_000, cached_input_tokens=400_000)
    assert pricing.price([span]).basis == "cache_aware"


def test_an_unestablished_write_leg_also_withholds_cache_aware(monkeypatch):
    # `None` is "nobody established whether this vendor prices writes apart",
    # which a missing count cannot settle either way.
    monkeypatch.setitem(pricing.CARD, ("testvendor", "m1"),
                        pricing.Rate(0.50, 1.50, 0.05, None))
    span = Span("m1", "testvendor", "chat_completions", prompt_tokens=1_000_000,
                completion_tokens=0, cached_input_tokens=400_000)
    assert pricing.price([span]).basis == "ceiling"


def test_one_write_blind_span_drops_the_whole_turn_to_ceiling():
    spans = [Span("gpt-5.6-sol", "openai", "codex", prompt_tokens=1_000_000,
                  completion_tokens=0, cached_input_tokens=0, cache_write_tokens=0),
             Span("gpt-5.6-sol", "openai", "codex", prompt_tokens=1_000_000,
                  completion_tokens=0, cached_input_tokens=0)]
    assert pricing.price(spans).basis == "ceiling"


# --- arithmetic -------------------------------------------------------------

def test_anthropic_prompt_tokens_stay_blended_and_the_cache_counts_come_out_of_them():
    # messages.ex folds input + cache_creation + cache_read into `prompt`. The
    # card subtracts the two cache figures back out; it must never add them on
    # top, which would double-bill every cached token.
    span = Span("claude-opus-4-8", "anthropic", "messages",
                prompt_tokens=100_000, completion_tokens=5_000,
                cached_input_tokens=70_000, cache_write_tokens=20_000)
    result = pricing.price([span])
    expected = (10_000 * 5.00 + 70_000 * 0.50 + 20_000 * 6.25 + 5_000 * 25.00) / 1e6
    assert result.cost_usd == pytest.approx(expected)
    assert result.basis == "cache_aware"


def test_a_subscription_route_is_priced_at_the_same_list_rates():
    # Owner decision 2: one card, API prices, applied uniformly — the Codex row
    # is explicitly a counterfactual, not measured spend.
    result = pricing.price([Span("gpt-5.6-sol", "openai", "codex",
                                 prompt_tokens=1_000_000, completion_tokens=0)])
    assert result.cost_usd == pytest.approx(4.00)
    assert ("openai_codex", "gpt-5.6-sol") in pricing.CARD


def test_a_trace_that_mixes_models_is_priced_per_span():
    # 3.8% of prod and 7.3% of dev traces carry 2-3 distinct (provider, model)
    # pairs; one rate for the trace would misprice all of them.
    spans = [Span("gpt-5.5", "openai", "responses", prompt_tokens=1_000_000,
                  completion_tokens=0),
             Span("claude-sonnet-4-6", "anthropic", "messages",
                  prompt_tokens=1_000_000, completion_tokens=0)]
    assert pricing.price(spans).cost_usd == pytest.approx(5.00 + 3.00)


def test_subagent_spans_are_billed_like_any_other():
    spans = [Span("gpt-5.5", "openai", "responses", prompt_tokens=1_000_000,
                  completion_tokens=0),
             Span("gpt-5.5", "openai", "responses", prompt_tokens=1_000_000,
                  completion_tokens=0, under_subagent=True)]
    assert pricing.price(spans).cost_usd == pytest.approx(10.00)


def test_local_spans_contribute_nothing_beside_a_billed_one():
    spans = [Span("gpt-5.5", "openai", "responses", prompt_tokens=1_000_000,
                  completion_tokens=0),
             Span("qwen3:32b", "ollama", prompt_tokens=500_000, completion_tokens=9_000)]
    result = pricing.price(spans)
    assert result.cost_usd == pytest.approx(5.00)
    assert result.basis == "ceiling"


# --- the two meanings a missing cache rate can carry ------------------------
#
# `BILLS_AT_INPUT_RATE` (the vendor charges no premium/discount, so the tokens
# bill as ordinary input) and `None` (nobody has established the figure) are
# priced differently ON PURPOSE — rule 12 forbids one silently standing in for
# the other. Both legs are exercised against a synthetic card entry so the case
# survives the next audit re-rating a real vendor.

def _carded(monkeypatch, rate: pricing.Rate) -> Span:
    """A span on a throwaway route carrying `rate`, restored after the test."""
    monkeypatch.setitem(pricing.CARD, ("testvendor", "m1"), rate)
    return Span("m1", "testvendor", "chat_completions", prompt_tokens=1_000_000,
                completion_tokens=0, cached_input_tokens=400_000, cache_write_tokens=100_000)


def test_a_vendor_with_no_cache_discount_bills_cached_input_at_the_input_rate(monkeypatch):
    span = _carded(monkeypatch, pricing.Rate(0.50, 1.50, pricing.BILLS_AT_INPUT_RATE,
                                             pricing.BILLS_AT_INPUT_RATE))
    # Every input token — uncached, cached and written — at $0.50/MTok.
    assert pricing.price([span]).cost_usd == pytest.approx(0.50)


def test_an_unestablished_cached_input_rate_refuses_rather_than_guessing(monkeypatch):
    # This is the Mistral defect in miniature: `None` used to fall back to the
    # input rate, which overstated a -90% cached token by 10x in silence.
    span = _carded(monkeypatch, pricing.Rate(0.50, 1.50, None,
                                             pricing.BILLS_AT_INPUT_RATE))
    with pytest.raises(ValueError, match="cached-input rate"):
        pricing.price([span])


def test_an_unestablished_rate_is_only_fatal_when_the_span_uses_that_leg(monkeypatch):
    # A card entry may honestly not know the cache-write price; that must not
    # refuse a span which never wrote to cache.
    monkeypatch.setitem(pricing.CARD, ("testvendor", "m1"),
                        pricing.Rate(0.50, 1.50, 0.05, None))
    span = Span("m1", "testvendor", "chat_completions", prompt_tokens=1_000_000,
                completion_tokens=0, cached_input_tokens=400_000)
    assert pricing.price([span]).cost_usd == pytest.approx(0.30 + 0.02)


# --- spans that reported no usage -------------------------------------------

def test_a_span_without_usage_is_counted_not_priced_as_zero():
    spans = [Span("gpt-5.5", "openai", "responses", prompt_tokens=1_000_000,
                  completion_tokens=0),
             Span("gpt-5.5", "openai", "responses", errored=True)]
    result = pricing.price(spans)
    assert result.cost_usd == pytest.approx(5.00)
    assert result.spans_without_usage == 1


def test_an_errored_span_that_did_report_usage_is_still_billed():
    # Errored calls spend real tokens; only a missing usage map makes them
    # unrecoverable.
    result = pricing.price([Span("gpt-5.5", "openai", "responses", prompt_tokens=1_000_000,
                                 completion_tokens=0, errored=True)])
    assert result.cost_usd == pytest.approx(5.00)
    assert result.spans_without_usage == 0


def test_a_usage_less_span_does_not_decide_the_cache_basis():
    spans = [Span("gpt-5.5", "openai", "responses", prompt_tokens=1_000_000,
                  completion_tokens=0, cached_input_tokens=0),
             Span("gpt-5.5", "openai", "responses", errored=True)]
    assert pricing.price(spans).basis == "cache_aware"


def test_when_nothing_reported_usage_the_count_carries_the_caveat():
    # Documented edge: the sum of nothing is 0.0, and `spans_without_usage` is
    # the only thing telling the reader the figure is not a measurement.
    result = pricing.price([Span("gpt-5.5", "openai", "responses", errored=True)])
    assert result.cost_usd == pytest.approx(0.0)
    assert result.spans_without_usage == 1
    assert result.basis == "ceiling"


def test_unpriced_routes_still_report_their_usage_less_spans():
    spans = [Span("gpt-9-nova", "openai", "responses", errored=True)]
    result = pricing.price(spans)
    assert result.basis == "unpriced"
    assert result.spans_without_usage == 1


# --- fail loud --------------------------------------------------------------

def test_cache_counts_exceeding_the_blended_prompt_raise():
    span = Span("claude-opus-4-8", "anthropic", "messages", prompt_tokens=1_000,
                completion_tokens=10, cached_input_tokens=900, cache_write_tokens=200)
    with pytest.raises(ValueError, match="BLENDED"):
        pricing.price([span])


def test_cache_write_tokens_against_an_unestablished_write_rate_raise():
    # Mistral publishes a cached-input discount but no cache-write line, so the
    # card records the write leg as unestablished. A write count on such a span
    # must refuse rather than invent a number.
    assert pricing.CARD[("mistral", "mistral-large-latest")].cache_write_per_mtok is None
    span = Span("mistral-large-latest", "mistral", "chat_completions", prompt_tokens=1_000,
                completion_tokens=10, cached_input_tokens=0, cache_write_tokens=100)
    with pytest.raises(ValueError, match="cache-write rate"):
        pricing.price([span])


def test_a_half_reported_usage_map_raises():
    span = Span("gpt-5.5", "openai", "responses", prompt_tokens=1_000)
    with pytest.raises(ValueError, match="no completion tokens"):
        pricing.price([span])


def test_a_span_that_identified_neither_model_nor_provider_is_named_not_dropped():
    # grade.LlmSpanUsage reports "" for both on realtime and legacy spans and
    # keeps the span, because the call really happened. It has no route, so the
    # turn's figure is withheld and the blank cell points at the exporter.
    result = pricing.price([Span("", "", None, prompt_tokens=1_000, completion_tokens=10)])
    assert result.basis == "unpriced"
    assert result.cost_usd is None
    assert result.unpriced_routes == ("(no provider)/(no model)",)


def test_a_span_missing_only_its_model_is_still_named():
    result = pricing.price([Span("", "openai", "responses", prompt_tokens=1_000,
                                 completion_tokens=10)])
    assert result.unpriced_routes == ("openai/(no model)",)


def test_malformed_spans_raise_rather_than_being_skipped():
    with pytest.raises(TypeError, match="not an LlmSpanUsage"):
        pricing.price([object()])
    with pytest.raises(TypeError, match="provider must be a string"):
        pricing.price([Span("gpt-5.5", None, "responses")])
    with pytest.raises(ValueError, match="negative"):
        pricing.price([Span("gpt-5.5", "openai", "responses", prompt_tokens=-1,
                            completion_tokens=0)])
    with pytest.raises(TypeError, match="must be an int or None"):
        pricing.price([Span("gpt-5.5", "openai", "responses", prompt_tokens=True,
                            completion_tokens=0)])
    with pytest.raises(TypeError):
        pricing.price(None)


# --- the audited figures themselves -----------------------------------------
#
# These pin numbers a reader would otherwise "correct" on sight. Each one was
# checked against first-party vendor pricing; the card carries the reason beside
# the entry, and the assertion here is what makes the reason enforceable.

_OPENAI_CACHE_WRITE_MODELS = ("gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna")


@pytest.mark.parametrize("model", _OPENAI_CACHE_WRITE_MODELS)
def test_gpt_5_6_and_later_bill_cache_writes_at_1_25x_input(model):
    for route in ("openai", "openai_codex"):
        rate = pricing.CARD[(route, model)]
        assert rate.cache_write_per_mtok == pytest.approx(1.25 * rate.input_per_mtok), \
            f"{route}/{model}"


def test_pre_gpt_5_6_openai_models_bill_a_written_token_as_ordinary_input():
    # Cache-write billing starts at GPT-5.6. Older slugs are not "unknown" —
    # the vendor verifiably charges no premium, so they carry the sentinel.
    for model in ("gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5", "gpt-5-mini",
                  "gpt-5-mini-2025-08-07", "gpt-4o"):
        rate = pricing.CARD[("openai", model)]
        assert rate.cache_write_per_mtok is pricing.BILLS_AT_INPUT_RATE, model


def _family_entries(direct_routes: tuple[str, ...], openrouter_prefix: str) -> dict:
    """Every card entry for one vendor's model family, however it is ROUTED.

    A cache leg is a property of the VENDOR's price list, not of the route the
    model is reached through, so the invariant has to follow the family across
    routes. The guard that looped over ("openai", "openai_codex") alone left
    `openrouter/openai/gpt-5.5` outside the invariant that exists for exactly it.
    """
    return {f"{route}/{model}": rate for (route, model), rate in pricing.CARD.items()
            if route in direct_routes
            or (route == "openrouter" and model.startswith(openrouter_prefix))}


def test_no_openai_family_entry_leaves_its_cache_write_leg_unestablished():
    # The latent crash this audit closed: every OpenAI-family entry used to say
    # `None`, so the first span carrying a cache-write count would have raised.
    entries = _family_entries(("openai", "openai_codex"), "openai/")
    # Derived, so it must not pass by finding nothing on the routed side.
    assert any(label.startswith("openrouter/") for label in entries), entries
    for label, rate in entries.items():
        assert rate.cache_write_per_mtok is not None, label


def test_no_anthropic_family_entry_leaves_its_cache_write_leg_unestablished():
    # Same invariant, same reason: Anthropic bills every cache write at 1.25x
    # input, so an unestablished leg on any route is a span away from raising.
    entries = _family_entries(("anthropic",), "anthropic/")
    assert any(label.startswith("openrouter/") for label in entries), entries
    for label, rate in entries.items():
        assert rate.cache_write_per_mtok is not None, label


def test_the_same_openai_model_bills_its_write_leg_the_same_on_every_route():
    # "A written token on gpt-5.5 bills as ordinary input" is a fact about
    # OpenAI's price list. Reaching the model through OpenRouter cannot change it.
    direct = pricing.CARD[("openai", "gpt-5.5")]
    routed = pricing.CARD[("openrouter", "openai/gpt-5.5")]
    assert routed.cache_write_per_mtok is direct.cache_write_per_mtok


def test_a_cache_write_count_prices_the_same_on_both_gpt_5_5_routes():
    # The proven divergence: 100 cache-write tokens priced normally on the
    # direct route and raised ValueError on the OpenRouter one.
    direct = Span("gpt-5.5", "openai", "responses", prompt_tokens=1_000_000,
                  completion_tokens=0, cached_input_tokens=0, cache_write_tokens=100)
    routed = Span("openai/gpt-5.5", "openrouter", "chat_completions",
                  prompt_tokens=1_000_000, completion_tokens=0,
                  cached_input_tokens=0, cache_write_tokens=100)
    assert pricing.price([routed]).cost_usd == pytest.approx(pricing.price([direct]).cost_usd)


def test_an_openai_cache_write_count_is_priced_not_refused():
    span = Span("gpt-6-astra", "openai", "responses", prompt_tokens=100_000,
                completion_tokens=1_000, cached_input_tokens=20_000,
                cache_write_tokens=30_000)
    expected = (50_000 * 10.00 + 20_000 * 1.00 + 30_000 * 12.50 + 1_000 * 50.00) / 1e6
    assert pricing.price([span]).cost_usd == pytest.approx(expected)


def test_a_pre_5_6_cache_write_costs_exactly_what_uncached_input_costs():
    written = Span("gpt-5.5", "openai", "responses", prompt_tokens=100_000,
                   completion_tokens=0, cached_input_tokens=0, cache_write_tokens=40_000)
    plain = Span("gpt-5.5", "openai", "responses", prompt_tokens=100_000,
                 completion_tokens=0, cached_input_tokens=0)
    assert pricing.price([written]).cost_usd == pytest.approx(pricing.price([plain]).cost_usd)


def test_the_codex_route_keeps_the_slugs_that_only_left_chatgpt_sign_in():
    # OpenAI's announcement is narrower than "retired from the Codex route":
    # "GPT-5.4 and GPT-5.4 mini will no longer be available for users signed in
    # with ChatGPT starting August 31. The models will remain available on the
    # OpenAI API and Codex sessions authenticated with an API key."
    # `provider_route` keys this route on the codex ADAPTER and records no
    # credential, so an API-key Codex session lands here and is a supported
    # pairing today — not evidence that something routed unexpectedly.
    for model in ("gpt-5.4", "gpt-5.4-mini"):
        assert pricing.classification("openai_codex", model) == "priced", model
        assert pricing.CARD[("openai_codex", model)] == pricing.CARD[("openai", model)], model
        assert f"openai_codex/{model}" not in pricing.UNPRICED_PENDING_RATE, model


def test_an_observed_codex_pairing_prices_rather_than_blanking_its_episode():
    # ("openai_codex", "gpt-5.4-mini") is in _SPAN_CENSUS below: an OBSERVED live
    # pairing, and a normal supported configuration before 2026-08-31. The card
    # has no date dimension, so withholding a rate applies RETROACTIVELY to every
    # historical span on it.
    span = Span("gpt-5.4-mini", "openai", "codex", prompt_tokens=1_000_000,
                completion_tokens=100_000)
    result = pricing.price([span])
    assert result.basis == "ceiling"
    assert result.cost_usd == pytest.approx(0.75 + 0.45)


def test_a_codex_pairing_seen_live_is_never_pending_while_the_direct_route_prices_it():
    """The silent half of the regression this closes.

    Owner decision 2 is one card, API prices, applied uniformly, and the two
    routes read the SAME OpenAI price list — so a slug the direct route prices
    cannot be an honest rate gap on the Codex route. It has to be gated HERE:
    `test_every_leaderboard_row_is_classified` fails only on "unknown", so a
    `pending_rate` sails through it, while `run_capability._episode_pricing`
    blanks the WHOLE episode's dollar figure on that one span and the fold
    carries the blank into the config's $/success cell.
    """
    observed = [model for route, model in _SPAN_CENSUS if route == "openai_codex"]
    assert observed, _SPAN_CENSUS
    for model in observed:
        if ("openai", model) in pricing.CARD:
            assert pricing.classification("openai_codex", model) == "priced", model


def test_the_codex_route_still_carries_everything_it_serves():
    for model in ("gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"):
        assert ("openai_codex", model) in pricing.CARD, model


def test_codex_spark_is_recorded_rather_than_unknown():
    # Codex-servable with ChatGPT sign-in, no public API price.
    assert pricing.classification("openai_codex", "gpt-5.3-codex-spark") == "pending_rate"


def test_mistral_publishes_a_cached_input_discount():
    # -90% off input on all three tiers. `None` here would overstate a cached
    # token by 10x the moment the basis flips off "ceiling".
    for model, cached in (("mistral-large-latest", 0.05), ("mistral-medium-latest", 0.15),
                          ("mistral-small-latest", 0.015)):
        rate = pricing.CARD[("mistral", model)]
        assert rate.cached_input_per_mtok == pytest.approx(cached), model
        assert rate.cached_input_per_mtok == pytest.approx(0.1 * rate.input_per_mtok), model


def test_mistral_large_really_is_cheaper_than_mistral_medium():
    # Not a transposition: Large 3 is the open-weight generalist and took a ~75%
    # cut in Dec 2025; Medium 3.5 is the frontier agentic tier.
    large = pricing.CARD[("mistral", "mistral-large-latest")]
    medium = pricing.CARD[("mistral", "mistral-medium-latest")]
    assert large.input_per_mtok < medium.input_per_mtok
    assert large.output_per_mtok < medium.output_per_mtok


def test_gpt_4o_sits_on_the_older_50_percent_caching_tier():
    # 0.5x input, not the 0.1x every newer OpenAI model gets. Verified
    # first-party: gpt-4o predates the 90%-off tier.
    rate = pricing.CARD[("openai", "gpt-4o")]
    assert rate.cached_input_per_mtok == pytest.approx(0.5 * rate.input_per_mtok)


def test_fable_5_1_caches_at_a_tenth_of_its_siblings_read_rate():
    # Verified first-party: the vendor's table footnotes Fable 5.1 and Mythos
    # 5.1 as the only models at 0.025x input; everything else is 0.1x.
    special = pricing.CARD[("anthropic", "claude-fable-5-1")]
    sibling = pricing.CARD[("anthropic", "claude-fable-5")]
    assert special.input_per_mtok == sibling.input_per_mtok
    assert special.cached_input_per_mtok == pytest.approx(0.025 * special.input_per_mtok)
    assert sibling.cached_input_per_mtok == pytest.approx(0.1 * sibling.input_per_mtok)


def test_claude_sonnet_5_carries_the_vendors_standard_price_on_every_leg():
    # 2.00/10.00 is the STANDARD price, not an introductory one: the pricing
    # page's dedicated note says the $2/$10 announced as introductory through
    # 2026-08-31 "is now the standard price" and the increase to $3/$15
    # scheduled for 2026-09-01 "will not occur". All four legs are pinned so a
    # reader cannot re-derive them from the cancelled schedule: read is the
    # standard 0.1x, write the standard 1.25x.
    new = pricing.CARD[("anthropic", "claude-sonnet-5")]
    old = pricing.CARD[("anthropic", "claude-sonnet-4-6")]
    assert (new.input_per_mtok, new.output_per_mtok) == (2.00, 10.00)
    assert new.cached_input_per_mtok == pytest.approx(0.1 * new.input_per_mtok)
    assert new.cache_write_per_mtok == pytest.approx(1.25 * new.input_per_mtok)
    # It UNDERCUTS its predecessor: pricing a Sonnet by analogy to the older one
    # would overstate it by 50%, which is also the size of the rise that was
    # cancelled — the two mistakes land on the same wrong number.
    assert new.input_per_mtok < old.input_per_mtok
    assert new.output_per_mtok < old.output_per_mtok


def test_the_card_does_not_plant_a_sonnet_5_price_rise_in_its_prose():
    # The only reason the module docstring ever named a Sonnet was to call
    # claude-sonnet-5's standard 2.00/10.00 "introductory" and send the next
    # maintainer off to expect a revert to 3.00/15.00 — a 50% overstatement the
    # vendor has explicitly cancelled, pointed at a date already past at this
    # card's own as-of date. The provenance belongs beside the entry, where a
    # maintainer about to change the rate reads it.
    doc = (pricing.__doc__ or "").lower()
    assert "sonnet" not in doc, (
        "the module docstring names a Sonnet; the standing rate needs no re-read "
        "note, and prose promising one plants a 50% overstatement"
    )


def test_the_established_xai_routes_left_the_pending_table():
    for model, expected in (("grok-4.5", (2.00, 6.00, 0.30)),
                            ("grok-4.20-0309-reasoning", (1.25, 2.50, 0.20)),
                            ("grok-4.20-0309-non-reasoning", (1.25, 2.50, 0.20))):
        rate = pricing.CARD[("xai", model)]
        assert (rate.input_per_mtok, rate.output_per_mtok,
                rate.cached_input_per_mtok) == expected, model


def test_grok_code_fast_1_points_at_a_successor_the_card_actually_carries():
    # The reason sent a reader to price grok-build-0.1 "under its own slug",
    # which was in neither table — the reason created the loose end it described.
    # Published first-party at 1.00 in / 0.20 cached / 2.00 out below 200k.
    reason = pricing.UNPRICED_PENDING_RATE["xai/grok-code-fast-1"]
    assert "model list" in reason and "grok-build-0.1" in reason
    rate = pricing.CARD[("xai", "grok-build-0.1")]
    assert (rate.input_per_mtok, rate.output_per_mtok,
            rate.cached_input_per_mtok) == (1.00, 2.00, 0.20)


def test_a_vendor_prefixed_openrouter_model_resolves_through_the_card():
    # The route key is (provider, model) and the model id keeps its vendor
    # prefix, exactly as `moonshotai/kimi-k3` already does — so a three-segment
    # route name like openrouter/anthropic/claude-sonnet-4.6 does resolve.
    span = Span("anthropic/claude-sonnet-4.6", "openrouter", "chat_completions",
                prompt_tokens=1_000_000, completion_tokens=0)
    assert pricing.price([span]).cost_usd == pytest.approx(3.00)
    assert pricing.classification("openrouter", "anthropic/claude-sonnet-4.6") == "priced"


def test_the_established_openrouter_routes_left_the_pending_table():
    for model, expected in (("anthropic/claude-sonnet-4.6", (3.00, 15.00, 0.30, 3.75)),
                            ("anthropic/claude-fable-5", (10.00, 50.00, 1.00, 12.50)),
                            ("anthropic/claude-opus-4.8", (5.00, 25.00, 0.50, 6.25))):
        rate = pricing.CARD[("openrouter", model)]
        assert (rate.input_per_mtok, rate.output_per_mtok, rate.cached_input_per_mtok,
                rate.cache_write_per_mtok) == expected, model
    for model, expected in (("openai/gpt-5.5", (5.00, 30.00, 0.50)),
                            ("x-ai/grok-4.3", (1.25, 2.50, 0.20))):
        rate = pricing.CARD[("openrouter", model)]
        assert (rate.input_per_mtok, rate.output_per_mtok,
                rate.cached_input_per_mtok) == expected, model


# --- table hygiene ----------------------------------------------------------

def test_card_version_is_stamped_on_every_verdict():
    assert isinstance(pricing.CARD_VERSION, str) and pricing.CARD_VERSION
    for result in (pricing.price([]),
                   pricing.price([Span("gpt-9-nova", "openai", "responses")]),
                   pricing.price([Span("gpt-5.5", "openai", "responses",
                                       prompt_tokens=1, completion_tokens=1)])):
        assert result.card_version == pricing.CARD_VERSION


def test_every_rate_is_internally_consistent():
    for (route, model), rate in pricing.CARD.items():
        label = f"{route}/{model}"
        assert rate.input_per_mtok > 0, label
        assert rate.output_per_mtok > 0, label
        if isinstance(rate.cached_input_per_mtok, float):
            assert 0 < rate.cached_input_per_mtok <= rate.input_per_mtok, label
        if isinstance(rate.cache_write_per_mtok, float):
            # A cache write is a premium over base input on every vendor that
            # bills one; a write cheaper than input would be a transcription slip.
            assert rate.cache_write_per_mtok >= rate.input_per_mtok, label


def test_a_cache_leg_is_a_float_the_sentinel_or_unestablished():
    # Three states, never a fourth: a published figure, the vendor's verified
    # "no premium/discount", or "not established". A stray string or int would
    # price silently wrong.
    for (route, model), rate in pricing.CARD.items():
        for leg in (rate.cached_input_per_mtok, rate.cache_write_per_mtok):
            assert leg is None or leg is pricing.BILLS_AT_INPUT_RATE \
                or isinstance(leg, float), f"{route}/{model}: {leg!r}"


def test_a_pending_rate_never_shadows_a_real_one():
    carded = {f"{route}/{model}" for route, model in pricing.CARD}
    assert not (carded & set(pricing.UNPRICED_PENDING_RATE))


def test_every_pending_rate_names_a_real_route_and_says_why():
    routes = {route for route, _ in pricing.CARD} | pricing.NOT_TOKEN_BILLED
    for key, reason in pricing.UNPRICED_PENDING_RATE.items():
        # A typo'd route prefix would make the entry a silent no-op.
        assert key.split("/")[0] in routes, key
        assert len(key.split("/", 1)) == 2, key
        assert len(reason) > 20, key


# --- coverage invariants (derived from live sources, not hand-listed) -------

_CATALOG_PATH = ("apps/fermix_core/lib/fermix_core/providers/model_catalog.ex")
_CATALOG_PROVIDERS = ("openai_codex", "openai", "anthropic", "xai", "openrouter",
                      "mistral", "ollama")


def _catalog_models() -> dict[str, list[str]]:
    """Every (provider -> model ids) pair the product's model catalog offers.

    Parsed out of the Elixir source because that catalog is what the wizard
    routes to, so it is the population this card has to cover. The assertions
    below exist so a parse that silently finds nothing fails as a stale
    extraction rather than passing vacuously.
    """
    source = (REPO_ROOT / _CATALOG_PATH).read_text()
    blocks = re.findall(r"^  @(" + "|".join(_CATALOG_PROVIDERS) + r") \[(.*?)^  \]$",
                        source, re.MULTILINE | re.DOTALL)
    parsed = {provider: re.findall(r'id:\s*"([^"]+)"', body) for provider, body in blocks}
    assert set(parsed) == set(_CATALOG_PROVIDERS), (
        f"parsed {sorted(parsed)} from {_CATALOG_PATH} — the extraction is stale, "
        "not the catalog"
    )
    assert "gpt-5.6-sol" in parsed["openai_codex"], parsed["openai_codex"]
    assert "claude-opus-4-8" in parsed["anthropic"], parsed["anthropic"]
    assert sum(len(ids) for ids in parsed.values()) >= 30, parsed
    return parsed


def test_every_model_the_product_can_route_to_is_classified():
    """Adding a model without a price must fail HERE, not render a blank cell.

    "Classified" means carded, `NOT_TOKEN_BILLED`, or recorded in
    `UNPRICED_PENDING_RATE` with the reason no published rate could be
    established. Only "nobody looked" fails.
    """
    unknown = [f"{provider}/{model}"
               for provider, models in _catalog_models().items()
               for model in models
               if pricing.classification(provider, model) == "unknown"]
    assert not unknown, (
        f"no rate, no NOT_TOKEN_BILLED classification and no recorded gap for: {unknown}. "
        "Add a CARD entry with its source, or an UNPRICED_PENDING_RATE line saying why "
        "the published rate could not be established."
    )


# The (provider_route, model) census of live Fermix llm spans, 2026-09-05. It
# covers slugs the catalog no longer offers (legacy modules still emit them) and
# ids observed only on the wire, so it is real coverage the catalog test cannot
# give. Re-derive it from spans rather than editing it by hand.
_SPAN_CENSUS = (
    ("openai_codex", "gpt-5.6-sol"), ("openai_codex", "gpt-5.6-terra"),
    ("openai_codex", "gpt-5.5"), ("openai_codex", "gpt-5.4-mini"),
    ("openai_codex", "gpt-6-astra"), ("openai_codex", "gpt-5.6-luna"),
    ("openai", "gpt-5.5"), ("openai", "gpt-5.4-mini"),
    ("openai", "gpt-5-mini-2025-08-07"), ("openai", "gpt-4o"), ("openai", "gpt-5"),
    ("anthropic", "claude-opus-4-8"), ("anthropic", "claude-sonnet-4-6"),
    ("xai", "grok-4.3"), ("xai", "grok-4.6"),
    ("mistral", "mistral-large-latest"),
    ("openrouter", "moonshotai/kimi-k3"), ("openrouter", "qwen3:32b"),
    ("openrouter", "gpt-5.4-mini"),
    ("ollama", "qwen3:32b"),
)


def test_every_route_seen_in_live_spans_is_classified():
    unknown = [f"{route}/{model}" for route, model in _SPAN_CENSUS
               if pricing.classification(route, model) == "unknown"]
    assert not unknown, unknown


def test_every_leaderboard_row_is_classified():
    """The rows the $/success column actually renders must all be priceable.

    The store is a run artifact (gitignored), so this skips where no run has
    happened; the catalog and census invariants above are the always-on gates.
    """
    path = leaderboard.store_path(str(BENCHMARK_DIR / "reports"))
    if not os.path.exists(path):
        pytest.skip(f"no leaderboard store at {path} — run the capability tier first")
    rows = leaderboard.load_store(path).get("rows", {})
    unknown = []
    for key in rows:
        route, model = _split_config_id(key.rsplit("@", 1)[0], path)
        if pricing.classification(route, model) == "unknown":
            unknown.append(f"{route}/{model}")
    assert not unknown, f"{path} ranks configs the card cannot price: {sorted(set(unknown))}"


def _split_config_id(config_id: str, path: str) -> tuple[str, str]:
    """`provider/model/effort` -> (provider, model). The model may itself contain
    slashes (`openrouter/moonshotai/kimi-k3/default`), the effort never does."""
    parts = config_id.split("/")
    if len(parts) < 3:
        raise ValueError(f"{path}: row key {config_id!r} is not provider/model/effort")
    return parts[0], "/".join(parts[1:-1])


def test_config_id_split_keeps_a_vendor_prefixed_model_whole():
    assert _split_config_id("openrouter/moonshotai/kimi-k3/default", "x") == (
        "openrouter", "moonshotai/kimi-k3")
    assert _split_config_id("openai/gpt-5.5/xhigh", "x") == ("openai", "gpt-5.5")
    with pytest.raises(ValueError):
        _split_config_id("openai/gpt-5.5", "x")


def test_the_leaderboard_store_shape_this_test_reads_is_the_one_on_disk():
    """Guards the skip above from becoming permanent for the wrong reason: if the
    store moves or changes shape, fail here instead of quietly skipping forever."""
    path = leaderboard.store_path(str(BENCHMARK_DIR / "reports"))
    if not os.path.exists(path):
        pytest.skip("no leaderboard store on this host")
    with open(path, "r", encoding="utf-8") as fh:
        raw = json.load(fh)
    assert isinstance(raw, dict) and raw, path


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))


# Routes the card knowingly cannot price, each of which therefore BLANKS the whole
# episode's dollar figure (and the config's $/success cell) if it is ever benchmarked.
# Every entry is a deliberate, reviewed acceptance — not a parking space. Adding one
# means agreeing to lose the cost column for any run that touches that route.
_ACCEPTED_BLANKS = (
    # Retired upstream; absent from xAI's current model list. Its successor
    # grok-build-0.1 IS carded, so the live path has a priced route.
    ("xai", "grok-code-fast-1"),
    # These two are a DATA defect, not a pricing gap, and pricing them would paper
    # over it. Neither is a valid OpenRouter id — OpenRouter's are `openai/gpt-5.4-mini`
    # and `qwen/qwen3-32b`, while `qwen3:32b` is an Ollama tag the catalog carries under
    # ollama. So the spans that produced this census pairing most likely carry a
    # mis-attributed provider. Guessing a rate would price a route that does not exist;
    # blanking says so out loud. Fix the attribution upstream, then delete these lines.
    ("openrouter", "gpt-5.4-mini"),
    ("openrouter", "qwen3:32b"),
)


def test_a_benchmarkable_route_is_priceable_not_merely_classified():
    """`pending_rate` passes the three `classification` invariants and still blanks
    the column, because `price/1` reports it `unpriced` and `_priced_columns` folds
    one unpriced route into a missing figure for the entire run. So "classified" is
    not the bar for a route the harness can actually be pointed at — "priceable" is.

    This is the defect class the module's opening paragraph exists to prevent: a
    silently blank dollar cell that every gate calls green.
    """
    routes = {(provider, model)
              for provider, models in _catalog_models().items()
              for model in models}
    routes.update(_SPAN_CENSUS)
    blanking = sorted(
        f"{route}/{model}" for route, model in routes
        if (route, model) not in _ACCEPTED_BLANKS
        and pricing.classification(route, model) not in ("priced", "not_token_billed"))
    assert not blanking, (
        f"these routes are reachable and unpriceable, so any run touching one loses its "
        f"cost column entirely: {blanking}. Card them, or add them to _ACCEPTED_BLANKS "
        f"with the reason — but do not leave the blank undeclared.")


def test_every_accepted_blank_records_why_it_cannot_be_priced():
    """An accepted blank must still say why, in the same table every other gap uses."""
    missing = [f"{route}/{model}" for route, model in _ACCEPTED_BLANKS
               if f"{route}/{model}" not in pricing.UNPRICED_PENDING_RATE]
    assert not missing, f"accepted blanks with no recorded reason: {missing}"
