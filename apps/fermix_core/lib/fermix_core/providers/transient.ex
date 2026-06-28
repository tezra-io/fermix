defmodule FermixCore.Providers.Transient do
  @moduledoc """
  Classifies a provider error as a transient infrastructure failure worth a
  bounded same-provider retry (vs. a deterministic failure that should fail
  loud or fail over to another provider).

  Single source of truth shared by the route-level retry in
  `FermixCore.Providers.Failover.run_chain/3` and the scheduled-job runner's
  coarser deadline-bounded backoff (`FermixCore.Jobs.Runner`). Keying both on
  one classifier keeps the two retry scopes — quick inner (every surface) and
  long outer (cron only) — from drifting apart.

  Retryable kinds are the ones a same-provider retry can plausibly clear: a
  pool-checkout/connection failure (the wake-from-sleep race), a transport
  timeout/close/network blip, and a provider 5xx/overload. `:rate_limit` and
  `:quota` are deliberately NOT retryable here — without the server's
  Retry-After a quota retry only burns attempts against a hard limit.
  """

  alias FermixCore.Net.HttpClient

  @retryable_transport_kinds [:connection_unavailable, :timeout, :transport_closed, :network]
  @retryable_api_kinds [:timeout, :provider_unavailable]

  @doc """
  True when `reason` is a transient infrastructure failure eligible for a
  bounded same-provider retry.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?({:provider_transport_error, %{kind: kind}}),
    do: kind in @retryable_transport_kinds

  def retryable?({:provider_error, %{kind: kind}}), do: kind in @retryable_api_kinds
  def retryable?(%RuntimeError{} = reason), do: HttpClient.connection_unavailable?(reason)
  def retryable?(_reason), do: false

  @doc """
  True when `reason` is specifically the connection-unavailable / pool-checkout
  failure — a network-wide condition that hits every provider at once, so it
  must retry the SAME route rather than fail over (the failover chain
  deliberately excludes it).
  """
  @spec connection_unavailable?(term()) :: boolean()
  def connection_unavailable?({:provider_transport_error, %{kind: :connection_unavailable}}),
    do: true

  def connection_unavailable?(%RuntimeError{} = reason),
    do: HttpClient.connection_unavailable?(reason)

  def connection_unavailable?(_reason), do: false
end
