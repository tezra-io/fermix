defmodule FermixCore.Memory.RepoTimeoutTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixTestSupport.StalledRepo

  setup do
    %{stalled: start_supervised!(StalledRepo)}
  end

  # The periodic workers' ticks opt in: a Repo stuck behind a long operation
  # skips their work until the next tick instead of exiting them, which under
  # the root supervisor's :rest_for_one restarted every later sibling.
  test "a caller that opts in gets an error when the Repo does not answer in time", ctx do
    assert Repo.next_scheduled_job(server: ctx.stalled, timeout: 50, on_timeout: :error) ==
             {:error, :repo_timeout}
  end

  test "every other caller still exits when the Repo does not answer in time", ctx do
    assert {:timeout, {GenServer, :call, _args}} =
             catch_exit(Repo.next_scheduled_job(server: ctx.stalled, timeout: 50))
  end

  test "the timeout is traced as :repo_call, naming the request, before the error returns", ctx do
    test_pid = self()
    handler = "repo-timeout-test-#{System.unique_integer([:positive])}"

    # The event fires in the calling process, so pinning the test pid keeps
    # another test's Repo timeout out of this assertion.
    :telemetry.attach(
      handler,
      [:fermix, :timeout, :expired],
      fn _event, measurements, meta, _config ->
        if self() == test_pid, do: send(test_pid, {:expired, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, :repo_timeout} = Repo.next_scheduled_job(Repo.periodic_opts(ctx.stalled, 50))
    assert_receive {:expired, %{ms: 50}, %{name: :repo_call}}
  end

  test "periodic_opts/2 is the opt-in every periodic worker passes" do
    assert Repo.periodic_opts(:a_repo, 50) == [server: :a_repo, on_timeout: :error, timeout: 50]
    assert_raise FunctionClauseError, fn -> Repo.periodic_opts(:a_repo, 0) end
  end

  # A caller whose request is safe to skip (a claim of new work, or a read a
  # later tick redoes) passes `skip_when_late: true`: the request then carries
  # the monotonic millisecond its caller gives up at, and the Repo turns it away
  # unrun once that has passed. Every other request goes out as it is and runs
  # when the Repo reaches it, late or not.
  describe "skip_when_late" do
    @message %{
      agent_id: "main",
      owner_id: "default",
      channel: "telegram",
      chat_id: "chat-deadline",
      thread_scope: "root",
      sender: "wren",
      role: "user",
      kind: "chat_message",
      content: "the lantern list for Thursday",
      metadata: %{}
    }
    @selector %{
      agent_id: "main",
      channel: "telegram",
      chat_id: "chat-deadline",
      thread_scope: "root"
    }

    test "an opted-in call carries its timeout from the moment it called" do
      server = start_fake_repo({:ok, "wal"})
      before = System.monotonic_time(:millisecond)

      assert {:ok, "wal"} =
               Repo.journal_mode(server: server, timeout: 7_000, skip_when_late: true)

      after_call = System.monotonic_time(:millisecond)

      assert_receive {:request, {:with_deadline, deadline, :journal_mode}}
      assert deadline >= before + 7_000 and deadline <= after_call + 7_000
    end

    test "an opted-in call that waits forever carries a deadline that never passes" do
      server = start_fake_repo({:ok, "wal"})

      assert {:ok, "wal"} =
               Repo.journal_mode(server: server, timeout: :infinity, skip_when_late: true)

      assert_receive {:request, {:with_deadline, :infinity, :journal_mode}}
    end

    test "a call that does not opt in goes out as it is, with no deadline" do
      server = start_fake_repo({:ok, "wal"})
      assert {:ok, "wal"} = Repo.journal_mode(server: server, timeout: 7_000)
      assert_receive {:request, :journal_mode}
    end

    # A write that records what already happened must land however late: a
    # delivered reminder the Repo skipped would be sent again.
    test "a write that records a send carries no deadline, so it is never turned away" do
      server = start_fake_repo(:ok)
      sent_at = ~U[2031-03-04 05:06:07Z]

      assert :ok =
               Repo.temporal_reminder_delivered("rem_cobalt_7", sent_at,
                 server: server,
                 timeout: 50,
                 on_timeout: :error
               )

      assert_receive {:request, {:temporal_reminder_delivered, "rem_cobalt_7", _stamp}}
    end

    test "a request whose deadline has passed when the Repo reaches it does not run" do
      repo = start_repo()
      passed = System.monotonic_time(:millisecond) - 1

      assert GenServer.call(repo, {:with_deadline, passed, {:insert_message, @message}}) ==
               {:error, :repo_timeout}

      assert Repo.get_messages(@selector, server: repo) == {:ok, []}
    end

    test "a request whose deadline is still ahead runs" do
      repo = start_repo()
      ahead = System.monotonic_time(:millisecond) + 60_000

      assert {:ok, %{id: id}} =
               GenServer.call(repo, {:with_deadline, ahead, {:insert_message, @message}})

      assert {:ok, [%{id: ^id}]} = Repo.get_messages(@selector, server: repo)
    end

    test "a request with no deadline runs" do
      repo = start_repo()

      assert {:ok, %{id: id}} =
               GenServer.call(repo, {:with_deadline, :infinity, {:insert_message, @message}})

      assert {:ok, [%{id: ^id}]} = Repo.get_messages(@selector, server: repo)
    end
  end

  # A process that takes one request, hands it to the test and answers `reply`.
  defp start_fake_repo(reply) do
    test_pid = self()

    start_supervised!(
      {Task,
       fn ->
         receive do
           {:"$gen_call", from, request} ->
             send(test_pid, {:request, request})
             GenServer.reply(from, reply)
         end
       end}
    )
  end

  defp start_repo do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-repo-deadline-#{unique}.db")
    repo = :"repo_deadline_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    repo
  end
end
