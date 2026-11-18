defmodule FermixCore.Management.PhoneCalls do
  @moduledoc """
  The `phone_calls.*` methods and the facts the Phone calls section of Settings,
  Voice shows (M94 §12, "Enablement, readiness and active calls"; §09, the
  recovery view). Every app and the setup page render what this module says and
  derive nothing of their own.

  Three facts, kept apart:

    * **enablement**: whether the owner turned phone calls on
      (`[fermix_core.phone_calls] enabled`);
    * **readiness**: whether the setup a call needs is complete, each missing
      requirement named in the owner's words (`PhoneCalls.Readiness`, read as
      if switched on, so a home with phone calls off still says what it
      lacks before it is turned on);
    * **the call**: the owner's call holding the one-call slot, in progress or
      uncertain (`PhoneCalls.Ledger.outstanding/2`).

  The summary reads them as one word (`summary_states/0`): the call first
  (`calling`, `stopping`, or `placement_unknown` or `termination_unconfirmed`
  while an uncertain call
  holds the slot, whether phone calls are on or off), then `disabled`, then
  `needs_setup`, then `ready`.

  The methods, all scoped to the home's owner (`Memory.Config.owner_id/0`):

    * `phone_calls.status`: the three facts, the summary and the engine that
      calls (GPT-Live, a fact of the engine and not a setting);
    * `phone_calls.list`: the owner's recent calls, newest first, each with
      its state, outcome, uncertainty and its three costs labelled apart;
    * `phone_calls.stop`: the owner's stop of a call, through
      `PhoneCalls.Manager.cancel/3`, the path the `phone_call` tool's cancel
      takes;
    * `phone_calls.recovery.get`: every unresolved call (whether it was
      placed is unknown, or its end is unconfirmed) with what is known of it:
      when it was attempted, the destination the brief permitted, the
      provider's and the carrier's ids where they are really known, when the
      slot is released, and what the owner can do at Telnyx meanwhile;
    * `phone_calls.recovery.confirm`: the owner's word that such a call has
      ended, which they checked in their Telnyx portal (`confirm_ended/2`).

  How a call is said is `PhoneCalls.Report`'s: every call view is drawn from
  `PhoneCalls.Report.view/2`, so the apps, the setup page and the settings CLI
  say a call in the words its report says it. Only the owner's confirmation
  releases a slot from here, with its own reason; no tool reaches it. A
  destination number appears only in the recovery view, where the owner needs
  it to find the call at the carrier, and no response carries a credential.

  Three hooks other modules call: `apply_enabled/2`, the runtime half of the
  off switch, which `Management.Settings` runs once the section's write has
  landed; `check_secret_value/2`, which `Management.Secrets` runs before it
  stores a trunk password; and `check_restart/1`, which the owner's restart
  asks (`lifecycle.prepare_restart`, the setup page's Restart). Holding a
  credential a call in progress reads is the writer's rule
  (`PhoneCalls.CallHold`), and its sentences are published here for the copy
  gate.

  Options, for tests: `:repo` (the ledger's server), `:manager` (the call
  manager's server), `:now` (a `DateTime`), `:owner_id`, `:config` (a
  `PhoneCalls.Config`) and `:readiness` (inputs `PhoneCalls.Readiness.current/1`
  takes).
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.PhoneCallsSql
  alias FermixCore.PhoneCalls.CallHold
  alias FermixCore.PhoneCalls.CarrierProfile
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Manager
  alias FermixCore.PhoneCalls.Readiness
  alias FermixCore.PhoneCalls.Report

  require Logger

  @capability "phone_calls"
  @methods ~w(phone_calls.status phone_calls.list phone_calls.stop phone_calls.recovery.get
               phone_calls.recovery.confirm)
  @call_id_params ~w(call_id)
  @engine %{"name" => "GPT-Live", "carrier" => "Telnyx"}

  @summary_states ~w(disabled needs_setup ready calling stopping placement_unknown
                      termination_unconfirmed)
  @summary_labels %{
    "disabled" => "Disabled",
    "needs_setup" => "Needs setup",
    "ready" => "Ready",
    "calling" => "Calling",
    "stopping" => "Stopping",
    "placement_unknown" => "Placement unknown",
    "termination_unconfirmed" => "Termination unconfirmed"
  }

  @disabled_sentence "Phone calls are off."
  @ready_sentence "Fermix can place a call when you ask for one."
  @calling_sentence "A call is in progress."
  @containment [
    "In the Telnyx portal, end any call still active on your connection, or turn the " <>
      "connection off to end every call through it.",
    "Meanwhile, if you set your connection's daily spend limit and its one channel as the " <>
      "setup asks, they bound what the call can cost.",
    "Once the portal shows the call has ended, confirm it here, and a new call may be " <>
      "placed. Fermix never dials this call again."
  ]

  @not_found_sentence "No phone call of yours has that id."
  @not_running_sentence "Phone calls are not running here, so no call is in progress to stop."
  @manager_unreachable_sentence "Fermix could not reach the part of it that places calls. " <>
                                  "See the daemon log."
  @unreadable_sentence "Fermix could not read its phone call records. See the daemon log."
  @undispatched_stopped_sentence "The call that had not been placed yet was stopped, and " <>
                                   "nothing was dialed."
  @live_stopped_sentence "The call in progress was asked to end. It reads stopping until its " <>
                           "end is known."
  @unresolved_sentence "An earlier call's termination is unconfirmed, so a new call waits " <>
                         "until you confirm it ended or OpenAI's own limit on a call passes."
  @confirmed_sentence "Fermix marked the call ended on your word, so a new call may be " <>
                        "placed. The outcome already recorded is unchanged."
  @in_progress_sentence "That call is still in progress, so only stopping it ends it."
  @nothing_to_confirm_sentence "That call has no unconfirmed end to confirm."
  @not_recorded_sentence "Fermix could not record that, so the call slot stays held. See the " <>
                           "daemon log."
  @confirm_not_running_sentence "Phone calls are not running here, so Fermix could not record " <>
                                  "that the call ended."
  @password_sentences %{
    too_long:
      "That password is longer than a connection password can be. Copy it again from your " <>
        "Telnyx connection.",
    control_characters:
      "A connection password has no line breaks. Copy it again from your Telnyx connection.",
    invalid_utf8: "A connection password is text. Copy it again from your Telnyx connection."
  }

  @type error ::
          {:unavailable, String.t(), String.t()} | {:invalid_params, String.t(), String.t()}

  @doc "The methods this family serves, in publication order."
  @spec methods() :: [String.t(), ...]
  def methods, do: @methods

  @doc "Every word the summary's `state` takes."
  @spec summary_states() :: [String.t(), ...]
  def summary_states, do: @summary_states

  @doc "Answers one `phone_calls.*` request, its parameters validated here."
  @spec route(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, atom(), map()}
  def route("phone_calls.status", params, opts) when is_map(params) and is_list(opts),
    do: with(:ok <- only(params, []), do: answer(status(opts)))

  def route("phone_calls.list", params, opts) when is_map(params) and is_list(opts),
    do: with(:ok <- only(params, []), do: answer(list(opts)))

  def route("phone_calls.recovery.get", params, opts) when is_map(params) and is_list(opts),
    do: with(:ok <- only(params, []), do: answer(recovery(opts)))

  def route("phone_calls.stop", params, opts) when is_map(params) and is_list(opts) do
    with :ok <- only(params, @call_id_params),
         {:ok, call_id} <- call_id_param(params) do
      answer(stop(call_id, opts))
    end
  end

  def route("phone_calls.recovery.confirm", params, opts) when is_map(params) and is_list(opts) do
    with :ok <- only(params, @call_id_params),
         {:ok, call_id} <- call_id_param(params) do
      answer(confirm_ended(call_id, opts))
    end
  end

  # -- status --------------------------------------------------------------------

  @doc "The three facts, the summary and the engine that calls."
  @spec status(keyword()) :: {:ok, map()} | {:error, error()}
  def status(opts \\ []) when is_list(opts) do
    with {:ok, facts} <- facts(opts) do
      {:ok,
       %{
         "enabled" => facts.config.enabled,
         "readiness" => readiness_view(facts.readiness),
         "call" => facts.call && call_view(facts.call, facts.now),
         "summary" => summary_view(facts),
         "engine" => engine_view()
       }}
    end
  end

  @doc """
  The summary alone (`state`, `label`, `sentence`), as the section's status
  row shows it.
  """
  @spec summary(keyword()) :: {:ok, map()} | {:error, error()}
  def summary(opts \\ []) when is_list(opts) do
    with {:ok, facts} <- facts(opts), do: {:ok, summary_view(facts)}
  end

  @doc "The engine that calls, as a row shows it: its name and the model it runs."
  @spec engine_label() :: String.t()
  def engine_label, do: "#{@engine["name"]} · #{CarrierProfile.model()}"

  defp facts(opts) do
    config = Keyword.get_lazy(opts, :config, &Config.get/0)
    now = now(opts)

    with {:ok, rows} <- outstanding(now, opts) do
      {:ok, %{config: config, readiness: setup(config, opts), call: List.first(rows), now: now}}
    end
  end

  # Read as if switched on, so a home with phone calls off still names what it
  # lacks. Enablement is the other fact, never folded into this one.
  defp setup(%Config{} = config, opts) do
    opts
    |> Keyword.get(:readiness, [])
    |> Keyword.put(:config, %{config | enabled: true})
    |> Readiness.current()
  end

  defp outstanding(now, opts) do
    owner = owner_id(opts)

    case Ledger.outstanding(now, ledger_opts(opts)) do
      {:ok, rows} -> {:ok, Enum.filter(rows, &(&1.owner_id == owner))}
      {:error, :disabled} -> {:ok, []}
      {:error, reason} -> unreadable(reason)
    end
  end

  defp readiness_view(:ready), do: %{"ready" => true, "missing" => []}

  defp readiness_view({:needs_setup, reasons}) do
    missing =
      Enum.map(
        reasons,
        &%{"requirement" => Atom.to_string(&1), "sentence" => Readiness.sentence(&1)}
      )

    %{"ready" => false, "missing" => missing}
  end

  defp summary_view(%{config: config, readiness: readiness, call: call}) do
    state = summary_state(config, readiness, call)

    %{
      "state" => state,
      "label" => Map.fetch!(@summary_labels, state),
      "sentence" => summary_sentence(state, readiness, call)
    }
  end

  defp summary_state(_config, _readiness, %{} = call), do: call_summary(call)
  defp summary_state(%Config{enabled: false}, _readiness, nil), do: "disabled"
  defp summary_state(_config, {:needs_setup, _reasons}, nil), do: "needs_setup"
  defp summary_state(_config, :ready, nil), do: "ready"

  defp call_summary(call) do
    cond do
      call.status == "dispatch_unknown" -> "placement_unknown"
      uncertain?(call) -> "termination_unconfirmed"
      stop_asked?(call) -> "stopping"
      true -> "calling"
    end
  end

  defp summary_sentence("disabled", _readiness, _call), do: @disabled_sentence
  defp summary_sentence("ready", _readiness, _call), do: @ready_sentence
  defp summary_sentence("calling", _readiness, _call), do: @calling_sentence
  defp summary_sentence("stopping", _readiness, call), do: Report.view(call).headline

  defp summary_sentence("needs_setup", {:needs_setup, reasons}, _call),
    do: Enum.map_join(reasons, " ", &Readiness.sentence/1)

  defp summary_sentence(state, _readiness, call)
       when state in ["placement_unknown", "termination_unconfirmed"] do
    view = Report.view(call)
    Enum.join(Enum.reject([view.headline, view.slot], &is_nil/1), " ")
  end

  defp engine_view, do: Map.put(@engine, "model", CarrierProfile.model())

  # -- the calls -------------------------------------------------------------------

  @doc "The owner's recent calls, newest first (at most the ledger's twenty)."
  @spec list(keyword()) :: {:ok, map()} | {:error, error()}
  def list(opts \\ []) when is_list(opts) do
    now = now(opts)

    case Ledger.list_recent(owner_id(opts), ledger_opts(opts)) do
      {:ok, rows} -> {:ok, %{"calls" => Enum.map(rows, &call_view(&1, now))}}
      {:error, :disabled} -> memory_off()
      {:error, reason} -> unreadable(reason)
    end
  end

  # How a call is said is `PhoneCalls.Report`'s, so the apps say a call in the
  # words its report says it.
  defp call_view(row, now) do
    view = Report.view(row, now)

    %{
      "call_id" => view.id,
      "state" => view.state,
      "placed" => Atom.to_string(view.placed),
      "contact_name" => view.contact_name,
      "destination_kind" => view.destination_kind,
      "outcome" => view.outcome,
      "outcome_sentence" => view.outcome_sentence,
      "uncertain" => view.uncertain?,
      "holds_slot" => view.holds_slot?,
      "sentence" => view.headline,
      "label" => view.label,
      "slot" => view.slot,
      "usage" => usage_view(view.usage),
      "why_stopped" => view.why_stopped,
      "failure_reason" => view.failure_reason,
      "vendor_message" => view.provider_words,
      "report" => view.report,
      "created_at" => iso(view.created_at),
      "ended_at" => iso(view.ended_at)
    }
  end

  # The three costs apart (M94 §10), each `nil` for a call never placed.
  defp usage_view(usage) do
    %{
      "voice_seconds" => usage.seconds,
      "voice_state" => usage.state,
      "voice" => usage.voice,
      "carrier" => usage.carrier,
      "backend_turns" => usage.turns,
      "backend_tokens" => usage.tokens,
      "backend" => usage.backend
    }
  end

  # -- recovery ----------------------------------------------------------------------

  @doc """
  Every unresolved call of the owner's: uncertain, and still holding the slot
  (`PhoneCalls.Ledger.unresolved/2`), with what the owner can do meanwhile.
  """
  @spec recovery(keyword()) :: {:ok, map()} | {:error, error()}
  def recovery(opts \\ []) when is_list(opts) do
    owner = owner_id(opts)

    case Ledger.unresolved(now(opts), ledger_opts(opts)) do
      {:ok, rows} ->
        {:ok,
         %{"calls" => for(row <- rows, row.owner_id == owner, do: recovery_view(row, now(opts)))}}

      {:error, :disabled} ->
        memory_off()

      {:error, reason} ->
        unreadable(reason)
    end
  end

  defp recovery_view(row, now) do
    view = Report.view(row, now)

    %{
      "call_id" => row.id,
      "state" => row.status,
      "attempted_at" => iso(row.dispatch_claimed_at || row.created_at),
      "destination" => view.destination,
      "contact_name" => view.contact_name,
      "provider_session_id" => row.provider_session_id,
      "carrier_call_id" => row.carrier_call_id,
      "slot_release_at" => iso(row.slot_expires_at),
      "sentence" => view.headline,
      "release" => view.slot,
      "containment" => @containment
    }
  end

  @doc """
  The owner's word that an unresolved call has ended, which they checked in
  their Telnyx portal, through the call manager that owns the slot
  (`PhoneCalls.Manager.confirm_ended/4`): its slot is released with the
  reason `owner_confirmed` at `now`, the manager's published slot fact is
  read again, and the outcome already recorded is unchanged. Only a call whose termination
  is unconfirmed and that still holds the slot: never one in progress, never
  one already over. If the owner is wrong, a second call can be placed while
  the first is still up, and the carrier's one-channel limit bounds it. An
  owner's action alone: no tool reaches it.
  """
  @spec confirm_ended(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def confirm_ended(call_id, opts \\ []) when is_binary(call_id) and is_list(opts) do
    now = now(opts)
    owner = owner_id(opts)

    case manager_call(opts, &Manager.confirm_ended(call_id, owner, now, &1)) do
      {:ok, {:ok, released}} ->
        {:ok, %{"sentence" => @confirmed_sentence, "call" => call_view(released, now)}}

      {:ok, {:error, reason}} ->
        confirm_refused(call_id, reason)

      :not_running ->
        {:error, {:unavailable, @capability, @confirm_not_running_sentence}}

      {:error, sentence} ->
        {:error, {:unavailable, @capability, sentence}}
    end
  end

  defp confirm_refused(_call_id, :not_found),
    do: {:error, {:invalid_params, "call_id", @not_found_sentence}}

  defp confirm_refused(_call_id, :in_progress),
    do: {:error, {:unavailable, @capability, @in_progress_sentence}}

  defp confirm_refused(_call_id, {:not_releasable, _status}),
    do: {:error, {:unavailable, @capability, @nothing_to_confirm_sentence}}

  defp confirm_refused(_call_id, :disabled), do: memory_off()

  defp confirm_refused(_call_id, :owned_by_running_engine), do: owned_elsewhere(:confirm)

  defp confirm_refused(call_id, reason) do
    Logger.error(
      "management phone calls: #{call_id} could not be released: #{Redaction.format(reason)}"
    )

    {:error, {:unavailable, @capability, @not_recorded_sentence}}
  end

  # -- stop ------------------------------------------------------------------------

  @doc """
  The owner's stop of `call_id`: a call not yet dialed ends at once with
  nothing dialed (`stop: cancelled`); one dialed is asked to end
  (`stop: stopping`). Answers the call as it now reads, in the stop's one
  set of sentences (`PhoneCalls.Report.stop_sentence/2`,
  `PhoneCalls.Report.stop_refusal/2`), the ones the `phone_call` tool says.
  """
  @spec stop(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def stop(call_id, opts \\ []) when is_binary(call_id) and is_list(opts) do
    with {:ok, row} <- owner_call(call_id, opts),
         :ok <- stoppable(row, opts),
         {:ok, stopped} <- cancel(row, opts),
         {:ok, now_row} <- owner_call(call_id, opts) do
      {:ok,
       %{
         "stop" => Atom.to_string(stopped),
         "sentence" => Report.stop_sentence(stopped, now_row),
         "call" => call_view(now_row, now(opts))
       }}
    end
  end

  defp owner_call(call_id, opts) do
    case Ledger.get_for_owner(call_id, owner_id(opts), ledger_opts(opts)) do
      {:ok, row} -> {:ok, row}
      {:error, :not_found} -> {:error, {:invalid_params, "call_id", @not_found_sentence}}
      {:error, :disabled} -> memory_off()
      {:error, reason} -> unreadable(reason)
    end
  end

  defp stoppable(row, opts) do
    case Report.stop_refusal(row, now(opts)) do
      nil -> :ok
      sentence -> {:error, {:unavailable, @capability, sentence}}
    end
  end

  defp cancel(row, opts) do
    case manager_call(opts, &Manager.cancel(row.id, row.owner_id, &1)) do
      {:ok, {:ok, stopped}} when stopped in [:cancelled, :stopping] -> {:ok, stopped}
      {:ok, {:error, :already_terminal}} -> ended_meanwhile(row.id, opts)
      {:ok, {:error, :owned_by_running_engine}} -> owned_elsewhere(:stop)
      {:ok, {:error, reason}} -> cancel_failed(row.id, reason)
      :not_running -> {:error, {:unavailable, @capability, @not_running_sentence}}
      {:error, sentence} -> {:error, {:unavailable, @capability, sentence}}
    end
  end

  # The call ended between the read and the stop: said as its row now reads.
  defp ended_meanwhile(call_id, opts) do
    with {:ok, row} <- owner_call(call_id, opts) do
      case stoppable(row, opts) do
        :ok -> unreadable({:in_progress_after_terminal, call_id})
        refusal -> refusal
      end
    end
  end

  # This process is not the home's running engine, which owns the call.
  defp owned_elsewhere(what),
    do: {:error, {:unavailable, @capability, Report.owned_elsewhere(what)}}

  defp cancel_failed(call_id, reason) do
    Logger.error(
      "management phone calls: the stop of #{call_id} was refused: #{Redaction.format(reason)}"
    )

    {:error, {:unavailable, @capability, @manager_unreachable_sentence}}
  end

  # -- the off switch ------------------------------------------------------------------

  @doc """
  The runtime half of the off switch, run once the section's write has landed:
  off closes admission, ends the work that has not dialed and asks a live call
  to end (`PhoneCalls.Manager.disable/1`); on reopens admission and nothing
  else (`enable/1`), so an unresolved call keeps its slot and nothing is
  redialed. Answers what the owner did not type, in their words. Where no call
  manager runs, no call is in progress, and there is nothing to say.
  """
  @spec apply_enabled(boolean(), keyword()) :: [String.t()]
  def apply_enabled(on?, opts \\ [])

  def apply_enabled(false, opts) when is_list(opts) do
    case manager_call(opts, &Manager.disable/1) do
      {:ok, %{} = stopped} -> stopped_sentences(stopped)
      :not_running -> []
      {:error, sentence} -> [sentence]
    end
  end

  def apply_enabled(true, opts) when is_list(opts) do
    case manager_call(opts, &Manager.enable/1) do
      {:ok, :ok} -> unresolved_sentences(opts)
      :not_running -> unresolved_sentences(opts)
      {:error, sentence} -> [sentence]
    end
  end

  # What the switch stopped here, and the calls the running engine still owns
  # when this process is not it (`running_engine`).
  defp stopped_sentences(%{cancelled: cancelled, stopping: stopping} = stopped) do
    running = Map.get(stopped, :running_engine, 0)

    Enum.flat_map(
      [{cancelled, @undispatched_stopped_sentence}, {stopping, @live_stopped_sentence}],
      fn {n, sentence} -> if n > 0, do: [sentence], else: [] end
    ) ++ if(running > 0, do: [Report.running_engine_calls(running)], else: [])
  end

  # Turning phone calls on is no evidence that an earlier call ended.
  defp unresolved_sentences(opts) do
    case recovery(opts) do
      {:ok, %{"calls" => []}} -> []
      {:ok, %{"calls" => [_ | _]}} -> [@unresolved_sentence]
      {:error, {:unavailable, @capability, sentence}} -> [sentence]
    end
  end

  # -- credentials -------------------------------------------------------------------

  @doc """
  Whether `secret.set` may store `value` for `key`: a trunk password is held
  to the provider's bounds, and every other value is `:ok`. Whether a change
  of a credential a call is reading may happen now is the writer's rule
  (`PhoneCalls.CallHold`, enforced in `Setup.Wizard`), not this one's.
  """
  @spec check_secret_value(atom(), String.t()) :: :ok | {:error, error()}
  def check_secret_value(:phone_calls_sip_password, value) when is_binary(value) do
    case Config.validate(sip_password: value) do
      {:ok, _config} -> :ok
      {:error, [{:sip_password, reason} | _rest]} -> password_refusal(reason)
    end
  end

  def check_secret_value(key, value) when is_atom(key) and is_binary(value), do: :ok

  defp password_refusal(reason),
    do: {:error, {:invalid_params, "value", password_sentence(reason)}}

  @doc """
  The owner's sentence for a trunk password `PhoneCalls.Config.validate/1`
  refuses: `:too_long`, `:control_characters` or `:invalid_utf8`.
  """
  @spec password_sentence(atom()) :: String.t()
  def password_sentence(reason) when is_map_key(@password_sentences, reason),
    do: Map.fetch!(@password_sentences, reason)

  @doc """
  Whether the owner's restart may run now (`lifecycle.prepare_restart`, which
  `fermix restart` takes, and the setup page's Restart; the apps' restart to
  apply takes `lifecycle.prepare`, so it is not asked yet): `:ok`, or this
  family's refusal while a phone call is in progress,
  since the restart would hang it up with no outcome read
  (`PhoneCalls.CallHold.check_restart/1`). A stop that is not the owner's
  restart (an update, a move, the service manager) is not asked.
  """
  @spec check_restart(keyword()) :: :ok | {:error, :unavailable, map()}
  def check_restart(opts \\ []) when is_list(opts) do
    case CallHold.check_restart(opts) do
      :ok ->
        :ok

      {:error, {:restart_held, sentence}} ->
        answer({:error, {:unavailable, @capability, sentence}})
    end
  end

  @doc "The capability every refusal of this family names."
  @spec capability() :: String.t()
  def capability, do: @capability

  @doc "Every sentence this module publishes, for the copy gate."
  @spec sentences() :: [String.t()]
  def sentences do
    Map.values(@summary_labels) ++
      [
        @disabled_sentence,
        @ready_sentence,
        @calling_sentence,
        @not_found_sentence,
        @not_running_sentence,
        @manager_unreachable_sentence,
        @unreadable_sentence,
        @undispatched_stopped_sentence,
        @live_stopped_sentence,
        @unresolved_sentence,
        @confirmed_sentence,
        @in_progress_sentence,
        @nothing_to_confirm_sentence,
        @not_recorded_sentence,
        @confirm_not_running_sentence
      ] ++
      @containment ++
      Report.sentences() ++
      CallHold.sentences() ++
      Map.values(@password_sentences) ++
      Enum.map(Readiness.reasons(), &Readiness.sentence/1)
  end

  # -- helpers -------------------------------------------------------------------------

  # The call manager, where it runs. One that exits under the call is said, and
  # logged with what it answered.
  defp manager_call(opts, fun) do
    server = Keyword.get(opts, :manager, Manager)

    case GenServer.whereis(server) do
      nil -> :not_running
      _pid -> {:ok, fun.(server)}
    end
  catch
    :exit, reason ->
      Logger.error("management phone calls: the call manager exited: #{Redaction.format(reason)}")
      {:error, @manager_unreachable_sentence}
  end

  defp answer({:ok, view}), do: {:ok, view}

  defp answer({:error, {:unavailable, capability, sentence}}),
    do: {:error, :unavailable, %{"capability" => capability, "sentence" => sentence}}

  defp answer({:error, {:invalid_params, field, sentence}}),
    do: {:error, :invalid_params, %{"field" => field, "sentence" => sentence}}

  defp only(params, allowed) do
    case Enum.find(Map.keys(params), &(&1 not in allowed)) do
      nil -> :ok
      field -> {:error, :invalid_params, %{"field" => field}}
    end
  end

  defp call_id_param(%{"call_id" => call_id}) do
    if Ledger.call_id?(call_id),
      do: {:ok, call_id},
      else: {:error, :invalid_params, %{"field" => "call_id", "sentence" => @not_found_sentence}}
  end

  defp call_id_param(_params), do: {:error, :invalid_params, %{"field" => "call_id"}}

  defp memory_off,
    do: {:error, {:unavailable, @capability, Readiness.sentence(:durable_memory_off)}}

  defp unreadable(reason) do
    Logger.error(
      "management phone calls: the call records could not be read: #{Redaction.format(reason)}"
    )

    {:error, {:unavailable, @capability, @unreadable_sentence}}
  end

  defp uncertain?(row), do: row.status in PhoneCallsSql.uncertain_statuses()
  defp stop_asked?(row), do: not is_nil(Map.get(row, :cancel_requested_at))

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(nil), do: nil

  defp ledger_opts(opts), do: [server: Keyword.get(opts, :repo, Repo), on_timeout: :error]
  defp owner_id(opts), do: Keyword.get_lazy(opts, :owner_id, fn -> MemoryConfig.owner_id() end)
  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
end
