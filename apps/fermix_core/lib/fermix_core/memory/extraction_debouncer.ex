defmodule FermixCore.Memory.ExtractionDebouncer do
  @moduledoc """
  Coalesces rapid background memory extraction requests per agent conversation.
  """

  use GenServer

  require Logger

  alias FermixCore.Memory.Config
  alias FermixCore.Memory.Extractor

  @type conversation_key :: {String.t(), String.t(), atom() | String.t() | integer()}
  @type request_opts :: keyword()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec request(request_opts(), keyword()) :: :ok
  def request(opts, request_opts \\ []) when is_list(opts) and is_list(request_opts) do
    server = Keyword.get(request_opts, :server, __MODULE__)
    key = extraction_key(opts)

    GenServer.cast(server, {:request_extraction, key, opts})
  end

  @impl true
  def init(opts) do
    state = %{
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      extractor_module: Keyword.get(opts, :extractor_module, Extractor),
      extraction_debounce_ms: Config.extraction_debounce_ms(opts),
      timers: %{},
      versions: %{},
      payloads: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:request_extraction, key, opts}, state) do
    debounce_ms = request_debounce_ms(opts, state)

    state =
      if debounce_ms == 0 do
        start_immediate_extraction(state, key, opts)
      else
        schedule_extraction(state, key, opts, debounce_ms)
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:run_extraction, key, version}, state) do
    case {Map.get(state.versions, key), Map.get(state.payloads, key)} do
      {^version, opts} when is_list(opts) ->
        state =
          state
          |> clear_pending(key)
          |> start_extraction(opts)

        {:noreply, state}

      _stale_or_missing ->
        {:noreply, state}
    end
  end

  defp extraction_key(opts) do
    {Keyword.fetch!(opts, :agent_id), Keyword.fetch!(opts, :conversation_key)}
  end

  defp request_debounce_ms(opts, state) do
    if Keyword.has_key?(opts, :extraction_debounce_ms) or
         Keyword.has_key?(opts, :extraction_debounce_seconds) do
      Config.extraction_debounce_ms(opts)
    else
      state.extraction_debounce_ms
    end
  end

  defp start_immediate_extraction(state, key, opts) do
    state
    |> cancel_pending_timer(key)
    |> clear_pending(key)
    |> start_extraction(opts)
  end

  defp schedule_extraction(state, key, opts, debounce_ms) do
    state = cancel_pending_timer(state, key)
    version = Map.get(state.versions, key, 0) + 1
    timer_ref = Process.send_after(self(), {:run_extraction, key, version}, debounce_ms)

    state
    |> put_in([:timers, key], timer_ref)
    |> put_in([:versions, key], version)
    |> put_in([:payloads, key], opts)
  end

  defp cancel_pending_timer(state, key) do
    case Map.pop(state.timers, key) do
      {nil, _timers} ->
        state

      {timer_ref, timers} ->
        Process.cancel_timer(timer_ref)
        %{state | timers: timers}
    end
  end

  defp clear_pending(state, key) do
    state
    |> update_in([:timers], &Map.delete(&1, key))
    |> update_in([:payloads], &Map.delete(&1, key))
  end

  defp start_extraction(state, opts) do
    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           run_extraction(state.extractor_module, opts)
         end) do
      {:ok, _pid} ->
        state

      {:error, reason} ->
        Logger.error("failed to start debounced background extraction: #{inspect(reason)}")
        state
    end
  end

  defp run_extraction(extractor_module, opts) do
    case extractor_module.extract(opts) do
      {:ok, _data} ->
        :ok

      {:error, reason} ->
        Logger.error("background extraction failed: #{inspect(reason)}")
        :ok
    end
  end
end
