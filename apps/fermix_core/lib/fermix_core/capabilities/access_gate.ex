defmodule FermixCore.Capabilities.AccessGate do
  @moduledoc """
  The one decision about whether an access-sensitive plugin command may run now.

  A plugin manifest marks a changing tool `"access_sensitive": true` (a car
  unlock); the flag reaches the capability as `metadata.access_sensitive?` on
  both plugin rails. `Capability.execute/3` — the single invoke boundary for the
  agent loop, the realtime voice bridge and inbound MCP — asks `admit/3` first,
  and every other capability returns on that one map lookup.

  For a flagged call, in order:

    1. a delegated worker (`subagent_depth` or `skill_depth` above zero) is
       refused: no owner is in that loop;
    2. an operator scheduled run dispatches only when its job row names the tool
       (`Harness.Authorization`'s job-row allowlist, the owner's consent given
       when they set the job up);
    3. anything that is not an attended owner turn
       (`Temporal.Access.attended_operator_turn?/1`) is refused;
    4. a turn that read content someone else could have written
       (`:outside_sources`, folded by the agent loop from
       `UntrustedContent.outside_source/1`, minus the target plugin's own reads),
       or any turn from a shared Buzz channel (`Acp.Identity.multi_principal?/1`:
       other people can post there, so the request is not proof the owner asked),
       parks the exact call and asks the owner once, on the surface the turn has
       (for ACP, the owner's own chat, never the channel itself);
    5. otherwise the owner's direct request is the consent, and it runs.

  A parked call is confirmed only by the owner — `/confirm` (a tap or an app
  card) on their chat, the gateway's owner-inbox delivery, or a spoken yes the
  voice session binds to the daemon's record — and `confirm/2` then runs exactly
  the recorded call. The model never sees the token and never supplies the
  confirmation. Whether a prompt is still live is the channel confirmations
  store's answer (it dedupes per origin), so a call parked again after a `/deny`
  or an expired token prompts afresh against the same record.

  Once a turn's call is parked, that turn may run nothing else while the owner
  decides: the held result carries `access_waiting: true`, the agent loop stamps
  `:access_waiting` on its context from it (the rest of the same step included),
  the Realtime session stamps it while its call's record waits (`waiting?/1`),
  and every capability is then refused here. The content that made the gate ask
  must not be able to answer the owner's prompt itself — click the app card or
  the Telegram button, drive a signed-in chat tab, or play a spoken "yes".

  Every held or refused call is still one model tool call, so it emits exactly
  one `[:fermix, :tool, :exec]` event under the capability's name, with
  `access_gate` naming the outcome and a typed `policy_enforcement` marker that
  proves the executor never ran. A dispatched call is labelled through the
  context (`access_gate`: `direct`, `scheduled` or `confirmed`), which the single
  emitter copies into the executor's own event.
  """

  require Logger

  alias FermixCore.Acp.Identity
  alias FermixCore.Capabilities.AccessGate.Pending
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Harness.Authorization
  alias FermixCore.Temporal.Access
  alias FermixCore.Tools.RequestDirectoryAccess
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @max_args_chars 300
  @max_outcome_chars 400
  @max_source_labels 5
  @after_confirm "Once you confirm, Fermix runs exactly this command."

  @affirmatives MapSet.new(
                  ~w(yes yeah yep yup confirm confirmed) ++
                    ["yes please", "go ahead", "do it", "yes do it", "yes go ahead"]
                )

  @snapshot_keys [
    :session_id,
    :parent_session,
    :agent_name,
    :redact_values,
    :conversation_key,
    :capability_registry,
    :computer_use_origin
  ]

  @type surface :: :voice | :this_chat | :owner_inbox
  @type refusal :: :worker | :unattended | :not_allowlisted | :no_surface
  @type decision :: :dispatch | {:confirm, surface()} | {:refuse, refusal()}

  @doc """
  Called by `Capability.execute/3` before the executor. `{:dispatch, context}`
  runs the executor with a labelled context; `{:held, result}` is the tool result
  the caller returns instead, and the executor is never called. A result that
  parked the call for the owner carries `access_waiting: true`. Under
  `:access_waiting` every capability is held, flagged or not.
  """
  @spec admit(Capability.t(), map(), map()) :: {:dispatch, map()} | {:held, Tool.tool_result()}
  def admit(%Capability{} = capability, args, %{access_waiting: true} = context)
      when is_map(args) do
    Logger.info("access_gate: #{capability.name} refused, a parked call is waiting")

    hold(
      %{capability: capability, args: args, context: context},
      waiting_text(),
      "refused_waiting"
    )
  end

  def admit(%Capability{metadata: %{access_sensitive?: true}} = capability, args, context)
      when is_map(args) and is_map(context) do
    call = %{capability: capability, args: args, context: context}

    case Map.fetch(context, :access_confirmed) do
      {:ok, digest} -> admit_confirmed(call, digest)
      :error -> apply_decision(decide(capability, context), call)
    end
  end

  def admit(%Capability{}, args, context) when is_map(args) and is_map(context),
    do: {:dispatch, context}

  @doc """
  Whether a flagged call may run now in `context`, must wait for the owner on a
  surface, or is refused. Pure apart from the job-row read a scheduled run makes.
  """
  @spec decide(Capability.t(), map()) :: decision()
  def decide(%Capability{} = capability, context) when is_map(context) do
    cond do
      worker?(context) -> {:refuse, :worker}
      scheduled_operator?(context) -> scheduled_decision(capability.name, context)
      not Access.attended_operator_turn?(context) -> {:refuse, :unattended}
      tainted?(capability, context) -> confirm_on(surface(context))
      true -> :dispatch
    end
  end

  @doc """
  Run a parked call the owner confirmed, once. Re-resolves the capability, which
  must still be the same flagged command on the same plugin and auth profile.
  Returns a short sentence for the owner either way.
  """
  @spec confirm(String.t(), GenServer.server()) :: {:ok, String.t()} | {:error, String.t()}
  def confirm(id, pending \\ Pending) when is_binary(id) do
    case Pending.take(id, pending) do
      {:ok, record} ->
        run_confirmed(record, pending)

      :error ->
        Logger.info("access_gate: confirm of intent #{id} found no waiting request")
        {:error, "that request expired or was already handled"}
    end
  end

  @doc """
  Settle a spoken answer to a parked voice call. Only a whole-utterance yes
  confirms; anything else drops the record so nothing runs.
  """
  @spec answer_spoken(String.t(), String.t(), GenServer.server()) ::
          {:confirmed, String.t()} | :declined
  def answer_spoken(id, text, pending \\ Pending) when is_binary(id) and is_binary(text) do
    if affirmative?(text) do
      {:confirmed, id}
    else
      Logger.info("access_gate: intent #{id} declined by voice")
      :ok = Pending.discard(id, pending)
      :declined
    end
  end

  @doc """
  Whether a call the turn (or voice call) in `context` parked still waits on the
  owner. While it does, that call may run nothing else: the Realtime session
  stamps `:access_waiting` from it and `admit/3` refuses every call.
  """
  @spec waiting?(map()) :: boolean()
  def waiting?(context) when is_map(context) do
    case Map.get(context, :session_id) do
      session_id when is_binary(session_id) ->
        Pending.pending_from(session_id, pending(context)) != :none

      _no_session ->
        false
    end
  end

  @doc """
  The owner's confirm line for a parked call, shared by the in-chat prompt and
  the owner-inbox delivery: the one token-visibility rule, and a promise that
  matches what happens (the daemon runs the command; nothing resumes).
  """
  @spec approval_line(String.t(), map()) :: String.t()
  def approval_line(token, context) when is_binary(token) and is_map(context),
    do: RequestDirectoryAccess.approval_line(token, context, @after_confirm)

  @doc """
  Whether a spoken utterance is, as a whole, a yes. Lower-cased, punctuation
  removed, then matched against a closed English set, so "yes, but first…" and
  an echoed "say yes to confirm" are not a yes. Fails closed.
  """
  @spec affirmative?(String.t()) :: boolean()
  def affirmative?(text) when is_binary(text) do
    normalized =
      text
      |> String.downcase()
      |> String.replace(~r/[\p{P}]+/u, " ")
      |> String.split()
      |> Enum.join(" ")

    MapSet.member?(@affirmatives, normalized)
  end

  @doc """
  For `schedule_job`, `update_job`, `resume_job` and `run_job_now`: a job naming
  a flagged tool may be set up, changed, resumed or run now only from a turn
  that would run that tool directly. Unknown and unflagged names pass.
  """
  @spec check_job_tools([String.t()], map()) :: :ok | {:error, String.t()}
  def check_job_tools(names, context) when is_list(names) and is_map(context) do
    registry = Map.get(context, :capability_registry) || CapabilityRegistry

    case Enum.find(names, &blocked_job_tool?(registry, &1, context)) do
      nil -> :ok
      name -> {:error, job_refusal(name)}
    end
  end

  @doc """
  What a voice model is told when a confirmed run crashed before it reported:
  whether the command reached the device is unknown, so it must not be resent
  blindly. Shared by both voice engines.
  """
  @spec outcome_unknown_text() :: String.t()
  def outcome_unknown_text do
    "The owner said yes, but whether the command reached the device is unknown. " <>
      "Check its state before sending it again."
  end

  @doc "The typed proof that a held or refused call never reached its executor."
  @spec pre_execution_marker(:confirm | :deny) :: map()
  def pre_execution_marker(decision) when decision in [:confirm, :deny] do
    %{source: "access_gate", decision: Atom.to_string(decision), phase: "pre_execution"}
  end

  @doc "The fingerprint a confirmation is bound to: the tool and its exact arguments."
  @spec digest(String.t(), map()) :: String.t()
  def digest(tool, args) when is_binary(tool) and is_map(args) do
    {tool, args}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # --- decision ------------------------------------------------------------

  defp worker?(context),
    do: Map.get(context, :subagent_depth, 0) != 0 or Map.get(context, :skill_depth, 0) != 0

  defp scheduled_operator?(context),
    do: Map.get(context, :source_trust) == :operator and Authorization.scheduled?(context)

  defp scheduled_decision(name, context) do
    case Authorization.authorize(name, context) do
      :ok ->
        :dispatch

      {:error, reason} ->
        Logger.info("access_gate: scheduled #{name} refused: #{inspect(reason)}")
        {:refuse, :not_allowlisted}
    end
  end

  defp tainted?(capability, context),
    do: shared_channel?(context) or read_outside?(capability, context)

  # Other people can post in a Buzz channel, so a request there is not proof the
  # owner asked, whatever the turn read (owner decision, MOB-1).
  defp shared_channel?(context), do: Identity.multi_principal?(Map.get(context, :session_env))

  # A context the loop never stamped is read as tainted: absence is not proof
  # that the turn read nothing.
  defp read_outside?(capability, context) do
    case Map.fetch(context, :outside_sources) do
      {:ok, %MapSet{} = sources} -> outside_labels(capability, sources) != []
      _absent_or_malformed -> true
    end
  end

  defp outside_labels(capability, sources) do
    sources
    |> MapSet.delete(UntrustedContent.outside_source(capability))
    |> Enum.map(fn {_kind, label} -> label end)
    |> Enum.sort()
  end

  defp source_set(context) do
    case Map.get(context, :outside_sources) do
      %MapSet{} = sources -> sources
      _absent_or_malformed -> MapSet.new()
    end
  end

  # The facts are disjoint configurations, checked in one order: a voice call
  # first (the voice channel is also an owner surface without slash commands).
  defp surface(context) do
    cond do
      is_binary(Map.get(context, :voice_call_id)) -> :voice
      RequestDirectoryAccess.attended_operator?(context) -> :this_chat
      is_function(Map.get(context, :owner_inbox_approval_fn), 1) -> :owner_inbox
      true -> :none
    end
  end

  defp confirm_on(:none), do: {:refuse, :no_surface}
  defp confirm_on(surface), do: {:confirm, surface}

  # The store a context parks in: the application's, unless a caller hands one
  # in (`:access_pending`), as a test does to stay off the shared store.
  defp pending(context), do: Map.get(context, :access_pending) || Pending

  # --- effects (`call` is the one flagged call: capability, args, context) --

  defp apply_decision(:dispatch, %{context: context}),
    do: {:dispatch, Map.put(context, :access_gate, dispatch_label(context))}

  defp apply_decision({:confirm, surface}, call), do: park(call, surface)
  defp apply_decision({:refuse, reason}, call), do: refuse(call, reason)

  defp dispatch_label(context),
    do: if(Authorization.scheduled?(context), do: "scheduled", else: "direct")

  defp admit_confirmed(%{capability: capability, args: args, context: context} = call, digest) do
    if digest == digest(capability.name, args) do
      {:dispatch, Map.put(context, :access_gate, "confirmed")}
    else
      Logger.warning("access_gate: #{capability.name} confirmation did not match its call")
      hold(call, mismatch_text(capability.name), "refused_confirm_mismatch")
    end
  end

  defp park(call, surface) do
    call =
      Map.merge(call, %{
        sources: outside_labels(call.capability, source_set(call.context)),
        shared_channel?: shared_channel?(call.context)
      })

    call
    |> pending_attrs(surface)
    |> Pending.park(pending(call.context))
    |> parked(call, surface)
  end

  defp pending_attrs(%{capability: capability, args: args, context: context} = call, surface) do
    %{
      tool: capability.name,
      args: args,
      digest: digest(capability.name, args),
      plugin: Map.get(capability.metadata, :plugin),
      auth_profile: Map.get(capability.metadata, :auth_profile),
      binding: binding(surface, context),
      sources: call.sources,
      snapshot: context |> Map.take(@snapshot_keys) |> Map.put(:source_trust, :operator)
    }
  end

  defp binding(:voice, context), do: {:voice_call, Map.fetch!(context, :voice_call_id)}
  defp binding(_surface, context), do: {:conversation, Map.get(context, :conversation_key)}

  defp parked({:ok, id, fresh}, call, surface) when fresh in [:new, :existing] do
    Logger.info(
      "access_gate: #{call.capability.name} parked as intent #{id} (#{surface}, #{fresh})"
    )

    deliver(surface, Map.put(call, :id, id), fresh)
  end

  defp parked({:ok, id, :running}, call, surface),
    do: hold(call, existing_text(), "held_#{surface}", id)

  defp parked({:ok, id, {:done, outcome}}, call, _surface),
    do: hold(call, done_text(call.capability.name, outcome), "already_confirmed", id)

  defp parked({:error, :too_many_pending}, call, _surface) do
    Logger.warning("access_gate: #{call.capability.name} refused, too many confirmations waiting")
    hold(call, full_text(call.capability.name), "refused_full")
  end

  # The channel confirmations store answers whether a prompt is live: `:new`
  # means the owner has no live token for this call (first ask, or the last one
  # was denied or expired), so the prompt goes out; `:existing` sends nothing.
  defp deliver(:this_chat, call, _fresh) do
    case call.context.approval_fn.(%{access_sensitive: call.id}) do
      {:ok, token, :new} ->
        call.context.reply_fn.({:approval_prompt, chat_prompt(call, token), token})
        hold_parked(call, chat_text(call), "held_this_chat")

      {:ok, _token, :existing} ->
        hold_parked(call, existing_text(), "held_this_chat")
    end
  end

  defp deliver(:owner_inbox, call, _fresh) do
    case call.context.owner_inbox_approval_fn.(%{
           access_sensitive: call.id,
           prompt: owner_prompt(call)
         }) do
      {:ok, _token, :new} ->
        hold_parked(call, inbox_text(call), "held_owner_inbox")

      {:ok, _token, :existing} ->
        hold_parked(call, existing_text(), "held_owner_inbox")

      {:error, reason} ->
        Logger.warning(
          "access_gate: intent #{call.id} owner inbox unreachable: #{inspect(reason)}"
        )

        :ok = Pending.discard(call.id, pending(call.context))
        refuse(call, :no_surface)
    end
  end

  defp deliver(:voice, call, :new),
    do: hold_parked(call, voice_text(call.capability.name), "held_voice")

  defp deliver(:voice, call, :existing), do: hold_parked(call, existing_text(), "held_voice")

  defp refuse(call, reason) do
    Logger.info("access_gate: #{call.capability.name} refused (#{reason})")
    hold(call, refusal_text(reason, call.capability.name), "refused_#{reason}")
  end

  # One model tool call, one exec event: the executor never ran, so the gate
  # emits the call's event itself, with the typed pre-execution marker.
  defp hold(call, text, label, intent_id \\ nil) do
    metadata =
      %{access_gate: label, policy_enforcement: pre_execution_marker(marker_decision(label))}
      |> maybe_put(:access_intent, intent_id)

    ToolTelemetry.exec(call.capability.name, call.context, false, 0,
      metadata: metadata,
      input: call.args
    )

    {:held, Tool.error(text)}
  end

  # The call now waits on the owner under its parked record (a new one, or one
  # this or another turn of the chat parked earlier): the result says so, so the
  # caller runs nothing else of this turn.
  defp hold_parked(call, text, label) do
    {:held, result} = hold(call, text, label, call.id)
    {:held, Map.put(result, :access_waiting, true)}
  end

  defp marker_decision("held_" <> _surface), do: :confirm
  defp marker_decision(_refused_or_done), do: :deny

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # --- confirmation --------------------------------------------------------

  defp run_confirmed(record, pending) do
    {status, text} =
      case current_capability(record) do
        {:ok, capability} -> dispatch_confirmed(capability, record)
        {:error, :plugin_changed} -> {:error, changed_text(record.tool)}
      end

    :ok = Pending.finish(record, text, pending)
    Logger.info("access_gate: intent #{record.id} confirmed and run: #{status}")
    {status, text}
  end

  defp current_capability(record) do
    registry = Map.get(record.snapshot, :capability_registry) || CapabilityRegistry

    case CapabilityRegistry.find(registry, record.tool) do
      {:ok, %Capability{} = capability} ->
        same_command(capability, record)

      :error ->
        Logger.warning("access_gate: intent #{record.id} lost #{record.tool} before confirm")
        {:error, :plugin_changed}
    end
  end

  defp same_command(%Capability{metadata: metadata} = capability, record) do
    if Map.get(metadata, :access_sensitive?) == true and
         Map.get(metadata, :plugin) == record.plugin and
         Map.get(metadata, :auth_profile) == record.auth_profile do
      {:ok, capability}
    else
      Logger.warning("access_gate: intent #{record.id} #{record.tool} changed before confirm")
      {:error, :plugin_changed}
    end
  end

  defp dispatch_confirmed(capability, record) do
    context =
      Map.merge(record.snapshot, %{access_confirmed: record.digest, access_intent: record.id})

    capability
    |> Capability.execute(record.args, context)
    |> confirmed_outcome(record.tool)
  end

  defp confirmed_outcome({:ok, %{success: true, output: output}}, tool),
    do: {:ok, "#{tool} ran: #{bounded(output, @max_outcome_chars)}"}

  defp confirmed_outcome({:ok, %{success: false, error: error}}, tool),
    do: {:error, "#{tool} failed: #{bounded(error, @max_outcome_chars)}"}

  defp confirmed_outcome({:error, reason}, tool),
    do: {:error, "#{tool} failed: #{bounded(inspect(reason), @max_outcome_chars)}"}

  defp blocked_job_tool?(registry, name, context) when is_binary(name) do
    case CapabilityRegistry.find(registry, name) do
      {:ok, %Capability{metadata: %{access_sensitive?: true}} = capability} ->
        decide(capability, context) != :dispatch

      _unknown_or_unflagged ->
        false
    end
  end

  defp blocked_job_tool?(_registry, _name, _context), do: false

  # --- owner-facing text (Fermix-authored; never quotes the model or a sender)

  defp owner_prompt(%{capability: capability} = call) do
    """
    Confirm #{capability.name}? #{capability.description}
    Arguments: #{args_text(call)}
    Asked because #{reason_phrase(call)}.\
    """
  end

  defp chat_prompt(call, token),
    do: owner_prompt(call) <> "\n\n" <> approval_line(token, call.context)

  defp args_text(%{args: args, context: context}) do
    args
    |> Jason.encode!()
    |> ToolTelemetry.redact(Map.get(context, :redact_values, []))
    |> bounded(@max_args_chars)
  end

  # Why the owner is asked: the shared channel, what the turn read, or both.
  defp reason_phrase(%{shared_channel?: true, sources: []}), do: shared_channel_reason()

  defp reason_phrase(%{shared_channel?: true, sources: sources}),
    do: shared_channel_reason() <> ", and " <> read_reason(sources)

  defp reason_phrase(%{sources: []}), do: "Fermix could not tell what this request read first"
  defp reason_phrase(%{sources: sources}), do: "this request came " <> read_reason(sources)

  defp shared_channel_reason,
    do: "this request came from a shared Buzz channel, where other people can send messages"

  defp read_reason(sources) do
    shown = sources |> Enum.take(@max_source_labels) |> Enum.join(", ")
    "after reading content someone else could have written (#{shown})"
  end

  defp bounded(text, max) when is_binary(text) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max) <> "…"
  end

  # --- model-facing text (fixed, never carries the token) -------------------

  defp chat_text(%{capability: %{name: tool}} = call) do
    "Not sent. #{tool} is an access-sensitive command and #{reason_phrase(call)}, so the " <>
      "owner must confirm it. A confirmation is now in this chat and expires in 60 seconds. " <>
      "Tell the owner and stop. Do not call #{tool} again: it runs the moment they confirm."
  end

  defp inbox_text(%{capability: %{name: tool}} = call) do
    "Not sent. #{tool} is an access-sensitive command and #{reason_phrase(call)}, so the " <>
      "confirmation went to the owner's own chat. Say it is waiting on the owner's " <>
      "confirmation there, then stop. Do not call #{tool} again: it runs the moment they confirm."
  end

  defp voice_text(tool) do
    "Not sent yet. The owner must say yes. Ask them in one short sentence whether to run " <>
      "#{tool} with these arguments, then wait. Do not call it again: Fermix runs it when " <>
      "it hears their yes and tells you what happened."
  end

  defp waiting_text do
    "Not run: an access-sensitive command is already waiting on the owner's answer, and " <>
      "nothing else runs until they give it. Tell the owner it is waiting, then stop."
  end

  defp existing_text do
    "Not sent. A confirmation for this exact request is already waiting on the owner. " <>
      "Do not call it again."
  end

  defp done_text(tool, outcome) do
    "Already done after the owner confirmed: #{outcome}. Do not send #{tool} again."
  end

  defp full_text(tool) do
    "#{tool} was not sent: too many confirmations are waiting; try again shortly."
  end

  defp mismatch_text(tool) do
    "#{tool} was not sent: this call does not match the request the owner confirmed."
  end

  defp changed_text(tool) do
    "#{tool} did not run: the command changed since the owner was asked (the plugin was " <>
      "turned off, no longer marks it, or signs in under a different profile). Ask again."
  end

  defp refusal_text(:worker, tool) do
    "#{tool} was not sent: it never runs from a delegated worker. Report that the owner " <>
      "must ask for it directly."
  end

  defp refusal_text(:unattended, tool) do
    "#{tool} was not sent: it runs only when the owner asks directly in their chat, the " <>
      "Fermix app or by voice, or from a scheduled job that names it."
  end

  defp refusal_text(:not_allowlisted, tool) do
    "#{tool} was not sent: this scheduled job does not name it. The owner can recreate the " <>
      "job from their own chat and name #{tool} in its allowed tools."
  end

  defp refusal_text(:no_surface, tool) do
    "#{tool} was not sent: it needs the owner's confirmation and Fermix has no private chat " <>
      "to ask them on. Ask from the Fermix app, your own chat, or by voice."
  end

  defp job_refusal(tool) do
    "A scheduled job that may run #{tool} can be set up, changed or run now only when you " <>
      "ask directly, from your own chat, app or voice, in a request that has read nothing " <>
      "from outside. Ask again directly."
  end
end
