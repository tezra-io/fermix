defmodule FermixCore.Jobs.HealRun do
  @moduledoc """
  One heal's conclusion (M106 §5.4, §5.5, §5.8, §5.9): for a job's heal of a
  kind a model could help with, one diagnosis and the move it may make; for
  every heal, the one message code builds and sends.

  The Scheduler claims a heal under a lease (`Memory.Repo.JobHealsSql`, the
  heal `diagnosing`) and starts this process under `Jobs.RunnerSupervisor`,
  one at a time in the engine; it monitors it as it does a runner.
  `restart: :temporary`, and `init/1` does no work (it defers to
  `handle_continue/2`), so the Scheduler never waits on a model or a send.

  The run, every write holding the lease:

    1. resolves the owner's inbox once, if the heal holds none, with
       `Delivery.OwnerInbox.for_approval/1`, and stores it; with no inbox the
       delivery is a dead letter, the heal waits, and nothing else is tried;
    2. diagnoses a heal on its first conclusion whose subject is its job and
       whose kind a model could help with (`Jobs.Failure.model_cannot_help?/1`
       false) and that holds no decision yet: one isolated loop
       (`Jobs.HealDiagnosis`) whose decision code checks (`Jobs.HealDecision`).
       A raised limit or a pause is written to the job through
       `Jobs.Registry`, the path an owner's edit takes, right after a write
       that proves the lease still held; then the decision, its note, what
       the run read and the exact change are recorded on the heal. A
       provider's heal, a kind no model can help with, and a verdict run no
       model;
    3. builds the message once with `Jobs.HealMessage` from the store's facts
       and stores it, so every later attempt sends the same text;
    4. sends it once through `Delivery.ChannelSend` under the key
       `job_heal:<id>` (never `job:`, the prefix `Companion.OriginBackfill`
       reads as a run), naming the job as its origin, link previews off;
    5. on a confirmed send, FIRST marks the delivery delivered, which takes
       the heal where its decision says (watching after a rerun or a raised
       limit, waiting otherwise, closed still failing on a verdict), THEN
       writes the message to that conversation's history, only for an inbox
       keyed as a turn there is (`OwnerInbox.dm_origin/1`), and THEN asks for
       a rerun's one run through the path "run now" takes, once per heal (the
       ask stamped by that same write), recording what came of it
       (`rerun_outcome/2`): started, already running, refused (only what
       proves no run will come; the heal then waits on the owner) or
       unanswered (anything that leaves a run possible; the heal keeps
       watching). A history write that exits is logged and the run still
       ends normally;
    6. on a failed send, counts the attempt and sets the next by the harness
       ladder (30 s doubling to a 30 min cap, a rate limit's wait the floor),
       the heal open again; an error no wait clears, the 20th attempt or a
       message a day old makes the delivery a dead letter, which concludes
       the heal as a delivered send does.

  A heal run that dies leaves its lease to run out, and a later pass claims
  the heal again. So the owner can get the message twice: a run that dies
  after its send landed and before its delivered mark (or whose mark found the
  lease gone) leaves a heal the next run sends again. The delivered mark comes
  before the history row so a death between those two never resends. A run
  that dies between a job write and the decision's record leaves the heal
  undecided: the run that claims it next diagnoses it again, from the job as
  it now stands.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Delivery.Error
  alias FermixCore.Delivery.OwnerInbox
  alias FermixCore.Jobs.Delivery
  alias FermixCore.Jobs.Failure
  alias FermixCore.Jobs.HealDecision
  alias FermixCore.Jobs.HealDiagnosis
  alias FermixCore.Jobs.HealMessage
  alias FermixCore.Jobs.Registry
  alias FermixCore.Jobs.Scheduler
  alias FermixCore.Jobs.Telemetry, as: JobTelemetry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo

  @heal_id_key :fermix_job_heal_id
  @send_timeout_ms 60_000
  @backoff_base_ms 30_000
  @backoff_cap_ms 1_800_000
  @max_attempts 20
  @max_age_s 86_400
  # The job's recent runs a diagnosis reads, as the message counts them.
  @recent_runs 8
  # How long a rerun's "run now" is waited for: `run_job_now`'s own wait.
  @rerun_timeout_ms 5_000
  # The most of a stopped Scheduler's exit reason the trace and log say.
  @stop_reason_max 200

  @doc """
  The heal a live heal run holds, read from the process-dictionary key it
  publishes in its own start (`put_heal_id/1`), never by calling it.
  """
  @spec heal_id(pid()) :: String.t() | nil
  def heal_id(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, @heal_id_key)
      nil -> nil
    end
  end

  @doc "Publishes the heal this process runs for `heal_id/1`."
  @spec put_heal_id(String.t()) :: :ok
  def put_heal_id(id) when is_binary(id) do
    Process.put(@heal_id_key, id)
    :ok
  end

  @doc """
  Starts the run for a claimed heal. `opts`: `:heal` (the claimed row),
  `:repo`, `:conversation_store`, `:delivery_opts` (`ChannelSend`'s `:adapter`
  or `:channels`), `:inbox_opts` (`OwnerInbox.for_approval/1`'s seams), `:clock`
  and `:clock_opts` (`FermixCore.Clock`'s); for the diagnosis
  `:capability_registry`, `:skill_registry`, `:scheduler` (the name the
  Scheduler a rerun's "run now" asks is registered under, never a pid, so a
  heal run that outlives a Scheduler restart asks the one running then),
  `:adapter` and `:adapter_opts` (an injected model; the main route
  otherwise), `:bootstrap_dir`, and the test seams `:diagnosis_timeout_ms`
  (the watchdog) and `:rerun_timeout_ms` (the wait for "run now").
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    %{id: id, lease_token: token} = Keyword.fetch!(opts, :heal)
    true = is_binary(id) and is_binary(token)
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    heal = Keyword.fetch!(opts, :heal)
    :ok = put_heal_id(heal.id)

    state = %{
      heal: heal,
      repo: Keyword.fetch!(opts, :repo),
      conversation_store: Keyword.get(opts, :conversation_store, ConversationStore),
      delivery_opts: Keyword.get(opts, :delivery_opts, []),
      inbox_opts: Keyword.get(opts, :inbox_opts, []),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      clock_opts: Keyword.get(opts, :clock_opts, []),
      capability_registry: Keyword.get(opts, :capability_registry, CapabilityRegistry),
      skill_registry: Keyword.get(opts, :skill_registry, SkillRegistry),
      scheduler: Keyword.get(opts, :scheduler, Scheduler),
      adapter: Keyword.get(opts, :adapter),
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      bootstrap_dir: Keyword.get(opts, :bootstrap_dir),
      diagnosis_timeout_ms: Keyword.get(opts, :diagnosis_timeout_ms, HealDiagnosis.watchdog_ms()),
      rerun_timeout_ms: Keyword.get(opts, :rerun_timeout_ms, @rerun_timeout_ms)
    }

    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    with {:ok, inbox} <- inbox(state),
         {:ok, state} <- diagnosis(state),
         {:ok, text} <- message(state) do
      deliver(state, inbox, text)
    else
      {:error, reason} -> log_unsent(state, reason)
    end

    {:stop, :normal, state}
  end

  # --- the inbox and the message, each settled once -----------------------------

  defp inbox(%{heal: %{inbox_platform: platform} = heal}) when is_binary(platform) do
    {:ok,
     %{
       platform: platform,
       destination: heal.inbox_destination,
       thread_scope: heal.inbox_thread_scope
     }}
  end

  defp inbox(state) do
    case OwnerInbox.for_approval(state.inbox_opts) do
      {:ok, inbox} ->
        with :ok <- write(state, {:put_inbox, state.heal.id, token(state), inbox, now(state)}),
             do: {:ok, inbox}

      :no_delivery_target ->
        dead_letter(state, :no_delivery_target)
        {:error, :no_delivery_target}
    end
  end

  defp message(%{heal: %{message: text}}) when is_binary(text), do: {:ok, text}

  defp message(state) do
    with {:ok, facts} <- Repo.job_heals_call({:message_facts, state.heal.id}, server: state.repo) do
      text = HealMessage.build(facts, state.clock_opts)

      with :ok <- write(state, {:put_message, state.heal.id, token(state), text, now(state)}),
           do: {:ok, text}
    end
  end

  # --- the diagnosis (M106 §5.5) ---------------------------------------------------

  defp diagnosis(%{heal: heal} = state) do
    if diagnosable?(heal), do: diagnose(state), else: {:ok, state}
  end

  # A provider's heal is told without a model: the provider that failed is
  # the one that would be asked. So is a kind no model run can help with, a
  # verdict, and a heal decided by a run before this one.
  defp diagnosable?(%{conclusion: "first", decision: nil, subject_kind: "job"} = heal),
    do: not Failure.model_cannot_help?(heal.failure_kind)

  defp diagnosable?(_heal), do: false

  defp diagnose(state) do
    with {:ok, job} <- Repo.get_scheduled_job(state.heal.job_id, server: state.repo),
         {:ok, runs} <- recent_runs(state, job) do
      {ending, decision} = HealDiagnosis.run(diagnosis_args(state, job, runs))

      decision
      |> HealDecision.resolve(job, checks(state))
      |> carry_out(job, state)
      |> record(ending, state)
    end
  end

  defp recent_runs(state, job),
    do: Repo.list_job_runs(%{job_id: job.id}, server: state.repo, limit: @recent_runs)

  defp diagnosis_args(state, job, runs) do
    %{
      heal: state.heal,
      job: job,
      runs: runs,
      parent_session: failed_session(state, runs),
      now: now(state),
      repo: state.repo,
      capability_registry: state.capability_registry,
      skill_registry: state.skill_registry,
      adapter: state.adapter,
      adapter_opts: state.adapter_opts,
      bootstrap_dir: state.bootstrap_dir,
      timeout_ms: state.diagnosis_timeout_ms
    }
  end

  # The failed run the heal last took, whose session the heal run's nests
  # under; nil once its row is gone.
  defp failed_session(%{heal: %{last_run_id: run_id}}, runs) do
    Enum.find_value(runs, fn run -> run.id == run_id && run.session_id end)
  end

  defp checks(state) do
    %{
      repo: state.repo,
      skill_registry: state.skill_registry,
      capability_registry: state.capability_registry,
      now: now(state)
    }
  end

  # A move on the job is written after a write that proves the lease is still
  # this run's, through the registry an owner's edit uses (which clears the
  # job's pending retry as any edit does). A write the registry refuses is
  # never retried another way: the decision goes on as tell.
  defp carry_out(%{decision: "raise_limit", change: change} = plan, job, state) do
    %{"timeout_seconds" => %{"to" => seconds}} = change

    fenced(plan, state, fn ->
      Registry.update_job(job.id, %{timeout_seconds: seconds}, registry_opts(state))
    end)
  end

  defp carry_out(%{decision: "pause"} = plan, job, state),
    do: fenced(plan, state, fn -> Registry.pause_job(job.id, registry_opts(state)) end)

  defp carry_out(plan, _job, _state), do: {:ok, plan}

  defp fenced(plan, state, job_write) do
    with :ok <- write(state, {:hold, state.heal.id, token(state), now(state)}) do
      case job_write.() do
        {:ok, _job} -> {:ok, plan}
        {:error, reason} -> {:ok, HealDecision.refuse(plan, {:move_failed, reason})}
      end
    end
  end

  defp registry_opts(state), do: [repo: state.repo, scheduler: state.scheduler, now: now(state)]

  # The decision is recorded on the heal, under the lease, and traced with
  # what was asked and why a check refused it; a refusal is logged too.
  defp record({:ok, plan}, ending, state) do
    read_outside = read_outside?(ending)
    stored = Map.take(plan, [:decision, :note, :change, :change_job_version])
    stored = Map.put(stored, :read_outside, read_outside)

    with :ok <- write(state, {:decided, state.heal.id, token(state), stored, now(state)}) do
      log_refusal(state, plan)

      trace(state, "decided", %{
        decision: plan.decision,
        requested: plan.requested,
        refusal: plan.refusal,
        read_outside: read_outside,
        error: plan.refusal_detail
      })

      {:ok, %{state | heal: Map.merge(state.heal, stored)}}
    end
  end

  defp record({:error, reason}, _ending, _state), do: {:error, reason}

  # Whether the run read content someone else could have written: its framed
  # failure or a tool's. A run the watchdog killed or that failed left no
  # record of what it read, and absence is no proof it read nothing.
  defp read_outside?({:finished, %MapSet{} = read}), do: MapSet.size(read) > 0
  defp read_outside?(_killed_or_failed), do: true

  defp log_refusal(_state, %{refusal: nil}), do: :ok

  defp log_refusal(state, plan) do
    Logger.warning(
      "Job heal #{state.heal.id}: its run asked #{plan.requested}, which Fermix carries out " <>
        "as #{plan.decision} (#{plan.refusal}#{detail_suffix(plan.refusal_detail)})"
    )
  end

  defp detail_suffix(nil), do: ""
  defp detail_suffix(detail), do: ": " <> detail

  # --- the one send ----------------------------------------------------------------

  defp deliver(state, inbox, text) do
    case send_once(state, inbox, text) do
      :ok -> delivered(state, inbox, text)
      {:error, reason} -> send_failed(state, inbox, reason)
    end
  end

  defp send_once(state, inbox, text) do
    send_opts =
      Delivery.put_origin(
        [proactive_key: "job_heal:#{state.heal.id}", link_previews: false],
        :job,
        job_name(state)
      )

    opts = Keyword.put(state.delivery_opts, :delivery_max_attempts, 1)

    @send_timeout_ms
    |> ChannelSend.with_timeout(fn ->
      ChannelSend.send(inbox.platform, inbox.destination, text, send_opts, opts)
    end)
    |> Error.normalize()
  end

  # The origin a job's message carries names the job; a provider's heal has
  # no one job to name.
  defp job_name(%{heal: %{subject_kind: "job", job_id: job_id}} = state) do
    case Repo.get_scheduled_job(job_id, server: state.repo) do
      {:ok, job} ->
        job.name

      {:error, reason} ->
        Logger.warning(
          "Job heal #{state.heal.id}: its job could not be read (#{inspect(reason)}), " <>
            "so its message names no origin"
        )

        nil
    end
  end

  defp job_name(_state), do: nil

  defp delivered(state, inbox, text) do
    case write(state, {:delivered, state.heal.id, token(state), now(state)}) do
      :ok ->
        trace(state, "delivered", %{platform: inbox.platform})
        trace_concluded(state)
        record_history(state, inbox, text)
        rerun_once(state)

      {:error, reason} ->
        Logger.warning(
          "Job heal #{state.heal.id}: its message was sent, but the delivery could not be " <>
            "marked (#{inspect(reason)}), so a later pass may send it again"
        )
    end
  end

  defp record_history(state, inbox, text) do
    case OwnerInbox.dm_origin(inbox) do
      {:ok, _origin} -> add_history(state, inbox, text)
      :error -> :ok
    end
  end

  defp add_history(state, inbox, text) do
    :ok =
      ConversationStore.add_message({inbox.platform, inbox.destination, :root}, "assistant", text,
        kind: "chat_message",
        metadata: %{job_heal: state.heal.id},
        server: state.conversation_store
      )
  catch
    :exit, reason ->
      Logger.warning(
        "Job heal #{state.heal.id}: its message was delivered, but writing it to the " <>
          "conversation's history exited: #{inspect(reason)}"
      )
  end

  # A verdict's concluding write closed the heal still failing (§5.9).
  defp trace_concluded(%{heal: %{conclusion: "verdict"}} = state),
    do: trace(state, "closed", %{outcome: "still_failing"})

  defp trace_concluded(_state), do: :ok

  # A rerun's one run, asked for after the concluding write that stamped the
  # ask, so the run's settle finds the heal watching. Once per heal: a heal
  # whose rerun was stamped before asks for none, and a verdict never reruns.
  # The message said the run was asked for, which holds whatever comes of it;
  # what did is recorded on the heal before it is traced, and a refusal
  # leaves the heal waiting on the owner, since no run is coming.
  defp rerun_once(%{heal: %{conclusion: "first", decision: "rerun", rerun_at: nil}} = state) do
    {outcome, facts} = state |> start_rerun() |> rerun_outcome(state.rerun_timeout_ms)
    record_rerun(state, outcome)
    log_rerun(state, outcome, facts)
    trace(state, "rerun", Map.put(facts, :rerun_outcome, outcome))
  end

  defp rerun_once(_state), do: :ok

  # The path "run now" takes (`run_job_now`): the cue rule, then the
  # Scheduler's own claim and start, asked of the Scheduler registered under
  # its name now. The check is a read of the store before any ask, so what
  # stops it (a refusal, an error, an exit) is kept apart as `{:not_asked, _}`:
  # it is no answer of the Scheduler's. An exit of the call itself is kept as
  # it is. `rerun_outcome/2` reads both.
  defp start_rerun(state) do
    case check_rerun(state) do
      :ok -> ask_rerun(state)
      {:error, reason} -> {:not_asked, reason}
    end
  end

  defp check_rerun(%{heal: %{job_id: job_id}} = state) do
    Registry.check_run_now(job_id, repo: state.repo)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp ask_rerun(%{heal: %{job_id: job_id}} = state) do
    Scheduler.run_now(state.scheduler, job_id, now: now(state), timeout: state.rerun_timeout_ms)
  catch
    :exit, reason -> {:exit, reason}
  end

  @doc """
  What came of a rerun's "run now", from what came back: the Scheduler's
  reply (`{:ok, run}` or `{:error, reason}`), the call's exit
  (`{:exit, reason}`), or the check before the call that stopped it
  (`{:not_asked, reason}`), with how long the call was waited for. Returns the
  outcome `job_heals.rerun_outcome` records and what the trace and the log
  say of it.

  `refused`, which takes the heal to waiting, only for what proves no run will
  come of this ask; anything that leaves a run possible, or does not say, is
  `unanswered`, and the heal keeps watching, so a run that does start and
  fails still reaches the owner as the verdict.

  The replies `Scheduler.run_now/3` can give (`manual_run/3`,
  `manual_run_job/3`, `claim_manual_run/3`) are `{:ok, run}`,
  `{:error, :already_running}`, `:expired`, `:not_runnable`, `:not_found`
  and the store's own `:disabled`, `:repo_timeout`, `:busy` and any error a
  query returned; `Registry.check_run_now/2` gives `:ok`, the cue sentence,
  `:not_found`, a store error, or exits.
  """
  @spec rerun_outcome(
          {:ok, map()} | {:error, term()} | {:exit, term()} | {:not_asked, term()},
          pos_integer()
        ) :: {String.t(), map()}
  def rerun_outcome(result, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: classify_rerun(result, timeout_ms)

  # The Scheduler claimed the job and started its run.
  defp classify_rerun({:ok, %{id: run_id}}, _timeout_ms), do: {"started", %{run_id: run_id}}

  # A run already holds the job (the Scheduler read it running, or the claim
  # found a run queued or running): its settle concludes the heal, as the
  # rerun's would.
  defp classify_rerun({:error, :already_running}, _timeout_ms), do: {"running", %{}}

  # Replies that prove no run comes of the ask, each read before any claim
  # or by a claim whose transaction rolled back: `:expired` (the job read past
  # its expiry never runs again), `:not_runnable` (read paused, disabled or
  # done, or the claim's own read of it found it so), `:not_found` (the job is
  # gone), `:disabled` (the store keeps nothing, so no claim can be written).
  defp classify_rerun({:error, reason}, _timeout_ms)
       when reason in [:expired, :not_runnable, :not_found, :disabled],
       do: {"refused", %{error: reason}}

  # Every other reply says only "I do not know": `:repo_timeout` (a claim the
  # store had started before its caller's deadline still finishes and can
  # commit late), `:busy` (a claim the store left open can commit with a
  # later write), and any error a query passed on. A run may follow it.
  defp classify_rerun({:error, reason}, _timeout_ms), do: {"unanswered", unclear(reason)}

  # The check before the call stopped it (the cue rule refused, the job is
  # gone, or the store could not be read): the Scheduler was never asked, so
  # no run can come of it, whatever the store does later with that read.
  defp classify_rerun({:not_asked, reason}, _timeout_ms),
    do: {"refused", %{error: {:not_asked, reason}}}

  # No Scheduler was registered under the name at that instant: the call
  # reached nobody, so no run can come of it.
  defp classify_rerun({:exit, {:noproc, _call}}, _timeout_ms),
    do: {"refused", %{error: {:scheduler_unavailable, :noproc}}}

  # The call ran out of time: it is still in the Scheduler's queue and may
  # yet be served, so a run may still start.
  defp classify_rerun({:exit, {:timeout, _call}}, timeout_ms),
    do: {"unanswered", %{error: "run now gave no answer within #{timeout_ms}ms"}}

  # Any other exit (killed, shut down, restarted, stopped, crashed) means the
  # Scheduler had taken the call and stopped while it held it. Its claim may
  # already have landed, and the restarted Scheduler adopts or reaps that
  # run, so a run may still start: never a refusal, which would leave the
  # heal waiting while that run's failure joined it unheard.
  defp classify_rerun({:exit, {reason, _call}}, _timeout_ms), do: {"unanswered", stopped(reason)}

  # An exit of no known shape proves nothing either.
  defp classify_rerun({:exit, reason}, _timeout_ms), do: {"unanswered", stopped(reason)}

  defp unclear(reason) do
    said = reason |> inspect() |> String.slice(0, @stop_reason_max)

    %{
      error:
        "the Scheduler could not tell whether a run was claimed (#{said}); the run may " <>
          "still start"
    }
  end

  # A crash's reason can carry a whole state, so only its start is said.
  defp stopped(reason) do
    said = reason |> inspect() |> String.slice(0, @stop_reason_max)

    %{
      error: "the Scheduler stopped while it held the request (#{said}); the run may still start"
    }
  end

  defp record_rerun(state, outcome) do
    case write(state, {:rerun_outcome, state.heal.id, outcome, now(state)}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Job heal #{state.heal.id}: what came of its rerun (#{outcome}) could not be " <>
            "recorded: #{inspect(reason)}"
        )
    end
  end

  defp log_rerun(_state, "started", _facts), do: :ok

  defp log_rerun(state, "running", _facts) do
    Logger.info(
      "Job heal #{state.heal.id}: its job was already running, so that run is the one the " <>
        "heal watches"
    )
  end

  defp log_rerun(state, "unanswered", facts) do
    Logger.warning(
      "Job heal #{state.heal.id}: its rerun was asked for, and whether a run started is not " <>
        "known (#{facts.error}); the heal watches the job's next run"
    )
  end

  defp log_rerun(state, "refused", %{error: {:not_asked, reason}}) do
    Logger.warning(
      "Job heal #{state.heal.id}: its rerun was never asked for: the check before it " <>
        "stopped it (#{inspect(reason)}); no run started, so the heal waits on the owner"
    )
  end

  defp log_rerun(state, "refused", facts) do
    Logger.warning(
      "Job heal #{state.heal.id}: its rerun did not start (#{inspect(facts.error)}); the " <>
        "heal waits on the owner, and its record says so"
    )
  end

  # --- a failed send ----------------------------------------------------------------

  defp send_failed(state, inbox, reason) do
    attempts = state.heal.delivery_attempts + 1
    now = now(state)

    if dead?(reason, attempts, state.heal, now) do
      dead_letter(state, reason, attempts, inbox)
    else
      next = DateTime.add(now, backoff_ms(attempts, reason), :millisecond)
      failure = %{attempts: attempts, next_delivery_at: next, error: inspect(reason)}
      trace(state, "delivery_failed", %{attempts: attempts, dead_letter: false, error: reason})

      log_write(
        state,
        write(state, {:delivery_failed, state.heal.id, token(state), failure, now})
      )
    end
  end

  # A message is a day old from when it became due: the heal's opening, or
  # for a verdict the failure that reopened it.
  defp dead?(reason, attempts, heal, now) do
    not Error.retryable?(reason) or attempts >= @max_attempts or
      DateTime.diff(now, due_since(heal), :second) >= @max_age_s
  end

  defp due_since(%{conclusion: "verdict", last_failed_at: %DateTime{} = at}), do: at
  defp due_since(%{opened_at: at}), do: at

  # The harness ladder (`Harness.DeliveryWorker`): 30 s after the first
  # failure, doubling to a 30 min cap, and never sooner than a rate limit's
  # own wait.
  defp backoff_ms(attempts, reason) do
    shift = min(attempts - 1, 20)
    ladder = min(@backoff_base_ms * Bitwise.bsl(1, shift), @backoff_cap_ms)

    case Error.retry_after_hint(reason) do
      {:ok, wait_ms} -> max(ladder, min(wait_ms, @backoff_cap_ms))
      :error -> ladder
    end
  end

  # A dead letter concludes the heal as a delivered send does, so a rerun
  # still starts and a verdict still closes.
  defp dead_letter(state, reason, attempts \\ nil, inbox \\ nil) do
    attempts = attempts || state.heal.delivery_attempts
    platform = inbox && inbox.platform

    Logger.warning("Job heal #{state.heal.id}: its message is a dead letter: #{inspect(reason)}")

    trace(state, "delivery_failed", %{
      attempts: attempts,
      dead_letter: true,
      error: reason,
      platform: platform
    })

    failure = %{attempts: attempts, error: inspect(reason)}

    case write(state, {:dead_letter, state.heal.id, token(state), failure, now(state)}) do
      :ok ->
        trace_concluded(state)
        rerun_once(state)

      {:error, reason} ->
        log_write(state, {:error, reason})
    end
  end

  # --- shared ------------------------------------------------------------------------

  defp write(state, request), do: Repo.job_heals_call(request, server: state.repo)

  defp log_write(_state, :ok), do: :ok

  defp log_write(state, {:error, reason}) do
    Logger.warning(
      "Job heal #{state.heal.id}: its delivery could not be recorded: #{inspect(reason)}"
    )
  end

  defp log_unsent(_state, :no_delivery_target), do: :ok

  defp log_unsent(state, reason) do
    trace(state, "delivery_failed", %{dead_letter: false, error: reason})

    Logger.warning(
      "Job heal #{state.heal.id}: its message was not sent (#{inspect(reason)}); " <>
        "a later pass tries again once its lease runs out"
    )
  end

  defp trace(state, phase, facts) do
    JobTelemetry.heal(
      phase,
      Map.merge(
        %{
          heal_id: state.heal.id,
          job_id: state.heal.job_id,
          subject_kind: state.heal.subject_kind,
          subject_id: state.heal.subject_id,
          failure_kind: state.heal.failure_kind,
          conclusion: state.heal.conclusion
        },
        facts
      )
    )
  end

  defp token(state), do: state.heal.lease_token
  defp now(state), do: state.clock.()
end
