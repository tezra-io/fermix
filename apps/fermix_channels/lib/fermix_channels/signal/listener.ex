defmodule FermixChannels.Signal.Listener do
  @moduledoc """
  Periodically polls `signal-cli` for inbound messages and dispatches normalized
  direct-message events through the shared runtime.
  """

  use GenServer

  require Logger

  alias FermixChannels.Dispatcher
  alias FermixChannels.Signal
  alias FermixCore.Agents.MainAgent

  @default_poll_interval_ms 1_000
  @default_error_backoff_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      poll_interval: Keyword.get(opts, :poll_interval, @default_poll_interval_ms),
      error_backoff_ms: Keyword.get(opts, :error_backoff_ms, @default_error_backoff_ms),
      agent: Keyword.get(opts, :agent, MainAgent),
      agent_server: Keyword.get(opts, :agent_server, MainAgent),
      client: Keyword.get(opts, :client),
      client_opts: Keyword.get(opts, :client_opts, [])
    }

    schedule_next_poll(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    case Signal.receive_messages(client: state.client, client_opts: state.client_opts) do
      {:ok, entries} ->
        process_entries(entries, state)
        schedule_next_poll(state)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Signal listener error: #{inspect(reason)}")
        schedule_error_retry(state)
        {:noreply, state}
    end
  end

  defp schedule_next_poll(%{poll_interval: :manual}), do: :ok

  defp schedule_next_poll(%{poll_interval: poll_interval}) when is_integer(poll_interval) do
    Process.send_after(self(), :poll, poll_interval)
  end

  defp schedule_error_retry(state) do
    unless state.poll_interval == :manual do
      Process.send_after(self(), :poll, state.error_backoff_ms)
    end
  end

  defp process_entries(entries, state) do
    Enum.each(entries, fn entry ->
      case Signal.parse_receive_entry(entry,
             client: state.client,
             client_opts: state.client_opts
           ) do
        {:ok, messages} when messages != [] ->
          Dispatcher.dispatch(messages,
            channel: Signal,
            agent: state.agent,
            agent_server: state.agent_server
          )

        _ ->
          :ok
      end
    end)
  end
end
