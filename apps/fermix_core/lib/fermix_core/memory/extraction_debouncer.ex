defmodule FermixCore.Memory.ExtractionDebouncer do
  @moduledoc """
  Legacy throttled coalescer for background memory extraction.

  The live post-turn memory path now uses `FermixCore.Memory.Reviewer`.
  This module remains for explicit tests and legacy callers; it no longer
  reads application config. When a caller supplies a throttle option,
  requests inside that window are coalesced into a single scheduled run
  that fires when the window opens; the payload is updated on each request
  so the latest conversation state is the one that gets extracted.

  Within a fresh cycle the very first request is held back by a small
  internal coalesce window (`min(throttle, @default_coalesce_cap_ms)`) so
  bursts of messages arriving in quick succession all reach the extractor
  together rather than spawning a single-message extraction.

  With no throttle option, or with a zero throttle, extraction fires
  immediately on every request with no coalesce.
  """

  use GenServer

  require Logger

  alias FermixCore.Memory.Extractor

  @type conversation_key :: {String.t(), String.t(), atom() | String.t() | integer()}
  @type request_opts :: keyword()

  @default_coalesce_cap_ms 60_000

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
    throttle_ms = request_throttle_ms(opts)

    coalesce_ms =
      Keyword.get(opts, :min_coalesce_window_ms, min(throttle_ms, @default_coalesce_cap_ms))

    state = %{
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      extractor_module: Keyword.get(opts, :extractor_module, Extractor),
      extraction_throttle_ms: throttle_ms,
      min_coalesce_window_ms: coalesce_ms,
      timers: %{},
      versions: %{},
      payloads: %{},
      last_run_at: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:request_extraction, key, opts}, state) do
    throttle_ms = request_throttle_ms(opts, state)

    state =
      cond do
        throttle_ms == 0 -> start_immediate_extraction(state, key, opts)
        Map.has_key?(state.timers, key) -> update_payload(state, key, opts)
        true -> schedule_extraction(state, key, opts, throttle_ms)
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
          |> start_extraction(key, opts)

        {:noreply, state}

      _stale_or_missing ->
        {:noreply, state}
    end
  end

  defp extraction_key(opts) do
    {Keyword.fetch!(opts, :agent_id), Keyword.fetch!(opts, :conversation_key)}
  end

  defp request_throttle_ms(opts, state) do
    if Keyword.has_key?(opts, :extraction_debounce_ms) or
         Keyword.has_key?(opts, :extraction_debounce_seconds) do
      request_throttle_ms(opts)
    else
      state.extraction_throttle_ms
    end
  end

  defp request_throttle_ms(opts) do
    cond do
      Keyword.has_key?(opts, :extraction_debounce_ms) ->
        non_negative_integer!(Keyword.fetch!(opts, :extraction_debounce_ms))

      Keyword.has_key?(opts, :extraction_debounce_seconds) ->
        non_negative_integer!(Keyword.fetch!(opts, :extraction_debounce_seconds)) * 1_000

      true ->
        0
    end
  end

  defp non_negative_integer!(value) when is_integer(value) and value >= 0, do: value

  defp update_payload(state, key, opts) do
    put_in(state, [:payloads, key], opts)
  end

  defp start_immediate_extraction(state, key, opts) do
    state
    |> cancel_pending_timer(key)
    |> clear_pending(key)
    |> start_extraction(key, opts)
  end

  defp schedule_extraction(state, key, opts, throttle_ms) do
    now = monotonic_ms()
    coalesce_ms = min(state.min_coalesce_window_ms, throttle_ms)

    delay_ms =
      compute_delay_ms(Map.get(state.last_run_at, key), throttle_ms, coalesce_ms, now)

    version = (Map.get(state.versions, key) || 0) + 1
    timer_ref = Process.send_after(self(), {:run_extraction, key, version}, delay_ms)

    state
    |> put_in([:timers, key], timer_ref)
    |> put_in([:versions, key], version)
    |> put_in([:payloads, key], opts)
  end

  defp compute_delay_ms(nil, _throttle_ms, coalesce_ms, _now), do: coalesce_ms

  defp compute_delay_ms(last_run, throttle_ms, coalesce_ms, now) do
    max(coalesce_ms, last_run + throttle_ms - now)
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

  # Marks `last_run_at[key]` only when the task actually starts so a
  # supervisor-full error does not consume the throttle window.
  defp start_extraction(state, key, opts) do
    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           run_extraction(state.extractor_module, opts)
         end) do
      {:ok, _pid} ->
        put_in(state, [:last_run_at, key], monotonic_ms())

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

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
