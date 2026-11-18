defmodule FermixCore.Agents.PhoneCallTurn do
  @moduledoc """
  The scoped backend turn a phone call runs when its voice needs work done
  (M94 §07, §11), and the one place its context is derived: from the call's
  delegation request and its recorded mandate, never from the owner's.

  It is a principal of its own, neither the owner's attended turn nor a
  guest's chat: the authenticated owner who asked for the call, the mandate
  (the brief) and the person on the line stay three identities, and the last
  is untrusted even when their number is a contact. So, all in code:

    * **Believed only from its bridge.** `from_message/1` answers a turn only
      for a message on the `phone_call` channel at `phone_call` trust, which
      only `FermixChannels.PhoneCalls.Bridge` enqueues. The gateway knows no
      such channel and assigns no such trust (`Gateway.Authorizer` answers an
      operator or a guest), so a message from any real channel that claims to
      be a phone-call turn is an ordinary message of its own channel, and one
      on the `phone_call` channel is refused at ingest. A map that clears the
      gate and is malformed is a defect in that bridge, and raises.
    * **Its own conversation and lane**, `{"phone_call", call_id, :root}`. It
      reads no history and writes none: each delegation carries the call's
      transcript window, so nothing of the call reaches the owner's memory or
      any memory review (`TurnRunner.commit/4` writes nothing for it).
    * **Its own context, chosen before any prompt is composed.** The system
      text is `PhoneCalls.Prompt.backend_context/2` alone and the user text
      the rendered window (`PhoneCalls.Prompt.render_window/1`, inside the
      untrusted frame); nothing of the owner's bootstrap, prompt memory,
      persona, chat, lists, events, recent calls or activity is in it.
    * **Exactly its tools.** The capabilities are `PhoneCalls.Prompt.capabilities/1`
      for the brief, the list the voice prompt names: the two in-call controls
      and each tool the brief grants, after `PhoneCalls.Grants.resolve/1`
      holds every grant to what a call may use. The controls are built here
      from their own modules (`Capabilities.Builtin.from_tool_module/1`, where
      their policy is declared) and no registry holds them, so no other turn
      can be offered or run one; each grant is read from the owner's registry
      and must be a built-in. The loop is handed that list as both what it
      advertises and all it can dispatch, and as its allowlist, so any other
      name is "not available" whatever the registry holds, a capability there
      named like a control included.
    * **Never attended, tainted from the start.** Its trust is `phone_call`
      and its origin `:unattended`, and it starts having read the call
      (`UntrustedContent.phone_call_source/0`), so `Capabilities.AccessGate`
      refuses every access-sensitive, host-command or external-effect call
      outright and parks none: nobody on a phone call can confirm for the owner. No owner surface
      is in its context: no reply function, approval, owner inbox, voice call,
      memory or coding-run chain.
    * **Bounded** by the request's `max_steps` (the loop's iterations); its
      deadline is the bridge's, which stops the queue turn.
    * **Quick to answer.** Someone waits on the line while it thinks, so it runs
      at a low reasoning effort (`@call_effort`) whatever the owner's routes
      carry, clamped per route as any routing overlay is.
    * **Checked before it leaves.** A reply passes `PhoneCalls.Disclosure`
      before it is told to the bridge, or the turn fails with
      `{:reply_withheld, why}` and nothing of it is sent. An empty reply fails
      as `:empty_reply`.
    * **Traced inside the call.** It carries the call's own `session_id`, so
      its provider spans and tool events nest under the call's trace (the
      meeting precedent). It emits no `[:fermix, :agent, :message]`, which
      would close that trace as a turn's end.

  The reply goes back as one event on the turn's raw stream callback,
  `{:phone_call_reply, reply, backend_usage}`, the runner's word to its
  channel that the voice bridge's provenance events already use; the bridge
  answers the call's worker with it.

  The in-call controls read the call they act on from the context
  (`in_call/1`): its id and the handle the worker minted, never a model
  argument, and the controls' module (`:phone_call_controls`, a test's seam,
  default `PhoneCalls.CallControls`).
  """

  require Logger

  alias FermixCore.AgentLoop
  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.BriefText
  alias FermixCore.PhoneCalls.Disclosure
  alias FermixCore.PhoneCalls.Grants
  alias FermixCore.PhoneCalls.Prompt
  alias FermixCore.Providers.RoutingOverrides
  alias FermixCore.Tools.PhoneCallEnd
  alias FermixCore.Tools.PhoneCallPressKeys

  @channel "phone_call"
  @trust :phone_call
  @agent_name "phone_call"
  @controls FermixCore.PhoneCalls.CallControls
  # The reasoning effort every turn of a call runs at: a person waits on the
  # line for its answer, so it never pays the owner's configured level.
  @call_effort :low
  @fields [:call_id, :handle, :delegation_id, :brief, :window, :session_id, :max_steps]

  @typedoc "One delegation's turn, as the bridge puts it on the message (`message/1`)."
  @type t :: %{
          call_id: String.t(),
          handle: String.t(),
          delegation_id: String.t(),
          brief: Brief.t(),
          window: [FermixCore.PhoneCalls.Transcript.entry()],
          session_id: String.t(),
          max_steps: pos_integer()
        }

  @typedoc """
  What the turn runs with, from `TurnRunner`: the capability registry, the
  loop's provider route options (`adapter`/`adapter_opts` or `routes`), the
  raw stream callback the reply is told through, and the seams `now_fn` and
  `controls`.
  """
  @type runtime :: %{
          required(:capability_registry) => GenServer.server(),
          required(:loop) => keyword(),
          required(:tell) => (term() -> term()),
          optional(:now_fn) => (-> DateTime.t()) | nil,
          optional(:controls) => module() | nil
        }

  @type in_call :: %{call_id: String.t(), handle: String.t(), controls: module()}

  @doc "The conversation, and so the queue lane, of call `call_id`'s backend turns."
  @spec conversation_key(String.t()) :: ConversationKey.t()
  def conversation_key(call_id) when is_binary(call_id) and call_id != "",
    do: {@channel, call_id, :root}

  @doc "The queue message id of one delegation, so a stop can name it."
  @spec message_id(String.t(), String.t()) :: String.t()
  def message_id(call_id, delegation_id)
      when is_binary(call_id) and call_id != "" and is_binary(delegation_id) and
             delegation_id != "",
      do: "phone-call-#{call_id}-#{delegation_id}"

  @doc """
  The queue message a delegation `request` (`PhoneCalls.Delegate.request/0`)
  runs as, before its bridge adds the closures that answer it. Raises on a
  malformed request.
  """
  @spec message(map()) :: map()
  def message(request) when is_map(request) do
    turn = validate!(request)

    %{
      id: message_id(turn.call_id, turn.delegation_id),
      channel: @channel,
      chat_id: turn.call_id,
      reply_target: turn.call_id,
      sender: @channel,
      content: Prompt.render_window(turn.window),
      metadata: %{phone_call: turn},
      source_trust: @trust
    }
  end

  @doc """
  The message's phone-call turn, or `:none` when it is not one (see the
  moduledoc). Raises on a malformed turn that cleared the gate.
  """
  @spec from_message(map()) :: {:ok, t()} | :none
  def from_message(msg) when is_map(msg) do
    metadata = Map.get(msg, :metadata) || %{}
    trusted(Map.get(msg, :source_trust), Map.get(msg, :channel), Map.get(metadata, :phone_call))
  end

  defp trusted(@trust, @channel, turn) when is_map(turn), do: {:ok, validate!(turn)}
  defp trusted(_trust, _channel, _turn), do: :none

  @doc """
  The call a tool context's in-call controls act on: its id, the handle the
  worker minted for this turn, and the worker's module. `:none` outside a
  phone call's backend turn.
  """
  @spec in_call(map()) :: {:ok, in_call()} | :none
  def in_call(%{
        source_trust: @trust,
        phone_call: %{call_id: call_id, handle: handle},
        phone_call_controls: controls
      })
      when is_binary(call_id) and call_id != "" and is_binary(handle) and handle != "" and
             is_atom(controls) and not is_nil(controls) do
    {:ok, %{call_id: call_id, handle: handle, controls: controls}}
  end

  def in_call(context) when is_map(context), do: :none

  @doc """
  The names of the tools this brief's turns offer, in `Prompt.capabilities/1`
  order, or the grants' refusal.
  """
  @spec tool_names(Brief.t()) :: {:ok, [String.t(), ...]} | {:error, Grants.refusal()}
  def tool_names(%Brief{tool_grants: grants} = brief) do
    with {:ok, _granted} <- Grants.resolve(grants) do
      {:ok, brief |> Prompt.capabilities() |> Enum.map(&capability_name/1) |> Enum.uniq()}
    end
  end

  defp capability_name(:keypad), do: PhoneCallPressKeys.name()
  defp capability_name(:end_call), do: PhoneCallEnd.name()
  defp capability_name({:tool, name}) when is_binary(name), do: name

  @doc """
  Runs the turn and answers what `TurnRunner.run/5` answers: `{:ok, reply,
  0}` once the reply is checked and told, or `{:error, reason}`.
  """
  @spec run(t(), runtime()) :: {:ok, String.t(), 0} | {:error, term()}
  def run(
        %{brief: %Brief{} = brief} = turn,
        %{capability_registry: registry, loop: loop} = runtime
      )
      when is_list(loop) do
    tell = fetch_tell!(runtime)
    now = now(runtime)

    with {:ok, names} <- tool_names(brief),
         {:ok, capabilities} <- capabilities(registry, brief) do
      system = Prompt.backend_context(brief, now: now)
      window = Prompt.render_window(turn.window)

      [system: system, window: window]
      |> loop_opts(turn, runtime, {names, capabilities})
      |> AgentLoop.run()
      |> finish(turn, tell, %{
        brief: brief,
        instructions: system,
        mandate: BriefText.block(brief, now),
        window: window
      })
    end
  end

  defp fetch_tell!(%{tell: tell}) when is_function(tell, 1), do: tell

  defp fetch_tell!(_runtime),
    do: raise(ArgumentError, "a phone call's backend turn needs its bridge's stream callback")

  defp now(%{now_fn: now_fn}) when is_function(now_fn, 0), do: now_fn.()
  defp now(_runtime), do: DateTime.utc_now()

  # The turn's capabilities in `Prompt.capabilities/1` order, so in
  # `tool_names/1` order: each control built from its module, each grant read
  # from the owner's registry.
  defp capabilities(registry, brief) do
    brief
    |> Prompt.capabilities()
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, found} ->
      case capability(registry, entry) do
        {:ok, capability} -> {:cont, {:ok, found ++ [capability]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp capability(_registry, :keypad), do: {:ok, Builtin.from_tool_module(PhoneCallPressKeys)}
  defp capability(_registry, :end_call), do: {:ok, Builtin.from_tool_module(PhoneCallEnd)}

  defp capability(registry, {:tool, name}) when is_binary(name) do
    case CapabilityRegistry.find(registry, name) do
      {:ok, %Capability{kind: :builtin} = capability} -> {:ok, capability}
      {:ok, %Capability{kind: kind}} -> {:error, {:capability_not_builtin, name, kind}}
      :error -> {:error, {:capability_missing, name}}
    end
  end

  defp loop_opts(prompt, turn, runtime, {names, capabilities}) do
    [
      messages: [
        %{role: "system", content: Keyword.fetch!(prompt, :system)},
        %{role: "user", content: Keyword.fetch!(prompt, :window)}
      ],
      context: context(turn, runtime),
      capability_registry: runtime.capability_registry,
      capabilities: capabilities,
      dispatchable_capabilities: capabilities,
      allowed_tools: names,
      max_iterations: turn.max_steps
    ] ++ at_call_effort(runtime.loop)
  end

  # The loop's provider options at `@call_effort`, by the one rule any route
  # overlay follows (`RoutingOverrides.apply_effort/2`: clamped per provider and
  # model, a provider with no effort levels left alone), for both shapes
  # `TurnRunner` hands a turn. A single adapter is the one route the loop builds
  # from it (`AgentLoop`): keyed by the loop's `route_key`, or without one by
  # the loop's own `:mock` provider, which has no effort levels.
  defp at_call_effort(loop) do
    case Keyword.fetch(loop, :routes) do
      {:ok, routes} ->
        Keyword.put(loop, :routes, RoutingOverrides.apply_effort(routes, @call_effort))

      :error ->
        key = Keyword.get(loop, :route_key, %{provider: :mock, model: "mock"})
        route = {key, Keyword.get(loop, :adapter_opts, [])}
        [{_key, adapter_opts}] = RoutingOverrides.apply_effort([route], @call_effort)
        Keyword.put(loop, :adapter_opts, adapter_opts)
    end
  end

  # Everything a tool of this turn can read. No owner surface is here: no
  # reply or approval function, owner inbox, voice call, memory, sandbox
  # folder or coding-run chain, so a tool that needs one finds none.
  defp context(turn, runtime) do
    %{
      agent_name: @agent_name,
      conversation_key: conversation_key(turn.call_id),
      session_id: turn.session_id,
      capability_registry: runtime.capability_registry,
      source_trust: @trust,
      source_channel: @channel,
      channel: @channel,
      computer_use_origin: :unattended,
      outside_sources: MapSet.new([UntrustedContent.phone_call_source()]),
      phone_call: Map.take(turn, [:call_id, :handle, :delegation_id]),
      phone_call_controls: Map.get(runtime, :controls) || @controls
    }
  end

  defp finish({:ok, %{response: response} = result}, turn, tell, inputs) do
    case String.trim(response) do
      "" -> {:error, :empty_reply}
      reply -> checked(reply, result, turn, tell, inputs)
    end
  end

  defp finish({:error, reason}, _turn, _tell, _inputs), do: {:error, reason}

  defp checked(reply, result, turn, tell, inputs) do
    case Disclosure.check(reply, inputs) do
      :ok ->
        tell.({:phone_call_reply, reply, backend_usage(result)})
        {:ok, reply, 0}

      {:withheld, why} ->
        Logger.warning(
          "phone call #{turn.call_id} delegation #{turn.delegation_id}: reply withheld, #{why}"
        )

        {:error, {:reply_withheld, why}}
    end
  end

  # What the loop measured; its cost is unknown here, and unknown is not zero.
  defp backend_usage(result) do
    %{
      "total_tokens" => Map.get(result, :total_tokens, 0),
      "iterations" => Map.get(result, :iterations, 0)
    }
  end

  defp validate!(turn) do
    if valid?(turn) do
      Map.take(turn, @fields)
    else
      raise ArgumentError, "malformed phone call turn: #{inspect(Map.keys(turn))}"
    end
  end

  defp valid?(%{brief: %Brief{}, window: window, max_steps: max_steps} = turn),
    do: texts?(turn) and is_list(window) and is_integer(max_steps) and max_steps >= 1

  defp valid?(_incomplete), do: false

  defp texts?(%{call_id: call_id, handle: handle, delegation_id: id, session_id: session_id}),
    do: Enum.all?([call_id, handle, id, session_id], &(is_binary(&1) and &1 != ""))

  defp texts?(_incomplete), do: false
end
