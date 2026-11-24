defmodule FermixCore.Memory.ConversationStoreLoadTest do
  @moduledoc """
  The store's in-memory entry for a conversation is either absent or that
  conversation's whole history up to the store's own bound, never a fragment
  (M106 §5.8, stage S2a): a message written outside any turn, into a
  conversation nobody has read since the store started, must land after the
  stored history and not in place of it.

  Each case keeps ONE store process across the write and the read, with the
  stored rows in the database before the conversation is first touched: a
  fresh store per step would re-create the very state under test.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo

  @key {"telegram", "harbour-chat", :root}
  @check_in "A check-in: did the Port Alder ferry work out on Saturday?"

  # Invented, with absolute timestamps so the stored order is fixed.
  @stored [
    {"user", "When does the ferry leave Port Alder on Saturday?", ~U[2026-03-14 09:00:00Z]},
    {"assistant", "The first Saturday ferry leaves Port Alder at 07:40.",
     ~U[2026-03-14 09:00:05Z]},
    {"user", "Remind me the evening before.", ~U[2026-03-14 09:01:00Z]}
  ]

  # SQLite work behind a loaded runner's file-server queue.
  @durable_write_wait_ms 10_000

  # A repo whose durable delete never lands: it answers a read with the rows it
  # was given and refuses every delete, so a test can read and write the store
  # while a clear's delete has not reached the database.
  defmodule UndeletedRepo do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid), rows: Keyword.fetch!(opts, :rows)}}
    end

    @impl true
    def handle_call(:enabled?, _from, state), do: {:reply, true, state}

    def handle_call({:get_messages, _selector, limit}, _from, state) do
      {:reply, {:ok, Enum.take(state.rows, -limit)}, state}
    end

    def handle_call({:delete_messages, _selector}, _from, state) do
      send(state.test_pid, :delete_refused)
      {:reply, {:error, :disk_busy}, state}
    end

    def handle_call({:insert_message, attrs}, _from, state) do
      {:reply, {:ok, Map.put(attrs, :id, length(state.rows) + 1)}, state}
    end
  end

  describe "a conversation nobody has read since the store started" do
    setup :start_durable_repo

    test "a message added out of turn lands after the stored history", ctx do
      seed(ctx.repo, @stored)
      store = start_store(ctx, max_messages: :infinity)

      :ok = ConversationStore.add_message(@key, "assistant", @check_in, server: store)

      assert contents(ConversationStore.get_history(@key, server: store)) ==
               stored_contents(@stored) ++ [@check_in]
    end

    test "under the store's message bound, the newest stored rows stay in front of it", ctx do
      earlier = [
        {"user", "Is the Port Alder pier open in March?", ~U[2026-03-13 18:00:00Z]},
        {"assistant", "It reopens on 1 March.", ~U[2026-03-13 18:00:04Z]}
      ]

      seed(ctx.repo, earlier ++ @stored)
      store = start_store(ctx, max_messages: 3)

      :ok = ConversationStore.add_message(@key, "assistant", @check_in, server: store)

      assert contents(ConversationStore.get_history(@key, server: store)) ==
               Enum.drop(stored_contents(@stored), 1) ++ [@check_in]
    end

    test "a later replace_history keeps the rows the add never loaded", ctx do
      seed(ctx.repo, @stored)
      store = start_store(ctx, max_messages: :infinity)

      :ok = ConversationStore.add_message(@key, "assistant", @check_in, server: store)
      await_durable_writes(ctx.tasks)

      # What auto-compaction does: read the history, then replace it with what
      # it made of that read. Written back unchanged, nothing may be lost.
      history = ConversationStore.get_history(@key, server: store)
      :ok = ConversationStore.replace_history(@key, history, server: store)
      await_durable_writes(ctx.tasks)

      assert durable_contents(ctx.repo) == stored_contents(@stored) ++ [@check_in]
    end

    test "a read with a small limit caches the whole window, not the slice", ctx do
      seed(ctx.repo, @stored)
      store = start_store(ctx, max_messages: :infinity)

      assert contents(ConversationStore.get_history(@key, 1, server: store)) ==
               Enum.take(stored_contents(@stored), -1)

      assert contents(ConversationStore.get_history(@key, server: store)) ==
               stored_contents(@stored)

      :ok = ConversationStore.add_message(@key, "assistant", @check_in, server: store)

      assert contents(ConversationStore.get_history(@key, server: store)) ==
               stored_contents(@stored) ++ [@check_in]
    end

    test "the stopped-turn marker closes a stored orphaned user turn", ctx do
      seed(ctx.repo, @stored)
      store = start_store(ctx, max_messages: :infinity)

      assert :marked = ConversationStore.append_stopped_marker(@key, "[stopped]", server: store)

      assert contents(ConversationStore.get_history(@key, server: store)) ==
               stored_contents(@stored) ++ ["[stopped]"]
    end

    test "the stopped-turn marker skips a stored turn that already has its reply", ctx do
      answered = @stored ++ [{"assistant", "I will.", ~U[2026-03-14 09:01:04Z]}]
      seed(ctx.repo, answered)
      store = start_store(ctx, max_messages: :infinity)

      assert :skipped = ConversationStore.append_stopped_marker(@key, "[stopped]", server: store)

      assert contents(ConversationStore.get_history(@key, server: store)) ==
               stored_contents(answered)
    end
  end

  describe "durable memory off" do
    setup :start_task_supervisor

    test "with no repo there is nothing to load", ctx do
      store = start_store(Map.put(ctx, :repo, nil), max_messages: :infinity)

      :ok = ConversationStore.add_message(@key, "assistant", @check_in, server: store)

      assert contents(ConversationStore.get_history(@key, server: store)) == [@check_in]
    end

    test "with the repo disabled there is nothing to load", ctx do
      repo = :"conversation_load_disabled_repo_#{System.unique_integer([:positive])}"
      start_supervised!({Repo, name: repo, enabled: false}, id: repo)
      store = start_store(Map.put(ctx, :repo, repo), max_messages: :infinity)

      assert :skipped = ConversationStore.append_stopped_marker(@key, "[stopped]", server: store)
      :ok = ConversationStore.add_message(@key, "assistant", @check_in, server: store)

      assert contents(ConversationStore.get_history(@key, server: store)) == [@check_in]
    end
  end

  describe "a cleared conversation" do
    setup :start_task_supervisor

    test "stays cleared while its durable delete has not landed", ctx do
      rows =
        Enum.map(@stored, fn {role, content, at} ->
          %{role: role, content: content, created_at: at, metadata: nil}
        end)

      repo = start_supervised!({UndeletedRepo, test_pid: self(), rows: rows})

      store =
        start_store(Map.put(ctx, :repo, repo),
          max_messages: :infinity,
          durable_max_attempts: 1,
          durable_retry_initial_ms: 0
        )

      assert contents(ConversationStore.get_history(@key, server: store)) ==
               stored_contents(@stored)

      :ok = ConversationStore.clear(@key, server: store)
      assert_receive :delete_refused, @durable_write_wait_ms

      assert ConversationStore.get_history(@key, server: store) == []

      :ok = ConversationStore.add_message(@key, "assistant", @check_in, server: store)

      assert contents(ConversationStore.get_history(@key, server: store)) == [@check_in]
    end
  end

  defp start_durable_repo(ctx) do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-conversation-load-#{unique}.db")
    repo = :"conversation_load_repo_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    {:ok, supervisor} = start_task_supervisor(ctx)
    {:ok, [repo: repo] ++ supervisor}
  end

  # The store's durable writes run under a supervisor the test owns, so a test
  # can wait for them to finish instead of sleeping.
  defp start_task_supervisor(_ctx) do
    name = :"conversation_load_tasks_#{System.unique_integer([:positive])}"
    {:ok, tasks: start_supervised!({Task.Supervisor, name: name}, id: name)}
  end

  defp start_store(ctx, opts) do
    name = :"conversation_load_store_#{System.unique_integer([:positive])}"

    # The ids the stored rows carry, named here rather than read from app env.
    base = [
      name: name,
      repo: ctx.repo,
      durable_task_supervisor: ctx.tasks,
      agent_id: "main",
      owner_id: "default"
    ]

    start_supervised!({ConversationStore, base ++ opts}, id: name)

    name
  end

  defp seed(repo, rows) do
    Enum.each(rows, fn {role, content, created_at} ->
      {:ok, _row} =
        Repo.insert_message(
          Map.merge(selector(), %{
            owner_id: "default",
            sender: role,
            role: role,
            content: content,
            created_at: created_at
          }),
          server: repo
        )
    end)
  end

  # Every durable write starts as a child of the test's task supervisor inside
  # the store's own call, so once that call returns, its write is listed there
  # or has already finished.
  defp await_durable_writes(tasks) do
    Enum.each(Task.Supervisor.children(tasks), fn pid ->
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @durable_write_wait_ms
    end)
  end

  defp durable_contents(repo) do
    {:ok, rows} = Repo.get_messages(selector(), limit: 100, server: repo)
    contents(rows)
  end

  defp selector do
    {channel, chat_id, thread_scope} = @key

    %{
      agent_id: "main",
      channel: channel,
      chat_id: chat_id,
      thread_scope: thread_scope,
      kind: "chat_message"
    }
  end

  defp stored_contents(rows), do: Enum.map(rows, fn {_role, content, _at} -> content end)
  defp contents(messages), do: Enum.map(messages, & &1.content)
end
