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

  @fallback_api_kinds [:timeout, :rate_limit, :quota, :provider_unavailable]
  # `:connection_unavailable` (pool-checkout exhaustion) is deliberately absent:
  # it means no connection could be obtained at all, which on a wake-from-sleep
  # race is true for every provider at once, so sweeping the chain only burns
  # doomed attempts. It stays terminal here and the scheduled-job runner's
  # transient backoff owns recovery instead.
  @fallback_transport_kinds [:timeout, :transport_closed, :network, :transport]

  @type route :: {Adapter.route_key(), keyword()}
  @type attempt_fn :: (route() -> {:ok, term()} | {:error, term()})

  @doc """
  The single bounded failover executor (§5): try each route in order; an
  eligible error moves to the next route, anything else stops immediately.
  Used by both the agent loop's initial chat and compaction — neither grows
  its own retry loop. Bounded by the route count.

  Options:

    * `:eligible?` — predicate replacing `eligible?/1` (the agent loop layers
      its stream-content gate on top).
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
    eligible_fn = Keyword.get(opts, :eligible?, &eligible?/1)
    meta = Keyword.get(opts, :telemetry, %{})
    attempt_route(route, rest, attempt_fn, eligible_fn, meta, [])
  end

  defp attempt_route({route_key, _route_opts} = route, rest, attempt_fn, eligible_fn, meta, tried) do
    case attempt_fn.(route) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        next_or_halt(route_key, reason, rest, attempt_fn, eligible_fn, meta, tried)
    end
  end

  defp next_or_halt(route_key, reason, rest, attempt_fn, eligible_fn, meta, tried) do
    tried = tried ++ [{route_key.provider, reason}]

    cond do
      not eligible_fn.(reason) ->
        halt(reason, tried)

      rest == [] ->
        halt(reason, tried)

      true ->
        [{next_key, _next_opts} = next | remaining] = rest
        emit_failover(route_key, next_key, reason, meta)
        attempt_route(next, remaining, attempt_fn, eligible_fn, meta, tried)
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
