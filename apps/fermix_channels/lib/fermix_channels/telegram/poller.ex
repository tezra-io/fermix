defmodule FermixChannels.Telegram.Poller do
  @moduledoc """
  Long-polls Telegram's getUpdates API for incoming messages.

  Startup/backlog policy:
  - The first poll cycle is a zero-timeout startup probe.
  - Any updates already queued in Telegram when the poller starts are treated as stale backlog.
  - The poller advances its offset past that backlog without processing it.
  - This also applies when switching from webhook mode to polling: queued pre-switch
    updates are dropped, and only updates that arrive after the startup probe are processed.

  Reuses Telegram.parse_update/1 for message parsing and
  MainAgent.handle_message/1 for dispatch.
  """

  use GenServer

  require Logger

  alias FermixChannels.Telegram
  alias FermixCore.Agents.MainAgent

  @bot_api_base "https://api.telegram.org"
  @default_error_backoff_ms 5_000
  @startup_probe_timeout 0
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
      startup_phase: :drain_backlog,
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
  def handle_info(:poll, %{startup_phase: :drain_backlog} = state) do
    case probe_startup_backlog(state) do
      {:ok, updates, state} ->
        state =
          state
          |> advance_offset(updates)
          |> Map.put(:startup_phase, :polling)

        if state.poll_interval == :immediate do
          send(self(), :poll)
        end

        {:noreply, state}

      {:error, reason, state} ->
        Logger.error("Telegram poller startup probe error: #{inspect(reason)}")
        Process.send_after(self(), :poll, state.error_backoff_ms)
        {:noreply, state}
    end
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

  defp probe_startup_backlog(state) do
    get_updates(state, @startup_probe_timeout)
  end

  defp do_poll(state) do
    get_updates(state, @poll_timeout)
  end

  defp get_updates(state, timeout) do
    with {:ok, token} <- Telegram.get_bot_token() do
      url = "#{@bot_api_base}/bot#{token}/getUpdates"

      body = %{
        offset: state.offset,
        timeout: timeout,
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
