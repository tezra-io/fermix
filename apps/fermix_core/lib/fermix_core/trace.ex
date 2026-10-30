defmodule FermixCore.Trace do
  @moduledoc """
  Writes structured JSONL traces to `<home>/traces/YYYY-MM-DD/`, one folder
  per UTC day.

  Each trace type gets its own file: `llm_call.jsonl`, `tool_exec.jsonl`, etc.
  File handles are cached per {date, type} and cleaned up on date rollover.

  **A trace never stops the engine** (M75 L14). Trace is an early child of
  core's `:rest_for_one` supervisor: a crash here restarts every child after
  it, and on a full disk the restarts repeat until core exits. So an entry it
  cannot encode, a day's file it cannot make or open, or a line the disk
  refuses (`:enospc`) is dropped, never raised. A failure to open or write is
  logged once, when it starts; the entries dropped after it are counted, not
  logged. Every new entry tries again (a refused write closes its file, so the
  next entry opens it afresh), and the first one written ends the failure
  with one line naming how many were dropped. A day's file that cannot be
  closed is logged.

  **Retention.** A pass of `FermixCore.Trace.Retention` (which states the
  bounds: days of age and total size, oldest days first) runs when Trace
  starts and every hour, after the files of earlier days are closed, so the
  days it removes free their space. `timer_enabled: false` (a test tree) runs
  none and plans none; a `:retention` message runs one. The clock (`:today`)
  and the opening of a day's file (`:open`) are injected for tests.
  """

  use GenServer

  alias FermixCore.Trace.Retention

  require Logger

  @valid_types [:llm_call, :tool_exec, :agent_event, :channel_msg, :error, :sandbox_event]
  @retention_every_ms 3_600_000

  # The exception classes `Jason.encode!/1` raises on un-encodable input: bad
  # UTF-8 (EncodeError) and a value with no `Jason.Encoder` — a PID/ref/fun or a
  # struct without one (Protocol.UndefinedError when protocols are consolidated,
  # UndefinedFunctionError otherwise). Trace must never crash (it is a
  # rest_for_one cascade root), so the encode boundary rescues exactly these.
  @encode_errors [Jason.EncodeError, Protocol.UndefinedError, UndefinedFunctionError]

  @type trace_type ::
          :llm_call | :tool_exec | :agent_event | :channel_msg | :error | :sandbox_event

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {init_opts, opts} = Keyword.split(opts, [:base_dir, :today, :open, :timer_enabled])
    {name, server_opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, [name: name] ++ server_opts)
  end

  @spec record(trace_type(), String.t() | atom(), map(), keyword()) :: :ok
  def record(type, agent, data, opts \\ [])
      when type in @valid_types and (is_binary(agent) or is_atom(agent)) and is_map(data) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.cast(server, {:record, type, to_string(agent), data})
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) when is_list(opts) do
    state = %{
      base_dir: Keyword.get_lazy(opts, :base_dir, &default_base_dir/0),
      today: Keyword.get(opts, :today, &Date.utc_today/0),
      open: Keyword.get(opts, :open, &open_append/1),
      timer_enabled: Keyword.get(opts, :timer_enabled, true),
      handles: %{},
      failing: nil
    }

    case state.timer_enabled do
      true -> {:ok, state, {:continue, :retention}}
      false -> {:ok, state}
    end
  end

  @impl true
  def handle_continue(:retention, state), do: {:noreply, retention_pass(state)}

  @impl true
  def handle_info(:retention, state), do: {:noreply, retention_pass(state)}

  # What `GenServer`'s default does, which defining `handle_info/2` replaces:
  # a stray message must not crash the cascade root.
  def handle_info(message, state) do
    Logger.warning("Trace ignored an unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:record, type, agent, data}, state) do
    entry = build_entry(type, agent, data)

    case ensure_handle(state, type) do
      {:ok, key, state} -> {:noreply, write_entry(state, key, entry)}
      {:error, path, reason, state} -> {:noreply, failed(state, "open #{path}", reason)}
    end
  end

  @impl true
  def terminate(_reason, state) do
    close_handles(state.base_dir, state.handles)
    :ok
  end

  # --- Private ---

  defp build_entry(type, agent, data) do
    normalized = Map.new(data, fn {k, v} -> {to_string(k), v} end)

    system_fields = %{
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "type" => Atom.to_string(type),
      "agent" => agent
    }

    Map.merge(normalized, system_fields)
  end

  # Trace is a `rest_for_one` ancestor of the agent and job supervisors, so a
  # crash here cascade-restarts them. An entry must therefore never raise.
  # Invalid UTF-8 in a captured value (e.g. a non-UTF-8 byte in tool output) is
  # the common cause, so scrub binary leaves and retry once before giving up;
  # anything still unencodable is logged and dropped, not raised.
  defp write_entry(state, {_date, type} = key, entry) do
    case encode_line(entry) do
      {:ok, line} ->
        write_line(state, key, line)

      {:error, reason} ->
        Logger.warning("Trace dropped #{type} entry: #{reason}")
        state
    end
  end

  # `:file.write/2` returns the disk's refusal, where `IO.write/2` raises it.
  # A refused write closes the file, so the next entry opens it afresh: a
  # handle whose file server died answers every later write `:terminated`.
  defp write_line(state, key, line) do
    case :file.write(Map.fetch!(state.handles, key), line) do
      :ok ->
        written(state)

      {:error, reason} ->
        state
        |> close_handle(key)
        |> failed("write #{trace_path(state.base_dir, key)}", reason)
    end
  end

  # One failure runs from the first open or write Trace cannot make to the
  # next entry it writes: logged when it starts and when it ends, with the
  # entries dropped in between counted, never logged one by one.
  defp failed(%{failing: nil} = state, what, reason) do
    Logger.error(
      "Trace cannot #{what}: #{describe(reason)}. Trace entries are dropped, and counted, " <>
        "until one is written again; every new entry tries again."
    )

    %{state | failing: %{reason: reason, dropped: 1}}
  end

  defp failed(%{failing: failing} = state, _what, _reason),
    do: %{state | failing: %{failing | dropped: failing.dropped + 1}}

  defp written(%{failing: nil} = state), do: state

  defp written(%{failing: %{reason: reason, dropped: dropped}} = state) do
    Logger.warning(
      "Trace writes again in #{state.base_dir} after dropping #{entries(dropped)} " <>
        "(#{describe(reason)})"
    )

    %{state | failing: nil}
  end

  defp entries(1), do: "1 entry"
  defp entries(count), do: "#{count} entries"

  defp describe(reason), do: "#{:file.format_error(reason)} (#{inspect(reason)})"

  defp encode_line(entry) do
    {:ok, Jason.encode!(entry) <> "\n"}
  rescue
    _exception in @encode_errors ->
      try do
        {:ok, Jason.encode!(scrub(entry)) <> "\n"}
      rescue
        exception in @encode_errors -> {:error, Exception.message(exception)}
      end
  end

  defp scrub(value) when is_binary(value), do: String.replace_invalid(value)
  defp scrub(value) when is_list(value), do: Enum.map(value, &scrub/1)
  defp scrub(%_struct{} = value), do: value
  defp scrub(%{} = value), do: Map.new(value, fn {k, v} -> {scrub(k), scrub(v)} end)
  defp scrub(value), do: value

  defp ensure_handle(state, type) do
    today = state.today.()
    key = {today, type}

    case Map.has_key?(state.handles, key) do
      true ->
        {:ok, key, state}

      false ->
        state = close_stale_handles(state, today)
        open_trace_file(state, key)
    end
  end

  # The day's folder and file are made here, so a full disk can refuse
  # either: both come back as the open's failure.
  defp open_trace_file(state, key) do
    path = trace_path(state.base_dir, key)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, handle} <- state.open.(path) do
      {:ok, key, put_in(state, [:handles, key], handle)}
    else
      {:error, reason} -> {:error, path, reason, state}
    end
  end

  # Binary, so a write is the bytes given and `:file.write/2` reports a
  # refusal instead of raising it.
  defp open_append(path), do: File.open(path, [:append, :binary])

  defp trace_path(base_dir, {date, type}),
    do: Path.join([base_dir, Date.to_iso8601(date), "#{type}.jsonl"])

  defp close_stale_handles(state, today) do
    {stale, current} =
      Map.split_with(state.handles, fn {{date, _type}, _handle} -> date != today end)

    close_handles(state.base_dir, stale)
    %{state | handles: current}
  end

  defp close_handle(state, key) do
    {handle, handles} = Map.pop!(state.handles, key)
    close_handles(state.base_dir, %{key => handle})
    %{state | handles: handles}
  end

  defp close_handles(base_dir, handles) do
    Enum.each(handles, fn {key, handle} ->
      case File.close(handle) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("Trace could not close #{trace_path(base_dir, key)}: #{describe(reason)}")
      end
    end)
  end

  # Closes the files of earlier days first: a removed file still open would
  # keep its space until it closes.
  defp retention_pass(state) do
    today = state.today.()
    state = close_stale_handles(state, today)

    state.base_dir
    |> Retention.prune(today)
    |> log_retention(state.base_dir)

    plan_retention(state)
  end

  defp plan_retention(%{timer_enabled: true} = state) do
    Process.send_after(self(), :retention, @retention_every_ms)
    state
  end

  defp plan_retention(state), do: state

  defp log_retention(%{removed: removed, refused: refused}, base_dir) do
    log_removed(removed, base_dir)

    Enum.each(refused, fn {path, reason} ->
      Logger.error("Trace retention left #{path} in place: #{describe(reason)}")
    end)
  end

  defp log_removed([], _base_dir), do: :ok

  defp log_removed(removed, base_dir) do
    Logger.info(
      "Trace retention removed #{length(removed)} day folder(s) from #{base_dir}, " <>
        "#{List.first(removed)} to #{List.last(removed)}"
    )
  end

  defp default_base_dir do
    Path.join(System.user_home!(), ".fermix/traces")
  end
end
