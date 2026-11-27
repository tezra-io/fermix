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
  its heal run; `closed` again when the Scheduler expires one, and when an
  owner's edit supersedes a waiting proposal; and `answered` (M106 §5.7, D5)
  when the owner's answer to a proposal is recorded, followed by `closed`
  when that answer closed it (`skipped`, or `superseded` for an apply to a
  job that moved on); `Jobs.HealAnswer` emits those two, called by the
  proposal's card (`Jobs.HealCard`) when the owner answers it. Each
  carries `heal_id`, and `job_id` and `run_id` when a run moved it. A settle
  that took a failure says its `failure_kind`, `subject_kind` and
  `subject_id`: an ok run whose tool never worked three runs in a row (M106
  §6) is `tool_never_succeeded`, its subject the tool's plugin or the job.

  A job's heal run is a run kind of its own (§5.5, §10): its diagnosis runs
  the agent loop under the session `heal_<job id>_<time>_<6 hex>`, the failed
  run's session as its `parent_session`, bracketed by
  `[:fermix, :job, :heal_run_start | :heal_run_complete | :heal_run_error]`.

  Each step of a heal is also one line in the engine log, written beside its
  event by a pure builder (`heal_line/2`, `look_line/2` for the look), and so
  is what became of a failed scheduled run (`run_line/3`): `info`, or
  `warning` for a step that says something went wrong. A line written here
  holds ids and Fermix's own words, each value one bounded token, never a
  failure's words, a note or a change's values. A step its caller already
  logs adds none here, and the caller's line may quote an error or a check's
  refusal, which can hold a provider's or a chat app's words.
  """

  require Logger

  alias FermixCore.Telemetry

  @run_start_event [:fermix, :job, :run_start]
  @run_complete_event [:fermix, :job, :run_complete]
  @run_error_event [:fermix, :job, :run_error]
  @heal_event [:fermix, :job, :heal]
  @heal_phases ~w(opened joined verdict decided rerun delivered delivery_failed closed answered)
  @heal_run_start_event [:fermix, :job, :heal_run_start]
  @heal_run_complete_event [:fermix, :job, :heal_run_complete]
  @heal_run_error_event [:fermix, :job, :heal_run_error]
  @heal_run_decisions ~w(rerun raise_limit pause propose tell none)
  # What places a step in its log line, and the word each is said with.
  @placed [:job_id, :run_id, :subject, :platform]
  @failure_placed [:job_id, :run_id, :failure_kind, :subject, :platform]
  @look_placed [:job_id, :session_id]
  @place_labels %{
    job_id: "job",
    run_id: "run",
    failure_kind: "failure",
    platform: "platform",
    session_id: "session"
  }
  # The most bytes of one value a log line says. The ids Fermix makes are
  # whole under it: a heal id is 20 bytes, a run id 15, a job id its name's
  # slug and a counter (no length limit), and a look's session its job id and
  # 28 bytes, so a session is whole for any job whose name is under about 470
  # characters. A value past it keeps its head and its tail, so a session
  # keeps its time and suffix and two looks at one job stay apart.
  @token_max 512
  @token_keep div(@token_max - 3, 2)

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

  @typedoc "One engine log line and the level it is written at."
  @type log_line :: {:info | :warning, String.t()}

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
  `heal_id`; a cue run's passes none. What became of a scheduled run's
  failure is also one log line (`run_line/3`).
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
    write_log(run_line(job, run, settlement))
  end

  @doc """
  The engine log's line for what became of a failed scheduled run (M106
  §5.3, §5.4), from its settlement, in one line: a quiet retry set (which
  one, and when it runs or that it is the job's next run), its quiet retries
  used up (a `warning`), the owner not told because a heal for the same
  failure closed lately (`quiet`), or no heal opened because the job is not
  the owner's (`out_of_scope`), two of them joined when both hold. A run
  whose `status` is `ok` is said as one that ended ok without working (M106
  §6): its settle passes it only when it was kept quiet (`heal_settled/3`).

  A failure a heal opened, joined or concluded is said by the heal's own
  line (`heal_line/2`), so this line is nil for it, but for quiet retries
  used up: that is said here, and the heal's `opened`, `joined` or `verdict`
  line follows. Nil for a run with no settlement (a cue run's). Total over
  its facts: any maps give a line or nil. Ids, the run's `failure_kind` and
  the settlement's numbers only, never the run's error.
  """
  @spec run_line(map(), map(), term()) :: log_line() | nil
  def run_line(job, run, settlement) when is_map(job) and is_map(run) do
    settlement = if is_map(settlement), do: settlement, else: %{}

    case Enum.reject([retry_said(settlement), kept_said(settlement, job)], &is_nil/1) do
      [] ->
        nil

      said ->
        prefix =
          "Scheduled job #{id_said(Map.get(job, :id))} run #{id_said(Map.get(run, :id))} " <>
            ended_said(run)

        kind = kind_said(kind_of(run, settlement))
        {run_level(settlement), prefix <> kind <> "; " <> Enum.join(said, "; ")}
    end
  end

  defp ended_said(%{status: "ok"}), do: "ended ok without working"
  defp ended_said(_failed), do: "failed"

  # A failed run's kind is its own; an ok run has none, and its kind is the
  # one its heal took it as.
  defp kind_of(%{status: "ok"}, settlement), do: Map.get(settlement, :failure_kind)
  defp kind_of(run, _settlement), do: Map.get(run, :failure_kind)

  defp retry_said(%{disposition: :retry} = settlement),
    do: "quiet retry" <> attempt_said(settlement) <> retry_when(Map.get(settlement, :retry_at))

  defp retry_said(%{disposition: :exhausted} = settlement),
    do: "its quiet retries are used up" <> in_a_row(settlement)

  defp retry_said(_none_or_unknown), do: nil

  defp attempt_said(%{attempts: attempts}) when is_integer(attempts), do: " #{token(attempts)}"
  defp attempt_said(_settlement), do: ""

  # A retry's time to the second, in UTC.
  defp retry_when(%DateTime{} = at) do
    utc = at |> DateTime.to_unix() |> DateTime.from_unix!()
    " runs at #{token(DateTime.to_iso8601(utc))}"
  end

  defp retry_when(nil), do: " is the job's next run"
  defp retry_when(_unsaid), do: " is set"

  defp in_a_row(%{attempts: attempts}) when is_integer(attempts),
    do: " after #{token(attempts)} failed runs in a row"

  defp in_a_row(_settlement), do: ""

  # A failure no heal took: kept quiet by one that closed lately for the same
  # subject and kind, so nothing reaches the owner, or a job that is not the
  # owner's (`Memory.Repo.JobHealsSql.settle/5`).
  defp kept_said(%{heal: :quiet} = settlement, job) do
    subject =
      settlement
      |> Map.take([:subject_kind, :subject_id])
      |> Map.put(:job_id, Map.get(job, :id))

    "the owner is not told: a heal for the same failure closed lately" <>
      placed(subject, [:subject])
  end

  defp kept_said(%{heal: :out_of_scope}, _job),
    do: "no heal opens: the job was not set up by the owner"

  defp kept_said(_taken_retried_or_unknown, _job), do: nil

  defp run_level(%{disposition: :exhausted}), do: :warning
  defp run_level(_settlement), do: :info

  defp kind_said(kind) do
    case token(kind) do
      nil -> ""
      said -> " (#{said})"
    end
  end

  @doc """
  The heal events a scheduled run's settle caused: `opened`, `joined` or
  `verdict` for a failure a heal took, with the settlement's `failure_kind`,
  `subject_kind` and `subject_id` (an ok run's included, M106 §6), and
  `closed` (outcome `healed`) for each heal an ok run closed. A failure
  retried, kept quiet or out of scope causes none; its `run_error` says which.
  An ok run that did not work and was kept quiet has no `run_error`, so its
  one log line is written here (`run_line/3`).
  """
  @spec heal_settled(map(), map(), map()) :: :ok
  def heal_settled(job, run, %{heal: heal, healed: healed} = settlement) when is_list(healed) do
    ids = %{job_id: job.id, run_id: run.id}

    case heal do
      {phase, heal_id} when phase in [:opened, :joined, :verdict] ->
        taken = Map.take(settlement, [:failure_kind, :subject_kind, :subject_id])
        heal(Atom.to_string(phase), ids |> Map.merge(taken) |> Map.put(:heal_id, heal_id))

      :quiet ->
        write_log(quiet_ok_line(job, run, settlement))

      _none_or_out_of_scope ->
        :ok
    end

    Enum.each(healed, &heal("closed", Map.merge(ids, %{heal_id: &1, outcome: "healed"})))
  end

  # A failed run's quiet is said with its `run_error`; only an ok run's is
  # said by its settle.
  defp quiet_ok_line(job, %{status: "ok"} = run, settlement), do: run_line(job, run, settlement)
  defp quiet_ok_line(_job, _failed_run, _settlement), do: nil

  @doc """
  One phase of a heal's life (`opened`, `joined`, `verdict`, `decided`,
  `rerun`, `delivered`, `delivery_failed`, `closed` or `answered`), with its
  `heal_id` and whatever of `job_id`, `run_id`, `subject_kind`,
  `subject_id`, `failure_kind`, `outcome`, `attempts`, `dead_letter`,
  `platform`, `error`, `conclusion`, `decision` (what code carried out),
  `requested` (what the heal run asked), `refusal` (why code did not carry
  the request out), `read_outside`, on `rerun` its `rerun_outcome`
  (`started`, `running`, `refused` or `unanswered`), and on `answered` the
  owner's `answer` (`apply` or `leave`), whether the change was `applied`
  and, as its `platform`, the kind of surface the answer came from, the
  phase knows. The step is also one line in the engine log (`heal_line/2`).
  """
  @spec heal(String.t(), map()) :: :ok
  def heal(phase, %{heal_id: heal_id} = facts)
      when phase in @heal_phases and is_binary(heal_id) do
    job_id = Map.get(facts, :job_id)

    metadata =
      facts
      |> Map.take(
        ~w(job_id run_id subject_kind subject_id failure_kind outcome attempts dead_letter platform
           conclusion decision requested refusal read_outside rerun_outcome answer applied)a
      )
      |> Map.merge(%{
        agent: if(job_id, do: "scheduled:#{job_id}", else: "job_heal"),
        phase: phase,
        heal_id: heal_id,
        error: facts |> Map.get(:error) |> heal_error()
      })

    execute(@heal_event, %{count: 1}, metadata)
    write_log(heal_line(phase, metadata))
  end

  defp heal_error(nil), do: nil
  defp heal_error(error), do: error |> format_error() |> String.slice(0, 500)

  @doc """
  The engine log's line for one step of a heal, from the facts its `job_heal`
  row carries: the heal's id, what happened, and the ids and Fermix's own
  words that place it (job, run, failure kind, subject, platform). A job's
  heal is placed by its job once; a provider's or a plugin's by its subject
  on every line whose facts carry it. An ok run's close carries only that
  run and its job, so it names them as the run that closed the heal. Never
  the failure's words (`error`), the look's note or a change's values,
  which can hold outside content.

  `warning` for a step that says something went wrong (a run the heal
  watched that did not work either, a send that failed on an attempt that
  was not its last, a heal closed `still_failing`), `info` for the rest.

  Nil for a step its caller already logs with more said, so no step is two
  lines: a refused or redirected decision (`Jobs.HealRun` warns what was
  asked and what Fermix carries out), a rerun that started no run of its own
  (`Jobs.HealRun` logs `running`, `refused` and `unanswered` where it asks),
  a dead letter, and a message that never reached a send (no attempt
  counted), each a warning in `Jobs.HealRun`. A failed run whose quiet
  retries are used up has its own line before its heal's (`run_line/3`):
  the two say different things.

  Total over its facts: a step whose fact is missing or odd still gets a
  plain line naming the step and the ids it has.
  """
  @spec heal_line(String.t(), map()) :: log_line() | nil
  def heal_line(phase, facts) when phase in @heal_phases and is_map(facts) do
    case heal_step(phase, facts) do
      nil -> nil
      {level, said} -> {level, heal_said(facts, said, placed_keys(phase))}
      {level, said, keys} -> {level, heal_said(facts, said, keys)}
    end
  end

  defp heal_step("opened", _facts), do: {:info, "opened"}
  defp heal_step("joined", _facts), do: {:info, "joined by a later run"}

  # A watched run that failed, or that ended ok while its tool never worked;
  # the heal is open again, and what it sends next is the verdict.
  defp heal_step("verdict", _facts),
    do:
      {:warning,
       "a run it watched did not work either; its next message says the job still fails"}

  defp heal_step("decided", %{refusal: refusal}) when not is_nil(refusal), do: nil

  defp heal_step("decided", facts) do
    case token(Map.get(facts, :decision)) do
      nil -> {:info, "its decision was recorded"}
      "none" -> {:info, "its look gave no decision"}
      decision -> {:info, "its decision is #{decision}"}
    end
  end

  defp heal_step("rerun", %{rerun_outcome: outcome})
       when outcome in ["running", "refused", "unanswered"],
       do: nil

  defp heal_step("rerun", %{rerun_outcome: "started"}), do: {:info, "its rerun started"}
  defp heal_step("rerun", _facts), do: {:info, "its rerun was asked for"}

  defp heal_step("delivered", facts), do: {:info, "its #{message_said(facts)} was delivered"}
  defp heal_step("delivery_failed", %{dead_letter: true}), do: nil

  # Not a dead letter: the attempt is counted and another is to come.
  defp heal_step("delivery_failed", %{dead_letter: false, attempts: attempts} = facts)
       when is_integer(attempts) do
    said = "its #{message_said(facts)} could not be sent on attempt #{token(attempts)}"
    {:warning, said <> ", which was not the last"}
  end

  defp heal_step("delivery_failed", %{dead_letter: false}), do: nil

  defp heal_step("delivery_failed", facts),
    do: {:warning, "its #{message_said(facts)} could not be sent"}

  # An ok run's close carries only that run and its job, which for a
  # provider's or a plugin's heal is whichever job's run proved it: it is
  # named as the run that closed the heal, never as the heal's own job.
  defp heal_step("closed", facts) do
    case {token(Map.get(facts, :outcome)), ran_said(facts)} do
      {nil, _ran} ->
        {:info, "closed"}

      {"healed", ran} when is_binary(ran) ->
        {:info, "closed as healed: #{ran} ended ok", [:subject, :platform]}

      {"still_failing", _ran} ->
        {:warning, "closed as still_failing"}

      {outcome, _ran} ->
        {:info, "closed as #{outcome}"}
    end
  end

  defp heal_step("answered", facts) do
    answered =
      case token(Map.get(facts, :answer)) do
        nil -> "the owner answered"
        answer -> "the owner answered #{answer}"
      end

    {:info, answered <> applied_said(Map.get(facts, :applied))}
  end

  defp placed_keys(phase) when phase in ["opened", "joined", "verdict"], do: @failure_placed
  defp placed_keys(_phase), do: @placed

  # A run by its own id and its job's, when the facts have its id.
  defp ran_said(facts) do
    case {token(Map.get(facts, :job_id)), token(Map.get(facts, :run_id))} do
      {_job, nil} -> nil
      {nil, run} -> "run #{run}"
      {job, run} -> "job #{job} run #{run}"
    end
  end

  defp message_said(%{conclusion: "verdict"}), do: "verdict"
  defp message_said(_first_or_none), do: "message"

  defp applied_said(true), do: "; the change was applied"
  defp applied_said(false), do: "; the change was not applied"
  defp applied_said(_unsaid), do: ""

  @doc """
  The engine log's line for Fermix's look at a heal (M106 §5.5), from the
  facts its bookend carries: `:start` with the look's session (the key to
  its trace) and the failed run; `:complete` with how long it took (the
  heal's `decided` line says what it decided); `:error` for a look the
  watchdog stopped, a `warning` with how long it ran. Nil for a look that
  failed, which `Jobs.HealDiagnosis` warns of with its reason. Total over its
  facts, as `heal_line/2` is.
  """
  @spec look_line(:start | :complete | :error, map()) :: log_line() | nil
  def look_line(stage, facts) when stage in [:start, :complete, :error] and is_map(facts) do
    case look_step(stage, facts) do
      nil -> nil
      {level, said, keys} -> {level, heal_said(facts, said, keys)}
    end
  end

  defp look_step(:start, _facts), do: {:info, "its look started", [:job_id, :run_id, :session_id]}

  defp look_step(:complete, facts),
    do: {:info, "its look finished" <> took("in", facts), @look_placed}

  defp look_step(:error, %{status: "error"}), do: nil

  defp look_step(:error, %{status: "timeout"} = facts),
    do: {:warning, "its look ran out of time" <> took("after", facts), @look_placed}

  defp look_step(:error, facts),
    do: {:warning, "its look ended" <> took("after", facts), @look_placed}

  defp took(word, %{duration_ms: ms}) when is_integer(ms), do: " #{word} #{token(ms)} ms"
  defp took(_word, _facts), do: ""

  defp heal_said(facts, said, keys),
    do: "Job heal #{id_said(Map.get(facts, :heal_id))}: #{said}#{placed(facts, keys)}"

  # The ids and words that place a step, each only when the step knows it.
  defp placed(facts, keys) do
    case Enum.flat_map(keys, &place(&1, facts)) do
      [] -> ""
      parts -> " (" <> Enum.join(parts, ", ") <> ")"
    end
  end

  # A subject that is the line's own job is said once, as the job.
  defp place(:subject, facts) do
    kind = token(Map.get(facts, :subject_kind))
    id = token(Map.get(facts, :subject_id))

    cond do
      is_nil(kind) or is_nil(id) -> []
      kind == "job" and id == token(Map.get(facts, :job_id)) -> []
      true -> ["subject #{kind} #{id}"]
    end
  end

  defp place(key, facts) do
    case token(Map.get(facts, key)) do
      nil -> []
      value -> ["#{Map.fetch!(@place_labels, key)} #{value}"]
    end
  end

  defp id_said(id), do: token(id) || "?"

  # A value as one token of a log line, checked here where it is said:
  # letters, digits and `_ . : @ + / -` kept, every other byte (a line break,
  # a control character, a space, any byte of a non-ASCII character) said as
  # `?`, and at most `@token_max` bytes, cut in the middle. A string, an atom
  # or an integer; anything else, and an empty value, is not said.
  defp token(value) when is_binary(value) and value != "" do
    safe = String.replace(value, ~r/[^A-Za-z0-9_.:@+\/-]/, "?")
    size = byte_size(safe)

    if size > @token_max,
      do:
        binary_part(safe, 0, @token_keep) <>
          "..." <> binary_part(safe, size - @token_keep, @token_keep),
      else: safe
  end

  defp token(value) when is_integer(value), do: value |> Integer.to_string() |> token()

  defp token(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> token()

  defp token(_unsaid), do: nil

  # The one effect a line has: the engine log, at its level.
  defp write_log(nil), do: :ok

  defp write_log({level, line}) when level in [:info, :warning] and is_binary(line),
    do: Logger.log(level, line)

  @doc """
  A heal run's opener (M106 §5.5), before its loop starts: its correlation
  and `max_duration_ms`, its watchdog and the exporter's sweep floor. Its
  line in the engine log names the look's session (`look_line/2`).
  """
  @spec heal_run_start(heal_run(), pos_integer()) :: :ok
  def heal_run_start(%{session_id: session_id} = run, max_duration_ms)
      when is_binary(session_id) and is_integer(max_duration_ms) and max_duration_ms > 0 do
    metadata = Map.put(heal_run_metadata(run), :max_duration_ms, max_duration_ms)
    execute(@heal_run_start_event, %{count: 1}, metadata)
    write_log(look_line(:start, metadata))
  end

  @doc """
  A heal run whose loop finished: the `decision` it asked for (`none` when
  it gave none), before code's checks, which the heal's `decided` phase says.
  Its line says how long the look took.
  """
  @spec heal_run_complete(heal_run(), String.t(), non_neg_integer()) :: :ok
  def heal_run_complete(run, decision, duration_ms)
      when decision in @heal_run_decisions and is_integer(duration_ms) do
    metadata = Map.put(heal_run_metadata(run), :decision, decision)
    execute(@heal_run_complete_event, %{duration_ms: duration_ms}, metadata)
    write_log(look_line(:complete, Map.put(metadata, :duration_ms, duration_ms)))
  end

  @doc """
  A heal run whose loop did not finish: the watchdog stopped it (`timeout`)
  or it failed (`error`), with its reason bounded to 500 characters. A
  timeout's line is a warning with how long it ran; a failure's is
  `Jobs.HealDiagnosis`'s own.
  """
  @spec heal_run_error(heal_run(), String.t(), non_neg_integer(), term()) :: :ok
  def heal_run_error(run, status, duration_ms, error)
      when status in ["timeout", "error"] and is_integer(duration_ms) do
    metadata = Map.merge(heal_run_metadata(run), %{status: status, error: heal_error(error)})
    execute(@heal_run_error_event, %{count: 1, duration_ms: duration_ms}, metadata)
    write_log(look_line(:error, Map.put(metadata, :duration_ms, duration_ms)))
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
