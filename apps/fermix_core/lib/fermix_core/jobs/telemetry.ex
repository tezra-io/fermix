defmodule FermixCore.Jobs.Telemetry do
  @moduledoc """
  Lifecycle telemetry for scheduled-job runs.

  A scheduled run executes the agent loop in isolation, so without these events
  its LLM/tool calls are only loosely identifiable by an agent-name prefix.
  These events bracket the run and carry its `session_id`, `job_id`, and
  `run_id` — the same `session_id` the run's `provider.call`/`tool.exec` events
  carry — so the whole run reassembles into one trace. The task prompt and final
  response are attached only when content capture is enabled.

  The events also route into `FermixCore.Trace` as `agent_event` rows, so
  scheduled runs are visible in the JSONL trace stream with or without Opik.
  """

  alias FermixCore.Telemetry

  @run_start_event [:fermix, :job, :run_start]
  @run_complete_event [:fermix, :job, :run_complete]
  @run_error_event [:fermix, :job, :run_error]

  @trace_event_definitions [
    %{
      event: @run_start_event,
      trace_event: "job_run_start",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @run_complete_event,
      trace_event: "job_run_complete",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @run_error_event,
      trace_event: "job_run_error",
      trace_type: :agent_event,
      agent_field: :agent
    }
  ]

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @spec run_start(map(), map(), map()) :: :ok
  def run_start(job, run, loop_input) do
    metadata = job |> base_metadata(run) |> maybe_put_input(loop_input)
    execute(@run_start_event, %{}, metadata)
  end

  @spec run_complete(map(), map(), map()) :: :ok
  def run_complete(job, run, result) do
    metadata =
      job
      |> base_metadata(run)
      |> Map.put(:status, "ok")
      |> maybe_put_output(result)

    measurements = %{
      duration_ms: run_duration_ms(run),
      iterations: Map.get(result, :iterations, 0),
      total_tokens: Map.get(result, :total_tokens, 0)
    }

    execute(@run_complete_event, measurements, metadata)
  end

  @spec run_error(map(), map(), String.t(), term()) :: :ok
  def run_error(job, run, status, error) when is_binary(status) do
    metadata =
      job
      |> base_metadata(run)
      |> Map.put(:status, status)
      |> Map.put(:error, format_error(error))

    execute(@run_error_event, %{count: 1, duration_ms: run_duration_ms(run)}, metadata)
  end

  defp base_metadata(job, run) do
    %{
      agent: "scheduled:#{job.id}",
      job_id: job.id,
      run_id: run.id,
      session_id: run.session_id,
      name: Map.get(job, :name),
      schedule_kind: Map.get(job, :schedule_kind),
      schedule_expr: Map.get(job, :schedule_expr),
      trigger: Map.get(run, :trigger)
    }
  end

  defp maybe_put_input(metadata, loop_input) do
    maybe_put_content(metadata, :input, Map.get(loop_input, :prompt_snapshot))
  end

  defp maybe_put_output(metadata, result) do
    maybe_put_content(metadata, :output, Map.get(result, :response))
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

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)

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
