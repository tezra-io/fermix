defmodule FermixCore.Harness.Telemetry do
  @moduledoc """
  Lifecycle telemetry for coding-harness runs (`codex`/`claude`, local/cloud).

  A harness run executes a vendor CLI in isolation with its own session, so like
  scheduled jobs its `provider.call`/`tool.exec` spans are only loosely
  identifiable without bookend events. These four events bracket the run and
  carry its `session_id` (`"harness_" <> run_id`) — the same `session_id` the
  run's provider/tool events carry — so the whole run reassembles into one trace.

  The spawning turn/cron session rides as `origin_session_id` **correlation
  metadata**, never as a `parent_session`: each harness run is its own root
  trace. A detached run finishing after its origin turn already closed must not
  nest into (or resurrect) the origin's trace and mint a broken second root — see
  `docs/design/CODING_HARNESS_ORCHESTRATION.md` §11 (H7 fix).

  The prompt and final response are attached only when content capture is
  enabled. The events also route into `FermixCore.Trace` as `agent_event` rows,
  so harness runs are visible in the JSONL trace stream with or without Opik.
  """

  alias FermixCore.Telemetry

  @run_start_event [:fermix, :harness, :run_start]
  @run_complete_event [:fermix, :harness, :run_complete]
  @run_error_event [:fermix, :harness, :run_error]
  @progress_event [:fermix, :harness, :progress]

  @trace_event_definitions [
    %{
      event: @run_start_event,
      trace_event: "harness_run_start",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @run_complete_event,
      trace_event: "harness_run_complete",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @run_error_event,
      trace_event: "harness_run_error",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @progress_event,
      trace_event: "harness_progress",
      trace_type: :agent_event,
      agent_field: :agent
    }
  ]

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @doc """
  Opens a run's trace. `max_duration_ms` bounds the Opik sweep floor so a
  long-but-alive run is never force-closed mid-flight; `prompt` is attached as
  `:input` only when content capture is enabled.
  """
  @spec run_start(map(), String.t() | nil, non_neg_integer() | nil) :: :ok
  def run_start(run, prompt \\ nil, max_duration_ms \\ nil) when is_map(run) do
    metadata =
      run
      |> base_metadata()
      |> maybe_put_content(:input, prompt)
      |> Map.put(:max_duration_ms, max_duration_ms)

    execute(@run_start_event, %{}, metadata)
  end

  @doc """
  Closes a run's trace as completed. `status`/`reason`/`exit_code`/`usage` are
  read from the (terminalized) run row; `output` is attached only when content
  capture is enabled.
  """
  @spec run_complete(map(), String.t() | nil) :: :ok
  def run_complete(run, output \\ nil) when is_map(run) do
    metadata =
      run
      |> base_metadata()
      |> Map.put(:status, Map.get(run, :status, "completed"))
      |> Map.put(:reason, Map.get(run, :reason))
      |> Map.put(:exit_code, Map.get(run, :exit_code))
      |> Map.put(:usage, Map.get(run, :usage))
      |> maybe_put_content(:output, output)

    execute(@run_complete_event, %{duration_ms: run_duration_ms(run)}, metadata)
  end

  @doc """
  Closes a run's trace as errored, carrying the terminal error class (e.g.
  `"protocol"`, `"timeout"`, `"run_crashed"`).
  """
  @spec run_error(map(), String.t()) :: :ok
  def run_error(run, error_class) when is_map(run) and is_binary(error_class) do
    metadata =
      run
      |> base_metadata()
      |> Map.put(:status, Map.get(run, :status, "failed"))
      |> Map.put(:reason, Map.get(run, :reason))
      |> Map.put(:error, error_class)

    execute(@run_error_event, %{count: 1, duration_ms: run_duration_ms(run)}, metadata)
  end

  @doc """
  Emits a liveness/progress point for a still-running run. `fields` carries the
  optional `:phase` label plus `:events`/`:framing_errors` counters.
  """
  @spec progress(map(), map()) :: :ok
  def progress(run, fields \\ %{}) when is_map(run) and is_map(fields) do
    metadata =
      run
      |> base_metadata()
      |> Map.put(:phase, stringify(Map.get(fields, :phase)))

    measurements =
      compact_map(%{
        events: Map.get(fields, :events),
        framing_errors: Map.get(fields, :framing_errors)
      })

    execute(@progress_event, measurements, metadata)
  end

  defp base_metadata(run) do
    run_id = fetch_id!(run)

    %{
      agent: "harness:#{stringify(Map.get(run, :vendor))}",
      run_id: run_id,
      session_id: "harness_" <> run_id,
      vendor: stringify(Map.get(run, :vendor)),
      rail: stringify(Map.get(run, :rail)),
      origin_kind: stringify(Map.get(run, :origin_kind)),
      origin_session_id: Map.get(run, :origin_session_id)
    }
  end

  defp fetch_id!(run) do
    case Map.fetch(run, :id) do
      {:ok, id} when is_binary(id) ->
        id

      _other ->
        raise ArgumentError,
              "harness telemetry requires a run with a binary :id, got: #{inspect(run)}"
    end
  end

  defp maybe_put_content(metadata, key, value) do
    if Telemetry.capture_content?() do
      case Telemetry.preview(value) do
        nil -> metadata
        preview -> Map.put(metadata, key, preview)
      end
    else
      metadata
    end
  end

  defp run_duration_ms(run) do
    case {Map.get(run, :started_at), Map.get(run, :completed_at)} do
      {%DateTime{} = started, %DateTime{} = completed} ->
        DateTime.diff(completed, started, :millisecond)

      _other ->
        0
    end
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: inspect(value)

  defp execute(event, measurements, metadata) do
    :telemetry.execute(event, measurements, compact_map(metadata))
  end

  defp compact_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end
end
