defmodule FermixCore.Temporal.Telemetry do
  @moduledoc """
  The single owner of the proactive-reminder lifecycle event (M30 §15.2).

  One stable event carries every phase:

      [:fermix, :reminder, :lifecycle]

  A dynamic `[:fermix, :reminder, <phase>]` tail would never be delivered —
  both `FermixCore.Trace.TelemetryHandler` and `FermixOpik.Reporter` bind exact
  names — so the phase is metadata, never part of the name.

  ## Why there is no caller metadata map

  `emit/2` builds its metadata from a fixed allowlist and refuses every other
  key outright (the discipline `FermixCore.Capabilities.MCP.Telemetry` sets).
  A reminder holds the owner's own personal calendar: event titles and
  descriptions, chat destinations, and channel error bodies. With no
  pass-through map, no caller — present or future — can attach any of them; a
  leak would require editing this module. The one content field, `:content`, is
  dropped unless `FermixCore.Telemetry.capture_content?/0` is on (§14).

  For the same reason `error_class` is *derived*, never caller-supplied: a
  reason's body can embed a destination or a remote message, so only an atom
  class (or a tagged tuple's atom head) survives and anything else is flattened
  to `"unclassified"`. The class groups failures; the vendor's own words stay in
  the `{:error, reason}` the caller still returns and in the row's bounded
  `last_error`.

  ## Why it is not an agent event

  A reminder delivery calls no model and belongs to no turn (§6.4), so there is
  no `session_id` to correlate on and this emitter deliberately accepts none.
  Correlation is by `event_id` / `reminder_id` / `occurrence_key`, and the
  JSONL/Opik consumers render each phase as a self-closing operation rather
  than nesting it under an invented agent session. `component` is the fixed
  `agent_field` those consumers group on.

  Never hand-roll this event elsewhere.
  """

  alias FermixCore.Telemetry

  @lifecycle_event [:fermix, :reminder, :lifecycle]
  @component "temporal_scheduler"

  @phases [
    :materialized,
    :claimed,
    :delivered,
    :retry_scheduled,
    :failed,
    :expired,
    :superseded,
    :cancelled,
    :event_completed,
    :scheduler_error
  ]

  @id_keys [:event_id, :reminder_id, :occurrence_key, :rule_id, :platform]
  @allowed_keys @id_keys ++ [:attempt, :result, :content, :duration_ms]

  @trace_event_definitions [
    %{
      event: @lifecycle_event,
      trace_event: "reminder_lifecycle",
      trace_type: :agent_event,
      agent_field: :component
    }
  ]

  @doc "Every lifecycle phase this emitter can emit."
  @spec phases() :: [atom()]
  def phases, do: @phases

  @doc "The stable reminder-lifecycle event name."
  @spec lifecycle_event() :: [atom()]
  def lifecycle_event, do: @lifecycle_event

  @doc "The fixed `agent_field` value for this non-agent event family."
  @spec component() :: String.t()
  def component, do: @component

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @doc """
  Emit one `[:fermix, :reminder, :lifecycle]` event.

  `opts` accepts only the allowlisted keys — `:event_id`, `:reminder_id`,
  `:occurrence_key`, `:rule_id`, `:platform`, `:attempt`, `:result`, `:content`,
  and `:duration_ms`. Anything else raises, because a reminder emitter that
  quietly forwarded an unknown key is exactly how personal calendar text reaches
  a trace.

  `result` is the operation's return value verbatim (`:ok` | `{:ok, _}` |
  `:error` | `{:error, reason}`); its tag and, on failure, its derived
  `error_class` are the only things that survive. `duration_ms` becomes the
  measurement where work occurred; every other phase measures `count: 1`.
  """
  @spec emit(atom(), keyword()) :: :ok
  def emit(phase, opts \\ []) when phase in @phases and is_list(opts) do
    validate_keys!(opts)

    :telemetry.execute(@lifecycle_event, measurements(opts), metadata(phase, opts))
  end

  @doc """
  The correlation fields of one reminder row, ready to pass to `emit/2`.

  Keeps every call site reading the same columns, so a phase cannot be emitted
  with a partially-filled identity.
  """
  @spec reminder(map()) :: keyword()
  def reminder(row) when is_map(row) do
    [
      event_id: Map.get(row, :event_id),
      reminder_id: Map.get(row, :id),
      occurrence_key: Map.get(row, :occurrence_key),
      rule_id: Map.get(row, :reminder_rule_id),
      platform: Map.get(row, :delivery_platform),
      attempt: Map.get(row, :attempt_count)
    ]
  end

  # --- metadata ------------------------------------------------------------

  defp validate_keys!(opts) do
    case Enum.reject(Keyword.keys(opts), &(&1 in @allowed_keys)) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "reminder telemetry accepts only #{inspect(@allowed_keys)}, got: " <>
                inspect(unknown)
    end
  end

  defp measurements(opts) do
    case duration!(opts) do
      nil -> %{count: 1}
      duration_ms -> %{duration_ms: duration_ms}
    end
  end

  defp metadata(phase, opts) do
    result = Keyword.get(opts, :result)

    @id_keys
    |> Enum.into(%{}, fn key -> {key, identity!(opts, key)} end)
    |> Map.merge(%{
      phase: phase,
      component: @component,
      attempt: attempt!(opts),
      result: result_tag(result),
      error_class: error_class(result),
      content: content(opts)
    })
    |> compact()
  end

  defp identity!(opts, key) do
    case Keyword.get(opts, key) do
      nil ->
        nil

      value when is_binary(value) and value != "" ->
        value

      other ->
        raise ArgumentError,
              "reminder telemetry #{inspect(key)} must be a non-empty binary or nil, got: " <>
                inspect(other)
    end
  end

  defp attempt!(opts) do
    case Keyword.get(opts, :attempt) do
      nil ->
        nil

      attempt when is_integer(attempt) and attempt >= 0 ->
        attempt

      other ->
        raise ArgumentError,
              "reminder telemetry :attempt must be a non-negative integer, got: " <>
                inspect(other)
    end
  end

  defp duration!(opts) do
    case Keyword.get(opts, :duration_ms) do
      nil ->
        nil

      duration when is_integer(duration) and duration >= 0 ->
        duration

      other ->
        raise ArgumentError,
              "reminder telemetry :duration_ms must be a non-negative integer, got: " <>
                inspect(other)
    end
  end

  # The one owner-facing string this event may carry, and only when the operator
  # turned on full-fidelity traces.
  defp content(opts) do
    case Keyword.get(opts, :content) do
      nil ->
        nil

      text when is_binary(text) ->
        if Telemetry.capture_content?(), do: text, else: nil

      other ->
        raise ArgumentError,
              "reminder telemetry :content must be a binary or nil, got: " <> inspect(other)
    end
  end

  defp result_tag(nil), do: nil
  defp result_tag(:ok), do: :ok
  defp result_tag({:ok, _value}), do: :ok
  defp result_tag(:error), do: :error
  defp result_tag({:error, _reason}), do: :error

  defp result_tag(other) do
    raise ArgumentError,
          "reminder telemetry :result must be :ok | {:ok, _} | :error | {:error, _}, got: " <>
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

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
