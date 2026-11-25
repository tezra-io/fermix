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

  A heal (M106 §5.4) has one point event, `[:fermix, :job, :heal]`, with its
  `phase`: `opened`, `joined`, `verdict` (a failure concluding a watching
  heal a second time, §5.9) and `closed` from a run's settle; `decided`,
  `rerun`, `delivered`, `delivery_failed` and `closed` (still failing) from
  its heal run; and `closed` again when the Scheduler expires one. Each
  carries `heal_id`, and `job_id` and `run_id` when a run moved it. A settle
  that took a failure says its `failure_kind`, `subject_kind` and
  `subject_id`: an ok run whose tool never worked three runs in a row (M106
  §6) is `tool_never_succeeded`, its subject the tool's plugin or the job.

  A job's heal run is a run kind of its own (§5.5, §10): its diagnosis runs
  the agent loop under the session `heal_<job id>_<time>_<6 hex>`, the failed
  run's session as its `parent_session`, bracketed by
  `[:fermix, :job, :heal_run_start | :heal_run_complete | :heal_run_error]`.
  """

  alias FermixCore.Telemetry

  @run_start_event [:fermix, :job, :run_start]
  @run_complete_event [:fermix, :job, :run_complete]
  @run_error_event [:fermix, :job, :run_error]
  @heal_event [:fermix, :job, :heal]
  @heal_phases ~w(opened joined verdict decided rerun delivered delivery_failed closed)
  @heal_run_start_event [:fermix, :job, :heal_run_start]
  @heal_run_complete_event [:fermix, :job, :heal_run_complete]
  @heal_run_error_event [:fermix, :job, :heal_run_error]
  @heal_run_decisions ~w(rerun raise_limit pause propose tell none)

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
    },
    %{
      event: @heal_event,
      trace_event: "job_heal",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @heal_run_start_event,
      trace_event: "job_heal_run_start",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @heal_run_complete_event,
      trace_event: "job_heal_run_complete",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @heal_run_error_event,
      trace_event: "job_heal_run_error",
      trace_type: :agent_event,
      agent_field: :agent
    }
  ]

  @typedoc """
  What correlates a heal run (M106 §5.5): its own `session_id` and `agent`,
  the failed run's session as its `parent_session` (nil when that run's row
  is gone), the heal, its job, the failed run and its kind.
  """
  @type heal_run :: %{
          required(:session_id) => String.t(),
          required(:parent_session) => String.t() | nil,
          required(:agent) => String.t(),
          required(:heal_id) => String.t(),
          required(:job_id) => String.t(),
          required(:run_id) => String.t() | nil,
          required(:failure_kind) => String.t()
        }

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @spec run_start(map(), map(), map(), non_neg_integer() | nil) :: :ok
  def run_start(job, run, loop_input, max_duration_ms \\ nil) do
    metadata =
      job
      |> base_metadata(run)
      |> maybe_put_input(loop_input)
      # The run's max wall-clock duration lets the Opik exporter bound a
      # scheduled trace's sweep by the run's own timeout instead of a flat idle
      # window, so a long-but-alive run is never force-closed mid-flight.
      |> Map.put(:max_duration_ms, max_duration_ms)

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
      total_tokens: Map.get(result, :total_tokens, 0),
      tool_failures: Map.get(result, :tool_failures, 0)
    }

    execute(@run_complete_event, measurements, metadata)
  end

  @doc """
  A run's failure. A scheduled run's settle passes its settlement (M106
  §5.3), which adds `retry_disposition` (`"none"`, `"retry"` or
  `"exhausted"`), `retry_attempts` and, for a retry with a time, `retry_at`,
  and what the heals made of it (§5.4): `heal` (`"none"`, `"opened"`,
  `"joined"`, `"quiet"` or `"out_of_scope"`) and, for one opened or joined,
  `heal_id`; a cue run's passes none.
  """
  @spec run_error(map(), map(), String.t(), term(), map() | nil) :: :ok
  def run_error(job, run, status, error, settlement \\ nil) when is_binary(status) do
    metadata =
      job
      |> base_metadata(run)
      |> Map.put(:status, status)
      |> Map.put(:error, format_error(error))
      |> Map.merge(retry_metadata(settlement))
      |> Map.merge(heal_disposition_metadata(settlement))

    execute(@run_error_event, %{count: 1, duration_ms: run_duration_ms(run)}, metadata)
  end

  @doc """
  The heal events a scheduled run's settle caused: `opened`, `joined` or
  `verdict` for a failure a heal took, with the settlement's `failure_kind`,
  `subject_kind` and `subject_id` (an ok run's included, M106 §6), and
  `closed` (outcome `healed`) for each heal an ok run closed. A failure
  retried, kept quiet or out of scope causes none; its `run_error` says which.
  """
  @spec heal_settled(map(), map(), map()) :: :ok
  def heal_settled(job, run, %{heal: heal, healed: healed} = settlement) when is_list(healed) do
    ids = %{job_id: job.id, run_id: run.id}

    case heal do
      {phase, heal_id} when phase in [:opened, :joined, :verdict] ->
        taken = Map.take(settlement, [:failure_kind, :subject_kind, :subject_id])
        heal(Atom.to_string(phase), ids |> Map.merge(taken) |> Map.put(:heal_id, heal_id))

      _none_quiet_or_out_of_scope ->
        :ok
    end

    Enum.each(healed, &heal("closed", Map.merge(ids, %{heal_id: &1, outcome: "healed"})))
  end

  @doc """
  One phase of a heal's life (`opened`, `joined`, `verdict`, `decided`,
  `rerun`, `delivered`, `delivery_failed` or `closed`), with its `heal_id`
  and whatever of `job_id`, `run_id`, `subject_kind`, `subject_id`,
  `failure_kind`, `outcome`, `attempts`, `dead_letter`, `platform`, `error`,
  `conclusion`, `decision` (what code carried out), `requested` (what the
  heal run asked), `refusal` (why code did not carry the request out),
  `read_outside` and, on `rerun`, its `rerun_outcome` (`started`, `running`,
  `refused` or `unanswered`) the phase knows.
  """
  @spec heal(String.t(), map()) :: :ok
  def heal(phase, %{heal_id: heal_id} = facts)
      when phase in @heal_phases and is_binary(heal_id) do
    job_id = Map.get(facts, :job_id)

    metadata =
      facts
      |> Map.take(
        ~w(job_id run_id subject_kind subject_id failure_kind outcome attempts dead_letter platform
           conclusion decision requested refusal read_outside rerun_outcome)a
      )
      |> Map.merge(%{
        agent: if(job_id, do: "scheduled:#{job_id}", else: "job_heal"),
        phase: phase,
        heal_id: heal_id,
        error: facts |> Map.get(:error) |> heal_error()
      })

    execute(@heal_event, %{count: 1}, metadata)
  end

  defp heal_error(nil), do: nil
  defp heal_error(error), do: error |> format_error() |> String.slice(0, 500)

  @doc """
  A heal run's opener (M106 §5.5), before its loop starts: its correlation
  and `max_duration_ms`, its watchdog and the exporter's sweep floor.
  """
  @spec heal_run_start(heal_run(), pos_integer()) :: :ok
  def heal_run_start(%{session_id: session_id} = run, max_duration_ms)
      when is_binary(session_id) and is_integer(max_duration_ms) and max_duration_ms > 0 do
    metadata = Map.put(heal_run_metadata(run), :max_duration_ms, max_duration_ms)
    execute(@heal_run_start_event, %{count: 1}, metadata)
  end

  @doc """
  A heal run whose loop finished: the `decision` it asked for (`none` when
  it gave none), before code's checks, which the heal's `decided` phase says.
  """
  @spec heal_run_complete(heal_run(), String.t(), non_neg_integer()) :: :ok
  def heal_run_complete(run, decision, duration_ms)
      when decision in @heal_run_decisions and is_integer(duration_ms) do
    metadata = Map.put(heal_run_metadata(run), :decision, decision)
    execute(@heal_run_complete_event, %{duration_ms: duration_ms}, metadata)
  end

  @doc """
  A heal run whose loop did not finish: the watchdog stopped it (`timeout`)
  or it failed (`error`), with its reason bounded to 500 characters.
  """
  @spec heal_run_error(heal_run(), String.t(), non_neg_integer(), term()) :: :ok
  def heal_run_error(run, status, duration_ms, error)
      when status in ["timeout", "error"] and is_integer(duration_ms) do
    metadata = Map.merge(heal_run_metadata(run), %{status: status, error: heal_error(error)})
    execute(@heal_run_error_event, %{count: 1, duration_ms: duration_ms}, metadata)
  end

  defp heal_run_metadata(run),
    do:
      Map.take(run, [
        :agent,
        :session_id,
        :parent_session,
        :heal_id,
        :job_id,
        :run_id,
        :failure_kind
      ])

  defp retry_metadata(nil), do: %{}

  defp retry_metadata(%{disposition: disposition, attempts: attempts, retry_at: retry_at})
       when disposition in [:none, :retry, :exhausted] do
    %{
      retry_disposition: Atom.to_string(disposition),
      retry_attempts: attempts,
      retry_at: retry_at && DateTime.to_iso8601(retry_at)
    }
  end

  defp heal_disposition_metadata(%{heal: {phase, heal_id}})
       when phase in [:opened, :joined, :verdict],
       do: %{heal: Atom.to_string(phase), heal_id: heal_id}

  defp heal_disposition_metadata(%{heal: heal}) when heal in [:none, :quiet, :out_of_scope],
    do: %{heal: Atom.to_string(heal)}

  defp heal_disposition_metadata(_none), do: %{}

  # A cue run (trigger "cue", M60 §9.6) also carries the delivery it held (the
  # run row's `cue_delivery_id`) and its watcher (`watcher_id`, which the runner
  # puts on the run map it passes here); a follow-up's run (trigger "watcher")
  # carries its watcher, the cue that set it off and its trigger (`cue_id`,
  # `trigger_id`, also put there by the runner). All are absent for any other
  # run.
  defp base_metadata(job, run) do
    %{
      agent: "scheduled:#{job.id}",
      job_id: job.id,
      run_id: run.id,
      session_id: run.session_id,
      name: Map.get(job, :name),
      schedule_kind: Map.get(job, :schedule_kind),
      schedule_expr: Map.get(job, :schedule_expr),
      trigger: Map.get(run, :trigger),
      delivery_id: Map.get(run, :cue_delivery_id),
      watcher_id: Map.get(run, :watcher_id),
      cue_id: Map.get(run, :cue_id),
      trigger_id: Map.get(run, :trigger_id)
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
