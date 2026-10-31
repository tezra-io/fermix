defmodule FermixCore.Cues.Telemetry do
  @moduledoc """
  The single owner of the cue events (M60 §14). Never hand-roll them elsewhere.

      [:fermix, :cue, :lifecycle]   one event per delivery or item transition
      [:fermix, :cue, :source]      connect, reconnect, auth failure, budget, gap

  The phase is metadata, never part of the name: `Trace.TelemetryHandler` and
  `FermixOpik.Reporter` bind exact names, so a `[:fermix, :cue, <phase>]` tail
  would never be delivered (the reminder lifecycle's rule).

  ## Ids and counts only

  Both emitters build metadata from a fixed allowlist and raise on any other key.
  A cue carries an outside party's text; with no pass-through map no caller can
  attach it. The one content key, `:content`, is dropped unless
  `FermixCore.Telemetry.capture_content?/0` is on. `error_class` is derived from
  `:result` (an atom, or a tagged tuple's atom head), never caller-supplied, so a
  reason's body never reaches a trace.

  ## Sessions

  The sessionless phases (`accepted` … `expired`, `unmatched`, `overflow`,
  `write_failed`, and the two error phases) render as self-closing traces and
  refuse a `session_id`. The run-scoped phases
  (`claimed`, `settled`, `retry`, `exhausted`) and the proposal phases need the
  run's `session_id`, so they nest under it. The filter-scoped phases take the
  filter call's `session_id`; `passed` may have none, because a `none` watcher's
  delivery passes at acceptance with no filter call.

  A watcher's follow-up (M60_WATCHER_CODING_RUNS.md §4.3) traces its
  trigger, by `trigger_id`, under the watcher: `follow_up_triggered` when a
  pass writes it (its `state` and a short `reason` label), `follow_up_decided`
  at the owner's answer, `follow_up_expired`, `follow_up_refused` (held, or not
  runnable when its turn came), all sessionless since no run exists yet, and
  `follow_up_started` with the run's `session_id`, so it nests in the run's
  trace. An Always allow on a card is a `follow_up_decided` with `decision`
  `always_allow` and what it came to as `outcome` (`allowed`, or `changed`
  when the follow-up changed since the card was shown);
  `follow_up_always_allow_revoked`, sessionless under the watcher with its
  `job_id`, is the owner taking it back, from chat or an app (`kind`).

  `ingest_error` and `sweep_error` are beyond design §14: every `{:error, reason}`
  from ingest or a retention sweep is traced before it is returned (the
  reminders' `scheduler_error` precedent).

  ## Counted phases

  A stream's items are judged before they are stored, and only a pass is
  written (M60_CUE_INTAKE_AT_SCALE.md §3.4). What is not stored is counted
  (`Cues.Counts`), and each count flush emits one event per phase with its
  `count` since the last flush and no item id: per source (`source_ref`)
  `unmatched` (no watcher's words matched), `rate_limited`, `over_budget`,
  `rejected` and `stale`; per watcher (`watcher_id`) `overflow` (its live queue
  was full), `over_budget` (its filter budget was spent), `dropped`,
  `filter_failed` and `write_failed` (a pass whose write kept failing). A pass
  keeps its per-item events.
  """

  alias FermixCore.Telemetry

  @lifecycle_event [:fermix, :cue, :lifecycle]
  @source_event [:fermix, :cue, :source]
  @component "cues"

  @sessionless_phases [
    :accepted,
    :duplicate,
    :conflict,
    :stale,
    :rejected,
    :rate_limited,
    :over_budget,
    :routed,
    :gap,
    :expired,
    :unmatched,
    :overflow,
    :write_failed,
    :ingest_error,
    :sweep_error,
    :follow_up_triggered,
    :follow_up_decided,
    :follow_up_expired,
    :follow_up_refused,
    :follow_up_always_allow_revoked
  ]
  @filter_phases [:passed, :dropped, :filter_retry, :filter_held, :filter_failed]
  @run_phases [:claimed, :settled, :retry, :exhausted]
  @proposal_phases [:proposed, :confirmed, :denied, :proposal_expired, :proposal_refused]
  @follow_up_run_phases [:follow_up_started]
  @session_phases @run_phases ++ @proposal_phases ++ @follow_up_run_phases
  @phases @sessionless_phases ++
            @filter_phases ++ @run_phases ++ @proposal_phases ++ @follow_up_run_phases

  @source_phases [
    :connect,
    :reconnect,
    :disconnect,
    :auth_failure,
    :budget,
    :gap,
    :stopped
  ]

  @id_keys [
    :source_ref,
    :cue_id,
    :delivery_id,
    :watcher_id,
    :gap_id,
    :job_id,
    :run_id,
    :filter_call_id,
    :mandate_call_id,
    :proposal_id,
    :trigger_id,
    :session_id,
    :parent_session
  ]
  @label_keys [
    :reason,
    :outcome,
    :state,
    :decision,
    :validator,
    :mandate,
    :tool,
    :provider,
    :model,
    :kind,
    :status
  ]
  @count_keys [:attempt, :count]
  @lifecycle_keys @id_keys ++ @label_keys ++ @count_keys ++ [:result, :content]
  @source_keys [
    :source_ref,
    :kind,
    :status,
    :reason,
    :attempt,
    :count,
    :skipped,
    :result,
    :content
  ]
  @measurement_keys [:count, :accept_ms, :queue_ms, :duration_ms, :skipped]

  @trace_event_definitions [
    %{
      event: @lifecycle_event,
      trace_event: "cue_lifecycle",
      trace_type: :agent_event,
      agent_field: :component
    },
    %{
      event: @source_event,
      trace_event: "cue_source",
      trace_type: :agent_event,
      agent_field: :component
    }
  ]

  @doc "Every lifecycle phase `lifecycle/3` accepts."
  @spec phases() :: [atom()]
  def phases, do: @phases

  @doc "Every source phase `source/2` accepts."
  @spec source_phases() :: [atom()]
  def source_phases, do: @source_phases

  @doc "The JSONL trace registrations for both events."
  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @doc """
  Emit one `[:fermix, :cue, :lifecycle]` event.

  `measurements` may hold `:count`, `:accept_ms`, `:queue_ms`, `:duration_ms`
  (non-negative integers); empty means `%{count: 1}`. `metadata` may hold only
  the allowlisted ids, labels and counts, `:result` (`:ok | {:ok, _} | :error |
  {:error, _}`, reduced to its tag and derived `error_class`) and `:content`
  (behind the content gate). Anything else raises.
  """
  @spec lifecycle(atom(), map(), map()) :: :ok
  def lifecycle(phase, measurements, metadata)
      when is_atom(phase) and is_map(measurements) and is_map(metadata) do
    known_phase!(phase, @phases)
    allowed_keys!(metadata, @lifecycle_keys)
    session_rule!(phase, metadata)

    :telemetry.execute(
      @lifecycle_event,
      measurements!(measurements),
      build_metadata(phase, metadata)
    )
  end

  @doc """
  Emit one `[:fermix, :cue, :source]` event. `metadata` needs `:source_ref`
  and may hold `:kind`, `:status`, `:reason`, `:attempt`, `:count`,
  `:skipped` (the items a feed's poll skipped as older than the receipt
  horizon), `:result` and `:content` (a stream service's own error message,
  behind the content gate). `:count` and `:skipped` become the measurements
  (`count: 1` when none is given).
  """
  @spec source(atom(), map()) :: :ok
  def source(phase, metadata) when is_atom(phase) and is_map(metadata) do
    known_phase!(phase, @source_phases)
    allowed_keys!(metadata, @source_keys)
    id_value!(:source_ref, Map.get(metadata, :source_ref), required: true)

    measurements =
      metadata
      |> Map.take([:count, :skipped])
      |> measurements!()

    :telemetry.execute(
      @source_event,
      measurements,
      build_metadata(phase, Map.drop(metadata, [:count, :skipped]))
    )
  end

  # --- validation ------------------------------------------------------------

  defp known_phase!(phase, allowed) do
    if phase in allowed do
      :ok
    else
      raise ArgumentError, "cue telemetry has no phase #{inspect(phase)}"
    end
  end

  defp allowed_keys!(metadata, allowed) do
    case Enum.reject(Map.keys(metadata), &(&1 in allowed)) do
      [] -> :ok
      unknown -> raise ArgumentError, "cue telemetry refuses keys #{inspect(unknown)}"
    end
  end

  defp session_rule!(phase, metadata) do
    session = Map.get(metadata, :session_id)

    cond do
      phase in @sessionless_phases and session != nil ->
        raise ArgumentError, "cue phase #{inspect(phase)} is sessionless; drop :session_id"

      phase in @session_phases and session == nil ->
        raise ArgumentError, "cue phase #{inspect(phase)} needs the run's :session_id"

      true ->
        :ok
    end
  end

  defp measurements!(measurements) do
    allowed_keys!(measurements, @measurement_keys)
    Enum.each(measurements, fn {key, value} -> count_value!(key, value) end)
    if measurements == %{}, do: %{count: 1}, else: measurements
  end

  defp build_metadata(phase, metadata) do
    result = Map.get(metadata, :result)

    metadata
    |> Map.drop([:result, :content])
    |> Map.new(fn {key, value} -> {key, checked(key, value)} end)
    |> Map.merge(%{
      phase: phase,
      component: @component,
      result: result_tag(result),
      error_class: error_class(result),
      content: content(Map.get(metadata, :content))
    })
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp checked(key, value) when key in @id_keys, do: id_value!(key, value, required: false)
  defp checked(key, value) when key in @count_keys, do: count_value!(key, value)
  defp checked(key, value) when key == :duration_ms, do: count_value!(key, value)
  defp checked(key, value), do: label_value!(key, value)

  defp id_value!(key, value, required: required?) do
    case value do
      nil when not required? ->
        nil

      text when is_binary(text) and text != "" ->
        text

      int when is_integer(int) and int >= 0 ->
        int

      other ->
        raise ArgumentError, "cue telemetry #{inspect(key)} is not an id: #{inspect(other)}"
    end
  end

  defp count_value!(_key, nil), do: nil
  defp count_value!(_key, value) when is_integer(value) and value >= 0, do: value

  defp count_value!(key, value) do
    raise ArgumentError,
          "cue telemetry #{inspect(key)} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp label_value!(_key, nil), do: nil
  defp label_value!(_key, value) when is_atom(value), do: value
  defp label_value!(_key, value) when is_binary(value) and byte_size(value) <= 128, do: value

  defp label_value!(key, value) do
    raise ArgumentError,
          "cue telemetry #{inspect(key)} must be a short label, got: #{inspect(value)}"
  end

  defp content(nil), do: nil

  defp content(text) when is_binary(text) do
    if Telemetry.capture_content?(), do: text, else: nil
  end

  defp content(other) do
    raise ArgumentError, "cue telemetry :content must be a binary, got: #{inspect(other)}"
  end

  defp result_tag(nil), do: nil
  defp result_tag(:ok), do: :ok
  defp result_tag({:ok, _value}), do: :ok
  defp result_tag(:error), do: :error
  defp result_tag({:error, _reason}), do: :error

  defp result_tag(other) do
    raise ArgumentError,
          "cue telemetry :result must be :ok | {:ok, _} | :error | {:error, _}, got: " <>
            inspect(other)
  end

  defp error_class({:error, reason}), do: class_of(reason)
  defp error_class(_result), do: nil

  defp class_of(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp class_of(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      head when is_atom(head) -> Atom.to_string(head)
      _other -> "unclassified"
    end
  end

  defp class_of(_reason), do: "unclassified"
end
