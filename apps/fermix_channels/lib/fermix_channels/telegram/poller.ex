defmodule FermixChannels.Telegram.Poller do
  @moduledoc """
  Long-polls Telegram's getUpdates API for incoming messages.

  Reuses Telegram.parse_update/1 for message parsing and
  MainAgent.handle_message/1 for dispatch.
  """

  use GenServer

  require Logger

  alias FermixChannels.Telegram
  alias FermixCore.Agents.MainAgent

  @bot_api_base "https://api.telegram.org"
  @default_error_backoff_ms 5_000
  @poll_timeout 30

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      offset: 0,
      req_options: Keyword.get(opts, :req_options, []),
      poll_interval: Keyword.get(opts, :poll_interval, :immediate),
      error_backoff_ms: Keyword.get(opts, :error_backoff_ms, @default_error_backoff_ms)
    }

    if state.poll_interval == :immediate do
      send(self(), :poll)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    case do_poll(state) do
      {:ok, updates, state} ->
        process_updates(updates)
        state = advance_offset(state, updates)

        if state.poll_interval == :immediate do
          send(self(), :poll)
        end

        {:noreply, state}

      {:error, reason, state} ->
        Logger.error("Telegram poller error: #{inspect(reason)}")
        Process.send_after(self(), :poll, state.error_backoff_ms)
        {:noreply, state}
    end
  end

  defp do_poll(state) do
    with {:ok, token} <- Telegram.get_bot_token() do
      url = "#{@bot_api_base}/bot#{token}/getUpdates"

      body = %{
        offset: state.offset,
        timeout: @poll_timeout,
        allowed_updates: ["message"]
      }

      result =
        Req.new(url: url, method: :post, json: body, receive_timeout: 35_000)
        |> Req.merge(state.req_options)
        |> Req.request()

      case result do
        {:ok, %{status: 200, body: %{"ok" => true, "result" => updates}}} ->
          {:ok, updates, state}

        {:ok, %{status: status, body: resp_body}} ->
          {:error, "Telegram API error #{status}: #{inspect(resp_body)}", state}

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp process_updates(updates) do
    Enum.each(updates, fn update ->
      case Telegram.parse_update(update) do
        {:ok, messages} when messages != [] ->
          :telemetry.execute(
            [:fermix, :channel, :message],
            %{count: length(messages)},
            %{channel: :telegram, direction: :inbound}
          )

          messages
          |> Telegram.build_agent_messages()
          |> Enum.each(&MainAgent.handle_message/1)

        _ ->
          :ok
      end
    end)
  end

  defp advance_offset(state, []), do: state

  defp advance_offset(state, updates) do
    max_id =
      updates
      |> Enum.map(& &1["update_id"])
      |> Enum.max()

    %{state | offset: max_id + 1}
  end
end
