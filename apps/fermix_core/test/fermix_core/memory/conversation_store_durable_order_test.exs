defmodule FermixCore.Memory.ConversationStoreDurableOrderTest do
  @moduledoc """
  The database ends in the state the store's calls describe, in the order they
  were made, whatever order their durable writes happen to run in: a replace
  then an add leaves the replacement and the added row after it; a clear then
  an add leaves only the added row; an add's row is never written again after a
  later replace has rewritten the history (M106 §5.8, stage S2a).

  Each case drives one ordering by injection and then reads the conversation
  from a NEW store process over the same database, the way the next start of
  the engine would. The writing store talks to the database through
  `RecordingRepo`, which tells the test each write it applied, so the test
  waits for the write it is about, never for time.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo

  @key {"telegram", "harbour-chat", :root}
  @check_in "A check-in: did the Port Alder ferry work out on Saturday?"
  @summary "Conversation checkpoint summary:\nThe owner is taking the Saturday ferry from Port Alder."

  # Invented, with absolute timestamps so the stored order is fixed.
  @stored [
    {"user", "When does the ferry leave Port Alder on Saturday?", ~U[2026-03-14 09:00:00Z]},
    {"assistant", "The first Saturday ferry leaves Port Alder at 07:40.",
     ~U[2026-03-14 09:00:05Z]},
    {"user", "Remind me the evening before.", ~U[2026-03-14 09:01:00Z]}
  ]

  # SQLite work behind a loaded runner's file-server queue.
  @durable_write_wait_ms 10_000

  # Stands in front of a real Repo. It forwards every call, tells the test each
  # write once it is applied, and, when `hold:` names a content, holds the first
  # insert of it until the test sends `:release`, so the test decides where
  # that write lands.
  defmodule RecordingRepo do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok,
       %{
         repo: Keyword.fetch!(opts, :repo),
         test_pid: Keyword.fetch!(opts, :test_pid),
         hold: Keyword.get(opts, :hold),
         held: nil
       }}
    end

    @impl true
    def handle_call(
          {:insert_message, %{content: content}} = request,
          from,
          %{hold: content} = state
        )
        when is_binary(content) do
      {writer, _tag} = from
      send(state.test_pid, {:held, writer})
      {:noreply, %{state | hold: nil, held: {request, from}}}
    end

    def handle_call(request, _from, state), do: {:reply, forward(request, state), state}

    @impl true
    def handle_info(:release, %{held: {request, from}} = state) do
      GenServer.reply(from, forward(request, state))
      {:noreply, %{state | held: nil}}
    end

    defp forward(request, state) do
      reply = GenServer.call(state.repo, request)
      report(request, state.test_pid)
      reply
    end

    defp report({:insert_message, attrs}, test_pid),
      do: send(test_pid, {:applied, :insert, attrs.content})

    defp report({:delete_messages, _selector}, test_pid),
      do: send(test_pid, {:applied, :delete, nil})

    defp report(_read, _test_pid), do: :ok
  end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-conversation-order-#{unique}.db")
    repo = :"conversation_order_repo_#{unique}"
    tasks = :"conversation_order_tasks_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    seed(repo, @stored)
    %{repo: repo, tasks: tasks}
  end

  describe "a write right after a replace or a clear" do
    test "an add the store takes before the replace's durable write starts keeps the replace",
         ctx do
      store = start_store(ctx, recording_repo(ctx))

      %{messages: history, version: version} =
        ConversationStore.get_history_snapshot(@key, server: store)

      last = List.last(history)

      compacted = [
        %{role: "system", content: @summary, timestamp: ~U[2026-03-14 09:00:05Z]},
        last
      ]

      in_one_batch(store, [
        {:replace_history, @key, compacted, [server: store, expected_version: version]},
        {:add_message, @key, "assistant", @check_in, [server: store]}
      ])

      await_applied(@check_in, 1)
      assert durable_contents(ctx) == [@summary, last.content, @check_in]
      assert restarted_contents(ctx) == [@summary, last.content, @check_in]
    end

    test "an add the store takes before the clear's durable delete starts keeps the clear",
         ctx do
      store = start_store(ctx, recording_repo(ctx))
      assert length(ConversationStore.get_history(@key, server: store)) == 3

      in_one_batch(store, [
        {:clear, @key},
        {:add_message, @key, "assistant", @check_in, [server: store]}
      ])

      await_applied(@check_in, 1)
      assert durable_contents(ctx) == [@check_in]
      assert restarted_contents(ctx) == [@check_in]
    end

    test "a clear with nothing after it stays cleared after a restart", ctx do
      store = start_store(ctx, recording_repo(ctx))
      assert length(ConversationStore.get_history(@key, server: store)) == 3

      :ok = ConversationStore.clear(@key, server: store)

      assert_receive {:applied, :delete, nil}, @durable_write_wait_ms
      assert restarted_contents(ctx) == []
    end
  end

  describe "an add's write that lands late" do
    test "is never written again after a later replace rewrote the history", ctx do
      proxy =
        start_supervised!({RecordingRepo, repo: ctx.repo, test_pid: self(), hold: @check_in})

      store = start_store(ctx, proxy)

      :ok = ConversationStore.add_message(@key, "assistant", @check_in, server: store)
      assert_receive {:held, held_writer}, @durable_write_wait_ms

      # A compaction that keeps everything: the history written back as read.
      history = ConversationStore.get_history(@key, server: store)
      :ok = ConversationStore.replace_history(@key, history, server: store)

      # The worst case for the held insert: it lands after every other durable
      # write that is running now has finished.
      await_writers_except(ctx.tasks, held_writer)
      send(proxy, :release)

      # The add's insert and the replace's re-insert of the same message.
      await_applied(@check_in, 2)
      assert durable_contents(ctx) == stored_contents(@stored) ++ [@check_in]
      assert restarted_contents(ctx) == stored_contents(@stored) ++ [@check_in]
    end
  end

  defp recording_repo(ctx) do
    start_supervised!({RecordingRepo, repo: ctx.repo, test_pid: self()})
  end

  defp start_store(ctx, repo) do
    name = :"conversation_order_store_#{System.unique_integer([:positive])}"

    start_supervised!(
      {ConversationStore,
       name: name,
       max_messages: :infinity,
       repo: repo,
       durable_task_supervisor: ctx.tasks,
       agent_id: "main",
       owner_id: "default"},
      id: name
    )

    name
  end

  # The calls reach the store in this order with nothing between them: the
  # store is held while they are queued, so no durable task it starts for the
  # first can be served before it has taken the next.
  defp in_one_batch(store, calls) do
    :ok = :sys.suspend(store)
    requests = Enum.map(calls, &:gen_server.send_request(store, &1))
    :ok = :sys.resume(store)

    Enum.each(requests, fn request ->
      assert {:reply, :ok} = :gen_server.receive_response(request, @durable_write_wait_ms)
    end)
  end

  defp await_applied(content, count) do
    Enum.each(1..count, fn _nth ->
      assert_receive {:applied, :insert, ^content}, @durable_write_wait_ms
    end)
  end

  defp await_writers_except(tasks, held_writer) do
    tasks
    |> Task.Supervisor.children()
    |> List.delete(held_writer)
    |> Enum.each(fn pid ->
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @durable_write_wait_ms
    end)
  end

  # What the next start of the engine reads: a new store over the same database.
  defp restarted_contents(ctx) do
    store = start_store(ctx, ctx.repo)
    contents(ConversationStore.get_history(@key, server: store))
  end

  defp durable_contents(ctx) do
    {:ok, rows} = Repo.get_messages(selector(), limit: 100, server: ctx.repo)
    contents(rows)
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
