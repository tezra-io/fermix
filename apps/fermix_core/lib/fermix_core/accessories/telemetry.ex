defmodule FermixCore.Accessories.Telemetry do
  @moduledoc """
  Single emitter for `[:fermix, :accessory, ...]`, the accessory link's events
  (M91; `docs/TELEMETRY_CONTRACT.md`, *Accessory link*):

    * `[:fermix, :accessory, :attach]`: one attach's outcome, a sessionless
      point like a pairing decision. `count: 1` and `duration_us` (from the
      host's `hello` to the verdict); `status` (`attached`, `unenrolled`, a
      host refusal by its `refuse.code`, or `accessory_refused` with the
      accessory's own code in `accessory_refusal`), the link's `mode`
      (`attach` for a port an enrolled accessory's hint named, `pairing` for
      the port the owner selected), the `kind` only when the host knows it,
      and the `endpoint` only once the proof verified.
    * `[:fermix, :accessory, :fault]`: a link fault, sessionless. `count`
      and the `reason` with the `stage` that found it (`receive`,
      `reassembly`, `control`, `peer`, `liveness`, `call`).
    * `[:fermix, :accessory, :call_link]`: once per accessory call, as it
      ends, under the CALL's own `session_id` (the engine session's scope,
      which the adapter mints), with the link's counters for the call as
      measurements, and the `endpoint`, `engine`, the call's `source` and why
      it ended.

  Atoms and counts only: no key, signature, nonce, audio, transcript or tool
  name reaches a field, and every status, reason and counter is from a closed
  set guarded here. All three route into `FermixCore.Trace` as `agent_event`
  rows; the Opik exporter nests `call_link` under the call's trace and does
  not subscribe to the two sessionless points.
  """

  @attach_event [:fermix, :accessory, :attach]
  @fault_event [:fermix, :accessory, :fault]
  @call_link_event [:fermix, :accessory, :call_link]

  @trace_event_definitions [
    %{
      event: @attach_event,
      trace_event: "accessory_attach",
      trace_type: :agent_event,
      agent_field: :status
    },
    %{
      event: @fault_event,
      trace_event: "accessory_fault",
      trace_type: :agent_event,
      agent_field: :reason
    },
    %{
      event: @call_link_event,
      trace_event: "accessory_call_link",
      trace_type: :agent_event,
      agent_field: :endpoint
    }
  ]

  @attach_statuses [
    :attached,
    :unenrolled,
    :wire_version,
    :unsupported_kind,
    :capability_missing,
    :unknown_accessory,
    :bad_proof,
    :auth_timeout,
    :stale_generation,
    :accessory_refused
  ]
  @modes [:attach, :pairing]
  @known_kinds %{"stackchan" => :stackchan}
  @fault_stages [:receive, :reassembly, :control, :peer, :liveness, :call]
  @call_sources [:screen_tap, :head_swipe, :mac]
  @call_counters [
    :duration_ms,
    :mic_frames,
    :mic_chunks,
    :pcm_seq_gaps,
    :speaker_frames,
    :speaker_bytes,
    :segments,
    :flushes,
    :credit_waits,
    :backlog_peak_bytes,
    :speaker_bytes_dropped,
    :task_events,
    :task_faults
  ]

  @type attach_status ::
          :attached
          | :unenrolled
          | :wire_version
          | :unsupported_kind
          | :capability_missing
          | :unknown_accessory
          | :bad_proof
          | :auth_timeout
          | :stale_generation
          | :accessory_refused

  @typedoc "What an attach event says besides its status."
  @type attach_facts :: %{
          mode: :attach | :pairing,
          kind: String.t() | nil,
          accessory_id: String.t() | nil,
          accessory_refusal: atom() | nil
        }

  @type fault_stage :: :receive | :reassembly | :control | :peer | :liveness | :call

  @typedoc "Who started the call: a tap or swipe on the accessory, or the Mac."
  @type call_source :: :screen_tap | :head_swipe | :mac

  @typedoc "What a call event says besides its counters."
  @type call_facts :: %{
          endpoint: String.t(),
          engine: String.t(),
          source: call_source(),
          reason: atom()
        }

  @doc "The counters a `call_link` event may carry."
  @spec call_counters() :: [atom()]
  def call_counters, do: @call_counters

  @doc "One attach's outcome."
  @spec emit_attach(attach_status(), non_neg_integer(), attach_facts()) :: :ok
  def emit_attach(status, duration_us, %{mode: mode} = facts)
      when status in @attach_statuses and is_integer(duration_us) and duration_us >= 0 and
             mode in @modes and
             (is_nil(facts.accessory_refusal) or is_atom(facts.accessory_refusal)) do
    :telemetry.execute(@attach_event, %{count: 1, duration_us: duration_us}, %{
      status: status,
      mode: mode,
      kind: Map.get(@known_kinds, facts.kind),
      endpoint: endpoint(status, facts.accessory_id),
      accessory_refusal: facts.accessory_refusal
    })
  end

  @doc "A link fault: its reason, the stage that found it, and how many."
  @spec emit_fault(atom(), fault_stage(), pos_integer()) :: :ok
  def emit_fault(reason, stage, count)
      when is_atom(reason) and not is_nil(reason) and stage in @fault_stages and
             is_integer(count) and count > 0 do
    :telemetry.execute(@fault_event, %{count: count}, %{reason: reason, stage: stage})
  end

  @doc """
  One accessory call's link counters, under the call's session id. A counter
  outside `call_counters/0`, or one that is not a non-negative integer,
  raises: nothing else may reach the event.
  """
  @spec emit_call_link(String.t(), %{optional(atom()) => non_neg_integer()}, call_facts()) ::
          :ok
  def emit_call_link(session_id, counters, %{source: source, reason: reason} = facts)
      when is_binary(session_id) and session_id != "" and is_map(counters) and
             source in @call_sources and is_atom(reason) and is_binary(facts.endpoint) and
             is_binary(facts.engine) do
    :ok = check_counters!(counters)

    :telemetry.execute(@call_link_event, counters, %{
      session_id: session_id,
      endpoint: facts.endpoint,
      engine: facts.engine,
      source: source,
      reason: reason
    })
  end

  @doc false
  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  defp endpoint(:attached, accessory_id) when is_binary(accessory_id),
    do: "accessory:" <> accessory_id

  defp endpoint(_status, _accessory_id), do: nil

  defp check_counters!(counters) do
    case Enum.find(counters, fn {key, value} -> not counter?(key, value) end) do
      nil -> :ok
      {key, value} -> raise ArgumentError, "not a call_link counter: #{inspect({key, value})}"
    end
  end

  defp counter?(key, value),
    do: key in @call_counters and is_integer(value) and value >= 0
end
