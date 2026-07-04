defmodule FermixChannels.CLI do
  @moduledoc """
  Local CLI channel integration.

  CLI input is normalized into the same message contract as remote channels and
  can be dispatched through `FermixChannels.Dispatcher` into the gateway queue.
  """

  @behaviour FermixChannels.Gateway.Channel

  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Telemetry

  @channel "cli"
  # End-to-end wait for one CLI turn's reply. Aligned with the gateway's 300s
  # turn budget (`Gateway.Typing`) so a long turn — e.g. reasoning that then
  # renders an image (a 300s inner HTTP budget, see `Net.TimeoutPolicy`) — is
  # not clipped at the CLI before the daemon finishes.
  @default_timeout_ms 300_000

  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @spec parse_input(String.t(), keyword()) :: {:ok, [Message.t()]} | {:error, :empty_input}
  def parse_input(input, opts \\ []) when is_binary(input) do
    {result, duration_us} = Telemetry.timed_us(fn -> do_parse_input(input, opts) end)
    ChannelTelemetry.emit_parse(:cli, result, duration_us)
    maybe_emit_inbound_message(result, duration_us)
    result
  end

  defp do_parse_input(input, opts) do
    content = String.trim(input)
    media_parts = Keyword.get(opts, :media_parts, [])

    if content == "" and media_parts == [] do
      {:error, :empty_input}
    else
      sender = opts |> Keyword.get(:sender, default_sender()) |> to_string()
      session_id = opts |> Keyword.get(:session_id, @channel) |> to_string()

      message =
        Message.new!(%{
          id: message_id(),
          content: content,
          sender: sender,
          channel: @channel,
          chat_id: session_id,
          reply_target: session_id,
          metadata: %{source: :cli, user_id: "cli", chat_type: "private"},
          media_parts: media_parts
        })

      {:ok, [message]}
    end
  end

  @spec dispatch_input(String.t(), keyword()) :: :ok | {:error, :empty_input}
  def dispatch_input(input, opts \\ []) when is_binary(input) do
    with {:ok, messages} <- parse_input(input, opts) do
      Gateway.ingest(messages,
        channel: __MODULE__,
        agent: Keyword.get(opts, :agent, Queue),
        agent_server: Keyword.get(opts, :agent_server, Queue)
      )
    end
  end

  @spec dispatch_input_sync(String.t(), keyword()) ::
          {:ok, %{response: String.t(), session_id: String.t()}} | {:error, term()}
  def dispatch_input_sync(input, opts \\ []) when is_binary(input) do
    timeout_ms = Keyword.get(opts, :timeout_ms, default_timeout_ms())
    parent = self()
    ref = make_ref()

    # This captures the reply before daemon socket delivery. The local sync
    # path emits inbound telemetry through parse_input/2; no outbound channel
    # transport exists here.
    with {:ok, [message]} <- parse_input(input, opts),
         :ok <-
           Gateway.ingest([message],
             channel: __MODULE__,
             agent: Keyword.get(opts, :agent, Queue),
             agent_server: Keyword.get(opts, :agent_server, Queue),
             reply_fn: fn
               {:text, text} ->
                 send(parent, {ref, {:reply, text}})
                 :ok

               {:media, _media_part} ->
                 {:error, :media_unsupported}

               {:react, _emoji} ->
                 {:error, :reaction_unsupported}

               other ->
                 {:error, {:invalid_reply_part, other}}
             end
           ) do
      await_reply(ref, message.chat_id, timeout_ms)
    end
  end

  @impl true
  def parse_webhook(_params), do: {:error, :unsupported_transport}

  @impl true
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  @spec send_message(String.t(), String.t(), FermixChannels.Gateway.Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_message(_chat_id, text, _opts \\ []) when is_binary(text) do
    {_result, duration_us} = Telemetry.timed_us(fn -> IO.puts(text) end)
    ChannelTelemetry.emit_message(:cli, :outbound, 1, duration_us)

    :ok
  end

  @impl true
  @spec send_media(String.t(), FermixChannels.Gateway.Channel.media_part()) ::
          {:error, :media_unsupported}
  @spec send_media(
          String.t(),
          FermixChannels.Gateway.Channel.media_part(),
          FermixChannels.Gateway.Channel.send_opts()
        ) ::
          {:error, :media_unsupported}
  def send_media(_chat_id, _media_part, _opts \\ []), do: {:error, :media_unsupported}

  @impl true
  def build_text_reply(%Message{reply_target: reply_target}) do
    fn text -> send_message(reply_target, text, []) end
  end

  @impl true
  def build_media_reply(%Message{reply_target: reply_target}) do
    fn media_part -> send_media(reply_target, media_part, []) end
  end

  @impl true
  def verify_webhook(_conn), do: {:error, :unsupported_transport}

  defp await_reply(ref, session_id, timeout_ms) do
    receive do
      {^ref, {:reply, response}} when is_binary(response) ->
        {:ok, %{response: response, session_id: session_id}}

      {^ref, {:reply, response}} ->
        {:ok, %{response: inspect(response), session_id: session_id}}
    after
      timeout_ms ->
        {:error, :timeout}
    end
  end

  defp message_id do
    "cli-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp default_sender do
    System.get_env("USER") || "operator"
  end

  defp maybe_emit_inbound_message({:ok, messages}, duration_us) when messages != [] do
    ChannelTelemetry.emit_message(:cli, :inbound, length(messages), duration_us)
  end

  defp maybe_emit_inbound_message(_result, _duration_us), do: :ok
end
