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

  `sentence/2` is the one owner of the plain sentence Fermix states for a
  failure (M106 §5.8, stage S4): one per kind on the list, built by code from
  the tagged reason, stated in the owner's units (a limit in minutes, naming
  the tool still running when the run's timeline has one), and never a
  generic line. A heal is told it, a run's row stores it, and a guest's
  failure line leads with it. `:other` says that Fermix has no sentence of
  its own for the failure; its text (`other_text/1`) is kept on the row and
  quoted, as someone else's words, beside the sentence.
  """

  alias FermixCore.Jobs.Degraded
  alias FermixCore.Providers.Error, as: ProviderError
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

  # The kinds a caller names with no reason term: a run the Scheduler settled
  # (its runner died, or none held it) and an ok run's heal (M106 §6).
  @named_kinds [:crashed, :reaped, :tool_start_unrecorded, :tool_never_succeeded]
  # The provider's own kinds, said of the provider by name.
  @provider_kinds @model_cannot_help -- [:no_route]

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
  The one plain sentence Fermix states for a failed run (M106 §5.8): of the
  kind of `reason` (`kind/1`), built from the tagged reason, or of a kind the
  caller names with no reason (`:crashed`, `:reaped`, `:tool_start_unrecorded`,
  `:tool_never_succeeded`). Every kind on the list has its own; none is a
  generic line. `opts`: `:in_flight`, the tool still running when the run
  stopped (the newest unfinished entry of its timeline), which a limit names.
  A name in a sentence (a skill, a tool) is quoted as data.
  """
  @spec sentence(term(), keyword()) :: String.t()
  def sentence(reason, opts \\ []) when is_list(opts) do
    kind = if reason in @named_kinds, do: reason, else: kind(reason)
    kind_sentence(kind, reason, opts)
  end

  @doc """
  The sentence of `kind` for `reason`, total: a reason in the kind's own shape
  gets its full sentence, any other reason the kind's plainest, and a kind off
  the list `:other`'s. A sentence is never what takes a run's settle down, so
  nothing here raises on a shape `kind/1` would never hand it.
  """
  @spec kind_sentence(atom(), term(), keyword()) :: String.t()
  def kind_sentence(kind, reason, opts \\ []) when is_atom(kind) and is_list(opts),
    do: told(kind, reason, in_flight(Keyword.get(opts, :in_flight)))

  defp in_flight(tool) when is_binary(tool) and tool != "", do: tool
  defp in_flight(_none), do: nil

  @doc """
  The text a failure Fermix has no sentence for keeps (`:other`): its own
  sentence when the reason is one, or tags one (`{tag, sentence}`); a
  provider's refusal's message, a failover chain's being its last route's;
  and the term as Elixir writes it otherwise. The run's row stores it, and a
  heal quotes it beside `sentence/2`'s line as the error's own words.
  """
  @spec other_text(term()) :: String.t()
  def other_text(reason) when is_binary(reason), do: reason
  def other_text({tag, text}) when is_atom(tag) and is_binary(text), do: text

  def other_text({:provider_error, %{message: message}})
      when is_binary(message) and message != "",
      do: message

  def other_text({:all_routes_failed, [_ | _] = attempts} = reason) do
    case List.last(attempts) do
      {_provider, last_reason} -> other_text(last_reason)
      _no_attempt -> inspect(reason)
    end
  end

  def other_text(reason), do: inspect(reason)

  # A key or sign-in the provider answered no to, or one Fermix never sent:
  # with no HTTP exchange (`Providers.Error.auth/3`) the provider refused
  # nothing, so the sentence does not say it did.
  defp told(:provider_auth, reason, _tool) do
    name = provider_name(reason)

    if unsent?(reason),
      do: "Fermix has no usable key or sign-in for #{name}.",
      else: provider_sentence(:provider_auth, name)
  end

  defp told(kind, reason, _tool) when kind in @provider_kinds,
    do: provider_sentence(kind, provider_name(reason))

  defp told(:no_route, _reason, _tool), do: "No model provider was available to take the run."

  defp told(:time_limit, {:time_limit, ms}, tool) when is_integer(ms) and ms > 0,
    do: "The run stopped at its #{span(ms, :adjective)} time limit#{still_running(tool)}."

  defp told(:time_limit, _reason, tool),
    do: "The run stopped at its time limit#{still_running(tool)}."

  defp told(:idle_limit, {:idle_limit, ms}, tool) when is_integer(ms) and ms > 0,
    do: "The run stopped after #{span(ms, :noun)} with nothing happening#{still_running(tool)}."

  defp told(:idle_limit, _reason, tool),
    do: "The run stopped after too long with nothing happening#{still_running(tool)}."

  defp told(:unknown_skill, {:unknown_skill, name}, _tool) when is_binary(name),
    do: "The run could not start: the skill #{named(name)} it is bound to does not exist."

  defp told(:unknown_skill, _reason, _tool),
    do: "The run could not start: the skill it is bound to does not exist."

  # A check's own sentence, which Fermix wrote from the job and its skill,
  # under the kind's own tag only.
  defp told(kind, {kind, sentence}, _tool)
       when kind in [:tools_unavailable, :skill_grants_nothing] and is_binary(sentence) and
              sentence != "",
       do: sentence

  defp told(:tools_unavailable, _reason, _tool),
    do: "The run could not start: the tools the job names are not available to it."

  defp told(:skill_grants_nothing, _reason, _tool),
    do: "The run could not start: the skill it is bound to grants it no tool it can use."

  defp told(:context_recovery, _reason, _tool),
    do:
      "The run's conversation grew larger than its model can hold, and Fermix could not " <>
        "compress it."

  defp told(:crashed, _reason, _tool),
    do: "The run stopped before it finished: the process running it ended."

  defp told(:reaped, _reason, _tool),
    do:
      "The run was found with nothing running it, after Fermix restarted or its store answered late."

  defp told(:tool_start_unrecorded, _reason, _tool),
    do:
      "The run stopped before its next tool ran: Fermix could not record that the tool was " <>
        "starting, so it did not start it."

  defp told(:tool_never_succeeded, _reason, _tool),
    do:
      "A tool the job calls failed on every call in each of its last #{Degraded.runs()} runs, " <>
        "though each of those runs ended without an error."

  # `:other`, and any kind off the list.
  defp told(_other, _reason, _tool),
    do: "The run stopped on an error Fermix has no sentence of its own for."

  defp provider_sentence(:provider_rate_limit, name),
    do: sentence_case("#{name} is limiting this account's requests.")

  defp provider_sentence(:provider_quota, name),
    do: sentence_case("#{name} says this account is out of credit or over its usage limit.")

  defp provider_sentence(:provider_auth, name),
    do: sentence_case("#{name} refused the key or sign-in Fermix uses.")

  defp provider_sentence(:provider_unavailable, name),
    do: sentence_case("#{name} was unavailable.")

  defp provider_sentence(:provider_timeout, name),
    do: sentence_case("#{name} did not answer in time.")

  defp provider_sentence(:provider_transport, name), do: "Fermix could not reach #{name}."

  # The provider a reason names, as every reply names it; a failover chain's
  # is its last route's, and a reason naming none is the model provider.
  defp provider_name({error, %{provider: provider}})
       when error in [:provider_error, :provider_transport_error] and is_atom(provider),
       do: ProviderError.provider_label(provider)

  defp provider_name({:all_routes_failed, [_ | _] = attempts}),
    do: attempts |> List.last() |> elem(1) |> provider_name()

  defp provider_name(_reason), do: "the model provider"

  # Whether the failure is a call that was never sent; a failover chain's is
  # its last route's.
  defp unsent?({:provider_error, %{status: nil}}), do: true

  defp unsent?({:all_routes_failed, [_ | _] = attempts}) do
    case List.last(attempts) do
      {_provider, last_reason} -> unsent?(last_reason)
      _no_attempt -> false
    end
  end

  defp unsent?(_reason), do: false

  defp sentence_case(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  defp still_running(nil), do: ""

  defp still_running(tool), do: " while its tool #{named(tool)} was still running"

  defp named(name) when is_binary(name), do: "\"" <> String.replace(name, "\"", "'") <> "\""

  # A limit in the owner's units: whole minutes, else whole seconds, else
  # milliseconds; as a "10-minute" limit, or "10 minutes" of something.
  defp span(ms, form) do
    cond do
      rem(ms, 60_000) == 0 -> unit(div(ms, 60_000), "minute", form)
      rem(ms, 1_000) == 0 -> unit(div(ms, 1_000), "second", form)
      true -> unit(ms, "millisecond", form)
    end
  end

  defp unit(n, name, :adjective), do: "#{n}-#{name}"
  defp unit(1, name, :noun), do: "1 #{name}"
  defp unit(n, name, :noun), do: "#{n} #{name}s"

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
