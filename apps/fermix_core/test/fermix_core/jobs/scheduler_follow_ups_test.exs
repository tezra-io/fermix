defmodule FermixCore.Jobs.SchedulerFollowUpsTest do
  @moduledoc """
  Follow-up admission inside `Jobs.Scheduler` (M60_WATCHER_CODING_RUNS.md
  §4.2, §9): a `starting` trigger waits for the cue share of the run slots and
  starts a run with `trigger: "watcher"`, never through the manual path; a
  trigger whose follow-up still runs ends refused; a confirmed card starts
  exactly one run; a follow-up whose tool is not set up is refused at its turn.
  """
  use ExUnit.Case, async: true

  import FermixTestSupport.CueFixtures

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Cues.FollowUps
  alias FermixCore.Cues.Ingest
  alias FermixCore.Cues.Watchers
  alias FermixCore.Jobs.CueAdmission
  alias FermixCore.Jobs.RunnerSupervisor
  alias FermixCore.Jobs.Scheduler
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesFollowUpSql

  @now ~U[2026-10-30 12:00:00.000000Z]
  @arrives_ms 10_000
  @token "cp_scheduler-follow-up-token"
  @owner %{platform: "telegram", chat_id: "chat-1", user_id: "owner-1"}

  defmodule ParkedRunner do
    @moduledoc false
    # Publishes its run id like the real Runner, reports the run it was started
    # with, then parks until told to settle it.
    alias FermixCore.Jobs.Runner
    alias FermixCore.Memory.Repo

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
      repo = Keyword.fetch!(opts, :repo)
      parent = self()

      pid =
        spawn_link(fn ->
          :ok = Runner.put_run_id(run.id)
          send(parent, {:labelled, self()})
          send(notify, {:parked, run, self()})
          park(run, repo, notify)
        end)

      receive do
        {:labelled, ^pid} -> {:ok, pid}
      after
        10_000 -> {:error, :label_timeout}
      end
    end

    defp park(run, repo, notify) do
      receive do
        {:finish, %DateTime{} = now} ->
          attrs = Map.merge(run, %{status: "ok", completed_at: now, updated_at: now})
          {:ok, _settled} = Repo.settle_job_run(attrs, server: repo)
          send(notify, {:settled, run.id})
      end
    end
  end

  setup do
    ctx = start_repo("scheduler_follow_ups")
    runner_supervisor = :"follow_up_runner_supervisor_#{System.unique_integer([:positive])}"
    start_supervised!({RunnerSupervisor, name: runner_supervisor})
    registry = :"follow_up_capabilities_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry})
    :ok = CapabilityRegistry.register(registry, tool("shell"))
    Map.merge(ctx, %{runner_supervisor: runner_supervisor, registry: registry})
  end

  test "follow-up runs hold the cue share beside cue runs" do
    monitors = %{make_ref() => %{trigger: "watcher"}, make_ref() => %{trigger: "cue"}}
    assert CueAdmission.active_cue_runs(monitors) == 2
    assert CueAdmission.free_slots(2, monitors, 4) == 1
  end

  test "a starting trigger waits for a free slot, then runs as the watcher's, not by hand",
       ctx do
    first = automatic_watcher!(ctx, "first")
    second = automatic_watcher!(ctx, "second")
    pass!(ctx, first, 1)
    pass!(ctx, second, 2)

    scheduler = start_scheduler(ctx, max_active_runs: 1)

    assert_receive {:parked, %{trigger: "watcher"} = run, pid}, @arrives_ms
    assert run.job_id == first.follow_up_job_id
    drain(scheduler)
    assert [%{state: "started", run_id: run_id}] = triggers(ctx, first)
    assert run_id == run.id
    assert [%{state: "starting"}] = triggers(ctx, second)

    send(pid, {:finish, @now})
    assert_receive {:settled, _run_id}, @arrives_ms
    assert_receive {:parked, %{trigger: "watcher"} = next, _pid}, @arrives_ms
    assert next.job_id == second.follow_up_job_id
    drain(scheduler)
    assert [%{state: "started"}] = triggers(ctx, second)
  end

  test "a trigger whose follow-up still runs ends refused", ctx do
    watcher = automatic_watcher!(ctx, "busy")
    pass!(ctx, watcher, 1)
    pass!(ctx, watcher, 2)

    scheduler = start_scheduler(ctx)

    assert_receive {:parked, _run, _pid}, @arrives_ms
    drain(scheduler)

    assert [
             %{state: "started"},
             %{state: "refused", reason: "Not started: it is already running."}
           ] = triggers(ctx, watcher)

    refute_received {:parked, _second, _pid}
  end

  test "a confirmed card starts exactly one run", ctx do
    watcher = watcher!(ctx, "asking", "approve", ["shell"])
    pass!(ctx, watcher, 1)

    {:ok, [trigger]} =
      Repo.cues_call(CuesFollowUpSql, {:claim_offers, @now, 10}, server: ctx.repo)

    :offered = FollowUps.offer(trigger, offer_opts(ctx))

    {:ok, _reply} =
      FollowUps.confirm(@token, @owner, repo: ctx.repo, now: @now, wake_scheduler: fn -> :ok end)

    assert {:error, _already} = FollowUps.confirm(@token, @owner, repo: ctx.repo, now: @now)

    scheduler = start_scheduler(ctx)
    assert_receive {:parked, %{trigger: "watcher"}, _pid}, @arrives_ms
    Scheduler.tick(scheduler, now: @now)
    drain(scheduler)

    refute_received {:parked, _again, _pid}

    assert [[1]] =
             rows(ctx.conn, "SELECT count(*) FROM job_runs WHERE job_id = ?", [trigger.job_id])
  end

  test "a follow-up whose tool is not set up is refused at its turn, with the held notice", ctx do
    watcher = watcher!(ctx, "unready", "auto", ["codex_run"])
    approve!(ctx, watcher)
    pass!(ctx, watcher, 1)
    test = self()

    scheduler =
      start_scheduler(ctx,
        cue_notice: fn id, kind, data -> send(test, {:notice, id, kind, data}) end
      )

    drain(scheduler)

    assert [%{state: "refused", reason: "codex_run is not set up on this computer" <> _}] =
             triggers(ctx, watcher)

    assert_received {:notice, _id, :follow_up_held, %{reason: "codex_run is not set up" <> _}}
    refute_received {:parked, _run, _pid}
  end

  # --- fixtures ----------------------------------------------------------------------

  defp automatic_watcher!(ctx, name) do
    watcher = watcher!(ctx, name, "auto", ["shell"])
    approve!(ctx, watcher)
    watcher
  end

  defp watcher!(ctx, name, mode, tools) do
    params = %{
      name: name,
      filter: "none",
      daily_cap: 5,
      sources: ["feed-#{name}"],
      follow_up: %{prompt: "Run the deploy check.", allowed_tools: tools, mode: mode}
    }

    {:ok, %{watcher: watcher}} = Watchers.create(params, context(), opts(ctx))
    watcher
  end

  defp approve!(ctx, watcher) do
    {:ok, digest} = Watchers.current_follow_up_digest(watcher.name, opts(ctx))
    {:ok, _approved} = Watchers.approve_follow_up(watcher.name, digest, opts(ctx))
  end

  defp pass!(ctx, watcher, n) do
    [ref] = watcher.sources
    item = item!(%{item_id: "post-#{n}", data: %{"text" => "post #{n}"}, occurred_at: @now}, @now)

    {:ok, _results} =
      Ingest.accept(%{ref: ref, daily_budget: 0}, [item],
        now: @now,
        repo: ctx.repo,
        wake_scheduler: fn -> :ok end,
        wake_filters: fn -> :ok end
      )
  end

  defp triggers(ctx, watcher) do
    ctx.conn
    |> rows(
      "SELECT state, reason, run_id FROM cue_follow_up_triggers WHERE watcher_id = ? " <>
        "ORDER BY rowid",
      [watcher.id]
    )
    |> Enum.map(fn [state, reason, run_id] -> %{state: state, reason: reason, run_id: run_id} end)
  end

  defp start_scheduler(ctx, opts \\ []) do
    name = :"follow_up_scheduler_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Scheduler,
       [
         name: name,
         repo: ctx.repo,
         runner_supervisor: ctx.runner_supervisor,
         capability_registry: ctx.registry,
         scheduler_enabled: true,
         timer_enabled: false,
         runner_module: ParkedRunner,
         runner_notify: self(),
         clock: fn -> @now end,
         cues_running?: fn -> true end,
         cue_notice: Keyword.get(opts, :cue_notice, fn _watcher, _kind, _data -> :ok end),
         follow_up_offer: fn _trigger -> :ok end,
         max_active_runs: Keyword.get(opts, :max_active_runs, 4)
       ]}
    )

    name
  end

  # Waits until every message already in the scheduler's mailbox, and the
  # admission pass any of them requested, has been handled.
  defp drain(scheduler) do
    _state = :sys.get_state(scheduler)
    _state = :sys.get_state(scheduler)
    :ok
  end

  defp context do
    %{
      agent_name: "main",
      conversation_key: {"telegram", "chat-1", :root},
      session_id: "telegram:chat-1:root",
      source_trust: :operator,
      memory_agent_id: "main"
    }
  end

  defp opts(ctx), do: [repo: ctx.repo, now: @now, scheduler: nil, cues_config: []]

  defp offer_opts(ctx) do
    digest = :sha256 |> :crypto.hash(@token) |> Base.encode16(case: :lower)
    binding = Map.put(@owner, :token_digest, digest)

    opts(ctx) ++
      [
        capability_registry: ctx.registry,
        notice: fn _watcher, _kind, _data -> :ok end,
        follow_up_sender: fn _card -> {:ok, binding} end
      ]
  end

  defp tool(name) do
    Capability.new(%{
      name: name,
      description: "a test tool",
      parameters: %{"type" => "object", "properties" => %{}},
      kind: :builtin,
      executor: {__MODULE__, :never, []},
      policy_class: :exec
    })
  end
end
