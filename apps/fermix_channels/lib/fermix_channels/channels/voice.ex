defmodule FermixChannels.Channels.Voice do
  @moduledoc """
  The voice channel adapter (MILESTONE_41_OPENAI_LIVE_VOICE.md §7).

  Under the `openai_live` engine the voice model never runs a tool: it delegates
  each task back to an ordinary Core turn. This module is the routing layer
  between the gateway's per-turn closures and the Live session that asked for
  the work — the same shape as `Channels.Acp`, and for the same reason: it holds
  no state and owns no socket.

  Three facts shape the adapter:

  - **There is no webhook transport.** `parse_webhook/1` and `verify_webhook/1`
    refuse with `:unsupported_transport`; delegations arrive through
    `FermixChannels.Voice.Bridge`, which the Live session calls directly.
  - **The stream tier is `:raw`.** Not because voice streams, but because it
    must NOT: the default `"block"` tier would deliver a long answer as several
    ordinary replies, and each reply is one delegation result. Taking the raw
    tier keeps the gateway from chunking, and this adapter then drops every
    delta — the session speaks the final answer once, and partial text reaching
    the voice model would be spoken twice. The stream carries one thing on to
    the session: `:history_tainted`, the runner's word, before the reply, that
    the reply is drawn from Computer History (M56 §9), so the session gives it
    to no voice that may not carry it.
  - **Media is refused.** The Live wire carries audio and text only, so an
    attachment has nowhere to go and says so (`:unsupported_in_voice`) instead
    of being silently dropped.

  Every closure carries the turn's fence — the call's UUID, the delegation id
  and its revision, minted by the session and carried on `metadata.voice_call`
  — so an event that arrives for a closed call or a superseded revision is
  recognised as late and dropped rather than spoken.

  A task can outlive its call (M56 §4.6): as a call in the chat ends, its
  running task is handed to `Voice.Detached`, which registers a route of its
  own before the session releases the session's. So an event is routed by the
  session's entry first and the detached owner's second, read afresh for each
  event, and only an event that finds neither is dropped as late.
  """

  @behaviour FermixChannels.Gateway.Channel

  require Logger

  alias FermixChannels.Gateway.Channel
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixChannels.Voice.Detached
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Reply
  alias FermixCore.Telemetry

  @channel "voice"
  @registry FermixChannels.Voice.Registry
  @turn_opt :voice_turn

  @typedoc "A delegation's fence: its call's UUID, the id the session minted and its revision."
  @type fence ::
          {call_uuid :: String.t(), delegation_id :: String.t(), revision :: pos_integer()}

  @doc "The channel string this adapter answers to."
  @spec channel() :: String.t()
  def channel, do: @channel

  @doc """
  The unique-keys Registry mapping `{call_id, delegation_id}` to the callbacks
  the Live session supplied for that delegation, and `Detached.route/2` to the
  ones a detached task's owner supplied. Written by
  `FermixChannels.Voice.Bridge` and `Voice.Detached`, read here.
  """
  @spec registry() :: atom()
  def registry, do: @registry

  @doc "The send-opt key carrying a delegation's fence into `send_message/3`."
  @spec turn_opt() :: atom()
  def turn_opt, do: @turn_opt

  @impl true
  def parse_webhook(_params), do: {:error, :unsupported_transport}

  @impl true
  def verify_webhook(_conn), do: {:error, :unsupported_transport}

  @impl true
  def stream_capability, do: :raw

  @doc """
  The `:raw` tier's stream callback — a deliberate drop (see the moduledoc).
  Its job is to OWN the streaming decision, not to stream: with it the gateway
  never builds a draft or block engine, so one delegation produces exactly one
  delivered answer. `:history_tainted` alone goes on to the session, fenced
  like the answer it comes before.
  """
  @impl true
  def build_raw_stream_callback(%Message{} = message) do
    route = route(message)

    fn
      :history_tainted -> notify(route, {:provenance, :history_tainted})
      _event -> :ok
    end
  end

  @impl true
  def build_activity_callback(%Message{} = message) do
    route = route(message)
    fn event -> notify(route, {:activity, event}) end
  end

  @impl true
  def build_turn_result(%Message{} = message) do
    route = route(message)
    fn outcome -> notify(route, {:turn_result, outcome}) end
  end

  @doc """
  The turn-result callback exclusively owns terminal error delivery: a failed
  turn must reach the session as a typed result it can speak in its own words,
  never as the gateway's canned chat sentence delivered as if it were the answer.
  """
  @impl true
  def terminal_error_capability, do: :turn_result

  @impl true
  def build_text_reply(%Message{chat_id: call_id} = message) do
    opts = [{@turn_opt, fence(message)}]
    fn text -> send_message(call_id, text, opts) end
  end

  @impl true
  def build_media_reply(%Message{chat_id: call_id} = message) do
    opts = [{@turn_opt, fence(message)}]
    fn media_part -> send_media(call_id, media_part, opts) end
  end

  @doc """
  Route one delegation answer to the Live session that asked for it.

  The fence travels in `opts` under `turn_opt/0`, because a call outlives its
  delegations and an answer must name the one it belongs to. A call without it
  cannot be placed and is refused rather than guessed at.
  """
  @impl true
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  @spec send_message(String.t(), String.t(), Channel.send_opts()) :: :ok | {:error, term()}
  def send_message(call_id, text, opts \\ []) when is_binary(call_id) and is_binary(text) do
    route = {call_id, Keyword.get(opts, @turn_opt)}
    {result, duration_us} = Telemetry.timed_us(fn -> notify(route, {:reply, text}) end)
    ChannelTelemetry.emit_message(:voice, :outbound, 1, duration_us)

    result
  end

  @doc """
  Refuse an attachment: the Live wire carries audio and text only, so there is
  no surface to deliver bytes on. The refusal is returned (never raised, never
  silently dropped) so the turn's ledger records that nothing was delivered and
  the canned empty-completion path still closes the turn honestly.
  """
  @impl true
  @spec send_media(String.t(), Reply.media_part()) :: {:error, :unsupported_in_voice}
  @spec send_media(String.t(), Reply.media_part(), Channel.send_opts()) ::
          {:error, :unsupported_in_voice}
  def send_media(call_id, media_part, _opts \\ [])
      when is_binary(call_id) and is_map(media_part) do
    Logger.warning(
      "voice adapter refusing a #{inspect(Map.get(media_part, :kind))} attachment for " <>
        "call #{call_id}: the Live wire carries no media"
    )

    {:error, :unsupported_in_voice}
  end

  # --- Routing ---

  defp route(%Message{chat_id: call_id} = message), do: {call_id, fence(message)}

  defp fence(%Message{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, :voice_call) do
      %{call_uuid: call_uuid, delegation_id: delegation_id, revision: revision} ->
        {call_uuid, delegation_id, revision}

      _absent ->
        nil
    end
  end

  # The session's route first, the detached owner's second (M56 §4.6). The
  # owner registers before the session releases its own, so one of the two
  # always holds the route of a task being handed over.
  defp notify({call_id, {call_uuid, delegation_id, revision}} = route, payload)
       when is_binary(call_id) and is_binary(call_uuid) and is_binary(delegation_id) and
              is_integer(revision) do
    case Registry.lookup(@registry, {call_id, delegation_id}) do
      [{_session, entry}] -> to_session(route, entry, payload)
      [] -> to_detached(route, payload)
    end
  end

  # A message with no fence was not built by the bridge, so there is no
  # delegation this could belong to. Refuse loudly instead of broadcasting.
  defp notify({call_id, _missing}, payload) do
    Logger.error(
      "voice adapter refusing #{elem(payload, 0)} for #{inspect(call_id)}: no delegation fence"
    )

    {:error, :missing_delegation_fence}
  end

  # A session can release its route between that lookup and the send, as it
  # hands the task over, and then exit without reading the event. So when the
  # route is gone after the send, the event also goes to the detached owner:
  # an event can reach it twice, never not at all, and it takes the first.
  defp to_session({call_id, {_call_uuid, delegation_id, _revision}} = route, entry, payload) do
    delivered = deliver(route, entry, payload)

    case Registry.lookup(@registry, {call_id, delegation_id}) do
      [_held] ->
        delivered

      [] ->
        _also = to_detached(route, payload)
        delivered
    end
  end

  defp to_detached({call_id, {call_uuid, delegation_id, _revision}} = route, payload) do
    case Registry.lookup(@registry, Detached.route(call_uuid, delegation_id)) do
      [{_owner, entry}] -> deliver(route, entry, payload)
      [] -> drop(call_id, delegation_id, payload, :call_closed)
    end
  end

  defp deliver(
         {_call_id, {_uuid, _id, revision}},
         %{revision: revision, callbacks: callbacks},
         payload
       ),
       do: dispatch(callbacks, payload)

  defp deliver({call_id, {_uuid, delegation_id, _revision}}, %{revision: _superseded}, payload),
    do: drop(call_id, delegation_id, payload, :superseded_revision)

  # The delivered answer IS the delegation's result: the gateway delivers text
  # exactly once per turn (a blank completion still delivers its canned retry),
  # so `{:completed}` below carries nothing this has not already reported.
  defp dispatch(%{result: result}, {:reply, text}) when is_function(result, 1) do
    _ = result.({:ok, text})
    :ok
  end

  defp dispatch(%{activity: activity}, {:activity, event}) when is_function(activity, 1) do
    _ = activity.(event)
    :ok
  end

  defp dispatch(%{history_tainted: tainted}, {:provenance, :history_tainted})
       when is_function(tainted, 0) do
    _ = tainted.()
    :ok
  end

  defp dispatch(%{result: result}, {:turn_result, {:cancelled}}) when is_function(result, 1) do
    _ = result.({:cancelled})
    :ok
  end

  # The RAW reason is stringified here, at the one layer that holds Core's
  # sentence vocabulary: the session speaks the vendor's own words rather than a
  # bare `exit_1`-shaped atom nobody can diagnose.
  defp dispatch(%{result: result}, {:turn_result, {:failed, reason}})
       when is_function(result, 1) do
    _ = result.({:error, TurnRunner.error_reply(reason)})
    :ok
  end

  defp dispatch(_callbacks, {:turn_result, {:completed}}), do: :ok

  defp drop(call_id, delegation_id, payload, reason) do
    Logger.debug(
      "voice adapter dropping #{elem(payload, 0)} for #{call_id}/#{delegation_id}: #{reason}"
    )

    {:error, reason}
  end
end
