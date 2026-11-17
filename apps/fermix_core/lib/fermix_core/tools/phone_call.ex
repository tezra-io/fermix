defmodule FermixCore.Tools.PhoneCall do
  @moduledoc """
  `phone_call` (M94 §06): start one outbound phone call, check one, or stop
  one. One tool, three actions; one `[:fermix, :tool, :exec]` event per model
  call under this name, refusals included.

  The barrier is at execute time, never `advertise?/1`:

    * every action runs only on the owner's attended, top-level turn
      (`Capabilities.AccessGate.check_attended/2`, the one rule: not a guest,
      a delegated worker, a scheduled or cue run, an unattended run, or a
      follow-up turn such as a finished call's own report);
    * a `start` in a turn that read outside content waits for the owner's own
      confirmation of the exact brief before it runs at all
      (`Capabilities.AccessGate`, which this built-in opts into as an
      unconfined host command, decided only for `start`; see
      `Capabilities.Builtin`);
    * the authorization evidence the Manager records is the server's own: the
      requesting turn's session id (`:session_id`), the principal
      (`:memory_owner_id`), the operation, the hash of the brief built here
      and whether the owner confirmed it (`:access_gate`, `:access_intent`).
      Nothing the model writes is taken as proof, and a brief carrying a
      server-owned field (an approval, a caller number, a credential) is
      refused by `PhoneCalls.Brief`.

  A refused brief (a private individual, outside the US, incomplete) and every
  admission refusal dial nothing and use no attempt, and say why. `start`
  answers once the call is accepted here, never once it is answered: the
  result comes back on its own, into the conversation for a chat turn and to
  the owner's private inbox for a voice turn.

  `advertise?/1` shows the tool on the owner's attended turn while phone calls
  are on, and, while they are off, only when the owner has a call from the
  last attempt window to check or stop; `dynamic_parameters/1` then offers
  `status` and `cancel` alone. Seams (tests): `:phone_call_manager`,
  `:phone_call_readiness`, `:phone_call_config`, `:phone_call_now`,
  `:phone_call_snapshot_opts`, `:memory_repo`.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  require Logger

  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Delivery
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.PhoneCalls.Manager
  alias FermixCore.PhoneCalls.Readiness
  alias FermixCore.Temporal.Access
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @name "phone_call"
  @actions ~w(start status cancel)
  @end_turn " End your turn now; do not check its status in a loop."

  @impl true
  @spec name() :: String.t()
  def name, do: @name

  @impl true
  @spec description() :: String.t()
  def description do
    "Place one outbound phone call as the owner's AI assistant, check one, or stop one. " <>
      "Use start only when the owner asked for this call: it calls a business or the owner's " <>
      "own phone, never a private person, one call at a time. start returns once the call is " <>
      "accepted, not answered; its result comes back on its own."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["action"],
      properties: %{
        action: %{type: "string", enum: @actions, description: "start, status or cancel."},
        call_id: %{type: "string", description: "The call's id (pc_…), for status and cancel."},
        brief: brief_schema()
      }
    }
  end

  @doc "The schema the turn is offered: without `start` while phone calls are off."
  @spec dynamic_parameters(map()) :: map()
  def dynamic_parameters(context) when is_map(context) do
    if config(context).enabled, do: parameters(), else: status_parameters()
  end

  defp status_parameters do
    %{
      type: "object",
      required: ["action", "call_id"],
      properties: %{
        action: %{type: "string", enum: ["status", "cancel"], description: "status or cancel."},
        call_id: %{type: "string", description: "The call's id (pc_…)."}
      }
    }
  end

  defp brief_schema do
    text = fn description -> %{type: "string", description: description} end

    list = fn description ->
      %{type: "array", items: %{type: "string"}, description: description}
    end

    %{
      type: "object",
      description: "For start: the whole mandate, which the call may not go beyond.",
      required: ~w(destination destination_kind number_source contact_name timezone goal
                   completion_criteria),
      properties: %{
        destination: text.("The number to call, E.164 (+1 and ten digits)."),
        destination_kind: %{
          type: "string",
          enum: ["business", "owner"],
          description: "A business, or the owner's own phone."
        },
        number_source: text.("Where this number came from."),
        contact_name: text.("Who is being called."),
        timezone: text.("The destination's IANA time zone."),
        goal: text.("The concrete task, with absolute dates and times."),
        completion_criteria:
          list.("What the person called must confirm for the task to be done."),
        must_not_commit: list.("What the call must not agree to."),
        alternatives: list.("Alternatives the owner accepts."),
        shareable_facts: %{
          type: "array",
          description: "Only the owner's facts the call needs, each a label and a value.",
          items: %{
            type: "object",
            required: ["label", "value"],
            properties: %{label: %{type: "string"}, value: %{type: "string"}}
          }
        },
        tool_grants: list.("Tools the call may use to answer, by name."),
        times: %{
          type: "array",
          description: "Absolute local times at the destination: YYYY-MM-DD or YYYY-MM-DDTHH:MM.",
          items: %{
            type: "object",
            required: ["label", "at"],
            properties: %{label: %{type: "string"}, at: %{type: "string"}}
          }
        },
        opening_language: text.("The language to open in, as a language tag; English if absent.")
      }
    }
  end

  @impl true
  @spec when_to_use() :: String.t()
  def when_to_use,
    do: "When the owner asks Fermix to phone a business or their own phone for a concrete task."

  @impl true
  @spec failure_modes() :: [map()]
  def failure_modes do
    [
      %{tag: "not_attended", description: "not the owner's own attended turn"},
      %{tag: "disabled", description: "phone calls are turned off"},
      %{tag: "needs_setup", description: "a setting the call needs is missing"},
      %{tag: "refused", description: "a private person, outside the US, or a special number"},
      %{tag: "invalid_brief", description: "the brief is incomplete or malformed"},
      %{tag: "slot_held", description: "another call is still outstanding"},
      %{tag: "attempts_exhausted", description: "the day's attempts are used up"}
    ]
  end

  @impl true
  @spec requires_setup() :: nil
  def requires_setup, do: nil

  @impl true
  @spec category() :: atom()
  def category, do: :phone_call

  @doc """
  Whether a call of `arguments` relays what someone else said: a `status`
  answers what the person called said, which is outside content.
  """
  @spec relays_outside_text?(map()) :: boolean()
  def relays_outside_text?(arguments) when is_map(arguments),
    do: Map.get(arguments, "action") not in ["start", "cancel"]

  @doc """
  Shown on the owner's attended turn while phone calls are on; while they are
  off, only when the owner has a call from the last attempt window to check or
  stop. Visibility only: `execute/2` decides.
  """
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context) do
    Access.attended_operator_turn?(context) and
      (config(context).enabled or recent_call?(context))
  end

  defp recent_call?(context) do
    since = DateTime.add(now(context), -Limits.attempt_window_ms(), :millisecond)

    case Ledger.list_recent(owner(context), limit: 1, server: repo(context)) do
      {:ok, [%{created_at: created_at}]} -> DateTime.compare(created_at, since) != :lt
      {:ok, []} -> false
      {:error, :disabled} -> false
      {:error, reason} -> unreadable_ledger(reason)
    end
  end

  defp unreadable_ledger(reason) do
    Logger.warning(
      "phone_call: the call ledger could not be read to offer status: #{inspect(reason)}"
    )

    false
  end

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    started = System.monotonic_time(:millisecond)
    result = run(args, context)
    duration = System.monotonic_time(:millisecond) - started

    ToolTelemetry.exec(@name, context, match?({:ok, %{success: true}}, result), duration,
      metadata: exec_metadata(args, result),
      result: result
    )

    result
  end

  defp exec_metadata(args, {:ok, %{success: false, error: error}}),
    do: %{action: action_word(args), error: error}

  defp exec_metadata(args, _result), do: %{action: action_word(args)}

  defp action_word(args) do
    case Map.get(args, "action") do
      action when action in @actions -> action
      _other -> "invalid"
    end
  end

  defp run(args, context) do
    with :ok <- AccessGate.check_attended(@name, context),
         {:ok, action} <- fetch_action(args) do
      act(action, args, context)
    else
      {:error, reason} -> error(reason)
    end
  end

  defp fetch_action(%{"action" => action}) when action in @actions, do: {:ok, action}
  defp fetch_action(args), do: {:error, {:invalid_action, Map.get(args, "action")}}

  # --- start -------------------------------------------------------------------

  defp act("start", args, context) do
    with :ok <- ready(context),
         {:ok, brief} <- build_brief(args, context),
         {:ok, snapshot} <- Delivery.snapshot(context, voice?(context), snapshot_opts(context)),
         {:ok, request_id} <- request_id(context),
         {:ok, started} <-
           Manager.start_call(request(brief, snapshot, request_id, context), manager(context)) do
      success(accepted(started, snapshot))
    else
      {:error, reason} -> error(reason)
    end
  end

  defp act("status", args, context) do
    with {:ok, call_id} <- fetch_call_id(args),
         {:ok, view} <-
           Manager.status(call_id, owner(context), repo: repo(context), now: now(context)) do
      success(view)
    else
      {:error, reason} -> error(reason)
    end
  end

  defp act("cancel", args, context) do
    with {:ok, call_id} <- fetch_call_id(args),
         {:ok, stopped} <- Manager.cancel(call_id, owner(context), manager(context)) do
      success(stopped_map(call_id, stopped))
    else
      {:error, reason} -> error(reason)
    end
  end

  # Readiness first: the brief takes the configured caller number, which a
  # call needing setup may not have.
  defp ready(context) do
    case Map.get(context, :phone_call_readiness, &Readiness.current/0).() do
      :ready -> :ok
      :disabled -> {:error, :disabled}
      {:needs_setup, reasons} -> {:error, {:needs_setup, reasons}}
    end
  end

  defp build_brief(args, context) do
    case Map.get(args, "brief") do
      params when is_map(params) ->
        Brief.new(params, caller_number: config(context).caller_number, now: now(context))

      _absent ->
        {:error, {:invalid_brief, [{:brief, :missing}]}}
    end
  end

  defp request(brief, snapshot, request_id, context) do
    %{
      brief: brief,
      brief_hash: Brief.hash(brief),
      request_id: request_id,
      owner_id: owner(context),
      operation: "phone_call.start",
      authorization: authorization(context),
      access_intent: Map.get(context, :access_intent),
      snapshot: snapshot
    }
  end

  # The access gate labels a call it dispatched: `confirmed` when the owner
  # confirmed this exact brief, `direct` when the owner's own request was the
  # consent.
  defp authorization(%{access_gate: "confirmed"}), do: "confirmed"
  defp authorization(_context), do: "direct"

  defp request_id(context) do
    case Map.get(context, :session_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _missing -> {:error, :missing_session}
    end
  end

  # A live voice turn, as the access gate tells one: a call's own context or an
  # origin the turn runner marked as voice.
  defp voice?(context),
    do:
      is_binary(Map.get(context, :voice_call_id)) or
        Map.get(context, :computer_use_origin) == :voice

  defp accepted(started, snapshot) do
    %{
      call_id: started.call_id,
      status: "accepted",
      state: started.state,
      reused: started.reused,
      detail: accepted_detail(started.reused, snapshot.origin_kind) <> @end_turn
    }
  end

  defp accepted_detail(true, _origin),
    do: "This request already started this call; no second call was placed."

  defp accepted_detail(false, "voice"),
    do:
      "Accepted here; the call has not been answered. Its result goes to the owner's " <>
        "private inbox when it ends."

  defp accepted_detail(false, _chat),
    do:
      "Accepted here; the call has not been answered. Its result comes back into this " <>
        "conversation when it ends."

  defp stopped_map(call_id, :cancelled),
    do: %{
      call_id: call_id,
      status: "cancelled",
      detail: "Stopped before dialing; nothing was dialed."
    }

  defp stopped_map(call_id, :stopping) do
    %{
      call_id: call_id,
      status: "stopping",
      detail:
        "Fermix asked the provider to hang up. The call reads stopping until its end is " <>
          "known, and its report follows. Stopping a call does not undo anything agreed on it."
    }
  end

  defp fetch_call_id(args) do
    case Map.get(args, "call_id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      _missing -> {:error, :missing_call_id}
    end
  end

  # --- seams ---------------------------------------------------------------------

  defp config(context), do: Map.get(context, :phone_call_config, &Config.get/0).()
  defp manager(context), do: Map.get(context, :phone_call_manager, Manager)
  defp repo(context), do: Map.get(context, :memory_repo) || Repo
  defp owner(context), do: Map.get(context, :memory_owner_id) || MemoryConfig.owner_id()
  defp now(context), do: Map.get(context, :phone_call_now, &DateTime.utc_now/0).()
  defp snapshot_opts(context), do: Map.get(context, :phone_call_snapshot_opts, [])

  # --- results ---------------------------------------------------------------------

  defp success(map), do: {:ok, Tool.success(Jason.encode!(map))}
  defp error(reason), do: {:ok, Tool.error(sentence(reason))}

  @nothing " Nothing was dialed and no attempt was used."

  defp sentence(text) when is_binary(text), do: text
  defp sentence({:invalid_action, _action}), do: "action must be start, status or cancel."
  defp sentence(:disabled), do: "Phone calls are turned off in Settings, Voice." <> @nothing

  defp sentence({:needs_setup, reasons}),
    do:
      "Phone calls need setup: " <> Enum.map_join(reasons, " ", &Readiness.sentence/1) <> @nothing

  defp sentence({:refused, _reason, refusal}), do: refusal <> @nothing

  defp sentence({:invalid_brief, problems}),
    do: "The brief is not usable (#{problems_text(problems)})." <> @nothing

  defp sentence({:slot_held, holder}),
    do:
      "Another call, #{holder}, still holds the one call Fermix places at a time, until it " <>
        "is shown to have ended. Check it with status." <> @nothing

  defp sentence({:daily_attempts_exhausted, _count}),
    do:
      "The #{Limits.max_attempts_per_day()} call attempts allowed in a rolling day are used " <>
        "up." <> @nothing

  defp sentence(:no_owner_inbox),
    do:
      "A call asked for by voice reports to the owner's private chat, and none is set up." <>
        @nothing

  defp sentence(:client_owned_origin),
    do: "A call started here could not report back; ask from the owner's own chat." <> @nothing

  defp sentence({:unsupported_origin, _kind}),
    do: "A call can only be started from the owner's own chat or voice." <> @nothing

  defp sentence({:call_start_failed, _reason}),
    do: "The call could not start; nothing was dialed."

  defp sentence({:authorization_evidence, field}),
    do: "The request carries no #{field} to authorize it." <> @nothing

  defp sentence(:missing_session), do: "This turn has no session to authorize a call." <> @nothing
  defp sentence(:missing_call_id), do: "status and cancel need the call's call_id."
  defp sentence(:not_found), do: "No phone call of the owner's has that id."
  defp sentence(:already_terminal), do: "That call has already ended."
  defp sentence(reason), do: "The phone call failed: #{inspect(reason)}"

  defp problems_text(problems),
    do: Enum.map_join(problems, "; ", fn {field, why} -> "#{field}: #{why}" end)
end
