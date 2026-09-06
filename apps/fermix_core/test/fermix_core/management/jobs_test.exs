defmodule FermixCore.Management.JobsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Management.Jobs
  alias FermixCore.Plugins.Dist.Lock

  setup context do
    tasks = :"jobs_tasks_#{:erlang.phash2(context.test)}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    server =
      start_supervised!(
        {Jobs, name: :"jobs_#{:erlang.phash2(context.test)}", task_supervisor: tasks}
      )

    %{server: server}
  end

  defp opts(server, extra \\ []), do: Keyword.put(extra, :server, server)

  # A run that blocks until this test releases it, so a "running" assertion is
  # about the job model rather than about a race with a fast operation.
  defp blocking_run(owner) do
    fn _job_id, _report ->
      send(owner, {:running, self()})

      receive do
        {:finish, outcome} -> outcome
      end
    end
  end

  describe "the job view" do
    test "a started job carries every published field", %{server: server} do
      owner = self()

      assert {:ok, view} =
               Jobs.start(
                 :provider_probe,
                 opts(server, name: "anthropic", run: blocking_run(owner))
               )

      assert Map.keys(view) |> Enum.sort() ==
               ~w(budget_ms failure finished_at job_id kind phase progress result started_at status)

      assert String.starts_with?(view["job_id"], "job:")
      assert view["kind"] == "provider_probe"
      assert view["status"] == "running"
      assert view["phase"] == nil
      assert view["progress"] == nil
      assert view["budget_ms"] == Jobs.budget_ms(:provider_probe)
      assert {:ok, _at, 0} = DateTime.from_iso8601(view["started_at"])
      assert view["finished_at"] == nil
      assert view["result"] == nil
      assert view["failure"] == nil

      assert_receive {:running, pid}
      send(pid, {:finish, {:ok, %{}}})
    end

    test "a completed job carries its result and drops its phase", %{server: server} do
      owner = self()

      run = fn _job_id, report ->
        report.({:phase, "calling"})
        send(owner, {:reported, self()})

        receive do
          {:finish, outcome} -> outcome
        end
      end

      assert {:ok, started} = Jobs.start(:provider_probe, opts(server, name: "a", run: run))
      assert_receive {:reported, pid}

      assert {:ok, running} = Jobs.get(started["job_id"], opts(server))
      assert running["phase"] == "calling"

      send(pid, {:finish, {:ok, %{"model" => "m", "latency_ms" => 12}}})

      assert {:ok, done} = eventually_terminal(server, started["job_id"])
      assert done["status"] == "completed"
      assert done["phase"] == nil
      assert done["result"] == %{"model" => "m", "latency_ms" => 12}
      assert done["failure"] == nil
      assert {:ok, _at, 0} = DateTime.from_iso8601(done["finished_at"])
    end

    # The phase a run died in is part of the diagnosis, so a failure keeps it
    # while a clean finish clears it.
    test "a failed job keeps the phase it stopped in and carries the daemon's sentence", %{
      server: server
    } do
      run = fn _job_id, report ->
        report.({:phase, "verifying"})
        {:error, {:unavailable, "cosign was not found on the resolved PATH."}}
      end

      assert {:ok, started} =
               Jobs.start(:capability_install, opts(server, name: "meetbot", run: run))

      assert {:ok, failed} = eventually_terminal(server, started["job_id"])

      assert failed["status"] == "failed"
      assert failed["phase"] == "verifying"
      assert failed["result"] == nil

      assert failed["failure"] == %{
               "code" => "unavailable",
               "sentence" => "cosign was not found on the resolved PATH."
             }
    end

    test "progress rides the view as done, total and unit", %{server: server} do
      owner = self()

      run = fn _job_id, report ->
        report.({:progress, %{done: 4, total: 18, unit: "steps"}})
        send(owner, {:reported, self()})

        receive do
          {:finish, outcome} -> outcome
        end
      end

      assert {:ok, started} =
               Jobs.start(:capability_install, opts(server, name: "meetbot", run: run))

      assert_receive {:reported, pid}

      assert {:ok, view} = Jobs.get(started["job_id"], opts(server))
      assert view["progress"] == %{"done" => 4, "total" => 18, "unit" => "steps"}

      send(pid, {:finish, {:ok, %{}}})
    end
  end

  describe "bounds" do
    test "refuses a second run of the same kind and name", %{server: server} do
      owner = self()
      run = blocking_run(owner)

      assert {:ok, _view} = Jobs.start(:provider_probe, opts(server, name: "anthropic", run: run))
      assert_receive {:running, pid}

      assert {:error, :busy} =
               Jobs.start(:provider_probe, opts(server, name: "anthropic", run: run))

      assert {:ok, _other} = Jobs.start(:provider_probe, opts(server, name: "openai", run: run))

      send(pid, {:finish, {:ok, %{}}})
    end

    test "refuses beyond the published concurrency bound", %{server: server} do
      owner = self()
      run = blocking_run(owner)

      for index <- 1..Jobs.max_concurrent() do
        assert {:ok, _view} =
                 Jobs.start(:provider_probe, opts(server, name: "p#{index}", run: run))
      end

      assert {:error, :busy} = Jobs.start(:provider_probe, opts(server, name: "extra", run: run))
    end

    test "a run that outlives its budget finishes timed out", %{server: server} do
      run = fn _job_id, _report ->
        Process.sleep(5_000)
        {:ok, %{}}
      end

      assert {:ok, started} =
               Jobs.start(:provider_probe, opts(server, name: "slow", run: run, budget_ms: 30))

      assert {:ok, view} = eventually_terminal(server, started["job_id"])
      assert view["status"] == "timed_out"
      assert view["failure"]["code"] == "timed_out"
    end

    test "every kind publishes a budget and a closed phase vocabulary" do
      for kind <- Jobs.kinds() do
        assert is_integer(Jobs.budget_ms(kind)) and Jobs.budget_ms(kind) > 0
        assert is_list(Jobs.phases(kind))
      end
    end

    # A phase the app has no sentence for renders as nothing, so a phase a run
    # can report and the vocabulary does not publish is invisible copy.
    test "a reported phase must be in its kind's published vocabulary", %{server: server} do
      run = fn _job_id, report ->
        report.({:phase, "not_a_phase"})
        Process.sleep(5_000)
        {:ok, %{}}
      end

      assert {:ok, started} = Jobs.start(:provider_probe, opts(server, name: "a", run: run))
      assert {:ok, view} = eventually_terminal(server, started["job_id"])

      assert view["status"] == "failed"
      assert view["failure"]["code"] == "internal_error"
    end
  end

  describe "get, list and cancel" do
    test "an unretained job is unknown", %{server: server} do
      assert {:error, :unknown_job} = Jobs.get("job:missing", opts(server))
      assert {:error, :unknown_job} = Jobs.cancel("job:missing", opts(server))
    end

    test "list reports every retained job, newest last", %{server: server} do
      owner = self()

      assert {:ok, first} =
               Jobs.start(:provider_probe, opts(server, name: "a", run: blocking_run(owner)))

      assert_receive {:running, first_pid}

      assert {:ok, second} =
               Jobs.start(:auth, opts(server, name: "xai", run: blocking_run(owner)))

      assert_receive {:running, second_pid}

      assert {:ok, jobs} = Jobs.list(opts(server))
      assert Enum.map(jobs, & &1["job_id"]) == [first["job_id"], second["job_id"]]

      send(first_pid, {:finish, {:ok, %{}}})
      send(second_pid, {:finish, {:ok, %{}}})
    end

    test "cancelling stops the run and answers the terminal view", %{server: server} do
      owner = self()

      assert {:ok, started} =
               Jobs.start(
                 :meetings_signin,
                 opts(server, name: "meetings", run: blocking_run(owner))
               )

      assert_receive {:running, pid}
      ref = Process.monitor(pid)

      assert {:ok, view} = Jobs.cancel(started["job_id"], opts(server))
      assert view["status"] == "cancelled"
      assert view["phase"] == nil
      assert view["failure"] == nil
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end

    test "cancelling a finished job is a no-op, not an error", %{server: server} do
      assert {:ok, started} =
               Jobs.start(
                 :provider_probe,
                 opts(server, name: "a", run: fn _job_id, _report -> {:ok, %{}} end)
               )

      assert {:ok, done} = eventually_terminal(server, started["job_id"])
      assert {:ok, again} = Jobs.cancel(started["job_id"], opts(server))
      assert again["status"] == done["status"]
    end

    test "a crashed run finishes failed rather than vanishing", %{server: server} do
      run = fn _job_id, _report -> raise "boom" end

      assert {:ok, started} = Jobs.start(:provider_probe, opts(server, name: "a", run: run))
      assert {:ok, view} = eventually_terminal(server, started["job_id"])

      assert view["status"] == "failed"
      assert view["failure"]["code"] == "internal_error"
    end

    # Cancel stops the run with an exit signal, which skips every `after` clause
    # the body relies on. A run holding the cross-VM plugin store lock must still
    # release it, or one Cancel refuses every plugin operation on this machine
    # until the stale threshold expires.
    test "cancelling a run releases the store lock it was holding", %{server: server} do
      owner = self()
      tmp = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-jobs-lock")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(tmp) end)
      lock = Path.join(tmp, ".lock")

      run = fn _job_id, _report ->
        Lock.with_lock(lock, fn ->
          send(owner, {:holding, self()})

          receive do
            {:finish, outcome} -> outcome
          end
        end)
      end

      assert {:ok, started} = Jobs.start(:plugin_install, opts(server, name: "google", run: run))
      assert_receive {:holding, pid}
      ref = Process.monitor(pid)
      assert File.exists?(lock)

      assert {:ok, view} = Jobs.cancel(started["job_id"], opts(server))
      assert view["status"] == "cancelled"
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      # Bounded, and stale-breaking off, so a pass can only come from a real
      # release rather than from the ten-minute threshold.
      assert :reacquired =
               Lock.with_lock(lock, fn -> :reacquired end,
                 attempts: 50,
                 delay_ms: 10,
                 stale_after_ms: 600_000
               )

      refute File.exists?(lock)
    end
  end

  describe "awaiting a value the run mints" do
    test "the start call answers with the value the run reported", %{server: server} do
      owner = self()

      run = fn _job_id, report ->
        report.(
          {:ready, %{"authorize_url" => "https://auth.example/x", "expires_in_ms" => 300_000}}
        )

        send(owner, {:running, self()})

        receive do
          {:finish, outcome} -> outcome
        end
      end

      assert {:ok, view} =
               Jobs.start(:auth, opts(server, name: "openai_codex", run: run, await: true))

      assert view["authorize_url"] == "https://auth.example/x"
      assert view["expires_in_ms"] == 300_000
      assert view["status"] == "running"

      assert_receive {:running, pid}

      # Returned once: a later read of the same job carries the job view only.
      assert {:ok, polled} = Jobs.get(view["job_id"], opts(server))
      refute Map.has_key?(polled, "authorize_url")

      send(pid, {:finish, {:ok, %{}}})
    end

    test "a run that fails before minting the value answers with the failed job", %{
      server: server
    } do
      run = fn _job_id, _report -> {:error, {:unavailable, "Port 1455 is already in use."}} end

      assert {:ok, view} =
               Jobs.start(:auth, opts(server, name: "openai_codex", run: run, await: true))

      assert view["status"] == "failed"
      assert view["failure"]["sentence"] == "Port 1455 is already in use."
      refute Map.has_key?(view, "authorize_url")
    end

    test "a run that never mints the value is cancelled and refused", %{server: server} do
      owner = self()

      assert {:error, :await_timeout} =
               Jobs.start(
                 :auth,
                 opts(server,
                   name: "openai_codex",
                   run: blocking_run(owner),
                   await: true,
                   await_timeout_ms: 30
                 )
               )

      assert {:ok, []} = running_jobs(server)
    end
  end

  # The grace is a bound, not a promise: a body that traps exits and ignores the
  # signal is killed when it expires, so one wedged run cannot hold a slot for
  # the rest of the daemon's life.
  test "a run that ignores :shutdown is killed when the cancel grace expires", context do
    owner = self()
    tasks = :"jobs_grace_tasks_#{:erlang.phash2(context.test)}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    server =
      start_supervised!(
        {Jobs,
         name: :"jobs_grace_#{:erlang.phash2(context.test)}",
         task_supervisor: tasks,
         cancel_grace_ms: 30},
        id: :jobs_grace
      )

    run = fn _job_id, _report ->
      Process.flag(:trap_exit, true)
      send(owner, {:running, self()})
      Process.sleep(:infinity)
    end

    assert {:ok, started} = Jobs.start(:meetings_signin, opts(server, name: "m", run: run))
    assert_receive {:running, pid}
    ref = Process.monitor(pid)

    assert {:ok, view} = Jobs.cancel(started["job_id"], opts(server))
    assert view["status"] == "cancelled"

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
  end

  # Retention is a promise about age, so a job past the window must be gone to
  # the next reader rather than to the next job event: a daemon that starts no
  # further job would otherwise keep answering with a job it says it dropped.
  describe "retention" do
    test "a job past the retention window is gone from get", context do
      {server, clock} = retention_server(context)
      job_id = finished_job(server)

      Agent.update(clock, fn _now -> Jobs.retention_ms() + 1 end)

      assert {:error, :unknown_job} = Jobs.get(job_id, opts(server))
    end

    test "a job past the retention window is gone from list", context do
      {server, clock} = retention_server(context)
      _job_id = finished_job(server)

      Agent.update(clock, fn _now -> Jobs.retention_ms() + 1 end)

      assert {:ok, []} = Jobs.list(opts(server))
    end
  end

  # A server on a clock this test drives, so retention is asserted at an exact
  # age rather than by sleeping past a ten-minute window.
  defp retention_server(context) do
    tasks = :"jobs_retention_tasks_#{:erlang.phash2(context.test)}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)
    clock = start_supervised!({Agent, fn -> 0 end}, id: :retention_clock)

    server =
      start_supervised!(
        {Jobs,
         name: :"jobs_retention_#{:erlang.phash2(context.test)}",
         task_supervisor: tasks,
         clock: fn -> Agent.get(clock, & &1) end},
        id: :retention_jobs
      )

    {server, clock}
  end

  defp finished_job(server) do
    assert {:ok, started} =
             Jobs.start(
               :provider_probe,
               opts(server, name: "a", run: fn _id, _report -> {:ok, %{}} end)
             )

    assert {:ok, done} = eventually_terminal(server, started["job_id"])
    assert done["status"] == "completed"
    started["job_id"]
  end

  defp running_jobs(server) do
    {:ok, jobs} = Jobs.list(server: server)
    {:ok, Enum.filter(jobs, &(&1["status"] == "running"))}
  end

  # Terminal status is what a poller waits for, so the helper polls the same way
  # the app does rather than sleeping a guessed interval.
  defp eventually_terminal(server, job_id, attempts \\ 200)

  defp eventually_terminal(_server, job_id, 0), do: {:error, {:never_terminal, job_id}}

  defp eventually_terminal(server, job_id, attempts) do
    {:ok, view} = Jobs.get(job_id, server: server)

    if view["status"] == "running" do
      Process.sleep(10)
      eventually_terminal(server, job_id, attempts - 1)
    else
      {:ok, view}
    end
  end
end
