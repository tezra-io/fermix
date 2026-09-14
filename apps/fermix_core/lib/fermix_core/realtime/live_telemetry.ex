defmodule FermixCore.Realtime.LiveTelemetry do
  @moduledoc """
  Single emitter for `[:fermix, :voice_live, ...]` — the GPT-Live call lifecycle.

  A Live call is its own run kind. The provider session holds the microphone,
  the voice and the clock, while every tool, memory lookup and model answer runs
  in a *separate* Fermix turn the call delegated to. Those turns carry their own
  `session_id` (`voice_delegation_<n>`) with `parent_session` set to this call's
  id, which is the only link between the two — so these bookends are what
  reassemble a call, its delegations and their spans into one trace.

  Two things are deliberately NOT here. The model turn and its tools ride the
  shared `FermixCore.Providers.Telemetry` / `FermixCore.Tools.Telemetry`
  emitters, so a Live delegation is priced and rendered exactly like any other
  turn. And spoken content — captions, transcript fragments, instructions —
  never reaches a field: `provider_error` carries the vendor's own bounded
  sentence and nothing else does.

  Voice is **duration-priced**: `call_stop` reports `voice_seconds` and integer
  `voice_cost_millicents`, never tokens. A Live minute is billed by the clock,
  so expressing it as tokens would invent a unit the invoice does not have.

  The events also route into `FermixCore.Trace` as `agent_event` rows, so a call
  is visible in the JSONL trace stream with or without Opik.
  """

  alias FermixCore.Telemetry

  @agent "voice_live"
  @engine "openai_live"

  @call_start_event [:fermix, :voice_live, :call_start]
  @session_started_event [:fermix, :voice_live, :session_started]
  @delegation_start_event [:fermix, :voice_live, :delegation_start]
  @delegation_stop_event [:fermix, :voice_live, :delegation_stop]
  @provider_error_event [:fermix, :voice_live, :provider_error]
  @call_stop_event [:fermix, :voice_live, :call_stop]

  @delegation_statuses ~w(completed failed cancelled)

  @trace_event_definitions [
    %{
      event: @call_start_event,
      trace_event: "voice_live_call_start",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @session_started_event,
      trace_event: "voice_live_session_started",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @delegation_start_event,
      trace_event: "voice_live_delegation_start",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @delegation_stop_event,
      trace_event: "voice_live_delegation_stop",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @provider_error_event,
      trace_event: "voice_live_provider_error",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @call_stop_event,
      trace_event: "voice_live_call_stop",
      trace_type: :agent_event,
      agent_field: :agent
    }
  ]

  @typedoc """
  The call's correlation fields. `session_id` is the call id and is required;
  everything else is dropped from the metadata when absent rather than emitted
  as nil. `provider_session_id` is unknown until `session.started` arrives.
  """
  @type meta :: %{
          required(:session_id) => String.t(),
          optional(:parent_session) => String.t(),
          optional(:device_id) => String.t(),
          optional(:model) => String.t(),
          optional(:voice) => String.t(),
          optional(:provider_session_id) => String.t()
        }

  @typedoc "One backend delegation's identity within the call."
  @type delegation :: %{
          required(:delegation_id) => String.t(),
          required(:revision) => pos_integer(),
          required(:turn_session_id) => String.t()
        }

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @doc """
  Opens the run, before the provider socket is even dialled.

  `max_duration_ms` is the call's own cap and becomes the Opik exporter's sweep
  floor: a Live call is silent between delegations for minutes at a time, so
  without it a quiet call is force-closed at the idle TTL and its `call_stop`
  mints a second, ledger-only root.
  """
  @spec call_start(meta(), pos_integer()) :: :ok
  def call_start(meta, max_duration_ms)
      when is_map(meta) and is_integer(max_duration_ms) and max_duration_ms > 0 do
    execute(@call_start_event, %{}, Map.put(base(meta), :max_duration_ms, max_duration_ms))
  end

  @doc """
  The provider accepted the session; `meta.provider_session_id` now names it.

  That id is the only handle a vendor-side investigation has, and it exists
  nowhere else in the trace — the call id is ours, not OpenAI's.
  """
  @spec session_started(meta()) :: :ok
  def session_started(meta) when is_map(meta) do
    execute(@session_started_event, %{}, base(meta))
  end

  @doc "A backend delegation was submitted to the agent."
  @spec delegation_start(meta(), delegation()) :: :ok
  def delegation_start(meta, delegation) when is_map(meta) and is_map(delegation) do
    execute(@delegation_start_event, %{}, delegation_metadata(meta, delegation))
  end

  @doc """
  A delegation reached a terminal state.

  `status` is the terminal word (`completed` / `failed` / `cancelled`), never a
  bare "ok": a cancelled delegation and a failed one are different outcomes and
  the trace is the only place that distinction survives.
  """
  @spec delegation_stop(meta(), delegation(), String.t(), non_neg_integer()) :: :ok
  def delegation_stop(meta, delegation, status, duration_ms)
      when is_map(meta) and is_map(delegation) and status in @delegation_statuses and
             is_integer(duration_ms) and duration_ms >= 0 do
    metadata =
      meta
      |> delegation_metadata(delegation)
      |> Map.put(:status, status)

    execute(@delegation_stop_event, %{duration_ms: duration_ms}, metadata)
  end

  @doc """
  The provider reported an error mid-call. Not terminal on its own — a
  moderation refusal cuts the audio and the session keeps running.
  """
  @spec provider_error(meta(), String.t()) :: :ok
  def provider_error(meta, reason) when is_map(meta) and is_binary(reason) do
    execute(@provider_error_event, %{}, Map.put(base(meta), :reason, Telemetry.preview(reason)))
  end

  @doc """
  Closes the run with the ledger and WHY it ended.

  `measurements` is the whole cost record — `voice_seconds`,
  `voice_cost_millicents` (integer sub-cent units, duration-priced),
  `backend_turns`, and `accounting_complete` as 0/1 — and every value must be a
  number: a rendered string reads as a measurement downstream and prices
  nothing. `reason` (`:call_stop`, `:cost_limit`, `:max_session_duration`,
  `:provider_disconnected`, `:session_expired`) rides as metadata, because a
  ceiling kill that looked like a hang-up is exactly what makes a torn-down call
  undiagnosable.
  """
  @spec call_stop(meta(), map(), atom()) :: :ok
  def call_stop(meta, measurements, reason)
      when is_map(meta) and is_map(measurements) and is_atom(reason) do
    execute(
      @call_stop_event,
      numeric!(measurements),
      Map.put(base(meta), :reason, Atom.to_string(reason))
    )
  end

  defp base(meta) do
    %{
      agent: @agent,
      engine: @engine,
      session_id: Map.fetch!(meta, :session_id),
      parent_session: Map.get(meta, :parent_session),
      device_id: Map.get(meta, :device_id),
      model: Map.get(meta, :model),
      voice: Map.get(meta, :voice),
      provider_session_id: Map.get(meta, :provider_session_id)
    }
  end

  defp delegation_metadata(meta, delegation) do
    meta
    |> base()
    |> Map.put(:delegation_id, Map.fetch!(delegation, :delegation_id))
    |> Map.put(:revision, Map.fetch!(delegation, :revision))
    |> Map.put(:turn_session_id, Map.fetch!(delegation, :turn_session_id))
  end

  defp numeric!(measurements) do
    case Enum.reject(measurements, fn {_key, value} -> is_number(value) end) do
      [] ->
        measurements

      [{key, value} | _rest] ->
        raise ArgumentError,
              "voice_live call_stop measurements must be numbers, " <>
                "#{inspect(key)} was #{inspect(value)}"
    end
  end

  defp execute(event, measurements, metadata) do
    :telemetry.execute(event, measurements, compact(metadata))
  end

  defp compact(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end
end
