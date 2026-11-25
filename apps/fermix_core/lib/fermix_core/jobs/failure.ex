defmodule FermixCore.Jobs.Failure do
  @moduledoc """
  What a failed job run's reason is (M106 §5.2), read from the reason term
  while it is still a term and never from its text.

  `kind/1` maps a run's failure reason to one kind from a closed list, which
  the run's facts store in `job_run_facts.failure_kind` (`stored/1`):

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
    * `:tool_start_unrecorded`: the run stopped before a tool because its
      first tool start could not be stored, and a tool never runs unrecorded
      (M106 §5.1). It is never the provider's, so it is never retried;
    * `:tool_never_succeeded`: no reason maps to it. A run that ended ok, in
      which a tool never once succeeded as in the job's runs before it
      (`Jobs.Degraded`, M106 §6), keeps its own row ok with no kind, and its
      settle gives this kind to the heal it opens. A model could help with it;
    * `:other`, any reason the list does not name. The run's `error` keeps its
      text.

  The loop detector's stop and the iteration cap still reach the runner as
  sentences, so they are `:other` until they are terms.

  `provider_failure?/1` is the one question code answers without a model:
  whether the provider failed. It is the cue run's rule (M60 §9.4), and it
  does not follow the kind: a sign-in failure has a provider kind but is not
  the provider's failure by this rule. It decides a retry (M106 §5.3).

  `model_cannot_help?/1` asks another question, of a stored kind: whether the
  failure lies with the provider or the route, where no model run of the job
  can change it. It is every provider kind and `no_route`, a sign-in failure
  included, and it makes a heal's subject the provider (M106 §5.4).

  `sentence/1` is the owner-facing sentence of a kind no other sentence says:
  a run the Scheduler settled (`:crashed`, `:reaped`), a run that stopped
  before a tool it could not record (`:tool_start_unrecorded`), and runs that
  ended ok with a tool that never worked (`:tool_never_succeeded`).
  """

  alias FermixCore.Jobs.Degraded
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
    :tool_start_unrecorded,
    :tool_never_succeeded,
    :other
  ]

  # The kinds no model run can help with (`model_cannot_help?/1`).
  @model_cannot_help [
    :provider_rate_limit,
    :provider_quota,
    :provider_auth,
    :provider_unavailable,
    :provider_timeout,
    :provider_transport,
    :no_route
  ]
  @model_cannot_help_stored Enum.map(@model_cannot_help, &Atom.to_string/1)

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
          | :tool_start_unrecorded
          | :tool_never_succeeded
          | :other

  @doc """
  Every kind `kind/1` can return, the Scheduler's `:reaped`, and
  `:tool_never_succeeded`, which an ok run's settle gives its heal.
  """
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
  def kind({:tool_start_unrecorded, _reason}), do: :tool_start_unrecorded
  def kind(%RuntimeError{} = error), do: runtime_kind(error)
  def kind(_reason), do: :other

  @doc "The text `job_runs.failure_kind` stores for `kind`."
  @spec stored(kind()) :: String.t()
  def stored(kind) when kind in @kinds, do: Atom.to_string(kind)

  @doc """
  Whether a kind, or the text `stored/1` made of it, is one no model run can
  help with: the provider's own kinds and `no_route`, a sign-in failure
  included. Not `provider_failure?/1`, which reads a reason and asks whether
  waiting can clear it.
  """
  @spec model_cannot_help?(kind() | String.t()) :: boolean()
  def model_cannot_help?(kind) when kind in @kinds, do: kind in @model_cannot_help

  def model_cannot_help?(stored) when is_binary(stored),
    do: stored in @model_cannot_help_stored

  @doc """
  The owner-facing sentence of a kind no other sentence says: a run the
  Scheduler settled, which no runner lived to write for (its runner died,
  `:crashed`, or none was found holding it, `:reaped`), a run that stopped
  before a tool whose start could not be stored (`:tool_start_unrecorded`),
  and runs that ended ok while a tool they called never worked
  (`:tool_never_succeeded`).
  """
  @spec sentence(:crashed | :reaped | :tool_start_unrecorded | :tool_never_succeeded) ::
          String.t()
  def sentence(:crashed), do: "The run stopped before it finished: the process running it ended."

  def sentence(:reaped),
    do:
      "The run was found with nothing running it, after Fermix restarted or its store answered late."

  def sentence(:tool_start_unrecorded),
    do:
      "The run stopped before its next tool ran: Fermix could not record that the tool was " <>
        "starting, so it did not start it."

  def sentence(:tool_never_succeeded),
    do:
      "A tool the job calls failed on every call in each of its last #{Degraded.runs()} runs, " <>
        "though each of those runs ended without an error."

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
