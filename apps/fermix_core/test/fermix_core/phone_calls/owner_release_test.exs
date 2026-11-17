defmodule FermixCore.PhoneCalls.OwnerReleaseTest do
  # The owner's word that an unresolved call ended (M94 §12): the release
  # reason it is recorded with, and migration 68, which lets a store migration
  # 67 laid down take that reason. Each test owns an isolated Repo on its own
  # database file, and every clock is the `now` the test hands in.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Ledger
  alias FermixTestSupport.PhoneCallStores

  # Every name, number and id here is invented.
  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @hash String.duplicate("b2", 32)
  @narrow "slot_release_reason = 'verified_termination'"
  @wide "slot_release_reason IN ('verified_termination', 'owner_confirmed')"

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-owner-release-#{unique}.db")
    repo = :"phone_owner_release_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{opts: [server: repo], repo: repo, db_path: db_path}
  end

  defp attrs do
    %{
      request_id: "main-#{System.unique_integer([:positive])}",
      owner_id: "default",
      authorization: "direct",
      origin_kind: "chat",
      origin_conversation: ["telegram", "40031", "root"],
      delivery_mode: "origin",
      platform: "telegram",
      destination: "40031",
      mandate: %{"destination" => "+14155550167", "goal" => "Ask whether the shop opens at nine"},
      mandate_hash: @hash,
      model: "gpt-live-1",
      voice: "marin",
      prompt_version: "phone-1",
      carrier_profile: "telnyx_credential_connection"
    }
  end

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)

  # A call that dialed and whose end OpenAI never confirmed.
  defp unconfirmed!(opts) do
    {:ok, {:admitted, row}} = Ledger.admit(attrs(), @t0, opts)
    {:ok, _row} = Ledger.claim_dispatch(row.id, @t0, opts)
    {:ok, _row} = Ledger.record_session(row.id, "sess_invented_7", at(1), opts)
    {:ok, row} = Ledger.terminalize(row.id, "closure_unconfirmed", %{ended_at: at(60)}, opts)
    row
  end

  defp sql!(db_path, statements) do
    {:ok, conn} = Sqlite3.open(db_path)
    Enum.each(statements, &(:ok = Sqlite3.execute(conn, &1)))
    :ok = Sqlite3.close(conn)
  end

  defp rows!(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path)
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    :ok = Sqlite3.close(conn)
    rows
  end

  defp table_sql!(db_path),
    do:
      rows!(
        db_path,
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'phone_calls'"
      )

  defp index_names!(db_path),
    do:
      rows!(
        db_path,
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'phone_calls' " <>
          "AND sql IS NOT NULL ORDER BY name"
      )

  # The table as migration 67 first laid it down: the release reason held to
  # verified termination alone, and 68 not yet run.
  defp narrow!(ctx) do
    :ok = stop_supervised(ctx.repo)
    :ok = PhoneCallStores.as_67!(ctx.db_path)
    assert [[narrowed]] = table_sql!(ctx.db_path)
    assert narrowed =~ @narrow
  end

  describe "the owner's release" do
    test "frees the slot with its own reason and time, the outcome kept unknown", ctx do
      row = unconfirmed!(ctx.opts)
      assert {:error, {:slot_held, _holder}} = Ledger.admit(attrs(), at(61), ctx.opts)

      assert {:ok, released} = Ledger.release_slot(row.id, :owner_confirmed, at(90), ctx.opts)
      assert released.slot_released_at == at(90)
      assert released.slot_release_reason == "owner_confirmed"
      assert released.outcome == "unknown"
      refute Ledger.holds_slot?(released, at(91))
      assert {:ok, {:admitted, _next}} = Ledger.admit(attrs(), at(91), ctx.opts)
    end

    test "never releases a call in progress", ctx do
      {:ok, {:admitted, live}} = Ledger.admit(attrs(), @t0, ctx.opts)

      assert {:error, {:not_releasable, "admitted"}} =
               Ledger.release_slot(live.id, :owner_confirmed, at(1), ctx.opts)
    end

    test "never releases a call twice", ctx do
      row = unconfirmed!(ctx.opts)
      {:ok, _released} = Ledger.release_slot(row.id, :owner_confirmed, at(90), ctx.opts)

      assert {:error, {:not_releasable, "closure_unconfirmed"}} =
               Ledger.release_slot(row.id, :owner_confirmed, at(95), ctx.opts)
    end

    test "takes no other reason" do
      assert_raise FunctionClauseError, fn ->
        Ledger.release_slot("pc_0a1b2c3d4e5f", :model_said_so, @t0, [])
      end
    end
  end

  describe "migration 68" do
    test "a fresh store takes the owner's word and records 68 once", ctx do
      assert [[ddl]] = table_sql!(ctx.db_path)
      assert ddl =~ @wide
      assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
      assert Enum.count(versions, &(&1 == 68)) == 1
      assert :ok = Repo.migrate(server: ctx.repo)
      assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
      assert Enum.count(versions, &(&1 == 68)) == 1
    end

    test "a store from before widens on open, every call and index kept", ctx do
      row = unconfirmed!(ctx.opts)
      indexes = index_names!(ctx.db_path)
      narrow!(ctx)

      reopened = :"#{ctx.repo}_before_68"

      start_supervised!({Repo, name: reopened, enabled: true, database_path: ctx.db_path},
        id: reopened
      )

      assert {:ok, versions} = Repo.migration_versions(server: reopened)
      assert Enum.count(versions, &(&1 == 68)) == 1

      assert {:ok, %{id: id, status: "closure_unconfirmed"}} =
               Ledger.get(row.id, server: reopened)

      assert id == row.id

      assert {:ok, %{slot_release_reason: "owner_confirmed"}} =
               Ledger.release_slot(row.id, :owner_confirmed, at(90), server: reopened)

      :ok = stop_supervised(reopened)
      assert [[ddl]] = table_sql!(ctx.db_path)
      assert ddl =~ @wide
      refute ddl =~ @narrow
      assert index_names!(ctx.db_path) == indexes
    end

    test "a store from before refuses the owner's word until it widens", ctx do
      row = unconfirmed!(ctx.opts)
      narrow!(ctx)

      {:ok, conn} = Sqlite3.open(ctx.db_path)
      sql = "UPDATE phone_calls SET slot_release_reason = 'owner_confirmed' WHERE id = ?1"
      {:ok, stmt} = Sqlite3.prepare(conn, sql)
      :ok = Sqlite3.bind(stmt, [row.id])
      assert {:error, message} = Sqlite3.step(conn, stmt)
      :ok = Sqlite3.release(conn, stmt)
      :ok = Sqlite3.close(conn)
      assert message =~ "CHECK constraint failed"
    end

    # Other features' upgrade tests forget every version after an old one and
    # reopen the store, so 68 runs again over a table already widened: it
    # recognises its own work, adds nothing, and ends where a fresh store ends.
    test "a store at the latest schema rolled back to before 67 reopens as a fresh one", ctx do
      row = unconfirmed!(ctx.opts)
      fresh = {table_sql!(ctx.db_path), index_names!(ctx.db_path)}
      :ok = stop_supervised(ctx.repo)
      sql!(ctx.db_path, ["DELETE FROM schema_migrations WHERE version >= 67"])

      reopened = :"#{ctx.repo}_rolled_back"

      start_supervised!({Repo, name: reopened, enabled: true, database_path: ctx.db_path},
        id: reopened
      )

      assert {:ok, versions} = Repo.migration_versions(server: reopened)
      assert Enum.count(versions, &(&1 == 68)) == 1
      assert {:ok, %{id: id}} = Ledger.get(row.id, server: reopened)
      assert id == row.id
      :ok = stop_supervised(reopened)
      assert {table_sql!(ctx.db_path), index_names!(ctx.db_path)} == fresh
    end
  end
end
