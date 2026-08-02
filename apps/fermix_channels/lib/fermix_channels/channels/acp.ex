defmodule FermixChannels.Channels.Acp do
  @moduledoc """
  The ACP channel adapter (MILESTONE_29_ACP_AGENT_SURFACE.md §6.1).

  This module holds no state and owns no socket. It is the routing layer between
  the gateway's per-turn closures and the `Channels.Acp.Peer` that owns the
  client connection: every closure it builds looks the peer up in the session
  Registry by the message's `reply_target` (the ACP session id) and hands it a
  fenced event. The Peer decides what reaches the wire.

  Two facts shape the whole adapter:

  - **There is no webhook transport.** `parse_webhook/1` and `verify_webhook/1`
    refuse with `:unsupported_transport`; inbound arrives over the UDS listener.
  - **The stream tier is `:raw`** (§8.4). The gateway hands the turn
    `build_raw_stream_callback/1` verbatim — no draft engine, no block chunking —
    so the only bytes a client sees are the ones the Peer chose to write.

  Every closure carries the turn's fence sequence (minted by the Peer, carried on
  the inbound message's `metadata[:acp_turn]`), so an event that arrives after
  its turn was answered can be recognised as late and dropped rather than
  attributed to whatever turn is open now.
  """

  @behaviour FermixChannels.Gateway.Channel

  require Logger

  alias FermixChannels.Gateway.Channel
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Reply
  alias FermixCore.Telemetry

  @channel "acp"
  @registry FermixChannels.Channels.Acp.Registry
  @turn_opt :acp_turn
  # The fence value a detached (session-less) turn carries in place of a sequence.
  @detached_turn :detached

  @doc "The channel string this adapter answers to."
  @spec channel() :: String.t()
  def channel, do: @channel

  @doc "The unique-keys Registry mapping a session id to the Peer that owns it."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc "The send-opt key carrying a turn's fence sequence into `send_message/3`."
  @spec turn_opt() :: atom()
  def turn_opt, do: @turn_opt

  @doc """
  The fence value marking a turn whose ACP session is gone (a harness
  continuation, M29 §17.6(c)). Every closure it builds is a quiet no-op.
  """
  @spec detached_turn() :: atom()
  def detached_turn, do: @detached_turn

  @impl true
  def parse_webhook(_params), do: {:error, :unsupported_transport}

  @impl true
  def verify_webhook(_conn), do: {:error, :unsupported_transport}

  @impl true
  def stream_capability, do: :raw

  @impl true
  def build_raw_stream_callback(%Message{} = message) do
    route = route(message)
    fn event -> notify(route, {:stream, event}) end
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

  @impl true
  def build_text_reply(%Message{reply_target: session_id} = message) do
    opts = [{@turn_opt, turn_seq(message)}]
    fn text -> send_message(session_id, text, opts) end
  end

  @impl true
  def build_media_reply(%Message{reply_target: session_id} = message) do
    opts = [{@turn_opt, turn_seq(message)}]
    fn media_part -> send_media(session_id, media_part, opts) end
  end

  @doc """
  Route one text delivery to the session's Peer.

  The turn's fence sequence travels in `opts` under `turn_opt/0`, because a
  session outlives its turns and a delivery must name the turn it belongs to. A
  call without it cannot be placed and is refused rather than guessed at.
  """
  @impl true
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  @spec send_message(String.t(), String.t(), Channel.send_opts()) :: :ok | {:error, term()}
  def send_message(session_id, text, opts \\ [])
      when is_binary(session_id) and is_binary(text) do
    deliver(session_id, opts, {:text, text})
  end

  @doc """
  Route one attachment delivery to the session's Peer, which renders it as a
  text line — ACP image content blocks are a §14 deferral, and this surface
  never transfers bytes.
  """
  @impl true
  @spec send_media(String.t(), Reply.media_part()) :: :ok | {:error, term()}
  @spec send_media(String.t(), Reply.media_part(), Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_media(session_id, media_part, opts \\ [])
      when is_binary(session_id) and is_map(media_part) do
    deliver(session_id, opts, {:media, media_part})
  end

  # Outbound telemetry lives here, at the one point every reply part passes
  # through, exactly as the CLI transport emits its own (§10 — `Gateway.ingest`
  # does not emit these).
  defp deliver(session_id, opts, part) do
    route = {session_id, Keyword.get(opts, @turn_opt)}
    {result, duration_us} = Telemetry.timed_us(fn -> notify(route, {:reply, part}) end)
    ChannelTelemetry.emit_message(:acp, :outbound, 1, duration_us)

    result
  end

  defp route(%Message{reply_target: session_id} = message), do: {session_id, turn_seq(message)}

  defp turn_seq(%Message{metadata: metadata}) when is_map(metadata),
    do: Map.get(metadata, @turn_opt)

  defp notify({session_id, seq}, payload) when is_binary(session_id) and is_integer(seq) do
    case Registry.lookup(@registry, session_id) do
      [{peer, _value}] ->
        send(peer, {:acp_event, session_id, seq, payload})
        :ok

      [] ->
        Logger.debug(
          "ACP adapter dropping #{elem(payload, 0)}: session #{session_id} has no peer"
        )

        {:error, :peer_gone}
    end
  end

  # A detached turn (M29 §17.6(c)): a harness continuation re-ingested minutes
  # after its ACP session ended. Its deliverable is the model's own post with the
  # client's credentials, and the wire reply is best-effort-if-alive — so this is
  # a quiet, NAMED no-op rather than the `Logger.error` per stream delta the
  # no-fence clause below would produce. `nil` still means bug.
  defp notify({session_id, @detached_turn}, payload) do
    Logger.debug("ACP adapter dropping #{elem(payload, 0)}: turn for #{session_id} is detached")

    {:error, :detached_turn}
  end

  # A message with no fence sequence was not built by a Peer, so there is no
  # session turn this could belong to. Refuse loudly instead of broadcasting.
  defp notify({session_id, _missing}, payload) do
    Logger.error(
      "ACP adapter refusing #{elem(payload, 0)} for #{inspect(session_id)}: no turn sequence"
    )

    {:error, :missing_turn_sequence}
  end
end
