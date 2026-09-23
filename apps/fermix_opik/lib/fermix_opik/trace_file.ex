defmodule FermixOpik.TraceFile do
  @moduledoc """
  Reads Fermix's JSONL trace files and rebuilds telemetry events from them.

  Fermix writes one JSONL file per trace type per day under
  `<trace_dir>/<YYYY-MM-DD>/<type>.jsonl`, flattening each event's measurements
  and metadata into one row (plus `ts`, `type`, and — for `agent_event` rows —
  `event`). This module reverses that into the `{event, measurements, metadata}`
  shape `FermixOpik.Aggregation` consumes, so historical traces can be replayed
  into Opik. Rows that aren't part of a trace (prompt_context, channel_msg, …)
  are skipped.
  """

  @doc """
  All replayable events under `dir`, sorted by timestamp.

  Returns `[{event, measurements, metadata, %DateTime{}}]`.
  """
  @spec read_events(String.t()) :: [{[atom()], map(), map(), DateTime.t()}]
  def read_events(dir) do
    dir
    |> Path.join("**/*.jsonl")
    |> Path.wildcard()
    |> Enum.flat_map(&read_file/1)
    |> Enum.sort_by(fn {_event, _meas, _meta, at} -> at end, DateTime)
  end

  defp read_file(path) do
    type = path |> Path.basename(".jsonl")

    path
    |> File.stream!()
    |> Enum.flat_map(fn line ->
      case decode_row(type, line) do
        {:ok, tuple} -> [tuple]
        :skip -> []
      end
    end)
  end

  defp decode_row(type, line) do
    with {:ok, row} <- Jason.decode(String.trim(line)),
         {:ok, at} <- parse_ts(row),
         {event, meas, meta} when is_list(event) <- normalize(type, row) do
      {:ok, {event, meas, meta, at}}
    else
      _other -> :skip
    end
  end

  defp parse_ts(%{"ts" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> {:ok, dt}
      _error -> :error
    end
  end

  defp parse_ts(_row), do: :error

  @doc false
  @spec normalize(String.t(), map()) :: {[atom()], map(), map()} | :skip
  def normalize("llm_call", row) do
    {[:fermix, :provider, :call], %{duration_ms: int(row["duration_ms"])},
     meta(row, [
       :session_id,
       :parent_session,
       :provider,
       :model,
       :status,
       :agent,
       :input,
       :output,
       :reasoning_effort,
       :adapter
     ])
     |> put_tokens(row)}
  end

  def normalize("tool_exec", row) do
    {[:fermix, :tool, :exec], %{duration_ms: int(row["duration_ms"])},
     meta(row, [
       :session_id,
       :parent_session,
       :tool,
       :agent,
       :success,
       :plugin,
       :error,
       :input,
       :output,
       :action,
       :kind,
       :profile,
       :url,
       :target_ref,
       :selector,
       :error_code,
       :error_summary,
       # The computer-use pair: the session the action drove, and what the action
       # actually did. The lifecycle run is its own root trace, so these are the
       # only link between a replayed action and its session.
       :cu_session,
       :outcome,
       # Coexistence (V3 R0): what the courtesy arbiter did about a person at
       # the machine — proceeded, waited for them, or stepped aside. A closed
       # enum; without it a replayed row cannot say why nothing was dispatched.
       :courtesy,
       # Addressing (M42 slice 3): how stale the image an action aimed at was, and
       # the code when it named no addressable one. A millisecond count and a
       # closed enum — never an id, a size, or anything from the screen.
       :observation_age_ms,
       :geometry_refusal,
       # References (M42 slice 4): by which mechanism the input went out, and what
       # the helper observed of it. Two closed enums — never the value a
       # `set_value` carried, which is content and rides the capture gate.
       :input_method,
       :effect,
       # The check (M42 slice 6): which evidence the action came back with,
       # whether the view changed since the one it acted on, and what each phase
       # cost. A closed enum, a boolean and four millisecond counts.
       :check_kind,
       :check_changed,
       :cu_input_ms,
       :cu_settle_ms,
       :cu_capture_ms,
       :cu_encode_ms,
       # Bound windows (M42 slice 5): what the action was pointed at, and how it
       # reached the screen. Two closed words — never a window title and never an
       # application name.
       :target_kind,
       :cu_mode
     ])}
  end

  def normalize("agent_event", %{"event" => event} = row), do: normalize_agent_event(event, row)
  def normalize(_type, _row), do: :skip

  defp normalize_agent_event("agent_start", row) do
    {[:fermix, :agent, :start], %{},
     meta(row, [:name, :role, :session_id, :parent, :parent_session])}
  end

  defp normalize_agent_event("agent_task_start", row) do
    {[:fermix, :agent, :task_start], %{},
     meta(row, [:name, :role, :session_id, :parent_session, :task_summary])}
  end

  defp normalize_agent_event("agent_task_complete", row) do
    {[:fermix, :agent, :task_complete],
     %{duration_ms: int(row["duration_ms"]), iterations: int(row["iterations"])},
     meta(row, [:name, :role, :session_id, :parent_session, :success])}
  end

  defp normalize_agent_event("agent_stop", row) do
    {[:fermix, :agent, :stop], %{duration_ms: int(row["duration_ms"])},
     meta(row, [:name, :role, :session_id, :parent_session, :reason])}
  end

  defp normalize_agent_event("skill_invoke", row) do
    {[:fermix, :skill, :invoke], %{duration_ms: int(row["duration_ms"])},
     meta(row, [:skill, :session_id, :parent_session, :task_summary, :success])}
  end

  defp normalize_agent_event("provider_failover", row) do
    {[:fermix, :provider, :failover], %{count: 1},
     meta(row, [
       :from_provider,
       :from_model,
       :to_provider,
       :to_model,
       :reason_kind,
       :surface,
       :session_id,
       :agent
     ])}
  end

  defp normalize_agent_event("turn_complete", row) do
    {[:fermix, :agent, :message],
     %{
       iterations: int(row["iterations"]),
       total_tokens: int(row["total_tokens"]),
       duration_ms: int(row["duration_ms"])
     }, meta(row, [:channel, :chat_id, :sender, :session_id, :agent, :input, :output])}
  end

  defp normalize_agent_event("turn_error", row) do
    {[:fermix, :agent, :message_error], %{count: 1},
     meta(row, [:channel, :chat_id, :reason, :session_id, :agent])}
  end

  defp normalize_agent_event("job_run_start", row) do
    {[:fermix, :job, :run_start], %{},
     meta(row, [
       :agent,
       :job_id,
       :run_id,
       :session_id,
       :name,
       :schedule_kind,
       :schedule_expr,
       :trigger,
       :input
     ])}
  end

  defp normalize_agent_event("job_run_complete", row) do
    {[:fermix, :job, :run_complete],
     %{
       duration_ms: int(row["duration_ms"]),
       iterations: int(row["iterations"]),
       total_tokens: int(row["total_tokens"]),
       tool_failures: int(row["tool_failures"])
     }, meta(row, [:agent, :job_id, :run_id, :session_id, :status, :output])}
  end

  defp normalize_agent_event("job_run_error", row) do
    {[:fermix, :job, :run_error], %{count: 1, duration_ms: int(row["duration_ms"])},
     meta(row, [:agent, :job_id, :run_id, :session_id, :status, :error])}
  end

  defp normalize_agent_event("realtime_call_start", row) do
    {[:fermix, :realtime, :call_start], %{}, realtime_meta(row)}
  end

  defp normalize_agent_event("realtime_session_created", row) do
    {[:fermix, :realtime, :session_created], %{}, realtime_meta(row)}
  end

  defp normalize_agent_event("realtime_session_updated", row) do
    {[:fermix, :realtime, :session_updated], %{}, realtime_meta(row)}
  end

  defp normalize_agent_event("realtime_provider_error", row) do
    {[:fermix, :realtime, :provider_error], %{}, realtime_meta(row)}
  end

  defp normalize_agent_event("realtime_reconnect", row) do
    {[:fermix, :realtime, :reconnect], %{}, realtime_meta(row)}
  end

  defp normalize_agent_event("realtime_call_stop", row) do
    {[:fermix, :realtime, :call_stop], realtime_usage_measurements(row), realtime_meta(row)}
  end

  # A GPT-Live voice call (M41 §7). Every row replays through one allowlist that
  # INCLUDES `parent_session`: a delegation's turn is linked to its call by that
  # field alone, so dropping it would replay a call and its backend turns as
  # unrelated roots.
  defp normalize_agent_event("voice_live_call_start", row) do
    {[:fermix, :voice_live, :call_start], voice_live_usage_measurements(row),
     voice_live_meta(row)}
  end

  defp normalize_agent_event("voice_live_session_started", row) do
    {[:fermix, :voice_live, :session_started], voice_live_usage_measurements(row),
     voice_live_meta(row)}
  end

  defp normalize_agent_event("voice_live_delegation_start", row) do
    {[:fermix, :voice_live, :delegation_start], voice_live_usage_measurements(row),
     voice_live_meta(row)}
  end

  defp normalize_agent_event("voice_live_delegation_stop", row) do
    {[:fermix, :voice_live, :delegation_stop], voice_live_usage_measurements(row),
     voice_live_meta(row)}
  end

  defp normalize_agent_event("voice_live_provider_error", row) do
    {[:fermix, :voice_live, :provider_error], voice_live_usage_measurements(row),
     voice_live_meta(row)}
  end

  defp normalize_agent_event("voice_live_call_stop", row) do
    {[:fermix, :voice_live, :call_stop], voice_live_usage_measurements(row), voice_live_meta(row)}
  end

  # A management Doctor run (M34 §5). Counts only — a check summary can name an
  # operator path, so no summary or evidence text is replayed.
  defp normalize_agent_event("doctor_session_start", row) do
    {[:fermix, :doctor, :session_start], %{checks: int(row["checks"])}, doctor_meta(row)}
  end

  defp normalize_agent_event("doctor_session_complete", row) do
    {[:fermix, :doctor, :session_complete], %{count: 1, duration_ms: int(row["duration_ms"])},
     meta(
       row,
       [:session_id, :agent, :parent_session, :scope, :budget_ms, :status, :checks_total] ++
         doctor_count_keys()
     )}
  end

  defp normalize_agent_event("doctor_session_error", row) do
    {[:fermix, :doctor, :session_error], %{count: 1},
     meta(row, [
       :session_id,
       :agent,
       :parent_session,
       :scope,
       :budget_ms,
       :status,
       :reason_kind,
       :error
     ])}
  end

  # A management job (M34 native setup §7.3). The failure sentence is the
  # daemon's own operator copy, so it replays; no operation result ever does.
  defp normalize_agent_event("management_job_start", row) do
    {[:fermix, :management_job, :start], %{count: 1}, management_job_meta(row)}
  end

  defp normalize_agent_event("management_job_complete", row) do
    {[:fermix, :management_job, :complete], %{count: 1, duration_ms: int(row["duration_ms"])},
     meta(row, [:session_id, :agent, :kind, :budget_ms, :status, :failure_code, :error])}
  end

  # A computer-use session (M42 slice 1 §3). Every row replays through one
  # allowlist that INCLUDES `parent_session`: the run is its own root and that
  # field is the only record of which turn opened the session.
  defp normalize_agent_event("computer_use_session_start", row) do
    {[:fermix, :computer_use, :session_start], %{}, computer_use_meta(row)}
  end

  defp normalize_agent_event("computer_use_session_complete", row) do
    {[:fermix, :computer_use, :session_complete], computer_use_measurements(row),
     computer_use_meta(row)}
  end

  defp normalize_agent_event("computer_use_session_error", row) do
    {[:fermix, :computer_use, :session_error], %{},
     meta(row, [:session_id, :parent_session, :agent, :mode, :origin, :reason])}
  end

  defp normalize_agent_event("computer_use_session_pause", row) do
    {[:fermix, :computer_use, :session_pause], %{}, computer_use_meta(row)}
  end

  defp normalize_agent_event("computer_use_session_resume", row) do
    {[:fermix, :computer_use, :session_resume], %{}, computer_use_meta(row)}
  end

  defp normalize_agent_event(_other, _row), do: :skip

  defp computer_use_meta(row) do
    meta(row, [:session_id, :parent_session, :agent, :mode, :origin])
  end

  # Only the counts actually present are carried: a session row written before
  # the measurements existed must replay with none rather than a fabricated zero.
  defp computer_use_measurements(row) do
    Enum.reduce([:actions, :duration_ms], %{}, fn key, acc ->
      case Map.fetch(row, Atom.to_string(key)) do
        {:ok, value} when is_number(value) -> Map.put(acc, key, value)
        _other -> acc
      end
    end)
  end

  defp management_job_meta(row), do: meta(row, [:session_id, :agent, :kind, :budget_ms])

  defp doctor_meta(row) do
    meta(row, [:session_id, :agent, :parent_session, :scope, :budget_ms])
  end

  defp doctor_count_keys do
    [:passed, :warning, :failed, :unavailable, :skipped, :cancelled, :timed_out]
  end

  defp voice_live_meta(row) do
    meta(row, [
      :session_id,
      :parent_session,
      :agent,
      :engine,
      :device_id,
      :model,
      :voice,
      :provider_session_id,
      :delegation_id,
      :revision,
      :turn_session_id,
      :status,
      :reason,
      :max_duration_ms
    ])
  end

  # Rebuild a voice_live row's numeric measurements. Voice is duration-priced,
  # so the ledger is seconds plus integer millicents — never tokens. Only keys
  # actually present are carried: a call whose finalization never completed must
  # replay with no cost rather than a fabricated zero.
  defp voice_live_usage_measurements(row) do
    [:voice_seconds, :voice_cost_millicents, :backend_turns, :accounting_complete, :duration_ms]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.fetch(row, Atom.to_string(key)) do
        {:ok, value} when is_number(value) -> Map.put(acc, key, value)
        _other -> acc
      end
    end)
  end

  defp realtime_meta(row) do
    meta(row, [:session_id, :agent, :device_id, :model, :voice, :session_scope, :reason, :attempt])
  end

  # Rebuild the call's final usage measurements from a flattened `call_stop` row.
  # Only numeric keys actually present are carried, so pre-usage traces replay
  # with empty measurements rather than fabricated zeros.
  defp realtime_usage_measurements(row) do
    [:input_audio_ms, :input_audio_tokens, :estimated_cost_cents, :reported_cost_cents]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.fetch(row, Atom.to_string(key)) do
        {:ok, value} when is_number(value) -> Map.put(acc, key, value)
        _other -> acc
      end
    end)
  end

  # Pull a whitelist of keys out of a string-keyed row into an atom-keyed map,
  # dropping absent keys. Only these known keys are atomized (no dynamic atoms).
  defp meta(row, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case Map.fetch(row, Atom.to_string(key)) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp put_tokens(meta, %{"tokens" => %{} = tokens}) do
    normalized =
      %{
        prompt: tokens["prompt"] || tokens["prompt_tokens"],
        completion: tokens["completion"] || tokens["completion_tokens"],
        total: tokens["total"] || tokens["total_tokens"]
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    Map.put(meta, :tokens, normalized)
  end

  defp put_tokens(meta, _row), do: meta

  defp int(value) when is_integer(value), do: value
  defp int(_value), do: 0
end
