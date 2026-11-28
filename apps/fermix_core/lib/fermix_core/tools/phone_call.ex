defmodule FermixCore.Tools.PhoneCall do
  @moduledoc """
  `phone_call` (M94 §06): start one outbound phone call, check one, or stop
  one. One tool, three actions; one `[:fermix, :tool, :exec]` event per model
  call under this name, refusals included, and a Manager that exits under a
  start or a stop (a timeout, a restart, a crash) is answered as a refusal
  too, never an exit through the owner's turn.

  The barrier is at execute time, never `advertise?/1`:

    * every action runs only on the owner's attended, top-level turn
      (`Capabilities.AccessGate.check_attended/2`, the one rule: not a guest,
      a delegated worker, a scheduled or cue run, an unattended run, or a
      follow-up turn such as a finished call's own report);
    * a `start` in a turn that read outside content, what a called party said
      in an earlier call's `status` included, waits for the owner's own
      confirmation of the brief before it runs at all
      (`Capabilities.AccessGate`, which this built-in opts into as an effect
      outside the machine, `external_effect?`; see `Capabilities.Builtin`).
      What the owner reads is `confirmation/2`: the call as one question,
      then every part of the brief the call acts on or says, rendered here;
      `effect_call?/1` names `start` alone;
    * the authorization evidence the Manager records is the server's own: the
      owner request's identity (`:request_id`, `Agents.RequestIdentity`,
      minted where the turn's tools are given their context and kept through
      the gate's confirmation, so a repeated start inside one request finds
      its call and another request never does), the requesting turn's
      session (`:session_id`, the call's trace parent), the principal
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
  are on, and, while they are off, exactly while a call holds the one-call
  slot (`PhoneCalls.Manager.slot_held?/2`, never a ledger read);
  `dynamic_parameters/1` then offers `status` and `cancel` alone. Seams
  (tests): `:phone_call_manager`,
  `:phone_call_readiness`, `:phone_call_config`, `:phone_call_now`,
  `:phone_call_snapshot_opts`, `:memory_repo`.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool
  @behaviour FermixCore.Capabilities.ExternalEffect

  require Logger

  alias FermixCore.Agents.RequestIdentity
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.ExternalEffect
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.BriefText
  alias FermixCore.PhoneCalls.Call.Printable
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Delivery
  alias FermixCore.PhoneCalls.Grants
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.PhoneCalls.Manager
  alias FermixCore.PhoneCalls.Prompt
  alias FermixCore.PhoneCalls.Readiness
  alias FermixCore.PhoneCalls.Report
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

  # The brief's own fields and bounds (`PhoneCalls.Brief`, `Brief.bounds/0`),
  # one property each; `Brief.new/2` is still the authority, so a value past a
  # byte bound the model cannot count is refused there by name.
  defp brief_schema do
    b = Brief.bounds()

    %{
      type: "object",
      additionalProperties: false,
      description:
        "For start: the whole mandate, which the call may not go beyond: every fact the call " <>
          "needs, each in the field that owns it, and no script. Times are absolute and local " <>
          "to the brief's timezone.",
      required: ~w(destination destination_kind number_source contact_name timezone goal
                   completion_criteria),
      properties: %{
        destination: text("The number to call, E.164 (+1 and ten digits)."),
        destination_kind: %{
          type: "string",
          enum: ["business", "owner"],
          description: "A business, or the owner's own phone."
        },
        number_source: text("Where this number came from.", b.number_source_bytes),
        contact_name: text("Who is being called.", b.contact_name_bytes),
        on_behalf_of:
          text(
            "The name the call gives when it says whom it is calling for, as the person called " <>
              "should hear it. Without it the call names no one, so the name goes here, never " <>
              "in the goal.",
            b.on_behalf_of_bytes
          ),
        timezone: text("The destination's IANA time zone.", b.timezone_bytes),
        goal:
          text(
            "The result the owner wants from the call, with everything it must find out or " <>
              "arrange and absolute dates and times: what to achieve, never what to say or in " <>
              "what order. The call's own instructions greet, say it is an AI assistant and " <>
              "whom it calls for, check it reached the right party, and say goodbye; none of " <>
              "that belongs here.",
            b.goal_bytes
          ),
        completion_criteria:
          list(
            "Facts the person called must state or confirm for the result to count, one fact " <>
              "per item: never a step, an instruction to the call or its report, or how to " <>
              "record an answer.",
            1,
            b.completion_criteria,
            b.item_bytes
          ),
        must_not_commit: list("What the call must not agree to.", 0, b.list_items, b.item_bytes),
        alternatives: list("Alternatives the owner accepts.", 0, b.list_items, b.item_bytes),
        shareable_facts:
          pairs(
            "Only the owner's facts the call needs, each a label and a value.",
            b.shareable_facts,
            value: text("The fact.", b.fact_value_bytes),
            label: b.label_bytes
          ),
        tool_grants: %{
          type: "array",
          maxItems: b.tool_grants,
          items: %{type: "string"},
          description: "Tools the call may use to answer, each by its name."
        },
        times:
          pairs(
            "Each time the task names, local to the brief's timezone: YYYY-MM-DD or " <>
              "YYYY-MM-DDTHH:MM, with no offset, and not already past.",
            b.times,
            at: text("The date or local time."),
            label: b.label_bytes
          ),
        opening_language:
          text("The language to open in, as a language tag; English if absent.", b.language_bytes)
      }
    }
  end

  defp text(description), do: %{type: "string", description: description}

  defp text(description, max_length),
    do: %{type: "string", description: description, maxLength: max_length}

  defp list(description, min_items, max_items, item_length) do
    %{
      type: "array",
      minItems: min_items,
      maxItems: max_items,
      items: %{type: "string", maxLength: item_length},
      description: description
    }
  end

  # A list of `%{label, <field>}` objects, as the brief's facts and times are.
  defp pairs(description, max_items, [{field, field_schema}, label: label_length]) do
    %{
      type: "array",
      maxItems: max_items,
      description: description,
      items: %{
        type: "object",
        additionalProperties: false,
        required: ["label", Atom.to_string(field)],
        properties: %{:label => %{type: "string", maxLength: label_length}, field => field_schema}
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

  # --- the owner's confirmation (`Capabilities.AccessGate`, `ExternalEffect`) ---

  # The opening language a brief carries when it names none (`Brief`'s
  # default): the one the card does not name.
  @usual_language "en"
  @confirm_promise "Once you confirm, Fermix places exactly this call."

  @impl ExternalEffect
  @spec effect() :: String.t()
  def effect, do: "places a phone call"

  @impl ExternalEffect
  @spec effect_call?(map()) :: boolean()
  def effect_call?(args) when is_map(args), do: Map.get(args, "action") == "start"

  @impl ExternalEffect
  @spec effect_name() :: String.t()
  def effect_name, do: "a phone call"

  @doc """
  What a confirmed `start` reads of its turn besides the gate's own snapshot:
  the owner and their store, and the seams this tool reads (the moduledoc's).
  """
  @impl ExternalEffect
  @spec context_keys() :: [atom()]
  def context_keys do
    [
      :memory_owner_id,
      :memory_repo,
      :phone_call_manager,
      :phone_call_readiness,
      :phone_call_config,
      :phone_call_now,
      :phone_call_snapshot_opts
    ]
  end

  @doc """
  What the owner reads once a `start` they confirmed has run, from the facts
  its result carries (`effect`): the call accepted, its id, that it is being
  placed and that its result follows in the chat that asked for it (or, for a
  request that had already started it, that no second call was placed). A
  start refused after the confirmation (the one call slot taken meanwhile,
  calls switched off) answers with the refusal's own sentence.
  """
  @impl ExternalEffect
  @spec confirmed(Tool.tool_result()) :: {:ok, String.t()} | {:error, String.t()}
  def confirmed(%{success: false, error: error}) when is_binary(error), do: {:error, error}

  def confirmed(%{success: true, effect: %{call_id: id, reused: false}}) when is_binary(id) do
    {:ok,
     "The call was accepted as #{id}, and Fermix is placing it now. Its result will " <>
       "follow in the chat that asked for it."}
  end

  def confirmed(%{success: true, effect: %{call_id: id, reused: true}}) when is_binary(id),
    do: {:ok, "This request had already started call #{id}; no second call was placed."}

  @doc """
  What the owner reads before a `start` goes ahead (`Capabilities.AccessGate`),
  short, and their defence against a request someone else wrote. It opens with
  the call as one question: whom it calls, a business or their own phone, at
  which number, and for whom when the brief names someone. Then every part of
  the brief the call acts on or says: where the number came from, the task,
  what must be confirmed, the times with their zone (the zone alone when it
  names no time), the alternatives it may accept, what it must not agree to,
  the facts it may share, the lookups it may use, and an opening language
  other than `@usual_language`. A part is left out only when it is empty (an
  empty list, which the gate shows as no row) or the same on every call (the
  owner's own caller number); no part is summarized, and nothing here is a
  model's words but the brief's own values. Every value is quoted as the
  brief's own rendering quotes it (`PhoneCalls.BriefText.quoted/1`), so it
  reads as data, and the gate keeps each on a line of its own. A start its admission would certainly
  refuse (`admissible/2`: calls off or needing setup, an unusable brief, a
  report with nowhere to go, no request identity, a grant a call cannot use, a
  prompt too large for the call) has nothing to confirm: it answers the
  sentence the start itself would, and the owner is never asked.
  """
  @impl ExternalEffect
  @spec confirmation(map(), Tool.context()) ::
          {:ok, ExternalEffect.confirmation()} | {:error, String.t()}
  def confirmation(args, context) when is_map(args) and is_map(context) do
    case admissible(args, context) do
      {:ok, %{brief: brief}} ->
        {:ok,
         %{head: question(brief), lines: confirmation_lines(brief), promise: @confirm_promise}}

      {:error, reason} ->
        {:error, sentence(reason)}
    end
  end

  # The call as the question the owner answers: whom, as what, at which
  # number, and for whom when the brief names someone.
  defp question(%Brief{} = brief) do
    "Call #{quoted(brief.contact_name)} (#{kind_words(brief)}) at #{brief.destination}" <>
      for_whom(brief.on_behalf_of) <> "?"
  end

  # Every part the call acts on or says. An optional part is a list, so an
  # empty one is no row (`Capabilities.AccessGate`); the caller number, the
  # owner's own on every call, is never one.
  defp confirmation_lines(%Brief{} = brief) do
    [
      {"Number found", quoted(brief.number_source)},
      {"Task", quoted(brief.goal)},
      {"Must be confirmed", Enum.map(brief.completion_criteria, &quoted/1)},
      times_line(brief),
      {"Alternatives it may accept", Enum.map(brief.alternatives, &quoted/1)},
      {"Must not agree to", Enum.map(brief.must_not_commit, &quoted/1)},
      {"Facts it may share", Enum.map(brief.shareable_facts, &fact_words/1)},
      {"Lookups it may use", brief.tool_grants},
      {"Opens in", unusual_language(brief.opening_language)}
    ]
  end

  defp quoted(value), do: BriefText.quoted(value)

  defp kind_words(%Brief{destination_kind: :business}), do: "a business"
  defp kind_words(%Brief{destination_kind: :owner}), do: "your own phone"

  defp for_whom(nil), do: ""
  defp for_whom(name) when is_binary(name), do: " for #{quoted(name)}"

  # The zone the call reads its times in, beside them, or alone when it names
  # none: it still sets the call's "today".
  defp times_line(%Brief{times: [], timezone: zone}), do: {"Time zone", zone}

  defp times_line(%Brief{times: times, timezone: zone}),
    do: {"Times, in #{zone}", Enum.map(times, &time_words/1)}

  defp time_words(%{label: label, at: at}), do: "#{quoted(label)}: #{BriefText.spelled(at)}"
  defp fact_words(%{label: label, value: value}), do: "#{quoted(label)}: #{quoted(value)}"

  defp unusual_language(@usual_language), do: []
  defp unusual_language(language) when is_binary(language), do: [language]

  @doc """
  Shown on the owner's attended turn while phone calls are on; while they are
  off, exactly while a call holds the one-call slot, as the Manager publishes
  it (`PhoneCalls.Manager.slot_held?/2`): a turn never reads the ledger to
  decide. Visibility only: `execute/2` decides.
  """
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context) do
    Access.attended_operator_turn?(context) and
      (config(context).enabled or Manager.slot_held?(now(context), manager(context)))
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
    with {:ok, %{brief: brief, snapshot: snapshot, ids: ids}} <- admissible(args, context),
         {:ok, started} <- start_call(request(brief, snapshot, ids, context), context) do
      {:ok, started_result(started, snapshot)}
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
    case fetch_call_id(args) do
      {:ok, call_id} ->
        call_id |> cancel_call(context) |> cancelled(call_id, context)

      {:error, reason} ->
        error(reason)
    end
  end

  # The Manager, asked under its bound. One that times out, restarts or
  # crashed under the call exits its caller; that is answered here, so the
  # turn goes on and its one exec event is emitted. The log names the exit by
  # its shape alone (`Call.Printable.reason/1`): the start's request carries
  # the brief, and a crash's frames carry their arguments.
  defp start_call(request, context) do
    Manager.start_call(request, manager(context))
  catch
    :exit, {reason, _call} -> manager_exited(:start, reason)
  end

  defp cancel_call(call_id, context) do
    Manager.cancel(call_id, owner(context), manager(context))
  catch
    :exit, {reason, _call} -> manager_exited(:cancel, reason)
  end

  defp manager_exited(action, reason) do
    Logger.error(
      "phone_call #{action}: the call manager exited: #{inspect(Printable.reason(reason))}"
    )

    {:error, {:manager_exited, action}}
  end

  # Everything a start's admission can already know, by the functions
  # admission itself runs, before the Manager is asked and before the owner is
  # asked to confirm one (`confirmation/2`): readiness, the brief, where its
  # report goes (`Delivery.snapshot/3`), the request's identity, the grants
  # (`Grants.resolve/1`) and the call's prompt fitting (`Prompt.render/2`). The
  # Manager checks the grants and the prompt again, as the authority; nothing
  # here writes.
  defp admissible(args, context) do
    with :ok <- ready(context),
         {:ok, brief} <- build_brief(args, context),
         {:ok, snapshot} <-
           Delivery.snapshot(context, AccessGate.voice_turn?(context), snapshot_opts(context)),
         {:ok, ids} <- request_ids(context),
         {:ok, _grantable} <- Grants.resolve(brief.tool_grants),
         {:ok, _rendered} <- Prompt.render(brief, now: now(context)) do
      {:ok, %{brief: brief, snapshot: snapshot, ids: ids}}
    end
  end

  # What a start answers: the accepted call for the model, and its facts
  # (`effect`) for the owner who confirmed it (`confirmed/1`).
  defp started_result(started, snapshot) do
    started
    |> accepted(snapshot)
    |> Jason.encode!()
    |> Tool.success()
    |> Map.put(:effect, %{call_id: started.call_id, reused: started.reused})
  end

  # What a stop says is the call's own (`PhoneCalls.Report.stop_sentence/2`,
  # `stop_refusal/2`, the sentences the apps' Stop says too), from its row as
  # it reads after the stop.
  defp cancelled({:ok, stopped}, call_id, context) do
    row =
      case owner_row(call_id, context) do
        {:ok, row} -> row
        {:error, _unread} -> nil
      end

    success(stopped_map(call_id, stopped, Report.stop_sentence(stopped, row)))
  end

  # The manager found it over: a call whose end is unresolved says so, and
  # the two ways out of it.
  defp cancelled({:error, :already_terminal}, call_id, context) do
    case owner_row(call_id, context) do
      {:ok, row} -> row |> Report.stop_refusal(now(context)) |> refused()
      {:error, reason} -> error(reason)
    end
  end

  defp cancelled({:error, reason}, _call_id, _context), do: error(reason)

  # A row the manager found over always has a refusal: none would be a call
  # not over, which it is not.
  defp refused(refusal) when is_binary(refusal), do: error(refusal)

  defp owner_row(call_id, context),
    do: Ledger.get_for_owner(call_id, owner(context), server: repo(context), on_timeout: :error)

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

  defp request(brief, snapshot, {request_id, session_id}, context) do
    %{
      brief: brief,
      brief_hash: Brief.hash(brief),
      request_id: request_id,
      parent_session: session_id,
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

  # Both server-owned: the request identity only as `Agents.RequestIdentity`
  # mints it, so a session id can never stand in for one.
  defp request_ids(context) do
    request_id = Map.get(context, :request_id)
    session_id = Map.get(context, :session_id)

    cond do
      not RequestIdentity.valid?(request_id) -> {:error, :missing_request}
      not (is_binary(session_id) and session_id != "") -> {:error, :missing_session}
      true -> {:ok, {request_id, session_id}}
    end
  end

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

  defp stopped_map(call_id, stopped, sentence),
    do: %{call_id: call_id, status: Atom.to_string(stopped), detail: sentence}

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

  defp sentence(:disabled),
    do: "Phone calls are turned off in Settings, Phone calls." <> @nothing

  defp sentence(:engine_stopping),
    do: "Fermix is stopping, so no call can start now; ask again once it is back." <> @nothing

  defp sentence({:needs_setup, reasons}),
    do:
      "Phone calls need setup: " <> Enum.map_join(reasons, " ", &Readiness.sentence/1) <> @nothing

  defp sentence({:refused, _reason, refusal}), do: refusal <> @nothing

  defp sentence({:invalid_brief, problems}),
    do: "The brief is not usable (#{problems_text(problems)})." <> @nothing

  defp sentence({:tools_not_grantable, rejected}),
    do:
      "The brief grants tools a phone call cannot use (#{problems_text(rejected)}); a call " <>
        "may use only #{Enum.join(Grants.grantable(), " and ")}, and its keypad and hang-up " <>
        "come with every call." <> @nothing

  defp sentence({:slot_held, holder}),
    do:
      "Another call, #{holder}, holds the one call Fermix places at a time until it ends, " <>
        "or, if its termination is unconfirmed, until the owner confirms it ended or " <>
        "OpenAI's own limit on a call passes. Check it with status." <> @nothing

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

  defp sentence({:prompt_too_large, part, bytes}),
    do:
      "The brief is too long to give the call whole: its #{prompt_part(part)} would be " <>
        "#{bytes} bytes, past the #{Map.fetch!(Prompt.bounds(), part)} the voice model takes. " <>
        "Shorten it and ask again." <> @nothing

  defp sentence({:call_start_failed, _reason}),
    do: "The call could not start; nothing was dialed."

  # Whether the Manager admitted the call before it exited is not known, so
  # this says nothing about dialing. Asking again finds this request's own
  # call, and the one call slot refuses any other while it runs.
  defp sentence({:manager_exited, :start}),
    do:
      "The part of Fermix that places calls did not answer, so whether this call was " <>
        "accepted is not known. Asking again is safe: it finds a call this request already " <>
        "started instead of placing a second."

  defp sentence({:manager_exited, :cancel}),
    do:
      "The part of Fermix that places calls did not answer, so the call may not have been " <>
        "stopped. Check it with status, and ask again to stop it."

  defp sentence({:authorization_evidence, field}),
    do: "The request carries no #{field} to authorize it." <> @nothing

  defp sentence(:missing_session), do: "This turn has no session to authorize a call." <> @nothing

  defp sentence(:missing_request),
    do: "This turn carries no request identity to authorize a call." <> @nothing

  defp sentence(:timeout),
    do:
      "The call ledger did not answer in time, so nothing changed: no call was dialed, " <>
        "stopped or charged an attempt. Ask again in a moment."

  defp sentence(:missing_call_id), do: "status and cancel need the call's call_id."
  defp sentence(:not_found), do: "No phone call of the owner's has that id."
  defp sentence(reason), do: "The phone call failed: #{inspect(reason)}"

  defp prompt_part(:input), do: "text"
  defp prompt_part(:instructions), do: "instructions, which name the tools it grants,"

  defp problems_text(problems),
    do: Enum.map_join(problems, "; ", fn {field, why} -> "#{field}: #{why}" end)
end
