defmodule FermixCore.Meetings.Telemetry do
  @moduledoc """
  Lifecycle telemetry for meeting runs.

  A meeting is its own run kind: it opens a transcription stream and a
  summarizer call of its own, and both carry the meeting's `session_id`, so
  these bookends are what reassemble a meeting into one trace. `phase/4` records
  every state-machine transition — the only durable record of *why* a meeting
  ended the way it did, since the row keeps only the final status.

  The meeting URL and title are attached only under `capture_content?/0`: a
  meeting URL can embed a passcode, and a title is participant-authored.

  The events also route into `FermixCore.Trace` as `agent_event` rows, so
  meetings are visible in the JSONL trace stream with or without Opik.
  """

  alias FermixCore.Telemetry

  @run_start_event [:fermix, :meeting, :run_start]
  @run_complete_event [:fermix, :meeting, :run_complete]
  @run_error_event [:fermix, :meeting, :run_error]
  @phase_event [:fermix, :meeting, :phase]

  @max_error_chars 500

  @trace_event_definitions [
    %{
      event: @run_start_event,
      trace_event: "meeting_run_start",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @run_complete_event,
      trace_event: "meeting_run_complete",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @run_error_event,
      trace_event: "meeting_run_error",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @phase_event,
      trace_event: "meeting_phase",
      trace_type: :agent_event,
      agent_field: :agent
    }
  ]

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @doc """
  Opens the run.

  `meeting` carries the correlation fields (`:id`, `:platform`, `:session_id`,
  `:parent_session`, `:origin`). The content-gated fields are passed as opts
  (`:url`, `:title`) so the gate is visible at the call site rather than hidden
  inside a map the caller also uses for other things.
  """
  @spec run_start(map(), keyword()) :: :ok
  def run_start(meeting, opts \\ []) when is_map(meeting) and is_list(opts) do
    metadata =
      meeting
      |> base_metadata()
      |> maybe_put_content(:url, Keyword.get(opts, :url))
      |> maybe_put_content(:title, Keyword.get(opts, :title))
      # Sweep floor for the Opik exporter: without it a quiet meeting root falls
      # back to the 120s idle TTL and gets force-closed mid-call.
      |> Map.put(:max_duration_ms, Keyword.get(opts, :max_duration_ms))

    execute(@run_start_event, %{}, metadata)
  end

  @doc """
  Closes a delivered run with its counters
  (`duration_ms`, `segments`, `words`, `participants_peak`).
  """
  @spec run_complete(map(), map()) :: :ok
  def run_complete(meeting, measurements) when is_map(meeting) and is_map(measurements) do
    metadata =
      meeting
      |> base_metadata()
      |> Map.put(:status, "delivered")

    execute(@run_complete_event, measurements, metadata)
  end

  @doc """
  Closes a failed run under its terminal status string.

  The run's elapsed time comes from the meeting map's `:duration_ms` — a failing
  Session has already measured it, and there are no counters to report.
  """
  @spec run_error(map(), String.t(), term()) :: :ok
  def run_error(meeting, terminal_status, error)
      when is_map(meeting) and is_binary(terminal_status) do
    metadata =
      meeting
      |> base_metadata()
      |> Map.put(:status, terminal_status)
      |> Map.put(:error, format_error(error))

    measurements = %{count: 1, duration_ms: Map.get(meeting, :duration_ms, 0)}

    execute(@run_error_event, measurements, metadata)
  end

  @doc """
  Records one state-machine transition.

  `reason` is an atom (an end cause or a failure kind), never free text — a
  phase row is a dimension to group by, not a message to read.
  """
  @spec phase(map(), atom(), atom(), atom() | nil) :: :ok
  def phase(meeting, from, to, reason \\ nil)
      when is_map(meeting) and is_atom(from) and is_atom(to) and is_atom(reason) do
    metadata =
      meeting
      |> base_metadata()
      |> Map.put(:from, Atom.to_string(from))
      |> Map.put(:to, Atom.to_string(to))
      |> Map.put(:reason, stringify(reason))

    execute(@phase_event, %{count: 1}, metadata)
  end

  defp base_metadata(meeting) do
    id = Map.fetch!(meeting, :id)

    %{
      agent: "meeting:#{id}",
      meeting_id: id,
      platform: stringify(Map.get(meeting, :platform)),
      session_id: Map.get(meeting, :session_id),
      parent_session: Map.get(meeting, :parent_session),
      origin: stringify(Map.get(meeting, :origin))
    }
  end

  defp maybe_put_content(metadata, _key, nil), do: metadata

  defp maybe_put_content(metadata, key, value) do
    if Telemetry.capture_content?(), do: Map.put(metadata, key, value), else: metadata
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value

  defp format_error(error) when is_binary(error), do: truncate(error)
  defp format_error(error), do: error |> inspect() |> truncate()

  defp truncate(text) do
    if String.length(text) <= @max_error_chars,
      do: text,
      else: String.slice(text, 0, @max_error_chars)
  end

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
