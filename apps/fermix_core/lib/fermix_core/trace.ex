defmodule FermixCore.Trace do
  @moduledoc """
  Writes structured JSONL traces to `~/.fermix/traces/YYYY-MM-DD/`.

  Each trace type gets its own file: `llm_call.jsonl`, `tool_exec.jsonl`, etc.
  File handles are cached per {date, type} and cleaned up on date rollover.
  """

  use GenServer

  require Logger

  @valid_types [:llm_call, :tool_exec, :agent_event, :channel_msg, :error, :sandbox_event]

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
    {base_dir, opts} = Keyword.pop(opts, :base_dir, default_base_dir())
    {name, server_opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, base_dir, [name: name] ++ server_opts)
  end

  @spec record(trace_type(), String.t() | atom(), map(), keyword()) :: :ok
  def record(type, agent, data, opts \\ [])
      when type in @valid_types and (is_binary(agent) or is_atom(agent)) and is_map(data) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.cast(server, {:record, type, to_string(agent), data})
  end

  # --- Server Callbacks ---

  @impl true
  def init(base_dir) when is_binary(base_dir) do
    {:ok, %{base_dir: base_dir, handles: %{}}}
  end

  @impl true
  def handle_cast({:record, type, agent, data}, state) do
    entry = build_entry(type, agent, data)

    case ensure_handle(state, type) do
      {:ok, handle, state} ->
        write_entry(handle, entry, type)
        {:noreply, state}

      {:error, reason, state} ->
        Logger.warning("Trace write failed for #{type}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    close_all_handles(state.handles)
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
  defp write_entry(handle, entry, type) do
    case encode_line(entry) do
      {:ok, line} -> IO.write(handle, line)
      {:error, reason} -> Logger.warning("Trace dropped #{type} entry: #{reason}")
    end
  end

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
    today = Date.utc_today()
    key = {today, type}

    case Map.fetch(state.handles, key) do
      {:ok, handle} ->
        {:ok, handle, state}

      :error ->
        state = close_stale_handles(state, today)

        case open_trace_file(state.base_dir, today, type) do
          {:ok, handle} ->
            {:ok, handle, put_in(state, [:handles, key], handle)}

          {:error, reason} ->
            {:error, reason, state}
        end
    end
  end

  defp open_trace_file(base_dir, date, type) do
    dir = Path.join(base_dir, Date.to_iso8601(date))

    with :ok <- File.mkdir_p(dir),
         {:ok, handle} <- File.open(Path.join(dir, "#{type}.jsonl"), [:append, :utf8]) do
      {:ok, handle}
    end
  end

  defp close_stale_handles(state, today) do
    {stale, current} =
      Map.split_with(state.handles, fn {{date, _type}, _handle} -> date != today end)

    close_all_handles(stale)
    %{state | handles: current}
  end

  defp close_all_handles(handles) do
    Enum.each(handles, fn {_key, handle} -> File.close(handle) end)
  end

  defp default_base_dir do
    Path.join(System.user_home!(), ".fermix/traces")
  end
end
