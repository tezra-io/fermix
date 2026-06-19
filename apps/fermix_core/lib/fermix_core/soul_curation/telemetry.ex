defmodule FermixCore.SoulCuration.Telemetry do
  @moduledoc """
  Lifecycle telemetry for `/soul review` draft runs.

  A soul-curation draft is a single bounded provider call issued from inside a
  channel command, *before* any turn `session_id` exists (commands dispatch in
  `Gateway.ingest`, ahead of `TurnRunner`). Without these bookends its
  `provider.call` event would be an orphaned LLM call with no run to correlate
  to — exactly what `docs/TELEMETRY_CONTRACT.md` forbids. So the draft mints its
  own `session_id` and these events bracket the run, carrying the same
  `session_id` the provider call is stamped with, so the whole draft reassembles
  into one trace (mirrors `FermixCore.Jobs.Telemetry`).

  `apply`/`revert`/`reset` are DB+file mutations, not provider runs, so they get
  no session and emit none of these events. The proposed persona text is gated
  behind `Telemetry.capture_content?/0` (off by default).
  """

  alias FermixCore.Telemetry

  @run_start_event [:fermix, :soul_curation, :run_start]
  @run_complete_event [:fermix, :soul_curation, :run_complete]
  @run_error_event [:fermix, :soul_curation, :run_error]

  @trace_event_definitions [
    %{
      event: @run_start_event,
      trace_event: "soul_curation_run_start",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @run_complete_event,
      trace_event: "soul_curation_run_complete",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @run_error_event,
      trace_event: "soul_curation_run_error",
      trace_type: :agent_event,
      agent_field: :agent
    }
  ]

  @typedoc """
  The command-scoped run identity threaded through `propose/2`.
  """
  @type run_meta :: %{
          required(:session_id) => String.t(),
          required(:mode) => :review | :suggest,
          optional(:parent_session) => String.t() | nil,
          optional(:with_context) => boolean(),
          optional(:instruction) => String.t() | nil
        }

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @spec run_start(run_meta()) :: :ok
  def run_start(meta) when is_map(meta) do
    metadata =
      meta
      |> base_metadata()
      |> maybe_put_content(:input, Map.get(meta, :instruction))

    execute(@run_start_event, %{}, metadata)
  end

  @spec run_complete(run_meta(), map()) :: :ok
  def run_complete(meta, result) when is_map(meta) and is_map(result) do
    metadata =
      meta
      |> base_metadata()
      |> Map.put(:status, Map.fetch!(result, :status))
      |> Map.merge(Map.take(result, [:route, :byte_delta, :line_delta, :suspect]))
      |> maybe_put_content(:output, Map.get(result, :diff))

    execute(@run_complete_event, run_measurements(result), metadata)
  end

  @spec run_error(run_meta(), term()) :: :ok
  def run_error(meta, reason) when is_map(meta) do
    metadata =
      meta
      |> base_metadata()
      |> Map.put(:status, "error")
      |> Map.put(:error, format_error(reason))

    execute(@run_error_event, %{count: 1}, metadata)
  end

  defp base_metadata(meta) do
    %{
      agent: "soul_curation",
      session_id: Map.fetch!(meta, :session_id),
      parent_session: Map.get(meta, :parent_session),
      mode: Map.get(meta, :mode),
      with_context: Map.get(meta, :with_context, false)
    }
  end

  defp run_measurements(result) do
    %{
      byte_delta: Map.get(result, :byte_delta, 0),
      line_delta: Map.get(result, :line_delta, 0)
    }
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

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

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
