defmodule FermixCore.Jobs.SchedulerCueReportTest do
  @moduledoc """
  A cue run the scheduler settles `exhausted` (a crash or a reap) tells the
  owner once (M60 §9.4): the failure text, prefixed "Watcher <name> · from
  <source>", with Fermix's report of the run's mandate calls, link previews off.
  A retried run tells nobody.
  """
  use ExUnit.Case, async: true

  import FermixTestSupport.CueFixtures

  alias FermixCore.Jobs.Registry
  alias FermixCore.Jobs.RunnerSupervisor
  alias FermixCore.Jobs.Scheduler
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql

  @now ~U[2026-05-02 14:00:00Z]
  @arrives_ms 10_000

  defmodule CrashingRunner do
    @moduledoc false
    # Publishes its run id like the real Runner, reports what it was started
    # with, then crashes when the test says so.
    alias FermixCore.Jobs.Runner

    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.fetch!(opts, :run).id},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    def start_link(opts) do
      run = Keyword.fetch!(opts, :run)
      notify = Keyword.fetch!(opts, :notify)
      parent = self()

      pid =
        spawn_link(fn ->
          :ok = Runner.put_run_id(run.id)
          send(parent, {:labelled, self()})
          send(notify, {:parked, run, self()})

          receive do
            :crash -> exit(:runner_crashed)
          end
        end)

      receive do
        {:labelled, ^pid} -> {:ok, pid}
      after
        10_000 -> {:error, :label_timeout}
      end
    end
  end

  defmodule RecordingDelivery do
    @moduledoc false
    def send_message(target, text, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:delivery_send, target, text, opts})
      :ok
    end
  end

  defmodule HeldDelivery do
    @moduledoc false
    # Tells the test it is sending, then holds the send until the test lets it go.
    def send_message(_target, _text, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:sending, self()})

      receive do
        :release -> :ok
      after
        10_000 -> {:error, :test_never_released}
      end
    end
  end

  setup do
    ctx = start_repo("scheduler_cue_report")
    runner_supervisor = :"cue_report_runners_#{System.unique_integer([:positive])}"
    start_supervised!({RunnerSupervisor, name: runner_supervisor})
    Map.put(ctx, :runner_supervisor, runner_supervisor)
  end

  test "a crash after an allowed mandate call sends the failure text and the calls once", ctx do
    %{job: job, delivery_id: delivery_id} = cue_task(ctx, 0)
    scheduler = start_scheduler(ctx)
    assert_receive {:parked, run, pid}, @arrives_ms
    assert run.cue_delivery_id == delivery_id

    exec!(ctx.conn, "UPDATE job_runs SET tools_started_at = ?, started_at = ? WHERE id = ?", [
      DateTime.to_iso8601(@now),
      DateTime.to_iso8601(@now),
      run.id
    ])

    mandate_call(ctx.conn, run, job, delivery_id)
    send(pid, :crash)

    assert_receive {:delivery_send, "4242", text, opts}, @arrives_ms
    assert String.starts_with?(text, "Watcher release-watch · from eng-blogs\n\n")
    assert text =~ ~s(Task "Release Notes Task" stopped before it finished)
    assert text =~ "runner crashed"
    assert text =~ "github_create_issue under mandate release-issues: allowed"
    assert Keyword.fetch!(opts, :link_previews) == false
    assert Keyword.fetch!(opts, :proactive_key) == "job:#{run.id}"

    assert eventually(fn ->
             {:ok, settled} = Repo.get_job_run(run.id, server: ctx.repo)
             settled.delivery_status == "sent"
           end)

    _state = :sys.get_state(scheduler)
    refute_received {:delivery_send, _target, _text, _opts}
  end

  test "a crash on the delivery's last attempt sends the failure text", ctx do
    %{delivery_id: delivery_id} = cue_task(ctx, 2)
    _scheduler = start_scheduler(ctx)
    assert_receive {:parked, run, pid}, @arrives_ms
    assert run.cue_delivery_id == delivery_id

    send(pid, :crash)

    assert_receive {:delivery_send, "4242", text, _opts}, @arrives_ms
    assert String.starts_with?(text, "Watcher release-watch · from eng-blogs\n\n")
    refute text =~ "action calls"
  end

  test "a crash that leaves the delivery to retry tells nobody", ctx do
    %{delivery_id: delivery_id} = cue_task(ctx, 0)
    scheduler = start_scheduler(ctx)
    assert_receive {:parked, _run, pid}, @arrives_ms

    send(pid, :crash)

    assert eventually(fn -> delivery_state(ctx.conn, delivery_id) == "passed" end)
    # The scheduler decides in its own loop whether to report; no report task
    # was started for a retried delivery.
    _state = :sys.get_state(scheduler)
    refute_received {:delivery_send, _target, _text, _opts}
  end

  # TLA job_runs witness 45: the report was recorded only after its send, so a
  # daemon that died around the send left a row saying nothing was to be sent.
  # As the runner's own send does, the row reads "pending" while it sends.
  test "the final failure report marks its delivery pending before it sends", ctx do
    %{delivery_id: delivery_id} = cue_task(ctx, 2)
    _scheduler = start_scheduler(ctx, HeldDelivery)
    assert_receive {:parked, run, pid}, @arrives_ms
    assert run.cue_delivery_id == delivery_id

    send(pid, :crash)

    assert_receive {:sending, sender}, @arrives_ms
    {:ok, sending} = Repo.get_job_run(run.id, server: ctx.repo)
    assert {sending.status, sending.delivery_status} == {"error", "pending"}

    send(sender, :release)

    assert eventually(fn ->
             {:ok, settled} = Repo.get_job_run(run.id, server: ctx.repo)
             settled.delivery_status == "sent"
           end)
  end

  # --- fixtures -------------------------------------------------------------------------

  defp start_scheduler(ctx, delivery_adapter \\ RecordingDelivery) do
    name = :"cue_report_scheduler_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Scheduler,
       [
         name: name,
         repo: ctx.repo,
         runner_supervisor: ctx.runner_supervisor,
         scheduler_enabled: true,
         timer_enabled: false,
         runner_module: CrashingRunner,
         runner_notify: self(),
         clock: fn -> @now end,
         cues_running?: fn -> true end,
         max_active_runs: 4,
         delivery_adapter: delivery_adapter,
         delivery_opts: [test_pid: self()],
         delivery_timeout_ms: 10_000
       ]}
    )

    name
  end

  defp cue_task(ctx, task_attempts) do
    {:ok, job} =
      Registry.create_cue_job(
        %{
          created_by_trust: "operator",
          name: "Release Notes Task",
          task_prompt: "Tell me what changed in the release the cue names.",
          delivery_mode: "channel",
          delivery_target: %{"platform" => "telegram", "chat_id" => "4242"}
        },
        repo: ctx.repo,
        scheduler: nil
      )

    watcher_id = "cwt_#{System.unique_integer([:positive])}"

    exec!(
      ctx.conn,
      """
      INSERT INTO cue_watchers (id, name, filter, task_job_id, enabled, created_at, updated_at)
      VALUES (?, 'release-watch', 'none', ?, 1, ?, ?)
      """,
      [watcher_id, job.id, CuesSql.stamp(@now), CuesSql.stamp(@now)]
    )

    exec!(ctx.conn, "INSERT INTO cue_watcher_sources (watcher_id, source_ref) VALUES (?, ?)", [
      watcher_id,
      "eng-blogs"
    ])

    received = CuesSql.stamp(DateTime.add(@now, -600, :second))

    [[cue_id]] =
      rows(
        ctx.conn,
        """
        INSERT INTO cues (source_ref, item_id, type, received_at, content_hash, payload,
          payload_bytes, routed_count, last_seen_at)
        VALUES ('eng-blogs', ?, 'feed.item', ?, ?, '{}', 2, 1, ?) RETURNING id
        """,
        ["item-#{System.unique_integer([:positive])}", received, "h1", received]
      )

    [[delivery_id]] =
      rows(
        ctx.conn,
        """
        INSERT INTO cue_deliveries (cue_id, watcher_id, source_ref, received_at, state,
          task_attempts, ready_at, valid_until)
        VALUES (?, ?, 'eng-blogs', ?, 'passed', ?, ?, ?) RETURNING id
        """,
        [
          cue_id,
          watcher_id,
          received,
          task_attempts,
          received,
          CuesSql.stamp(DateTime.add(@now, 7 * 86_400, :second))
        ]
      )

    %{job: job, delivery_id: delivery_id}
  end

  defp mandate_call(conn, run, job, delivery_id) do
    exec!(
      conn,
      """
      INSERT INTO cue_mandate_calls (id, run_id, job_id, mandate, tool, args_json,
        idempotency_key, delivery_id, decision, created_at, decided_at)
      VALUES (?, ?, ?, 'release-issues', 'github_create_issue', '{"title":"Upgrade"}', ?, ?,
        'allow', ?, ?)
      """,
      [
        "cmc_#{System.unique_integer([:positive])}",
        run.id,
        job.id,
        "key-#{System.unique_integer([:positive])}",
        delivery_id,
        CuesSql.stamp(@now),
        CuesSql.stamp(@now)
      ]
    )
  end

  defp delivery_state(conn, id) do
    [[state]] = rows(conn, "SELECT state FROM cue_deliveries WHERE id = ?", [id])
    state
  end

  defp eventually(fun, deadline_ms \\ @arrives_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        # sleep: the poll interval of a bounded wait on a row another process writes
        Process.sleep(5)
        poll(fun, deadline)
    end
  end
end
