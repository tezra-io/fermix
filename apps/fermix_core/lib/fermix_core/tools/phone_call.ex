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
    * a `start` in a turn that read outside content, what a called party said
      in an earlier call's `status` included, waits for the owner's own
      confirmation of the brief before it runs at all
      (`Capabilities.AccessGate`, which this built-in opts into as an effect
      outside the machine, `external_effect?`; see `Capabilities.Builtin`).
      What the owner reads is `confirmation/2`, the whole brief rendered here;
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

  alias FermixCore.Agents.RequestIdentity
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.BriefText
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Delivery
  alias FermixCore.PhoneCalls.Grants
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.PhoneCalls.Manager
  alias FermixCore.PhoneCalls.Prompt
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

  # The brief's own fields and bounds (`PhoneCalls.Brief`, `Brief.bounds/0`),
  # one property each; `Brief.new/2` is still the authority, so a value past a
  # byte bound the model cannot count is refused there by name.
  defp brief_schema do
    b = Brief.bounds()

    %{
      type: "object",
      additionalProperties: false,
      description:
        "For start: the whole mandate, which the call may not go beyond. Times are absolute " <>
          "and local to the brief's timezone.",
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
            "The name the assistant may say it is calling for, as the person called should " <>
              "hear it. Leave it out to name no one.",
            b.on_behalf_of_bytes
          ),
        timezone: text("The destination's IANA time zone.", b.timezone_bytes),
        goal: text("The concrete task, with absolute dates and times.", b.goal_bytes),
        completion_criteria:
          list(
            "What the person called must confirm for the task to be done.",
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

  # --- the owner's confirmation (`Capabilities.AccessGate`, `external_effect?`) ---

  @confirm_head "It places a phone call for you, from your number, made by Fermix as your AI " <>
                  "assistant."
  @confirm_promise "Once you confirm, Fermix places exactly this call."
  @too_long "phone_call was not run: its brief is too long to show the owner whole in one " <>
              "confirmation. Write a shorter brief (its goal, lists and facts) and start the " <>
              "call again."

  @impl true
  @spec effect() :: String.t()
  def effect, do: "places a phone call"

  @impl true
  @spec effect_call?(map()) :: boolean()
  def effect_call?(args) when is_map(args), do: Map.get(args, "action") == "start"

  @impl true
  @spec effect_name() :: String.t()
  def effect_name, do: "a phone call"

  @doc """
  What the owner reads once a `start` they confirmed has run, from the start's
  own answer: the call accepted, its id, that it is being placed and that its
  result follows in the chat that asked for it (or, for a request that had
  already started it, that no second call was placed). A start refused after
  the confirmation (the one call slot taken meanwhile, calls switched off)
  answers with the refusal's own sentence.
  """
  @impl true
  @spec confirmed(Tool.tool_result()) :: {:ok, String.t()} | {:error, String.t()}
  def confirmed(%{success: false, error: error}) when is_binary(error), do: {:error, error}

  def confirmed(%{success: true, output: output}) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, %{"call_id" => id, "status" => "accepted", "reused" => false}} when is_binary(id) ->
        {:ok,
         "The call was accepted as #{id}, and Fermix is placing it now. Its result will " <>
           "follow in the chat that asked for it."}

      {:ok, %{"call_id" => id, "status" => "accepted", "reused" => true}} when is_binary(id) ->
        {:ok, "This request had already started call #{id}; no second call was placed."}

      _unreadable ->
        {:error, "The call's start answered in a way Fermix cannot read; ask for its status."}
    end
  end

  @doc """
  What the owner reads before a `start` goes ahead (`Capabilities.AccessGate`):
  the whole brief, as a person would want to read it before a call is placed
  in their name. The number dialed and who it is, where the number came from,
  the number it is placed from, the name it calls for, the task, what must be
  confirmed, the times spelled out, the alternatives it may accept, what it
  must not agree to, the facts it may share, the lookups it may use and the
  language it opens in. Every value of the brief is quoted as its own rendering
  quotes it (`PhoneCalls.BriefText.quoted/1`), so it reads as data, and the
  gate keeps each on a line of its own. When phone calls are off or need setup,
  or the brief is not usable, there is nothing to confirm, and the sentence the
  start itself would answer says why.
  """
  @impl true
  @spec confirmation(map(), Tool.context()) :: {:ok, Tool.confirmation()} | {:error, String.t()}
  def confirmation(args, context) when is_map(args) and is_map(context) do
    with :ok <- ready(context),
         {:ok, brief} <- build_brief(args, context) do
      {:ok,
       %{
         head: @confirm_head,
         lines: confirmation_lines(brief),
         promise: @confirm_promise,
         too_long: @too_long
       }}
    else
      {:error, reason} -> {:error, sentence(reason)}
    end
  end

  defp confirmation_lines(%Brief{} = brief) do
    [
      {"Calls", "#{brief.destination}, #{quoted(brief.contact_name)}, #{kind_words(brief)}"},
      {"Number found", quoted(brief.number_source)},
      {"From", "#{brief.caller_number}, your number"},
      {"Calling for", calling_for(brief.on_behalf_of)},
      {"Task", quoted(brief.goal)},
      {"Must be confirmed", Enum.map(brief.completion_criteria, &quoted/1)},
      {"Times, in #{brief.timezone}", Enum.map(brief.times, &time_words/1)},
      {"Alternatives it may accept", Enum.map(brief.alternatives, &quoted/1)},
      {"Must not agree to", Enum.map(brief.must_not_commit, &quoted/1)},
      {"Facts it may share", Enum.map(brief.shareable_facts, &fact_words/1)},
      {"Lookups it may use", lookup_words(brief.tool_grants)},
      {"Opens in", brief.opening_language}
    ]
  end

  defp quoted(value), do: BriefText.quoted(value)

  defp kind_words(%Brief{destination_kind: :business}), do: "a business"
  defp kind_words(%Brief{destination_kind: :owner}), do: "your own phone"

  defp calling_for(nil), do: "nobody named"
  defp calling_for(name) when is_binary(name), do: quoted(name)

  defp time_words(%{label: label, at: at}), do: "#{quoted(label)}: #{BriefText.spelled(at)}"
  defp fact_words(%{label: label, value: value}), do: "#{quoted(label)}: #{quoted(value)}"

  defp lookup_words([]), do: "none"
  defp lookup_words(grants), do: Enum.join(grants, ", ")

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
    with :ok <- ready(context),
         {:ok, brief} <- build_brief(args, context),
         {:ok, snapshot} <-
           Delivery.snapshot(context, AccessGate.voice_turn?(context), snapshot_opts(context)),
         {:ok, ids} <- request_ids(context),
         {:ok, started} <-
           Manager.start_call(request(brief, snapshot, ids, context), manager(context)) do
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
  defp sentence(:already_terminal), do: "That call has already ended."
  defp sentence(reason), do: "The phone call failed: #{inspect(reason)}"

  defp prompt_part(:input), do: "text"
  defp prompt_part(:instructions), do: "instructions, which name the tools it grants,"

  defp problems_text(problems),
    do: Enum.map_join(problems, "; ", fn {field, why} -> "#{field}: #{why}" end)
end
