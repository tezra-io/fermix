defmodule FermixCore.Memory.RepoOwnerHoursIndexMigrationTest do
  # M107: the active-hours query reads up to 10,000 of the owner's own chat
  # messages over 28 days, newest first. Migration 75 adds the partial index,
  # ascending, that the query reads as one range backwards; without it SQLite
  # sorts every message of the agent and owner first. The memory store's
  # range read of the owner's chat messages (newest first, the higher id
  # winning a tie) reads the same index backwards. Neither query names the
  # index, so the rows each returns are the same with or without it.
  # Membership, never list equality: later migrations join the list.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.OpenLoopsSql

  @version 75
  @index "idx_messages_owner_hours"
  # Every date in this file is invented. The window is the 28 days before
  # 2031-06-02 14:00 UTC.
  @since ~U[2031-05-05 14:00:00.000000Z]
  # The range read's window, `from <= created_at < until`.
  @range_from ~U[2031-05-01 00:00:00.000000Z]
  @range_until ~U[2031-06-01 00:00:00.000000Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-owner-hours-index-#{unique}.db")
    repo = :"memory_repo_owner_hours_index_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: :first)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, db_path: db_path}
  end

  test "a fresh store has the index: agent, owner and time ascending, owner chat rows only",
       %{repo: repo, db_path: db_path} do
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @version in versions
    assert_index(db_path)
  end

  test "a store at 73 gains the index on open, keeping its rows, and reapplying changes nothing",
       %{repo: repo, db_path: db_path} do
    stop_supervised!(:first)

    raw(
      db_path,
      "DROP INDEX #{@index}; DELETE FROM schema_migrations WHERE version = #{@version};"
    )

    refute index?(db_path)
    insert(db_path, [owner_row("2031-06-01T09:00:00.000000Z")])

    reopen(repo, db_path, :second)
    assert_index(db_path)
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert Enum.count(versions, &(&1 == @version)) == 1
    assert hours(repo, "main", "default") == [~U[2031-06-01 09:00:00.000000Z]]

    assert :ok = Repo.migrate(server: repo)
    assert {:ok, ^versions} = Repo.migration_versions(server: repo)

    # The step runs again over the index it made, as a store whose version
    # row was lost would run it.
    stop_supervised!(:second)
    raw(db_path, "DELETE FROM schema_migrations WHERE version = #{@version};")
    reopen(repo, db_path, :third)
    assert {:ok, ^versions} = Repo.migration_versions(server: repo)
    assert_index(db_path)
  end

  # The production text, planned on the migrated schema. Without the index the
  # plan searches `idx_messages_review_tail` by agent and owner and then
  # builds a temporary B-tree to sort every row it found.
  test "the active-hours query reads its index range in order, with no sort",
       %{db_path: db_path} do
    sql = OpenLoopsSql.owner_message_hours_sql()
    plan = plan(db_path, sql, ["main", "default", stamp(@since), 10_000])

    assert Enum.any?(
             plan,
             &(&1 =~ "USING INDEX #{@index} (agent_id=? AND owner_id=? AND created_at>?)")
           ),
           inspect(plan)

    refute Enum.any?(plan, &(&1 =~ "TEMP B-TREE")), inspect(plan)
  end

  # Skill curation reads 30 days of the owner's chat messages with `role` and
  # `kind` bound. SQLite reads the bound values, so this read qualifies for the
  # partial index, and a backward read of it gives `created_at DESC, id DESC`
  # (the rowid is the key's last column): no sort, even for the tie-break.
  test "the owner's chat-message range read uses the index backwards, with no sort",
       %{db_path: db_path} do
    plan = range_plan(db_path, %{role: "user", kind: "chat_message"})

    assert Enum.any?(
             plan,
             &(&1 =~
                 "USING INDEX #{@index} (agent_id=? AND owner_id=? AND created_at>? AND created_at<?)")
           ),
           inspect(plan)

    refute Enum.any?(plan, &(&1 =~ "TEMP B-TREE")), inspect(plan)
  end

  test "a range read of another role, another kind or every role never reads the index",
       %{db_path: db_path} do
    for selector <- [
          %{role: "assistant", kind: "chat_message"},
          %{role: "user", kind: "checkpoint_summary"},
          %{kind: "chat_message"},
          %{kind: "checkpoint_summary"}
        ] do
      plan = range_plan(db_path, selector)
      refute Enum.any?(plan, &(&1 =~ @index)), inspect({selector, plan})
    end
  end

  # Four of the owner's chat messages share one instant. A limit that cuts
  # through them keeps the higher ids, and every read returns its rows oldest
  # first, by id within the instant: the same with the index and without it.
  test "range reads return the same rows with and without the index, a tie to the higher id",
       %{repo: repo, db_path: db_path} do
    insert(db_path, [
      owner_row("2031-04-30T23:59:59.999999Z", content: "before"),
      owner_row("2031-05-10T08:00:00.000000Z", content: "tie-1"),
      owner_row("2031-05-10T08:00:00.000000Z", content: "tie-2"),
      owner_row("2031-05-10T08:00:00.000000Z", content: "tie-3"),
      owner_row("2031-05-10T08:00:00.000000Z", content: "tie-4"),
      owner_row("2031-05-10T08:00:00.000000Z", content: "assistant-1", role: "assistant"),
      owner_row("2031-05-15T08:00:00.000000Z", content: "assistant-2", role: "assistant"),
      owner_row("2031-05-12T08:00:00.000000Z", content: "summary-1", kind: "checkpoint_summary"),
      owner_row("2031-05-13T08:00:00.000000Z",
        content: "summary-2",
        kind: "checkpoint_summary",
        role: "system"
      ),
      owner_row("2031-05-18T08:00:00.000000Z", content: "second owner", owner: "second"),
      owner_row("2031-05-20T08:00:00.000000Z", content: "later"),
      owner_row("2031-06-01T00:00:00.000000Z", content: "at the window's end")
    ])

    expected = %{
      {%{role: "user", kind: "chat_message"}, 3} => ["tie-3", "tie-4", "later"],
      {%{role: "user", kind: "chat_message"}, 10} => ["tie-1", "tie-2", "tie-3", "tie-4", "later"],
      {%{role: "assistant", kind: "chat_message"}, 10} => ["assistant-1", "assistant-2"],
      {%{role: "user", kind: "checkpoint_summary"}, 10} => ["summary-1"],
      {%{kind: "checkpoint_summary"}, 10} => ["summary-1", "summary-2"],
      {%{kind: "chat_message"}, 3} => ["assistant-1", "assistant-2", "later"]
    }

    assert index?(db_path)
    assert range_reads(repo, expected) == expected

    raw(db_path, "DROP INDEX #{@index};")
    refute index?(db_path)
    assert range_reads(repo, expected) == expected
  end

  test "the rows returned are the same with and without the index", %{
    repo: repo,
    db_path: db_path
  } do
    insert(db_path, [
      # Exactly at the window's start is in it; a microsecond before is not.
      owner_row(stamp(@since), metadata: nil),
      owner_row("2031-05-05T13:59:59.999999Z"),
      # Two messages in the same instant are two messages.
      owner_row("2031-05-20T09:00:00.000000Z"),
      owner_row("2031-05-20T09:00:00.000000Z", metadata: nil),
      # Metadata that is not JSON is not a guest's.
      owner_row("2031-05-21T10:00:00.000000Z", metadata: "not json {"),
      owner_row("2031-05-22T11:00:00.000000Z", metadata: ~s({"guest":true})),
      owner_row("2031-05-23T12:00:00.000000Z", metadata: ~s({"guest":false})),
      owner_row("2031-05-24T13:00:00.000000Z", role: "assistant"),
      owner_row("2031-05-25T14:00:00.000000Z", kind: "tool_result"),
      owner_row("2031-05-26T15:00:00.000000Z", agent: "scout"),
      owner_row("2031-05-27T16:00:00.000000Z", owner: "second"),
      owner_row("2031-05-28T17:00:00.000000Z", owner: "second", metadata: ~s({"guest":true})),
      owner_row("2031-05-29T18:00:00.000000Z", agent: "scout", role: "assistant")
    ])

    expected = %{
      {"main", "default"} => [
        ~U[2031-05-23 12:00:00.000000Z],
        ~U[2031-05-21 10:00:00.000000Z],
        ~U[2031-05-20 09:00:00.000000Z],
        ~U[2031-05-20 09:00:00.000000Z],
        @since
      ],
      {"scout", "default"} => [~U[2031-05-26 15:00:00.000000Z]],
      {"main", "second"} => [~U[2031-05-27 16:00:00.000000Z]],
      {"scout", "second"} => []
    }

    assert_same_with_and_without_index(repo, db_path, expected)
  end

  # 10,050 of the owner's messages in the window, and five guest messages
  # newer than all of them: the limit counts only what is selected, and keeps
  # the newest.
  test "the 10,000-row limit keeps the newest owner messages", %{repo: repo, db_path: db_path} do
    raw(db_path, """
    WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 10055)
    INSERT INTO messages (agent_id, owner_id, channel, chat_id, sender, role, kind, content,
      metadata_json, created_at)
    SELECT 'main', 'busy', 'telegram', '40001', 'owner', 'user', 'chat_message',
      'an invented message', CASE WHEN i > 10050 THEN '{"guest":true}' ELSE '{}' END,
      strftime('%Y-%m-%dT%H:%M:%S', '2031-05-05 14:00:00', '+' || i || ' seconds') || '.000000Z'
    FROM s;
    """)

    newest = Enum.map(10_050..51//-1, &DateTime.add(@since, &1, :second))
    assert length(newest) == 10_000

    assert_same_with_and_without_index(repo, db_path, %{{"main", "busy"} => newest})
  end

  # The same reads through the Repo, first over the migrated schema, then with
  # the index dropped, as a store the migration has not reached yet.
  defp assert_same_with_and_without_index(repo, db_path, expected) do
    assert index?(db_path)
    assert all_hours(repo, expected) == expected

    raw(db_path, "DROP INDEX #{@index};")
    refute index?(db_path)
    assert all_hours(repo, expected) == expected
  end

  defp all_hours(repo, expected) do
    Map.new(expected, fn {{agent, owner}, _instants} ->
      {{agent, owner}, hours(repo, agent, owner)}
    end)
  end

  defp hours(repo, agent, owner) do
    assert {:ok, instants} = Repo.owner_message_hours(agent, owner, @since, server: repo)
    instants
  end

  defp range_reads(repo, expected) do
    Map.new(expected, fn {{selector, limit}, _contents} ->
      assert {:ok, messages} =
               Repo.get_messages_in_range(
                 owner_selector(selector),
                 @range_from,
                 @range_until,
                 limit,
                 server: repo
               )

      {{selector, limit}, Enum.map(messages, & &1.content)}
    end)
  end

  # The production SQL with the values it binds: SQLite decides from them
  # whether the partial index can serve the read.
  defp range_plan(db_path, selector) do
    {sql, params} =
      Repo.messages_in_range_query(owner_selector(selector), @range_from, @range_until, 10)

    plan(db_path, sql, params)
  end

  defp owner_selector(selector), do: Map.merge(%{agent_id: "main", owner_id: "default"}, selector)

  defp plan(db_path, sql, params) do
    db_path |> rows("EXPLAIN QUERY PLAN " <> sql, params) |> Enum.map(&List.last/1)
  end

  defp assert_index(db_path) do
    assert rows(db_path, "SELECT name, desc FROM pragma_index_xinfo('#{@index}') WHERE key = 1") ==
             [["agent_id", 0], ["owner_id", 0], ["created_at", 0]]

    assert rows(db_path, "SELECT partial FROM pragma_index_list('messages') WHERE name = ?", [
             @index
           ]) == [[1]]

    assert [[sql]] = rows(db_path, "SELECT sql FROM sqlite_master WHERE name = ?", [@index])
    assert sql =~ "WHERE role = 'user' AND kind = 'chat_message'"
  end

  defp index?(db_path) do
    rows(db_path, "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?", [@index]) ==
      [[1]]
  end

  defp owner_row(created_at, overrides \\ []) do
    %{
      agent: Keyword.get(overrides, :agent, "main"),
      owner: Keyword.get(overrides, :owner, "default"),
      role: Keyword.get(overrides, :role, "user"),
      kind: Keyword.get(overrides, :kind, "chat_message"),
      metadata: Keyword.get(overrides, :metadata, "{}"),
      content: Keyword.get(overrides, :content, "an invented message"),
      created_at: created_at
    }
  end

  defp insert(db_path, messages) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 2000;")

      {:ok, statement} =
        Sqlite3.prepare(conn, """
        INSERT INTO messages (agent_id, owner_id, channel, chat_id, sender, role, kind, content,
          metadata_json, created_at)
        VALUES (?, ?, 'telegram', '40001', 'owner', ?, ?, ?, ?, ?)
        """)

      Enum.each(messages, &insert_one(conn, statement, &1))
      :ok = Sqlite3.release(conn, statement)
    after
      Sqlite3.close(conn)
    end
  end

  defp insert_one(conn, statement, message) do
    :ok =
      Sqlite3.bind(statement, [
        message.agent,
        message.owner,
        message.role,
        message.kind,
        message.content,
        message.metadata,
        message.created_at
      ])

    :done = Sqlite3.step(conn, statement)
  end

  defp stamp(at), do: OpenLoopsSql.stamp!(at)

  defp reopen(repo, db_path, id) do
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: id)
  end

  defp raw(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 2000;")
      :ok = Sqlite3.execute(conn, sql)
    after
      Sqlite3.close(conn)
    end
  end

  defp rows(db_path, sql, params \\ []) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 2000;")
      {:ok, statement} = Sqlite3.prepare(conn, sql)
      :ok = Sqlite3.bind(statement, params)
      {:ok, rows} = Sqlite3.fetch_all(conn, statement)
      :ok = Sqlite3.release(conn, statement)
      rows
    after
      Sqlite3.close(conn)
    end
  end
end
