defmodule FermixCore.Agents.LifecycleTelemetry do
  @moduledoc """
  Emits the explicit M2 lifecycle telemetry contract used by Trace and tests.

  Full runtime delegation is still landing, so these helpers pin the lifecycle
  event names and fields at the currently available telemetry seams.
  """

  alias FermixCore.Telemetry

  @agent_start_event [:fermix, :agent, :start]
  @agent_stop_event [:fermix, :agent, :stop]
  @agent_task_start_event [:fermix, :agent, :task_start]
  @agent_task_complete_event [:fermix, :agent, :task_complete]
  @skill_invoke_event [:fermix, :skill, :invoke]
  @skill_journal_write_event [:fermix, :skill, :journal_write]
  # These supervisor events are part of the public telemetry contract for direct
  # subscribers and tests only. They are intentionally not routed into Trace, so
  # they must stay out of `@trace_event_definitions` and `trace_event_name/1`.
  @supervisor_spawn_event [:fermix, :supervisor, :spawn]
  @supervisor_exit_event [:fermix, :supervisor, :exit]

  # Only events that become `:agent_event` trace rows belong here. Keeping this
  # list separate from the full emitted contract avoids implying supervisor
  # lifecycle events are trace-backed today.
  @trace_event_definitions [
    %{
      event: @agent_start_event,
      trace_event: "agent_start",
      trace_type: :agent_event,
      agent_field: :name
    },
    %{
      event: @agent_stop_event,
      trace_event: "agent_stop",
      trace_type: :agent_event,
      agent_field: :name
    },
    %{
      event: @agent_task_start_event,
      trace_event: "agent_task_start",
      trace_type: :agent_event,
      agent_field: :name
    },
    %{
      event: @agent_task_complete_event,
      trace_event: "agent_task_complete",
      trace_type: :agent_event,
      agent_field: :name
    },
    %{
      event: @skill_invoke_event,
      trace_event: "skill_invoke",
      trace_type: :agent_event,
      agent_field: :skill
    },
    %{
      event: @skill_journal_write_event,
      trace_event: "skill_journal_write",
      trace_type: :agent_event,
      agent_field: :skill
    }
  ]

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @spec trace_event_name([atom()]) :: String.t()
  def trace_event_name(event) do
    @trace_event_definitions
    |> Enum.find_value(fn definition ->
      if definition.event == event, do: definition.trace_event
    end)
    |> case do
      nil -> raise ArgumentError, "unknown lifecycle telemetry event: #{inspect(event)}"
      trace_event -> trace_event
    end
  end

  @spec agent_start(String.t(), String.t() | atom(), String.t(), keyword()) :: :ok
  def agent_start(name, role, session_id, opts \\ []) do
    execute(@agent_start_event, %{}, agent_metadata(name, role, session_id, opts))
  end

  @spec agent_stop(
          String.t(),
          String.t() | atom(),
          String.t(),
          String.t() | atom(),
          non_neg_integer(),
          keyword()
        ) ::
          :ok
  def agent_stop(name, role, session_id, reason, duration_ms, opts \\ []) do
    execute(
      @agent_stop_event,
      %{duration_ms: duration_ms},
      agent_metadata(name, role, session_id, opts)
      |> Map.put(:reason, normalize_string(reason))
    )
  end

  @spec agent_task_start(String.t(), String.t() | atom(), String.t(), String.t(), keyword()) ::
          :ok
  def agent_task_start(name, role, session_id, task_summary, opts \\ []) do
    execute(
      @agent_task_start_event,
      %{},
      agent_metadata(name, role, session_id, opts)
      |> Map.put(:task_summary, captured_content(task_summary))
    )
  end

  @spec agent_task_complete(
          String.t(),
          String.t() | atom(),
          String.t(),
          boolean(),
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) :: :ok
  def agent_task_complete(name, role, session_id, success, duration_ms, iterations, opts \\ []) do
    execute(
      @agent_task_complete_event,
      %{duration_ms: duration_ms, iterations: iterations},
      agent_metadata(name, role, session_id, opts)
      |> Map.put(:success, success)
    )
  end

  @spec skill_invoke(
          String.t(),
          String.t(),
          String.t(),
          boolean(),
          non_neg_integer(),
          String.t(),
          keyword()
        ) :: :ok
  def skill_invoke(
        skill,
        session_id,
        task_summary,
        success,
        duration_ms,
        parent_session,
        opts \\ []
      ) do
    execute(
      @skill_invoke_event,
      %{duration_ms: duration_ms},
      %{
        skill: skill,
        session_id: session_id,
        task_summary: captured_content(task_summary),
        success: success,
        parent: Keyword.get(opts, :parent),
        parent_session: parent_session
      }
    )
  end

  @spec skill_journal_write(String.t(), String.t(), String.t(), non_neg_integer()) :: :ok
  def skill_journal_write(skill, session_id, path, bytes) do
    execute(
      @skill_journal_write_event,
      %{bytes: bytes},
      %{skill: skill, session_id: session_id, path: path}
    )
  end

  @spec supervisor_spawn(String.t(), boolean(), String.t()) :: :ok
  def supervisor_spawn(name, persistent, parent) do
    execute(
      @supervisor_spawn_event,
      %{},
      %{name: name, persistent: persistent, parent: parent}
    )
  end

  @spec supervisor_exit(String.t(), String.t() | atom(), boolean()) :: :ok
  def supervisor_exit(name, reason, was_monitored) do
    execute(
      @supervisor_exit_event,
      %{},
      %{name: name, reason: normalize_string(reason), was_monitored: was_monitored}
    )
  end

  defp agent_metadata(name, role, session_id, opts) do
    %{
      name: name,
      role: normalize_string(role),
      session_id: session_id,
      parent: Keyword.get(opts, :parent),
      parent_session: Keyword.get(opts, :parent_session)
    }
  end

  # A task summary is the leading text of the delegated prompt — the owner's own
  # words, and the same class of payload as the `input`/`output` previews that
  # `capture_content` governs (the Opik mapper in fact renders it AS the trace's
  # `input`). It therefore obeys the same switch instead of shipping regardless.
  # `compact_map/1` drops the key when this returns nil, so a lean trace keeps
  # its shape rather than carrying an empty string.
  defp captured_content(summary) do
    if Telemetry.capture_content?(), do: summary
  end

  defp execute(event, measurements, metadata) do
    :telemetry.execute(event, compact_map(measurements), compact_map(metadata))
  end

  defp compact_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: inspect(value)
end
