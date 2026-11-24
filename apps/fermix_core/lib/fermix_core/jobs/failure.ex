defmodule FermixCore.Jobs.Failure do
  @moduledoc """
  What a failed job run's reason is (M106 §5.2), read from the reason term
  while it is still a term and never from its text.

  `kind/1` maps a run's failure reason to one kind from a closed list, which
  the run's row stores in `job_runs.failure_kind` (`stored/1`):

    * the provider's: `:provider_rate_limit`, `:provider_quota`,
      `:provider_auth` (a sign-in or key the provider refused),
      `:provider_unavailable`, `:provider_timeout`, `:provider_transport`, from
      the provider error's own `kind` (`Providers.Error`), and `:no_route`
      when no provider could be selected for the run;
    * the runner's watchdog: `:time_limit`, `:idle_limit`;
    * the runner's checks before the loop: `:unknown_skill`,
      `:tools_unavailable`, `:skill_grants_nothing`;
    * the agent loop's: `:context_recovery`;
    * a run whose process died: `:crashed` (the Scheduler's monitor, or the
      runner seeing its loop die) and `:reaped` (the Scheduler's reconcile
      pass found no runner);
    * `:other`, any reason the list does not name. The run's `error` keeps its
      text.

  The loop detector's stop and the iteration cap still reach the runner as
  sentences, so they are `:other` until they are terms.

  `provider_failure?/1` is the one question code answers without a model:
  whether the provider failed. It is the cue run's rule (M60 §9.4), and it
  does not follow the kind: a sign-in failure has a provider kind but is not
  the provider's failure by this rule.
  """

  alias FermixCore.Providers.Transient

  @kinds [
    :provider_rate_limit,
    :provider_quota,
    :provider_auth,
    :provider_unavailable,
    :provider_timeout,
    :provider_transport,
    :no_route,
    :time_limit,
    :idle_limit,
    :unknown_skill,
    :tools_unavailable,
    :skill_grants_nothing,
    :context_recovery,
    :crashed,
    :reaped,
    :other
  ]

  # A provider API error's own kind and the run kind it is (`Providers.Error`).
  @api_kinds %{
    rate_limit: :provider_rate_limit,
    quota: :provider_quota,
    auth: :provider_auth,
    provider_unavailable: :provider_unavailable,
    timeout: :provider_timeout
  }

  # Provider error kinds that end a run as a provider failure (M60 §9.4: no
  # route, a transport error, a rate limit, a 5xx). An exhausted account
  # (`:quota`) clears the same way a rate limit does. Every transport error
  # counts, whatever its kind.
  @provider_api_kinds [:rate_limit, :quota, :provider_unavailable, :timeout]

  @type kind ::
          :provider_rate_limit
          | :provider_quota
          | :provider_auth
          | :provider_unavailable
          | :provider_timeout
          | :provider_transport
          | :no_route
          | :time_limit
          | :idle_limit
          | :unknown_skill
          | :tools_unavailable
          | :skill_grants_nothing
          | :context_recovery
          | :crashed
          | :reaped
          | :other

  @doc "Every kind `kind/1` can return, and the Scheduler's `:reaped`."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The kind of a run's failure reason. A failover chain's kind is its last
  route's, the failure that ended the run.
  """
  @spec kind(term()) :: kind()
  def kind({:provider_error, %{kind: kind} = error}) when is_atom(kind),
    do: api_kind(kind, Map.get(error, :status))

  def kind({:provider_transport_error, %{kind: :timeout}}), do: :provider_timeout
  def kind({:provider_transport_error, %{kind: kind}}) when is_atom(kind), do: :provider_transport

  def kind({:all_routes_failed, [_ | _] = attempts}) do
    {_provider, last_reason} = List.last(attempts)
    kind(last_reason)
  end

  def kind({:no_route, message}) when is_binary(message), do: :no_route
  def kind(:no_routes), do: :no_route
  def kind({:time_limit, ms}) when is_integer(ms), do: :time_limit
  def kind({:idle_limit, ms}) when is_integer(ms), do: :idle_limit
  def kind({:unknown_skill, name}) when is_binary(name), do: :unknown_skill
  def kind({:tools_unavailable, sentence}) when is_binary(sentence), do: :tools_unavailable
  def kind({:skill_grants_nothing, sentence}) when is_binary(sentence), do: :skill_grants_nothing
  def kind({:context_recovery_failed, _reason}), do: :context_recovery
  def kind({:agent_loop_exit, _reason}), do: :crashed
  def kind(%RuntimeError{} = error), do: runtime_kind(error)
  def kind(_reason), do: :other

  @doc "The text `job_runs.failure_kind` stores for `kind`."
  @spec stored(kind()) :: String.t()
  def stored(kind) when kind in @kinds, do: Atom.to_string(kind)

  @doc "Whether a run's error reason is a provider failure (M60 §9.4)."
  @spec provider_failure?(term()) :: boolean()
  def provider_failure?({:provider_transport_error, %{kind: kind}}) when is_atom(kind), do: true

  def provider_failure?({:provider_error, %{kind: kind} = error}) when is_atom(kind),
    do: kind in @provider_api_kinds or server_error?(Map.get(error, :status))

  def provider_failure?({:all_routes_failed, [_ | _] = attempts}),
    do: Enum.all?(attempts, fn {_provider, reason} -> provider_failure?(reason) end)

  def provider_failure?({:context_recovery_failed, reason}), do: provider_failure?(reason)
  def provider_failure?({:no_route, message}) when is_binary(message), do: true
  def provider_failure?(:no_routes), do: true
  def provider_failure?(%RuntimeError{} = error), do: Transient.connection_unavailable?(error)
  def provider_failure?(_reason), do: false

  # A 5xx the provider error did not name `:provider_unavailable` is one all
  # the same, as `provider_failure?/1` reads it.
  defp api_kind(kind, status) do
    cond do
      Map.has_key?(@api_kinds, kind) -> Map.fetch!(@api_kinds, kind)
      server_error?(status) -> :provider_unavailable
      true -> :other
    end
  end

  # The bare Finch error a pool with no connection to give returns
  # (`Transient.connection_unavailable?/1`); any other raise is the run's own.
  defp runtime_kind(error) do
    if Transient.connection_unavailable?(error), do: :provider_transport, else: :other
  end

  defp server_error?(status), do: is_integer(status) and status >= 500
end
