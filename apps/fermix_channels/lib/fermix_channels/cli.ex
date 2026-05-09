defmodule FermixChannels.CLI do
  @moduledoc """
  Local CLI channel integration.

  CLI input is normalized into the same message contract as remote channels and
  can be dispatched through `FermixChannels.Dispatcher` into `MainAgent`.
  """

  @behaviour FermixChannels.Channel

  alias FermixChannels.Dispatcher
  alias FermixChannels.Message
  alias FermixCore.Agents.MainAgent

  @channel "cli"
  @default_timeout_ms 120_000

  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @spec parse_input(String.t(), keyword()) :: {:ok, [Message.t()]} | {:error, :empty_input}
  def parse_input(input, opts \\ []) when is_binary(input) do
    content = String.trim(input)

    if content == "" do
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
          metadata: %{source: :cli}
        })

      :telemetry.execute(
        [:fermix, :channel, :message],
        %{count: 1},
        %{channel: :cli, direction: :inbound}
      )

      {:ok, [message]}
    end
  end

  @spec dispatch_input(String.t(), keyword()) :: :ok | {:error, :empty_input}
  def dispatch_input(input, opts \\ []) when is_binary(input) do
    with {:ok, messages} <- parse_input(input, opts) do
      Dispatcher.dispatch(messages,
        channel: __MODULE__,
        agent: Keyword.get(opts, :agent, MainAgent),
        agent_server: Keyword.get(opts, :agent_server, MainAgent)
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
           Dispatcher.dispatch([message],
             channel: __MODULE__,
             agent: Keyword.get(opts, :agent, MainAgent),
             agent_server: Keyword.get(opts, :agent_server, MainAgent),
             reply_fn: fn text ->
               send(parent, {ref, {:reply, text}})
               :ok
             end
           ) do
      await_reply(ref, message.chat_id, timeout_ms)
    end
  end

  @impl true
  def parse_webhook(_params), do: {:error, :unsupported_transport}

  @impl true
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  @spec send_message(String.t(), String.t(), FermixChannels.Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_message(_chat_id, text, _opts \\ []) when is_binary(text) do
    IO.puts(text)

    :telemetry.execute(
      [:fermix, :channel, :message],
      %{count: 1},
      %{channel: :cli, direction: :outbound}
    )

    :ok
  end

  @impl true
  def build_reply(%Message{reply_target: reply_target}) do
    fn text -> send_message(reply_target, text, []) end
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
end
