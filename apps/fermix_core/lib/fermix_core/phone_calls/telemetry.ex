defmodule FermixCore.PhoneCalls.Telemetry do
  @moduledoc """
  Lifecycle telemetry for phone calls (M94 §11), the `Harness.Telemetry` and
  `Meetings.Telemetry` shape.

  A phone call is a run kind: it outlives the turn that asked for it, and its
  own backend turns and provider calls carry its `session_id`
  (`"phone_call_" <> call_id`), so these bookends reassemble one call into one
  trace. The requesting turn's session (the row's `parent_session`, kept
  apart from its request id) rides as `parent_session`, correlation
  only (Opik keeps the call its own root, as it does a meeting: the turn ships
  long before the call ends). `PhoneCalls.Manager` is the single emitter of all
  three: `run_start` once, when a call is admitted and its worker started, and
  one of `run_complete` / `run_error` when its terminal row is written.

  What reaches ordinary metadata is ids, state words and counters. The
  destination, the mandate, transcripts and credentials never do; the
  vendor's own failure words do, bounded, with anything that reads as a
  phone number replaced, so a provider message that quotes the dialed number
  does not carry it into a trace. Those words arrive already free of the API
  key and the trunk password: every vendor word, from the create and hang-up
  answers to whatever the sideband carries during the call, passes the one
  scrub in `OpenAILive` (`scrubber/1`) before it leaves the transport. The events also route into
  `FermixCore.Trace` as `agent_event` rows.
  """

  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.Text

  @run_start_event [:fermix, :phone_call, :run_start]
  @run_complete_event [:fermix, :phone_call, :run_complete]
  @run_error_event [:fermix, :phone_call, :run_error]

  # A run of digits long enough to be a phone number, with its separators.
  @number_pattern ~r/\+?\d[\d\s().-]{6,}\d/

  @trace_event_definitions [
    %{
      event: @run_start_event,
      trace_event: "phone_call_run_start",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @run_complete_event,
      trace_event: "phone_call_run_complete",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @run_error_event,
      trace_event: "phone_call_run_error",
      trace_type: :agent_event,
      agent_field: :agent
    }
  ]

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @doc "The call's own `session_id`, which its backend turns and provider calls carry too."
  @spec session_id(String.t()) :: String.t()
  def session_id(call_id) when is_binary(call_id) and call_id != "", do: "phone_call_" <> call_id

  @doc """
  Opens the call's trace. `max_duration_ms` is the Opik sweep floor, so a call
  on hold is never force-closed at the idle TTL.
  """
  @spec run_start(map(), non_neg_integer()) :: :ok
  def run_start(row, max_duration_ms)
      when is_map(row) and is_integer(max_duration_ms) and max_duration_ms >= 0 do
    metadata =
      row
      |> base_metadata()
      |> Map.put(:status, Map.get(row, :status))
      |> Map.put(:max_duration_ms, max_duration_ms)

    execute(@run_start_event, %{}, metadata)
  end

  @doc """
  Closes the call's trace from its terminal row: `run_complete` for a call
  that ended (whatever its outcome), `run_error` for one that failed or whose
  end is uncertain, carrying the failure word and the vendor's own message.
  """
  @spec run_end(map()) :: :ok
  def run_end(%{status: "ended"} = row) do
    metadata = row |> base_metadata() |> Map.merge(end_metadata(row))
    execute(@run_complete_event, end_measurements(row), metadata)
  end

  def run_end(%{status: status} = row) when is_binary(status) do
    metadata =
      row
      |> base_metadata()
      |> Map.merge(end_metadata(row))
      |> Map.put(:error, Map.get(row, :failure_reason) || status)

    execute(@run_error_event, Map.put(end_measurements(row), :count, 1), metadata)
  end

  defp base_metadata(row) do
    call_id = fetch_id!(row)

    %{
      agent: "phone_call:" <> call_id,
      call_id: call_id,
      session_id: session_id(call_id),
      parent_session: Map.get(row, :parent_session),
      origin_kind: Map.get(row, :origin_kind),
      model: Map.get(row, :model),
      carrier_profile: Map.get(row, :carrier_profile),
      authorization: Map.get(row, :authorization)
    }
  end

  defp end_metadata(row) do
    %{
      status: Map.get(row, :status),
      outcome: Map.get(row, :outcome),
      usage_state: Map.get(row, :usage_state),
      failure_reason: Map.get(row, :failure_reason),
      vendor_message: scrub(Map.get(row, :vendor_message))
    }
  end

  defp end_measurements(row) do
    %{
      duration_ms: duration_ms(row),
      voice_seconds: Map.get(row, :voice_seconds),
      core_turns: Map.get(row, :core_turns),
      dtmf_keys: Map.get(row, :dtmf_keys),
      cleanup_attempts: Map.get(row, :cleanup_attempts)
    }
    |> compact_map()
  end

  defp duration_ms(row) do
    case {Map.get(row, :created_at), Map.get(row, :ended_at)} do
      {%DateTime{} = from, %DateTime{} = to} -> max(DateTime.diff(to, from, :millisecond), 0)
      _incomplete -> 0
    end
  end

  defp scrub(nil), do: nil

  defp scrub(text) when is_binary(text) do
    text
    |> String.replace(@number_pattern, "[number]")
    |> Text.truncate_utf8(Limits.max_record_text_bytes())
  end

  defp fetch_id!(row) do
    case Map.fetch(row, :id) do
      {:ok, id} when is_binary(id) and id != "" ->
        id

      _other ->
        raise ArgumentError, "phone call telemetry needs a row with a binary :id"
    end
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
