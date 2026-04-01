defmodule FermixCore.Trace do
  @moduledoc """
  Writes structured JSONL traces to `~/.fermix/traces/YYYY-MM-DD/`.

  Each trace type gets its own file: `llm_call.jsonl`, `tool_exec.jsonl`, etc.
  File handles are cached per {date, type} and cleaned up on date rollover.
  """

  use GenServer

  @valid_types [:llm_call, :tool_exec, :agent_event, :channel_msg, :error]

  @type trace_type :: :llm_call | :tool_exec | :agent_event | :channel_msg | :error

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
    {handle, state} = ensure_handle(state, type)
    IO.write(handle, Jason.encode!(entry) <> "\n")
    {:noreply, state}
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

  defp ensure_handle(state, type) do
    today = Date.utc_today()
    key = {today, type}

    case Map.fetch(state.handles, key) do
      {:ok, handle} ->
        {handle, state}

      :error ->
        state = close_stale_handles(state, today)
        handle = open_trace_file(state.base_dir, today, type)
        {handle, put_in(state, [:handles, key], handle)}
    end
  end

  defp open_trace_file(base_dir, date, type) do
    dir = Path.join(base_dir, Date.to_iso8601(date))
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{type}.jsonl")
    {:ok, handle} = File.open(path, [:append, :utf8])
    handle
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
