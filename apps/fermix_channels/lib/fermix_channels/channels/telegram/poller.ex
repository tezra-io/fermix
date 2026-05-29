defmodule FermixChannels.Channels.Telegram.Poller do
  @moduledoc """
  Long-polls Telegram's getUpdates API for incoming messages.

  Startup/backlog policy:
  - The first poll cycle is a zero-timeout startup probe.
  - Any updates already queued in Telegram when the poller starts are treated as stale backlog.
  - The poller advances its offset past that backlog without processing it.
  - This also applies when switching from webhook mode to polling: queued pre-switch
    updates are dropped, and only updates that arrive after the startup probe are processed.

  Reuses Telegram.parse_update/1 for message parsing and
  FermixChannels.Dispatcher for delivery.
  """

  use GenServer

  require Logger

  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Dispatcher
  alias FermixCore.Agents.MainAgent

  @bot_api_base "https://api.telegram.org"
  @default_error_backoff_ms 5_000
  @default_transient_backoff_ms 250
  @startup_probe_timeout 0
  @poll_timeout 50
  @receive_timeout_ms 60_000
  @transient_transport_errors [:closed, :timeout, :econnreset, :socket_closed_remotely]

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
      error_backoff_ms: Keyword.get(opts, :error_backoff_ms, @default_error_backoff_ms),
      transient_backoff_ms:
        Keyword.get(opts, :transient_backoff_ms, @default_transient_backoff_ms),
      agent: Keyword.get(opts, :agent, MainAgent),
      agent_server: Keyword.get(opts, :agent_server, MainAgent)
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
        log_poll_error("startup probe", reason)
        schedule_error_retry(state, reason)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    case do_poll(state) do
      {:ok, updates, state} ->
        process_updates(updates, state)
        state = advance_offset(state, updates)

        if state.poll_interval == :immediate do
          send(self(), :poll)
        end

        {:noreply, state}

      {:error, reason, state} ->
        log_poll_error("poll", reason)
        schedule_error_retry(state, reason)
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
        Req.new(url: url, method: :post, json: body, receive_timeout: @receive_timeout_ms)
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

  defp log_poll_error(context, reason) do
    if transient_transport_error?(reason) do
      Logger.warning("Telegram poller #{context} reconnecting after #{inspect(reason)}")
    else
      Logger.error("Telegram poller #{context} error: #{inspect(reason)}")
    end
  end

  defp schedule_error_retry(state, reason) do
    backoff =
      if transient_transport_error?(reason) do
        state.transient_backoff_ms
      else
        state.error_backoff_ms
      end

    Process.send_after(self(), :poll, backoff)
  end

  defp transient_transport_error?(%Req.TransportError{reason: reason})
       when reason in @transient_transport_errors,
       do: true

  defp transient_transport_error?(_reason), do: false

  defp process_updates(updates, state) do
    Enum.each(updates, fn update ->
      case Telegram.parse_update(update) do
        {:ok, messages} when messages != [] ->
          emit_inbound_telemetry(length(messages))
          handle_dispatch_result(messages, state)

        _ ->
          :ok
      end
    end)
  end

  defp emit_inbound_telemetry(count) do
    :telemetry.execute(
      [:fermix, :channel, :message],
      %{count: count},
      %{channel: :telegram, direction: :inbound}
    )
  end

  defp handle_dispatch_result(messages, state) do
    case Dispatcher.dispatch(messages,
           channel: Telegram,
           agent: state.agent,
           agent_server: state.agent_server
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Telegram poller dispatch failed: #{inspect(reason)}")
    end
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
