defmodule FermixCore.Harness.MachineStoreTest do
  # M98 G3a: this machine's coding store, `device/coding.db`. It opens only
  # where a coding agent can run, says why when it cannot open, and never stops
  # what starts after it (AGENTS.md "Cascade roots").
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Harness.MachineStore
  alias FermixTestSupport.SafeRm

  setup do
    home = SafeRm.make_tmp_dir!("harness-machine-store")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home, path: MachineStore.path(home)}
  end

  defp mark(run_id) do
    %{
      marked_at: ~U[2026-03-14 09:26:53Z],
      run_id: run_id,
      sign_in_file: "/invented/codex-home/auth.json",
      file_stat: %{"size" => 412, "mtime" => 1_773_480_413, "inode" => 90_211}
    }
  end

  describe "where an agent can run" do
    test "the store is made 0600 in a 0700 device folder, with its schema", ctx do
      store = start_supervised!({MachineStore, name: nil, path: ctx.path, open?: true})

      assert MachineStore.status(server: store) == :open
      assert File.stat!(ctx.path).mode |> Bitwise.band(0o777) == 0o600
      assert File.stat!(Path.dirname(ctx.path)).mode |> Bitwise.band(0o777) == 0o700
      assert versions(ctx.path) == [1]
    end

    test "opening it again runs the migrations again and changes nothing", ctx do
      store = start_supervised!({MachineStore, name: nil, path: ctx.path, open?: true})
      assert :ok = MachineStore.put_mark("codex", mark("hr_0a1b2c3d4e5f"), server: store)
      :ok = stop_supervised(MachineStore)

      again = start_supervised!({MachineStore, name: nil, path: ctx.path, open?: true})

      assert MachineStore.status(server: again) == :open
      assert versions(ctx.path) == [1]
      assert {:ok, %{"codex" => %{run_id: "hr_0a1b2c3d4e5f"}}} = MachineStore.marks(server: again)
    end

    test "a mark is kept per agent, replaced by the next one, and deleted", ctx do
      store = start_supervised!({MachineStore, name: nil, path: ctx.path, open?: true})

      assert MachineStore.marks(server: store) == {:ok, %{}}
      assert :ok = MachineStore.put_mark("codex", mark("hr_0a1b2c3d4e5f"), server: store)
      assert :ok = MachineStore.put_mark("codex", mark("hr_99887766aabb"), server: store)

      claude = %{mark("hr_1234abcd5678") | sign_in_file: nil, file_stat: nil}
      assert :ok = MachineStore.put_mark("claude", claude, server: store)

      assert {:ok, marks} = MachineStore.marks(server: store)

      assert marks["codex"] == %{
               vendor: "codex",
               marked_at: "2026-03-14T09:26:53Z",
               run_id: "hr_99887766aabb",
               sign_in_file: "/invented/codex-home/auth.json",
               file_stat: %{"size" => 412, "mtime" => 1_773_480_413, "inode" => 90_211}
             }

      assert %{sign_in_file: nil, file_stat: nil} = marks["claude"]

      assert :ok = MachineStore.delete_mark("codex", server: store)
      assert {:ok, %{"claude" => _claude}} = MachineStore.marks(server: store)
      assert map_size(elem(MachineStore.marks(server: store), 1)) == 1
    end

    test "another engine reads the marks on a read-only connection of its own", ctx do
      store = start_supervised!({MachineStore, name: nil, path: ctx.path, open?: true})
      :ok = MachineStore.put_mark("codex", mark("hr_0a1b2c3d4e5f"), server: store)

      assert {:ok, %{"codex" => %{run_id: "hr_0a1b2c3d4e5f"}}} = MachineStore.marks_at(ctx.path)
    end

    test "marks are cleared on a connection of its own, as a computer clears them", ctx do
      store = start_supervised!({MachineStore, name: nil, path: ctx.path, open?: true})
      :ok = MachineStore.put_mark("codex", mark("hr_0a1b2c3d4e5f"), server: store)
      :ok = MachineStore.put_mark("claude", mark("hr_1234abcd5678"), server: store)

      assert :ok = MachineStore.delete_marks_at(ctx.path, ["codex"])
      assert {:ok, marks} = MachineStore.marks(server: store)
      assert Map.keys(marks) == ["claude"]
    end
  end

  describe "where no agent can run" do
    test "no file is made; reads find no mark, nothing is deleted, a mark says why", ctx do
      store = start_supervised!({MachineStore, name: nil, path: ctx.path, open?: false})

      assert MachineStore.status(server: store) == :absent
      assert MachineStore.marks(server: store) == {:ok, %{}}

      assert MachineStore.put_mark("codex", mark("hr_0a1b2c3d4e5f"), server: store) ==
               {:error, :no_coding_agent}

      assert MachineStore.delete_mark("codex", server: store) == :ok
      assert MachineStore.marks_at(ctx.path) == {:ok, %{}}
      assert MachineStore.delete_marks_at(ctx.path, ["codex"]) == :ok
      refute File.exists?(ctx.path)
      refute File.exists?(Path.dirname(ctx.path))
    end
  end

  describe "a store that cannot open" do
    setup ctx do
      # A file where the device folder would be: nothing under it can be made.
      File.write!(Path.join(ctx.home, "device"), "")
      :ok
    end

    test "stays up, says why, and answers every request with it", ctx do
      store = start_supervised!({MachineStore, name: nil, path: ctx.path, open?: true})
      path = ctx.path

      assert {:unavailable, ^path, :enotdir} = MachineStore.status(server: store)
      assert {:error, {:store_unavailable, :enotdir}} = MachineStore.marks(server: store)

      assert {:error, {:store_unavailable, :enotdir}} =
               MachineStore.put_mark("codex", mark("hr_0a1b2c3d4e5f"), server: store)

      assert {:error, :enotdir} = MachineStore.marks_at(ctx.path)
      assert {:error, :enotdir} = MachineStore.delete_marks_at(ctx.path, ["codex"])
    end

    test "under a rest_for_one parent, the children after it start and stay up", ctx do
      children = [
        %{
          id: :store,
          start: {MachineStore, :start_link, [[name: nil, path: ctx.path, open?: true]]}
        },
        %{id: :after, start: {Agent, :start_link, [fn -> :after end]}}
      ]

      sup =
        start_supervised!(%{
          id: :parent,
          start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]},
          type: :supervisor
        })

      assert [{:after, after_pid, _, _}, {:store, store, _, _}] = Supervisor.which_children(sup)

      for _ <- 1..3 do
        assert {:error, {:store_unavailable, _reason}} = MachineStore.marks(server: store)

        assert {:error, {:store_unavailable, _reason}} =
                 MachineStore.put_mark("codex", mark("hr_0a1b2c3d4e5f"), server: store)
      end

      assert [{:after, ^after_pid, _, _}, {:store, ^store, _, _}] = Supervisor.which_children(sup)
    end
  end

  defp versions(path) do
    {:ok, conn} = Sqlite3.open(path, mode: :readonly)
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT version FROM schema_migrations ORDER BY version")
    {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    :ok = Sqlite3.close(conn)
    List.flatten(rows)
  end

  # A sign-in mark is never worth a run: a store that does not answer in time,
  # or is not there, answers its caller (the Manager, after a hand-off and at
  # boot) as unavailable, and the caller goes on.
  describe "a store that does not answer" do
    test "every call answers unavailable, and the caller is not stopped" do
      mute = start_supervised!(%{id: :mute_store, start: {Task, :start_link, [&never_answer/0]}})
      opts = [server: mute, timeout: 0]

      assert MachineStore.status(opts) == {:error, {:store_unavailable, :timeout}}
      assert MachineStore.marks(opts) == {:error, {:store_unavailable, :timeout}}

      assert MachineStore.put_mark("codex", mark("hr_0a1b2c3d4e5f"), opts) ==
               {:error, {:store_unavailable, :timeout}}

      assert MachineStore.delete_mark("codex", opts) == {:error, {:store_unavailable, :timeout}}
      assert Process.alive?(mute)
    end

    test "a store that is not running answers unavailable too" do
      gone = :"harness_machine_store_gone_#{System.unique_integer([:positive])}"
      assert MachineStore.marks(server: gone) == {:error, {:store_unavailable, :not_running}}
    end
  end

  defp never_answer do
    receive do
      :never -> :ok
    end
  end
end
