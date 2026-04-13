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

  @spec parse_input(String.t(), keyword()) :: {:ok, [Message.t()]} | {:error, :empty_input}
  def parse_input(input, opts \\ []) when is_binary(input) do
    content = String.trim(input)

    if content == "" do
      {:error, :empty_input}
    else
      sender = opts |> Keyword.get(:sender, default_sender()) |> to_string()

      message =
        Message.new!(%{
          id: message_id(),
          content: content,
          sender: sender,
          channel: @channel,
          chat_id: @channel,
          reply_target: @channel,
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

  @impl true
  def parse_webhook(_params), do: {:error, :unsupported_transport}

  @impl true
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

  defp message_id do
    "cli-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp default_sender do
    System.get_env("USER") || "operator"
  end
end
