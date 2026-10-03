defmodule FermixChannels.Channels.Companion do
  @moduledoc """
  Channel adapter for the local companion socket (`FERMIX_HOME/companion.sock`),
  the Mac app's chat.

  Trust comes from the transport, a 0600 socket owned by the daemon's user, so
  the registry marks this channel `:local_operator` and a turn from it runs the
  ordinary agent loop as the owner, with history keyed on the `companion`
  channel. Its durable timeline is the companion timeline the phone shares.

  The adapter owns no socket. It writes to the timeline through
  `Companion.Output` (the same writes and events the mobile adapter makes) and
  broadcasts the logical events to every connection watching the profile,
  through the `registry/0` those connections join after their handshake. A row
  it writes reaches the phones too (`Companion.Fanout`); an approval stays on
  this socket, the only transport its token resolves from. A turn's replies
  and its ending go through `Companion.Turns`, which writes and announces them
  only once the queue fires the turn's outcome.

  The stream tier is `:raw`: the gateway hands the turn `build_raw_stream_callback/1`
  verbatim. The loop's stream events are cumulative snapshots, so the callback
  relays each snapshot and every connection sends its own client the suffix it
  has not written yet; a client that connects mid-turn gets the text so far as
  its first delta. `turn_started` goes out when the loop starts.

  During a Live call in the chat a turn may end with no reply (M56 §4.4): a
  snapshot that could still become the sentinel is held back, so such a turn
  never shows a draft, and the runner's `:silent_reply` tells `Turns` the turn
  ends that way.
  """

  @behaviour FermixChannels.Gateway.Channel

  require Logger

  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.Fanout
  alias FermixChannels.Companion.Output
  alias FermixChannels.Companion.Turns
  alias FermixChannels.Gateway.Channel
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Agents.LiveCallTurn
  alias FermixCore.Companion.Protocol
  alias FermixCore.Companion.Timeline
  alias FermixCore.Reply
  alias FermixCore.Telemetry

  @channel "companion"
  @profile "main"
  @registry FermixChannels.Companion.Registry

  @typedoc """
  A decoded `msg` or `command`. `:caller` is who connected, as
  `Companion.Connection` placed the socket's peer: absent on the phone's
  requests and on a request recovered at boot.
  """
  @type event :: %{
          required(:type) => String.t(),
          required(:payload) => map(),
          optional(:caller) => FermixCore.SocketPeer.caller()
        }

  @doc "The channel string this adapter answers to."
  @spec channel() :: String.t()
  def channel, do: @channel

  @doc "The duplicate-keys Registry each connection joins under its profile."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc "The Gateway conversation a profile's companion turns run in."
  @spec conversation_key(String.t()) :: {String.t(), String.t(), :root}
  def conversation_key(profile_id) when is_binary(profile_id), do: {@channel, profile_id, :root}

  @doc """
  The owner's chat: the conversation the Mac app's turns run in, and the one a
  Live call's hand-offs join unless the call is private (M56 §4.1). Named here,
  where the channel and its profile live, so Core never spells either.
  """
  @spec chat_conversation_key() :: {String.t(), String.t(), :root}
  def chat_conversation_key, do: conversation_key(@profile)

  @doc """
  Whether every client watching the owner's chat now reads server event
  `type`, each connection known by the version its hello declared; true with
  none attached. A turn may end with no reply (`turn_done`) only while this
  holds, or a version 1 client would show it as thinking (M56 §6).
  """
  @spec every_client_reads?(String.t()) :: boolean()
  def every_client_reads?(type) when is_binary(type) do
    needs = Protocol.server_event_version(type)

    @registry
    |> Registry.lookup(@profile)
    |> Enum.all?(fn {_connection, version} -> is_integer(version) and version >= needs end)
  end

  @doc "Normalize a decoded `msg` or `command` into a gateway message."
  @spec parse_event(event()) :: {:ok, [Message.t()]} | {:error, term()}
  def parse_event(event) do
    {result, duration_us} = Telemetry.timed_us(fn -> do_parse_event(event) end)
    ChannelTelemetry.emit_parse(:companion, result, duration_us)
    result
  end

  defp do_parse_event(%{type: "msg", payload: payload} = event) when is_map(payload) do
    with {:ok, profile} <- profile(payload),
         {:ok, client_id} <- required(payload, "client_msg_id"),
         {:ok, text} <- binary(payload, "text"),
         :ok <- no_attachments(payload) do
      {:ok, [message(client_id, profile, text, "msg", event)]}
    end
  end

  defp do_parse_event(%{type: "command", payload: payload} = event) when is_map(payload) do
    with {:ok, profile} <- profile(payload),
         {:ok, client_id} <- required(payload, "client_msg_id"),
         {:ok, command} <- command_text(payload) do
      {:ok, [message(client_id, profile, command, "command", event)]}
    end
  end

  defp do_parse_event(%{type: type}) when is_binary(type),
    do: {:error, {:unsupported_event, type}}

  defp do_parse_event(_event), do: {:error, :invalid_event}

  @doc """
  Send one logical event to every connection watching `profile_id` in
  `registry` (the one connections join by default). A profile nobody is
  watching is not an error: the timeline already holds what matters.
  """
  @spec broadcast(String.t(), map(), atom()) :: :ok
  def broadcast(profile_id, event, registry \\ @registry)
      when is_binary(profile_id) and is_map(event) and is_atom(registry) do
    dispatch(registry, profile_id, {:companion_event, event})
  end

  @impl true
  def parse_webhook(_params), do: {:error, :unsupported_transport}

  @impl true
  def verify_webhook(_conn), do: {:error, :unsupported_transport}

  @impl true
  def stream_capability, do: :raw

  @impl true
  def terminal_error_capability, do: :turn_result

  @impl true
  def build_raw_stream_callback(%Message{chat_id: profile_id} = message) do
    turn_id = turn_id(message)
    started = Output.turn_started(profile_id, turn_id, client_message_id(message))

    fn
      {:session_started, _session_id} ->
        broadcast(profile_id, started)

      {:iteration_started, _iteration} ->
        stream(profile_id, turn_id, :reset)

      {kind, text} when kind in [:text_delta, :text_done] ->
        relay(profile_id, turn_id, text)

      :silent_reply ->
        Turns.silent(message)

      _reasoning_or_other ->
        :ok
    end
  end

  @impl true
  def build_text_reply(%Message{} = message) do
    fn text -> Turns.reply(message, text) end
  end

  @impl true
  def build_media_reply(%Message{reply_target: profile_id} = message) do
    opts = reply_opts(message)
    fn media -> send_media(profile_id, media, opts) end
  end

  # A provider call is not a tool: `tool_event` is a tool's lifecycle, named,
  # never the model call that picks it. The turn's thinking state already
  # reaches the client through `turn_started` and the first `text_delta`.
  @impl true
  def build_activity_callback(%Message{} = message) do
    turn_id = turn_id(message)

    fn
      :provider_start -> :ok
      :provider_response -> :ok
      event -> broadcast(message.chat_id, Output.tool_event(turn_id, event))
    end
  end

  @impl true
  def build_turn_result(%Message{} = message) do
    fn outcome ->
      with {:ok, _settled} <- Turns.outcome(message, outcome), do: :ok
    end
  end

  @impl true
  def send_approval(%Message{} = message, text, token)
      when is_binary(text) and is_binary(token) do
    send_approval(message, %{kind: :sandbox, text: text, token: token})
  end

  @doc """
  Deliver a kind-aware approval card with exact approve and deny routes, to
  this socket's connections alone: its token resolves only from here (M19
  §9.5). It is kept until it resolves or expires, for a client that connects
  later.
  """
  @impl true
  @spec send_approval(Message.t(), map()) :: :ok | {:error, term()}
  def send_approval(%Message{} = message, %{kind: kind, text: text, token: token} = spec)
      when kind in [:sandbox, :soul] and is_binary(text) and is_binary(token) do
    Approvals.announce(Approvals.server(), message.chat_id, Output.approval(spec), :companion)
  end

  @doc """
  Write one reply or delivery to the timeline and announce it. A request's
  output is fenced by its attempt, a proactive delivery is deduplicated by its
  key, and anything else (a scheduled job's result) is a plain row; whether or
  not a client is connected, the row is the delivery.
  """
  @impl true
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  @spec send_message(String.t(), String.t(), Channel.send_opts()) :: :ok | {:error, term()}
  def send_message(profile_id, text, opts \\ [])
      when is_binary(profile_id) and is_binary(text) and is_list(opts) do
    {result, duration_us} =
      Telemetry.timed_us(fn ->
        with :ok <- validate_profile(profile_id),
             {:ok, {status, row}} <-
               Output.persist_text(store(), profile_id, text, Map.new(opts)) do
          announce_written(status, profile_id, row)
          {:ok, status}
        end
      end)

    emit_outbound(result, duration_us)
  end

  @doc """
  Attachments do not travel on this socket in version 1, so a media reply is
  refused rather than written as a row the client could never fetch.
  """
  @impl true
  @spec send_media(String.t(), Reply.media_part()) :: :ok | {:error, term()}
  @spec send_media(String.t(), Reply.media_part(), Channel.send_opts()) :: :ok | {:error, term()}
  def send_media(profile_id, media, opts \\ [])
      when is_binary(profile_id) and is_map(media) and is_list(opts) do
    {:error, :unsupported_media}
  end

  # A row written here is no turn's completion (a slash command's answer, a
  # delivery), so it is announced as a `row`, not a `text_done`, to every
  # watcher of the profile, each wire in its own shape; a row the store
  # deduplicated was announced when it was created.
  defp announce_written(:created, profile, row),
    do: Fanout.announce(profile, Output.row(profile, row))

  defp announce_written(:existing, _profile, _row), do: :ok

  # One durable timeline row is one delivered outbound message; a row the store
  # deduplicated was counted when it was created.
  defp emit_outbound({:ok, :created}, duration_us) do
    ChannelTelemetry.emit_message(:companion, :outbound, 1, duration_us)
  end

  defp emit_outbound({:ok, :existing}, _duration_us), do: :ok
  defp emit_outbound({:error, reason}, _duration_us), do: {:error, reason}

  # A snapshot that could still become the sentinel waits for the next one: a
  # turn that ends silently never shows a draft, and one that does not loses
  # nothing, since the next snapshot, or its `text_done`, carries the text.
  defp relay(profile_id, turn_id, text) when is_binary(text) do
    if LiveCallTurn.sentinel_prefix?(text),
      do: :ok,
      else: stream(profile_id, turn_id, {:snapshot, text})
  end

  defp stream(profile_id, turn_id, update),
    do: dispatch(@registry, profile_id, {:companion_stream, turn_id, update})

  defp dispatch(registry, profile_id, message) do
    Registry.dispatch(registry, profile_id, fn entries ->
      Enum.each(entries, fn {pid, _value} -> send(pid, message) end)
    end)
  end

  defp message(client_id, profile, text, request_type, event) do
    metadata = %{
      client_msg_id: client_id,
      companion_request_type: request_type,
      turn_id: "turn-" <> client_id
    }

    Message.new!(%{
      id: client_id,
      content: text,
      sender: "Companion owner",
      channel: @channel,
      chat_id: profile,
      reply_target: profile,
      metadata: put_caller(metadata, event),
      attachments: []
    })
  end

  # Who connected, as the connection read it off the socket's peer
  # (`FermixCore.SocketPeer`), never from the client's payload: a process the
  # daemon started is the agent, and nobody watches a detached one, so
  # `TurnRunner.computer_use_origin/1` labels either turn unattended (SIDE-V1).
  defp put_caller(metadata, %{caller: caller})
       when caller in [:daemon_descendant, :detached, :independent],
       do: Map.put(metadata, :caller, caller)

  defp put_caller(_metadata, %{caller: other}),
    do: raise(ArgumentError, "unknown companion caller #{inspect(other)}")

  defp put_caller(metadata, _event), do: metadata

  @doc "The send options a reply to `message` carries: its turn, request and attempt."
  @spec reply_opts(Message.t()) :: keyword()
  def reply_opts(%Message{} = message),
    do: [
      turn_id: turn_id(message),
      in_reply_to: client_message_id(message),
      attempt: request_attempt(message)
    ]

  defp turn_id(%Message{metadata: metadata}), do: Map.get(metadata, :turn_id) || new_turn_id()

  defp client_message_id(%Message{} = message),
    do: Map.get(message.metadata, :client_msg_id) || message.id

  defp request_attempt(%Message{metadata: metadata}), do: Map.get(metadata, :companion_attempt)

  defp profile(payload) do
    with {:ok, profile} <- required(payload, "profile_id"),
         :ok <- validate_profile(profile) do
      {:ok, profile}
    end
  end

  defp validate_profile(@profile), do: :ok
  defp validate_profile(_profile), do: {:error, :unsupported_profile}

  defp no_attachments(%{"attach_ids" => []}), do: :ok
  defp no_attachments(_payload), do: {:error, :attachments_unsupported}

  defp command_text(payload) do
    with {:ok, name} <- required(payload, "name"),
         true <- Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) do
      args = Map.get(payload, "args", "")

      if is_binary(args),
        do: {:ok, String.trim("/#{name} #{args}")},
        else: {:error, :invalid_command}
    else
      _other -> {:error, :invalid_command}
    end
  end

  defp required(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_field, key}}
    end
  end

  defp binary(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:invalid_field, key}}
    end
  end

  @doc "The timeline this channel writes through (a test injects another)."
  @spec store() :: module()
  def store, do: Application.get_env(:fermix_channels, :companion_store, Timeline)

  defp new_turn_id, do: "turn-#{System.unique_integer([:positive, :monotonic])}"
end
