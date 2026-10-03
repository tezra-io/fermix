defmodule FermixCore.Memory.RepoOneHistoryMigrationTest do
  # M56 D9: the phone's turns run in the Mac's chat, so the history the phone
  # kept under its own key, and that history's review state, move to the
  # chat's once, at the upgrade. Rows keep their ids and their times, and a
  # history is read in time order, so the two transports' rows interleave as
  # they were said. Membership, never list equality, for the version.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo

  @version 39
  @phone %{channel: "mobile", chat_id: "main", thread_scope: :root}
  @chat %{channel: "companion", chat_id: "main", thread_scope: :root}
  @owner %{agent_id: "main", owner_id: "default"}
  @at ~U[2026-10-03 09:00:00.000000Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-one-history-migration-#{unique}.db")
    repo = :"memory_repo_one_history_migration_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: :first)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, db_path: db_path}
  end

  test "a fresh database carries the version", %{repo: repo} do
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @version in versions
  end

  # The Mac's rows are written first here, so the ids do not follow the
  # times: the history is read by time, and the times are what interleave.
  test "the phone's rows join the chat's, in the order they were said", ctx do
    said = [
      {@chat, "user", "mac: the lease is due"},
      {@phone, "user", "phone: here is the link"},
      {@chat, "assistant", "mac: noted"},
      {@phone, "assistant", "phone: saved the link"},
      {@chat, "user", "mac: use that link"}
    ]

    said
    |> Enum.with_index()
    |> Enum.sort_by(fn {{key, _role, _content}, minute} -> {key == @phone, minute} end)
    |> Enum.each(fn {row, minute} -> insert!(ctx.repo, row, minute) end)

    insert!(ctx.repo, {%{@phone | chat_id: "other"}, "user", "another profile's"}, 9)

    insert!(
      ctx.repo,
      {%{channel: "telegram", chat_id: "1", thread_scope: :root}, "user", "tg"},
      9
    )

    upgrade(ctx)

    assert Enum.map(history(ctx.repo, @chat), & &1.content) ==
             Enum.map(said, fn {_key, _role, content} -> content end)

    assert history(ctx.repo, @phone) == []
    assert [%{content: "another profile's"}] = history(ctx.repo, %{@phone | chat_id: "other"})
    assert [%{content: "tg"}] = history(ctx.repo, %{@chat | channel: "telegram", chat_id: "1"})
  end

  # One cursor stands for both: the further-ahead one is kept, so the review
  # never re-reads the other transport's history from where it lagged.
  test "the review state further ahead becomes the chat's, and the other is gone", ctx do
    ids = Enum.map(0..4, &insert!(ctx.repo, {key_at(&1), "user", "said #{&1}"}, &1))
    reviewed!(ctx.repo, @phone, Enum.at(ids, 1))
    reviewed!(ctx.repo, @chat, Enum.at(ids, 2))

    upgrade(ctx)

    expected = Enum.at(ids, 2)
    assert {:ok, %{last_reviewed_message_id: ^expected}} = review_state(ctx.repo, @chat)
    assert {:error, :not_found} = review_state(ctx.repo, @phone)
    assert unreviewed(ctx.repo) == Enum.drop(ids, 3)
  end

  test "the phone's review state, further ahead, replaces the chat's", ctx do
    ids = Enum.map(0..4, &insert!(ctx.repo, {key_at(&1), "user", "said #{&1}"}, &1))
    reviewed!(ctx.repo, @chat, Enum.at(ids, 0))
    reviewed!(ctx.repo, @phone, Enum.at(ids, 3))

    upgrade(ctx)

    expected = Enum.at(ids, 3)
    assert {:ok, %{last_reviewed_message_id: ^expected}} = review_state(ctx.repo, @chat)
    assert {:error, :not_found} = review_state(ctx.repo, @phone)
  end

  test "the phone's review state alone moves to the chat's key", ctx do
    id = insert!(ctx.repo, {@phone, "user", "from the phone"}, 0)
    reviewed!(ctx.repo, @phone, id)

    upgrade(ctx)

    assert {:ok, %{last_reviewed_message_id: ^id}} = review_state(ctx.repo, @chat)
    assert {:error, :not_found} = review_state(ctx.repo, @phone)
  end

  test "it runs once, and a second run moves nothing", ctx do
    id = insert!(ctx.repo, {@phone, "user", "from the phone"}, 0)
    insert!(ctx.repo, {@chat, "user", "from the mac"}, 1)
    reviewed!(ctx.repo, @phone, id)

    upgrade(ctx)
    first = {history(ctx.repo, @chat), review_state(ctx.repo, @chat)}

    stop_supervised!(:reopened)
    upgrade_again(ctx)

    assert {history(ctx.repo, @chat), review_state(ctx.repo, @chat)} == first
    assert history(ctx.repo, @phone) == []
    assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
    assert Enum.count(versions, &(&1 == @version)) == 1
  end

  # The store as a release before this one left it: the version not applied.
  defp upgrade(ctx) do
    stop_supervised!(:first)
    raw(ctx.db_path, "DELETE FROM schema_migrations WHERE version = #{@version};")

    start_supervised!({Repo, name: ctx.repo, enabled: true, database_path: ctx.db_path},
      id: :reopened
    )
  end

  defp upgrade_again(ctx) do
    raw(ctx.db_path, "DELETE FROM schema_migrations WHERE version = #{@version};")

    start_supervised!({Repo, name: ctx.repo, enabled: true, database_path: ctx.db_path},
      id: :again
    )
  end

  # Even minutes are the Mac's, odd the phone's: the two take turns.
  defp key_at(minute) when rem(minute, 2) == 0, do: @chat
  defp key_at(_minute), do: @phone

  defp insert!(repo, {key, role, content}, minute) do
    attrs =
      @owner
      |> Map.merge(key)
      |> Map.merge(%{
        sender: role,
        role: role,
        kind: "chat_message",
        content: content,
        created_at: DateTime.add(@at, minute, :minute)
      })

    {:ok, %{id: id}} = Repo.insert_message(attrs, server: repo)
    id
  end

  defp history(repo, key) do
    selector = key |> Map.merge(%{agent_id: "main", kind: "chat_message"})
    {:ok, rows} = Repo.get_messages(selector, limit: 50, server: repo)
    rows
  end

  defp reviewed!(repo, key, last_id) do
    selector = Map.merge(@owner, key)
    {:ok, _claimed} = Repo.claim_memory_review(selector, @at, 60_000, server: repo)
    {:ok, _done} = Repo.complete_memory_review(selector, :ok, last_id, @at, server: repo)
  end

  defp review_state(repo, key),
    do: Repo.get_memory_review_state(Map.merge(@owner, key), server: repo)

  defp unreviewed(repo) do
    {:ok, %{last_reviewed_message_id: cursor}} = review_state(repo, @chat)
    {:ok, rows} = Repo.get_user_messages_after(Map.merge(@owner, @chat), cursor, 50, server: repo)
    Enum.map(rows, & &1.id)
  end

  defp raw(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path)
    :ok = Sqlite3.execute(conn, sql)
    :ok = Sqlite3.close(conn)
  end
end
