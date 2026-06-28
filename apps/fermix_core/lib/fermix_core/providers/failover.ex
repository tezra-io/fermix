defmodule FermixCore.Providers.Failover do
  @moduledoc """
  Failover eligibility for provider errors
  (docs/design/MULTI_PROVIDER_FAILOVER.md §6).

  Fallback handles unavailable providers, not deterministic bugs. Decisions
  key on `FermixCore.Providers.Error` `kind` atoms and the `stage` field —
  never on message strings.

  Token refresh on OAuth auth failure has exactly one owner: the adapter.
  A residual `kind: :auth` tagged `auth_mode: :oauth` means the
  adapter-internal refresh+retry already failed — terminal for the route,
  immediately eligible for fallback. API-key auth failure is broken setup
  and stops immediately.

  The streaming boundary (§5) is enforced where user visibility is actually
  known: the agent loop wraps its stream callback, tracks whether content
  was emitted, and vetoes failover through its `eligible?` override once it
  was — re-streaming from another provider would mix outputs. The error's
  `stage` tag is diagnostic only; surfaces without a stream callback have
  no user-visible content and fail over on kind alone.
  """

  require Logger

  alias FermixCore.Providers.Adapter
  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry
  alias FermixCore.Providers.Transient

  @fallback_api_kinds [:timeout, :rate_limit, :quota, :provider_unavailable]
  # `:connection_unavailable` (pool-checkout exhaustion) is deliberately absent:
  # it means no connection could be obtained at all, which on a wake-from-sleep
  # race is true for every provider at once, so sweeping the chain only burns
  # doomed attempts. It stays terminal here and the scheduled-job runner's
  # transient backoff owns recovery instead.
  @fallback_transport_kinds [:timeout, :transport_closed, :network, :transport]

  # Route-level same-provider retry budget — the inner loop under failover.
  # Short exponential backoff (250/500/1000ms) clears a transient flake (e.g.
  # the wake-from-sleep pool-checkout race) without materially delaying a live
  # turn. The cron runner layers its own coarser deadline-bounded backoff on
  # top for multi-minute outages, keyed on the same `Transient` classifier.
  @default_max_retries 3
  @retry_base_delay_ms 250

  @type route :: {Adapter.route_key(), keyword()}
  @type attempt_fn :: (route() -> {:ok, term()} | {:error, term()})

  @doc """
  The single bounded recovery executor (§5). Two layered loops: an inner
  bounded same-provider retry for transient infrastructure errors, and an
  outer failover that moves to the next route on an eligible error. Anything
  else stops immediately. Bounded by `max_retries` per route × the route count.
  Used by the agent loop's initial chat and compaction.

  Options:

    * `:eligible?` — predicate replacing `eligible?/1` for FAILOVER (the agent
      loop layers its stream-content gate on top).
    * `:retryable?` — predicate replacing `Transient.retryable?/1` for the
      same-provider RETRY (the agent loop layers the same stream-content gate
      so a retry never fires once content has streamed).
    * `:max_retries` — bound on same-provider retries per route (default 3).
    * `:retry_delay_fn` — `fn ms -> :ok end` invoked for backoff between
      retries (default `Process.sleep/1`; injected in tests).
    * `:telemetry` — metadata map (e.g. `%{agent: "main"}`) merged into the
      `[:fermix, :provider, :failover]` event emitted per transition.

  Returns the attempt's `{:ok, result}`; the bare reason when only one route
  was attempted (today's single-route behavior); or
  `{:error, {:all_routes_failed, [{provider, reason}]}}` once 2+ routes were
  attempted — whether the chain was exhausted or halted early by an
  ineligible error (the attempted list shows exactly which routes ran).
  """
  @spec run_chain([route()], attempt_fn(), keyword()) :: {:ok, term()} | {:error, term()}
  def run_chain(routes, attempt_fn, opts \\ [])

  def run_chain([], _attempt_fn, _opts), do: {:error, :no_routes}

  def run_chain([route | rest], attempt_fn, opts) when is_function(attempt_fn, 1) do
    ctx = %{
      attempt_fn: attempt_fn,
      eligible_fn: Keyword.get(opts, :eligible?, &eligible?/1),
      retryable_fn: Keyword.get(opts, :retryable?, &Transient.retryable?/1),
      max_retries: Keyword.get(opts, :max_retries, @default_max_retries),
      delay_fn: Keyword.get(opts, :retry_delay_fn, &Process.sleep/1),
      meta: Keyword.get(opts, :telemetry, %{})
    }

    attempt_route(route, rest, ctx, [])
  end

  defp attempt_route({route_key, _route_opts} = route, rest, ctx, tried) do
    attempt_with_retry(route, route_key, rest, ctx, tried, 0)
  end

  # Inner loop: bounded same-provider retry for a transient flake — retry THIS
  # route rather than burn a failover hop or hard-fail. Retry only when the
  # error is transient AND either it is the network-wide `:connection_unavailable`
  # (failover can't help — every provider shares the dead local network) OR this
  # is the last route (nothing to fail over to). Otherwise hand off to the
  # failover/halt path unchanged.
  defp attempt_with_retry(route, route_key, rest, ctx, tried, attempt) do
    case ctx.attempt_fn.(route) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        if retry_same?(reason, rest, ctx, attempt) do
          delay_ms = retry_backoff_ms(attempt)

          Logger.warning(
            "Provider retry: #{route_key.provider}/#{route_key.model} " <>
              "(#{inspect(reason_kind(reason))}) attempt #{attempt + 1}/#{ctx.max_retries} " <>
              "after #{delay_ms}ms"
          )

          ctx.delay_fn.(delay_ms)
          attempt_with_retry(route, route_key, rest, ctx, tried, attempt + 1)
        else
          next_or_halt(route_key, reason, rest, ctx, tried)
        end
    end
  end

  defp retry_same?(reason, rest, ctx, attempt) do
    attempt < ctx.max_retries and
      ctx.retryable_fn.(reason) and
      (Transient.connection_unavailable?(reason) or rest == [])
  end

  defp retry_backoff_ms(attempt), do: @retry_base_delay_ms * Integer.pow(2, attempt)

  defp next_or_halt(route_key, reason, rest, ctx, tried) do
    tried = tried ++ [{route_key.provider, reason}]

    cond do
      not ctx.eligible_fn.(reason) ->
        halt(reason, tried)

      rest == [] ->
        halt(reason, tried)

      true ->
        [{next_key, _next_opts} = next | remaining] = rest
        emit_failover(route_key, next_key, reason, ctx.meta)
        attempt_route(next, remaining, ctx, tried)
    end
  end

  defp halt(reason, [_single_attempt]), do: {:error, reason}
  defp halt(_reason, tried), do: {:error, {:all_routes_failed, tried}}

  defp emit_failover(from_key, to_key, reason, meta) do
    Logger.warning(
      "Provider failover: #{from_key.provider}/#{from_key.model} -> " <>
        "#{to_key.provider}/#{to_key.model} (#{inspect(reason_kind(reason))})"
    )

    meta
    |> Map.merge(%{
      from_provider: from_key.provider,
      from_model: from_key.model,
      to_provider: to_key.provider,
      to_model: to_key.model,
      reason_kind: reason_kind(reason)
    })
    |> ProviderTelemetry.emit_failover()
  end

  defp reason_kind({:provider_error, %{kind: kind}}), do: kind
  defp reason_kind({:provider_transport_error, %{kind: kind}}), do: kind
  defp reason_kind({:image_unsupported, _provider, _model}), do: :image_unsupported
  defp reason_kind(_reason), do: :unknown

  # Eligibility keys on the error `kind` only. The user-visible streaming
  # boundary is owned by the AGENT LOOP's emitted? flag (its eligible?
  # override), not by the error's `stage`: stage derives from raw SSE chunk
  # arrival, so chunks nobody saw (no stream callback — jobs, memory review,
  # compaction, non-streaming channels — or a callback that never emitted)
  # must not block a safe failover. `stage` stays on the error as a
  # diagnostic and rides telemetry as `transport_stage`.
  @spec eligible?(term()) :: boolean()
  def eligible?({:provider_error, %{kind: :auth} = error}) do
    Map.get(error, :auth_mode) == :oauth and refreshed_auth_failure?(error)
  end

  def eligible?({:provider_error, %{kind: kind}}), do: kind in @fallback_api_kinds

  def eligible?({:provider_transport_error, %{kind: kind}}),
    do: kind in @fallback_transport_kinds

  # An image turn routed to a non-vision model can't be served by THIS route, but
  # a later route in the chain may be vision-capable — so fail over to look for
  # one. If none exists the chain exhausts and surfaces the precise message.
  def eligible?({:image_unsupported, _provider, _model}), do: true

  # Unknown shapes (bare strings, atoms, anything outside the Error
  # contract) are conservative: no fallback, fail loud at the boundary.
  def eligible?(_reason), do: false

  # The OAuth eligibility premise is "the adapter's refresh+retry already
  # ran and still failed" — true for a residual 401 and for refresh-machinery
  # failures (status nil). A 403 is entitlement/tier denial (e.g. a Grok plan
  # without API access): re-auth won't fix it and failing over would mask
  # broken setup, so it stays terminal.
  defp refreshed_auth_failure?(error), do: Map.get(error, :status) != 403
end
