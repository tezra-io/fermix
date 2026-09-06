"""Published-list-price rate card for the harness's cost column.

The single named source of truth for what a graded turn WOULD have cost at
published API list prices, keyed by `(provider_route, model)`. Same discipline
as `FermixCore.Realtime.CostTracker`'s `@rates`: rates live in code, in dollars
per million tokens, and a test pins that every model the product can route to is
either carded, classified `NOT_TOKEN_BILLED`, or explicitly recorded in
`UNPRICED_PENDING_RATE` — so a model added without a price fails the suite
instead of silently rendering a blank cell.

Three properties of this number, all deliberate:

  * It is a COUNTERFACTUAL, not measured spend. Every stored leaderboard row so
    far ran on a non-metered adapter (Codex OAuth, Anthropic Messages under a
    subscription, OpenRouter), and the card is applied to those routes anyway —
    "what this run would have cost at API rates" is the only figure comparable
    across configs. `provider_route` keeps the OAuth route distinguishable
    (`openai_codex`) so a reader can see which rows are counterfactual.

  * It is a NEAR-CEILING while `basis == "ceiling"`. Cached input is billed at
    the full input rate until the adapters emit cache counts, which OVERSTATES
    true billed cost by ~1.01x-2.18x in aggregate (up to ~9.8x on a single
    call), scaling with cache-hit rate. One leg now runs the other way: the four
    OpenAI models that bill cache WRITES at 1.25x input are charged here at
    1.00x while write counts are invisible, so those tokens are UNDER-stated by
    20%. In aggregate the figure still sits well above true spend — cached reads
    dwarf writes — but "strict ceiling" is no longer literally true, and a turn
    that is almost all cache writes could in principle come in under.

    The two legs are on different footings, and only one of them can settle
    itself. READ: once an adapter emits `cached_input_tokens`, `price/1` reports
    `cache_aware` with no change here — for entries whose write leg is
    `BILLS_AT_INPUT_RATE`, where a written token costs exactly what the uncached
    input it is folded into costs, so its absence approximates nothing. WRITE: no
    OpenAI write count arrives today, and no amount of waiting changes that —
    `grade._span_usage` reads `usage.cache_creation_input_tokens`, an
    Anthropic-shaped key that only `anthropic/messages.ex` emits; the OpenAI
    adapters (openai.ex, responses_shared.ex, chat_completions.ex, codex.ex)
    emit `cached_input_tokens` and nothing else. That is a gap, not a wall:
    OpenAI DOES report the count, as `input_tokens_details.cache_write_tokens`,
    so closing it is one more field read in the same four adapters that already
    read `cached_tokens`, plus a second key name in `grade._span_usage`. Until
    someone does that a GPT-5.6+ span stays at
    `ceiling` however many read counts arrive, and the 20% understatement above
    is a labelled gap rather than a silent one.

  * It is TASK-PERFORMANCE-NEUTRAL. This module belongs to the aggregate and
    reporting layer only. It must NEVER set `grade.TurnView.cost` /
    `cost_reported`, and must never be written back onto a trace: 261 declared
    `max_cost_usd` gates currently evaluate as "n/a" because cost is unreported,
    and filling it in at the grading layer would arm all of them at once against
    July pricing and read as a model regression.

Cost is computed PER SPAN and summed, never per trace with one rate — a trace
routinely mixes models (provider failover, the nested memory reviewer, subagent
fan-out, media tools), and 3.8% of prod / 7.3% of dev traces carry 2-3 distinct
(provider, model) pairs. Subagent spans are included: their tokens are real
spend.

Rates are per MODEL, never per effort: reasoning tokens bill at the output rate,
so effort is not part of the key.

--- Rates: sources and as-of date ---------------------------------------------
All figures are published list prices in US dollars per MILLION tokens, standard
(non-batch, non-priority) processing, read 2026-09-05 and re-checked against
first-party vendor pricing the same day:

  OpenAI      https://developers.openai.com/api/docs/pricing (first-party;
              input / cached input / output for every slug). Cache WRITES are
              billed at 1.25x uncached input from GPT-5.6 onward — gpt-6-astra,
              gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna. Every older slug carded
              here predates that line and bills a written token as ordinary
              input; that is a read fact (`BILLS_AT_INPUT_RATE`), not a gap.
              An earlier note here claimed OpenAI bills no cache-write premium
              at all — false since GPT-5.6, and a latent crash, because a write
              count against an unestablished rate raises.
              `gpt-5-mini-2025-08-07` is INFERRED, not read: the pricing page
              lists only undated aliases, so its input/output come from two
              independent aggregators agreeing and its cached figure is
              inherited from the undated `gpt-5-mini` alias.
  Anthropic   https://platform.claude.com/docs/en/about-claude/pricing
              (first-party. NOT claude.com/pricing — the per-model table and the
              cache-multiplier footnotes live only on the docs page)
              (first-party; cache-write figures are the 5-minute TTL column)
  xAI         https://docs.x.ai/docs/models (first-party, fetches cleanly). The
              HTTP 403 an earlier note recorded is on x.ai/api, a different
              page; it was wrong to generalise that refusal to the domain and
              to treat aggregator figures as the best available source.
  Mistral     https://mistral.ai/pricing/api (first-party). The `-latest`
              aliases resolve to the current build of each tier: large -> Mistral
              Large 3, medium -> Mistral Medium 3.5, small -> Mistral Small 4.
              Cached input is -90% on all three tiers.
  OpenRouter  first-party per-model pages, openrouter.ai/<vendor>/<model>;
              OpenRouter adds no per-token markup. `moonshotai/kimi-k3` is a
              FLOOR rather than a fixed rate: K3 is open-weight and served by
              roughly 15 endpoints, and the page's headline is the cheapest of
              them, so that one entry can UNDER-state what the account paid.

Two known bounds, both accepted rather than modelled:

  * LONG-CONTEXT TIERS ARE NOT APPLIED. OpenAI reprices a request above 272k
    input tokens at 2x input/cache and 1.5x output for the whole request, and
    xAI doubles every rate at 200k. A card entry is the standard tier, so a
    turn that crosses either cliff is UNDER-stated here. This partly offsets the
    cache-blind overstatement above; both disappear from the comparison only if
    the reporting layer starts carrying tiers.
  * `gpt-5.6-sol` is the card's ONE promotional rate: 4.00 input is published
    as running at least through 2026-11-21, and its cache-write leg is 1.25x
    whatever input is, so it becomes 6.25 if input reverts to 5.00. Re-read that
    source after the date and bump `CARD_VERSION` rather than letting a stale
    rate ride. No other entry is awaiting a revert; a rate whose promotion the
    vendor has ENDED by making it standard is not one, and saying otherwise
    plants the cancelled increase in the next reader's head.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from typing import Protocol

# Bump on ANY rate edit, addition or removal. Stamped onto every PricedUsage so
# a rendered dollar figure can be traced back to the table that produced it, and
# the aggregate folds a cost axis only across one version. Nothing PARSES this
# string — `aggregate` compares it as an opaque token by equality — so all a
# same-day `.N` suffix has to be is DISTINCT from every token already stamped
# onto a stored row. It is not an ordered sequence and the values in between
# need not exist: `.1` never did, and renaming `.2` now would make a token that
# is already on disk mean two different tables.
CARD_VERSION = "2026-09-05.3"


class LlmSpanUsage(Protocol):
    """One llm span's usage, as `grade.LlmSpanUsage` exposes it.

    Declared structurally on purpose: this module must not import the grading
    layer (see the module docstring), and any object carrying these attributes
    prices correctly.

    `prompt_tokens is None` means the span reported no usage at all — an errored
    call, almost always. Such a span is NOT priced as $0; it is counted in
    `PricedUsage.spans_without_usage`, because its spend is real and merely
    unrecoverable.

    `prompt_tokens` keeps the provider adapter's semantics, which for Anthropic
    is the BLENDED figure (input + cache_creation + cache_read). Cache counts
    ride alongside; the uncached remainder is obtained by subtracting them.

    `model` and `provider` are `""` when the span carried neither — the grading
    layer keeps such a span rather than dropping a call that really happened.
    It has no route, so it cannot be keyed: `price/1` reports it as an unpriced
    route named "(no provider)/(no model)" and withholds the turn's figure.
    """

    model: str
    provider: str
    adapter: str | None
    prompt_tokens: int | None
    completion_tokens: int | None
    cached_input_tokens: int | None
    cache_write_tokens: int | None
    errored: bool
    under_subagent: bool


class _BillsAtInputRate:
    """The type of `BILLS_AT_INPUT_RATE`. One instance, compared by identity."""

    __slots__ = ()

    def __repr__(self) -> str:
        return "BILLS_AT_INPUT_RATE"


# The vendor charges no premium or discount on this cache leg, so those tokens
# bill at the plain input rate. It is a READ FACT about the price list, and it
# is deliberately not spelled `None`: `None` means the figure was never
# established, which must refuse rather than guess. Collapsing the two is the
# silent fallback rule 12 forbids, and it is exactly how Mistral's published
# -90% cached-input discount shipped as "bills at the full input rate".
BILLS_AT_INPUT_RATE = _BillsAtInputRate()

# One cache leg's price: published figure, no-premium, or never established.
CacheRate = float | _BillsAtInputRate | None


@dataclass(frozen=True)
class Rate:
    """Dollars per million tokens for one `(provider_route, model)`.

    Each cache leg carries one of three values, never two:

      * a float — the vendor's published rate for that leg;
      * `BILLS_AT_INPUT_RATE` — the vendor publishes no premium or discount
        there, so those tokens bill at `input_per_mtok`;
      * `None` — nobody has established the figure. A span reporting tokens on
        such a leg RAISES; it is never priced at an invented rate and never
        quietly folded into the input rate.

    `cache_write_per_mtok` defaults to `None`, so an entry added without
    researching that leg refuses loudly instead of pricing itself.
    `cached_input_per_mtok` has no default at all, for the same reason.
    """

    input_per_mtok: float
    output_per_mtok: float
    cached_input_per_mtok: CacheRate
    cache_write_per_mtok: CacheRate = None


@dataclass(frozen=True)
class PricedUsage:
    """The card's verdict on one collection of spans.

    `cost_usd is None` whenever no dollar figure may honestly be shown; the
    reason is always in `basis`.
    """

    cost_usd: float | None
    basis: str                          # cache_aware | ceiling | not_token_billed | unpriced
    unpriced_routes: tuple[str, ...]    # "<provider_route>/<model>" needing a card entry
    spans_without_usage: int
    card_version: str


# Routes that bill no per-token rate at all. Route-level, not per model: every
# model served locally is free of API dollars, and enumerating local tags would
# rot on the first `ollama pull`.
NOT_TOKEN_BILLED: frozenset[str] = frozenset({"ollama", "local"})

# Cache WRITES bill at 1.25x uncached input from GPT-5.6 onward. The older
# slugs predate that line and bill a written token as ordinary input, which is
# `BILLS_AT_INPUT_RATE` — a read fact, not an unresearched leg.
_OPENAI_RATES: dict[str, Rate] = {
    "gpt-6-astra": Rate(10.00, 50.00, 1.00, 12.50),
    # 4.00 input is promotional through at least 2026-11-21; the write leg is
    # 1.25x whatever input is, so it becomes 6.25 if input reverts to 5.00.
    "gpt-5.6-sol": Rate(4.00, 20.00, 0.40, 5.00),
    "gpt-5.6-terra": Rate(2.00, 12.00, 0.20, 2.50),
    "gpt-5.6-luna": Rate(0.20, 1.20, 0.02, 0.25),
    "gpt-5.5": Rate(5.00, 30.00, 0.50, BILLS_AT_INPUT_RATE),
    "gpt-5.4": Rate(2.50, 15.00, 0.25, BILLS_AT_INPUT_RATE),
    "gpt-5.4-mini": Rate(0.75, 4.50, 0.075, BILLS_AT_INPUT_RATE),
}

# The direct API also serves the older slugs still present in live spans; the
# Codex route does not offer them, so they are absent from the `openai_codex`
# block and an unexpected pairing surfaces as "unpriced" instead of borrowing
# a rate.
_OPENAI_LEGACY_RATES: dict[str, Rate] = {
    "gpt-5": Rate(1.25, 10.00, 0.125, BILLS_AT_INPUT_RATE),
    "gpt-5-mini": Rate(0.25, 2.00, 0.025, BILLS_AT_INPUT_RATE),
    # INFERRED, not read: the pricing page carries only undated aliases.
    # Input/output are corroborated by two independent aggregators; the cached
    # figure is inherited from the undated `gpt-5-mini` alias above.
    "gpt-5-mini-2025-08-07": Rate(0.25, 2.00, 0.025, BILLS_AT_INPUT_RATE),
    # 1.25 cached is 0.5x input, NOT the conventional 0.1x, and it is correct:
    # verified first-party, gpt-4o predates OpenAI's 90%-off caching tier and
    # is still on the older 50% tier. Do not "fix" it to 0.25.
    "gpt-4o": Rate(2.50, 10.00, 1.25, BILLS_AT_INPUT_RATE),
}

# ChatGPT-subscription OAuth bills no per-token rate; these entries are the
# uniform list-price counterfactual the owner asked for (decision 2), which is
# why they mirror the direct-API column exactly.
#
# gpt-5.4 and gpt-5.4-mini belong here. OpenAI's announcement is narrower than
# "retired from the Codex route": "GPT-5.4 and GPT-5.4 mini will no longer be
# available for users signed in with ChatGPT starting August 31. The models will
# remain available on the OpenAI API and Codex sessions authenticated with an API
# key." `provider_route/2` keys this route on the codex ADAPTER and records no
# credential, so an API-key Codex session lands here and is a supported pairing
# today. The card also has no date dimension, so withholding a rate would apply
# retroactively to every historical span on a pairing the live-span census
# observed — and one unpriced span blanks the WHOLE episode's dollar figure in
# `run_capability._episode_pricing`, which the fold carries into the config's
# $/success cell.
_CODEX_RATES: dict[str, Rate] = dict(_OPENAI_RATES)

_ANTHROPIC_RATES: dict[str, Rate] = {
    "claude-opus-4-8": Rate(5.00, 25.00, 0.50, 6.25),
    "claude-sonnet-4-6": Rate(3.00, 15.00, 0.30, 3.75),
    # STANDARD pricing, not introductory. The pricing page carries a dedicated
    # note: the $2/$10 announced as introductory through 2026-08-31 "is now the
    # standard price", and the increase to $3/$15 scheduled for 2026-09-01
    # "will not occur". There is nothing here to re-read and no revert to
    # expect. It also UNDERCUTS the older Sonnet 4.6 above — the newer model is
    # the cheaper one — so pricing a Sonnet by analogy to its predecessor
    # overstates it by 50%, the same wrong number the cancelled rise would give.
    "claude-sonnet-5": Rate(2.00, 10.00, 0.20, 2.50),
    "claude-opus-5": Rate(5.00, 25.00, 0.50, 6.25),
    # 0.25 cache read is 0.025x input, a tenth of what the sibling below pays,
    # and it is correct: the vendor's pricing table footnotes Fable 5.1 and
    # Mythos 5.1 as the only models on the 0.025x read tier, everything else at
    # the standard 0.1x. Do not "fix" it to 1.00.
    "claude-fable-5-1": Rate(10.00, 50.00, 0.25, 12.50),
    "claude-fable-5": Rate(10.00, 50.00, 1.00, 12.50),
    "claude-haiku-4-5": Rate(1.00, 5.00, 0.10, 1.25),
}

# xAI prices the reasoning and non-reasoning surfaces of Grok 4.20 identically;
# the two ids are one rate, not a copy-paste slip.
_XAI_RATES: dict[str, Rate] = {
    "grok-4.6": Rate(2.00, 6.00, 0.50),
    "grok-4.5": Rate(2.00, 6.00, 0.30),
    "grok-4.3": Rate(1.25, 2.50, 0.20),
    "grok-4.20-0309-reasoning": Rate(1.25, 2.50, 0.20),
    "grok-4.20-0309-non-reasoning": Rate(1.25, 2.50, 0.20),
    # The successor xAI retired grok-code-fast-1 in favour of, carded under its
    # own slug so the pending reason below points somewhere real. Standard tier
    # only, like every entry here — xAI doubles all three figures at 200k, a
    # long-context cliff the card deliberately does not model.
    "grok-build-0.1": Rate(1.00, 2.00, 0.20),
}

# Cached input is -90% on every tier, published first-party. It is not absent:
# leaving these unset would bill a cached token at ten times its price the
# moment the basis flips off "ceiling".
#
# Large sitting BELOW Medium is real vendor pricing, not a transposition:
# "Large" is the open-weight generalist and took a ~75% cut in Dec 2025, while
# "Medium" is the frontier agentic tier. Do not swap them.
_MISTRAL_RATES: dict[str, Rate] = {
    "mistral-large-latest": Rate(0.50, 1.50, 0.05),
    "mistral-medium-latest": Rate(1.50, 7.50, 0.15),
    "mistral-small-latest": Rate(0.15, 0.60, 0.015),
}

# OpenRouter model ids keep their vendor prefix, so a route name reads as three
# segments (openrouter/anthropic/claude-sonnet-4.6) while the CARD key stays the
# same two-tuple, ("openrouter", "anthropic/claude-sonnet-4.6"). Nothing splits
# on the slash — `provider_route` returns the provider untouched and the model
# id is carried whole — so these resolve exactly as `moonshotai/kimi-k3` does.
#
# A cache leg is a property of the VENDOR's price list, not of the route the
# model is reached through, so a passthrough slug carries the same legs as its
# direct entry: `openai/gpt-5.5` bills a written token as ordinary input exactly
# as `("openai", "gpt-5.5")` does, and the Anthropic slugs carry the same
# published write price as theirs. Only `moonshotai/kimi-k3` (no direct entry)
# and `x-ai/grok-4.3` (xAI publishes no cache-write line at all, so `("xai",
# "grok-4.3")` has none either) leave that leg unestablished.
_OPENROUTER_RATES: dict[str, Rate] = {
    # A FLOOR, not a fixed rate: K3 is open-weight and served by roughly 15
    # endpoints, and this headline is the cheapest of them, so this one entry
    # can UNDER-state what the account was actually billed.
    "moonshotai/kimi-k3": Rate(2.55, 12.75, 0.256),
    "anthropic/claude-sonnet-4.6": Rate(3.00, 15.00, 0.30, 3.75),
    "anthropic/claude-fable-5": Rate(10.00, 50.00, 1.00, 12.50),
    "anthropic/claude-opus-4.8": Rate(5.00, 25.00, 0.50, 6.25),
    "openai/gpt-5.5": Rate(5.00, 30.00, 0.50, BILLS_AT_INPUT_RATE),
    "x-ai/grok-4.3": Rate(1.25, 2.50, 0.20),
}

CARD: dict[tuple[str, str], Rate] = {
    **{("openai", model): rate for model, rate in _OPENAI_RATES.items()},
    **{("openai", model): rate for model, rate in _OPENAI_LEGACY_RATES.items()},
    **{("openai_codex", model): rate for model, rate in _CODEX_RATES.items()},
    **{("anthropic", model): rate for model, rate in _ANTHROPIC_RATES.items()},
    **{("xai", model): rate for model, rate in _XAI_RATES.items()},
    **{("mistral", model): rate for model, rate in _MISTRAL_RATES.items()},
    **{("openrouter", model): rate for model, rate in _OPENROUTER_RATES.items()},
}

# Routes seen in live spans or offered by the product's model catalog for which
# no honest list price can be quoted — either the published rate could not be
# established, or the vendor no longer serves that pairing. They are NOT priced:
# `price/1` reports them as "unpriced" with their route name, exactly like an
# unknown model. This table exists so the invariant test can tell "nobody has
# looked at this yet" from "looked, here is why there is no number"; resolving
# one means deleting its line and adding a CARD entry.
UNPRICED_PENDING_RATE: dict[str, str] = {
    "openai_codex/gpt-5.3-codex-spark":
        "Codex-servable with ChatGPT sign-in but absent from OpenAI's public API price "
        "list, so there is no list price to quote as the counterfactual; re-read the "
        "pricing page once the slug is offered on the API",
    "openrouter/gpt-5.4-mini":
        "non-canonical OpenRouter slug (its catalog id is openai/gpt-5.4-mini); "
        "confirm what the account is actually billed at openrouter.ai/openai/gpt-5.4-mini",
    "openrouter/qwen3:32b":
        "qwen3:32b is an Ollama tag, not an OpenRouter id (that would be "
        "qwen/qwen3-32b) — establish which model the route really served before pricing it",
    "xai/grok-code-fast-1":
        "absent from xAI's current model list (docs.x.ai/docs/models) — retired or "
        "renamed. Its successor grok-build-0.1 IS carded, under its own slug; this one "
        "keeps no rate rather than borrowing the successor's for a slug the vendor "
        "dropped",
}


def provider_route(provider: str, adapter: str | None) -> str:
    """The billing route a span belongs to.

    The ONLY adapter value that selects a route is the literal "codex", which
    marks the ChatGPT-subscription OAuth path. Every other adapter — including
    values that happen to read like provider tokens ("openai", "openai_codex")
    and the 852 adapter-less spans a census found on realtime and legacy
    modules — leaves the route as the span's own `provider`, so nothing is
    promoted to a metered API route by a field that was never a route selector.
    """
    if not isinstance(provider, str) or not provider:
        raise ValueError(f"provider_route: provider must be a non-empty string, got {provider!r}")
    if adapter is not None and not isinstance(adapter, str):
        raise TypeError(f"provider_route: adapter must be a string or None, got {adapter!r}")
    return "openai_codex" if adapter == "codex" else provider


def classification(route: str, model: str) -> str:
    """How the card classifies one route+model: the ONE place the invariant lives.

    Returns "priced", "not_token_billed", "pending_rate" (a known gap, listed in
    `UNPRICED_PENDING_RATE` with its reason) or "unknown" (nobody has looked).
    Only "unknown" is a suite failure.
    """
    if not isinstance(route, str) or not route:
        raise ValueError(f"classification: route must be a non-empty string, got {route!r}")
    if not isinstance(model, str) or not model:
        raise ValueError(f"classification: model must be a non-empty string, got {model!r}")
    if route in NOT_TOKEN_BILLED:
        return "not_token_billed"
    if (route, model) in CARD:
        return "priced"
    if f"{route}/{model}" in UNPRICED_PENDING_RATE:
        return "pending_rate"
    return "unknown"


def price(spans: Sequence[LlmSpanUsage]) -> PricedUsage:
    """Price a turn's llm spans at list rates.

    Every span is validated first; a malformed one raises rather than being
    skipped, because a silently dropped span is a silently understated bill.
    """
    if spans is None:
        raise TypeError("price: spans must be a sequence, got None")
    for index, span in enumerate(spans):
        _validate_span(span, index)

    billable = [s for s in spans if _route_of(s) not in NOT_TOKEN_BILLED]
    if not billable:
        # No billed call to price: every span ran locally, or there were no llm
        # spans at all. Either way there is no dollar figure to show.
        return PricedUsage(None, "not_token_billed", (), 0, CARD_VERSION)

    unpriced = _unpriced_routes(billable)
    # Counted over billable spans only: a local span that reported nothing
    # still owes no dollars, so flagging it would be a caveat about nothing.
    without_usage = sum(1 for s in billable if s.prompt_tokens is None)
    if unpriced:
        return PricedUsage(None, "unpriced", unpriced, without_usage, CARD_VERSION)

    priced = [s for s in billable if s.prompt_tokens is not None]
    cost = sum(_span_cost(s) for s in priced)
    cache_aware = bool(priced) and all(_cache_detailed(s) for s in priced)
    return PricedUsage(cost, "cache_aware" if cache_aware else "ceiling", (),
                       without_usage, CARD_VERSION)


def _cache_detailed(span: LlmSpanUsage) -> bool:
    """Whether every cache leg this span could have used is priced from a count.

    `cache_aware` is the strongest label the vocabulary carries — `aggregate`
    spells it "priced with every span's cache split known" — so it must not be
    granted on half a split.

      * The READ leg always needs its count: a cached read is cheaper than input
        on every vendor carded here, so billing it blind overstates.
      * The WRITE leg needs its count wherever the vendor prices that leg apart
        from input. `BILLS_AT_INPUT_RATE` is the one exemption, and it is exact
        rather than lenient: a written token costs precisely what the uncached
        input it is folded into costs, so the count changes no dollar. A
        published premium (GPT-5.6+ at 1.25x, every Anthropic entry) left
        uncounted understates that leg by 20%, and an unestablished leg settles
        nothing either way — both stay "ceiling" until the count arrives.
    """
    if span.cached_input_tokens is None:
        return False
    # Unpriced routes short-circuit before `price/1` reaches here.
    rate = CARD[(provider_route(span.provider, span.adapter), span.model)]
    return (rate.cache_write_per_mtok is BILLS_AT_INPUT_RATE
            or span.cache_write_tokens is not None)


def _route_of(span: LlmSpanUsage) -> str | None:
    """The span's billing route, or None when the span did not identify itself.

    A span with no provider or no model has no route to look up. It is neither
    dropped nor priced: `_unpriced_routes` names it so the blank cell points at
    the exporter that produced it.
    """
    if not span.provider or not span.model:
        return None
    return provider_route(span.provider, span.adapter)


def _unpriced_routes(billable: Sequence[LlmSpanUsage]) -> tuple[str, ...]:
    """The "<route>/<model>" names a reader must act on, deduped and sorted."""
    names = set()
    for span in billable:
        route = _route_of(span)
        if route is None:
            names.add(f"{span.provider or '(no provider)'}/{span.model or '(no model)'}")
        elif (route, span.model) not in CARD:
            names.add(f"{route}/{span.model}")
    return tuple(sorted(names))


def _span_cost(span: LlmSpanUsage) -> float:
    """One span's list-price cost in dollars.

    `prompt_tokens` is the vendor's blended input figure, so the cache counts
    are SUBTRACTED out of it rather than added to it.
    """
    route = provider_route(span.provider, span.adapter)
    rate = CARD[(route, span.model)]  # unpriced routes short-circuit before here
    cached = span.cached_input_tokens or 0
    written = span.cache_write_tokens or 0
    uncached = span.prompt_tokens - cached - written
    if uncached < 0:
        raise ValueError(
            f"pricing: {route}/{span.model} reported {cached} cached + {written} cache-write "
            f"tokens against {span.prompt_tokens} prompt tokens — prompt_tokens is the BLENDED "
            "figure and must contain both; the adapter's token map is wrong"
        )
    if span.completion_tokens is None:
        raise ValueError(
            f"pricing: {route}/{span.model} reported prompt tokens but no completion tokens — "
            "a span carries either a whole usage map or none"
        )
    label = f"{route}/{span.model}"
    cached_rate = _leg_rate(rate.cached_input_per_mtok, rate.input_per_mtok, cached,
                            label, "cached-input")
    write_rate = _leg_rate(rate.cache_write_per_mtok, rate.input_per_mtok, written,
                           label, "cache-write")
    return (uncached * rate.input_per_mtok
            + cached * cached_rate
            + written * write_rate
            + span.completion_tokens * rate.output_per_mtok) / 1_000_000


def _leg_rate(published: CacheRate, input_per_mtok: float, tokens: int,
              label: str, leg: str) -> float:
    """Dollars per MTok for one cache leg, or a loud refusal.

    Three states, not two. `BILLS_AT_INPUT_RATE` is the vendor's read price for
    that leg and prices at the input rate. `None` means the figure was never
    established and must refuse, because pricing it at the input rate anyway is
    the silent fallback that hid Mistral's published -90% cached-input discount.
    An unestablished leg refuses only when the span actually used it, so a card
    entry may honestly not know a rate the product never exercises.
    """
    if published is BILLS_AT_INPUT_RATE:
        return input_per_mtok
    if published is None:
        if tokens:
            raise ValueError(
                f"pricing: {label} reported {tokens} {leg} tokens but the card records no "
                f"{leg} rate for it — that leg was never established, so pricing it would be "
                "a guess. Read the vendor's price list and add the rate, or "
                "BILLS_AT_INPUT_RATE if the vendor charges no premium there"
            )
        return 0.0
    if not isinstance(published, float):
        raise TypeError(f"pricing: {label} {leg} rate must be a float, BILLS_AT_INPUT_RATE "
                        f"or None, got {published!r}")
    return published


_REQUIRED_ATTRS = ("model", "provider", "adapter", "prompt_tokens", "completion_tokens",
                   "cached_input_tokens", "cache_write_tokens", "errored", "under_subagent")
_TOKEN_ATTRS = ("prompt_tokens", "completion_tokens", "cached_input_tokens", "cache_write_tokens")


def _validate_span(span: LlmSpanUsage, index: int) -> None:
    missing = [name for name in _REQUIRED_ATTRS if not hasattr(span, name)]
    if missing:
        raise TypeError(f"pricing: span {index} is missing {', '.join(missing)} — "
                        "it is not an LlmSpanUsage")
    # "" is what the grading layer reports for a span that carried no model or
    # provider — a real value to be surfaced as unpriced, not malformed input.
    if not isinstance(span.model, str):
        raise TypeError(f"pricing: span {index} model must be a string ({span.model!r})")
    if not isinstance(span.provider, str):
        raise TypeError(f"pricing: span {index} provider must be a string ({span.provider!r})")
    if span.adapter is not None and not isinstance(span.adapter, str):
        raise TypeError(f"pricing: span {index} adapter must be a string or None "
                        f"({span.adapter!r})")
    for name in _TOKEN_ATTRS:
        _validate_count(getattr(span, name), name, index)


def _validate_count(value: object, name: str, index: int) -> None:
    if value is None:
        return
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"pricing: span {index} {name} must be an int or None, got {value!r}")
    if value < 0:
        raise ValueError(f"pricing: span {index} {name} is negative ({value})")
