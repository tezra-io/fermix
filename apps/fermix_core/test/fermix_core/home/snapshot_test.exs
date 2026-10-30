defmodule FermixCore.Home.SnapshotTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Home.Archive
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Format
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixTestSupport.SafeRm

  @passphrase "invented-orchard-turbine"
  @now_ms 1_793_083_733_000
  @host "macos-aarch64"
  @created_at ~U[2026-10-27 09:30:00Z]

  @included %{
    "config.toml" => 0o600,
    "auth.json" => 0o600,
    "secrets/openai_api_key" => 0o600,
    "mobile/devices.toml" => 0o600,
    "mobile/gateway_key" => 0o400,
    "memory/main/MEMORY.md" => 0o644,
    "journals/2026-10-27.md" => 0o640,
    "plugins/installed/invented/1.0.0/bin/run" => 0o755
  }

  @excluded [
    "logs/fermix.log",
    "traces/2026-10-27/run.jsonl",
    "daemon.sock",
    "grants/grant-1793083733-1.json",
    "snapshots/status.json"
  ]

  @link {"plugins/installed/invented/current", "1.0.0"}

  # The derivation is the slow part, so the recovery pair is made once.
  setup_all do
    {:ok, pair} = Recipient.from_passphrase(@passphrase)
    %{pair: pair}
  end

  setup do
    tmp = SafeRm.make_tmp_dir!("home_snapshot")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)

    home = Path.join(tmp, "home")
    seed_home!(home)

    %{tmp: tmp, home: home, out: Path.join(tmp, "out.fxsnap"), into: Path.join(tmp, "restored")}
  end

  describe "a round trip" do
    test "restores every included file with its bytes and mode at epoch + 1",
         %{pair: pair, home: home, out: out, into: into} do
      assert {:ok, written} = write(home, pair, out)

      assert written.name == "20261027T093000Z-e3.fxsnap"
      assert written.epoch == 3
      assert written.created_at == @created_at
      assert written.size == File.stat!(out).size
      assert written.sha256 == sha256_file(out)
      assert mode(out) == 0o600
      assert Format.snapshot?(out)
      assert {:ok, %{epoch: 3, created_at: @created_at}} = Format.peek_header(out)

      assert {:ok, restored} = restore(out, pair, into)
      assert restored.epoch == 4
      assert restored.rewritten == ["sandbox.workspace_root"]
      assert restored.harness_consent_reset
      # The included files, the database, the epoch and the plugin lockfile.
      assert restored.files == map_size(@included) + 3

      for {path, file_mode} <- @included, path != "config.toml" do
        assert File.read!(Path.join(into, path)) == File.read!(Path.join(home, path)), path
        assert mode(Path.join(into, path)) == file_mode, path
      end

      assert File.read!(Path.join(into, "config.toml")) ==
               config_toml(home)
               |> String.replace(~s("#{home}/workspace"), ~s("#{into}/workspace"))
               |> String.replace("approved = true", "approved = false")

      assert rows(Path.join(into, "memory.db")) == 2
      assert mode(Path.join(into, "memory.db")) == 0o644

      {link, target} = @link
      assert File.read_link(Path.join(into, link)) == {:ok, target}

      for path <- @excluded, do: refute(File.exists?(Path.join(into, path)), path)
      assert Epoch.read(into) == {:ok, 4}
      assert Epoch.read(home) == {:ok, 3}
      assert mode(into) == 0o700
      assert hidden(into) == []
      assert hidden(Snapshot.Capture.dir(home)) == []
    end

    test "a function sink receives the same stream a file holds",
         %{pair: pair, home: home, tmp: tmp, into: into} do
      test = self()
      ref = make_ref()
      emit = fn iodata -> send(test, {ref, IO.iodata_to_binary(iodata)}) && :ok end

      assert {:ok, written} = Snapshot.write(home, Recipient.public(pair), emit, opts())

      stream = collect(ref, [])
      assert written.size == byte_size(stream)
      assert written.sha256 == Base.encode16(:crypto.hash(:sha256, stream), case: :lower)

      path = Path.join(tmp, "streamed.fxsnap")
      File.write!(path, stream)
      assert {:ok, %{epoch: 4}} = restore(path, pair, into)
    end

    test "files given in memory ride inside the stream, in place of a captured one",
         %{pair: pair, home: home, out: out, into: into} do
      extra = [
        {"secrets/openai_api_key", "invented-replacement"},
        {"secrets/ANTHROPIC_API_KEY", "invented-moved-value"}
      ]

      opts = Keyword.put(opts(), :extra_files, extra)
      assert {:ok, _written} = Snapshot.write(home, Recipient.public(pair), out, opts)
      refute File.read!(out) =~ "invented-moved-value"

      assert {:ok, _restored} = restore(out, pair, into)
      assert File.read!(Path.join(into, "secrets/openai_api_key")) == "invented-replacement"
      assert File.read!(Path.join(into, "secrets/ANTHROPIC_API_KEY")) == "invented-moved-value"
      assert mode(Path.join(into, "secrets/ANTHROPIC_API_KEY")) == 0o600
      assert mode(Path.join(into, "secrets")) == 0o700
      # The home itself is untouched.
      refute File.exists?(Path.join(home, "secrets/ANTHROPIC_API_KEY"))
    end

    test "a reader function restores as a file does", %{
      pair: pair,
      home: home,
      out: out,
      into: into
    } do
      {:ok, _written} = write(home, pair, out)
      {:ok, io} = File.open(out, [:read, :binary])

      try do
        assert {:ok, %{epoch: 4}} =
                 Snapshot.restore(Format.file_reader(io), pair, into, restore_opts())
      after
        File.close(io)
      end
    end

    test "into an existing empty root", %{pair: pair, home: home, out: out, into: into} do
      {:ok, _written} = write(home, pair, out)
      File.mkdir_p!(into)

      assert {:ok, %{epoch: 4}} = restore(out, pair, into)
    end
  end

  describe "a running engine" do
    # A writer holds the database open in WAL mode with committed rows still in
    # the WAL and a transaction it has not committed: the snapshot carries the
    # committed rows and nothing of the open transaction, and never the WAL.
    test "the capture is consistent while a writer holds the database",
         %{pair: pair, home: home, out: out, into: into} do
      db = Path.join(home, "memory.db")
      {:ok, conn} = Sqlite3.open(db)

      try do
        :ok = Sqlite3.execute(conn, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        :ok = Sqlite3.execute(conn, "INSERT INTO unrelated VALUES (3);")
        :ok = Sqlite3.execute(conn, "BEGIN; INSERT INTO unrelated VALUES (4);")
        assert File.exists?(db <> "-wal")

        assert {:ok, _written} = write(home, pair, out)
        :ok = Sqlite3.execute(conn, "COMMIT;")
      after
        :ok = Sqlite3.close(conn)
      end

      assert {:ok, restored} = restore(out, pair, into)
      assert restored.files == map_size(@included) + 3
      assert rows(Path.join(into, "memory.db")) == 3
      refute File.exists?(Path.join(into, "memory.db-wal"))
    end
  end

  describe "the same restore as the archive" do
    test "an archive and a snapshot of one stopped home restore alike",
         %{pair: pair, home: home, tmp: tmp} do
      archive = Path.join(tmp, "home.fxhome")
      snapshot = Path.join(tmp, "home.fxsnap")
      from_archive = Path.join(tmp, "from-archive")
      from_snapshot = Path.join(tmp, "from-snapshot")

      {:ok, _created} =
        Archive.create(home, @passphrase,
          to: archive,
          hello: fn -> {:error, :not_running} end,
          host: @host
        )

      {:ok, _written} = write(home, pair, snapshot)

      {:ok, archived} = Archive.restore(archive, @passphrase, from_archive, restore_opts())
      {:ok, snapped} = restore(snapshot, pair, from_snapshot)

      assert Map.drop(archived, [:files]) == Map.drop(snapped, [:files])
      assert tree(from_archive, from_archive) == tree(from_snapshot, from_snapshot)

      assert rows(Path.join(from_archive, "memory.db")) ==
               rows(Path.join(from_snapshot, "memory.db"))
    end
  end

  describe "what is refused" do
    test "the wrong passphrase, before anything is written",
         %{pair: pair, home: home, out: out, into: into} do
      {:ok, _written} = write(home, pair, out)
      {:ok, header} = Format.peek_header(out)
      {:ok, wrong} = Recipient.derive("another-invented-phrase", header.salt)

      assert restore(out, wrong, into) == {:error, :wrong_key}
      refute File.exists?(into)
    end

    test "a damaged snapshot leaves the root as it found it",
         %{pair: pair, home: home, out: out, into: into} do
      {:ok, written} = write(home, pair, out)
      bytes = File.read!(out)
      offset = written.size - 5
      <<before::binary-size(offset), byte, rest::binary>> = bytes
      File.write!(out, <<before::binary, Bitwise.bxor(byte, 1), rest::binary>>)

      assert restore(out, pair, into) == {:error, :snapshot_rejected}
      refute File.exists?(into)

      File.mkdir_p!(into)
      assert restore(out, pair, into) == {:error, :snapshot_rejected}
      assert File.ls!(into) == []
    end

    test "a root that is not empty", %{pair: pair, home: home, out: out, into: into} do
      {:ok, _written} = write(home, pair, out)
      File.mkdir_p!(into)
      File.write!(Path.join(into, "keep.txt"), "mine")

      assert restore(out, pair, into) == {:error, :root_not_empty}
      assert File.ls!(into) == ["keep.txt"]
    end

    test "a home that moved, and one with no primary epoch", %{pair: pair, home: home, out: out} do
      SafeRm.rm!(Epoch.path(home))
      assert write(home, pair, out) == {:error, :epoch_absent}

      :ok = Epoch.write(home, 3)
      :ok = Moved.write(home, %{epoch: 3, moved_at: @created_at, to: "invented host"})
      assert {:error, {:home_moved, %{to: "invented host"}}} = write(home, pair, out)
      refute File.exists?(out)
    end

    test "a destination that exists", %{pair: pair, home: home, out: out} do
      File.write!(out, "occupied")

      assert write(home, pair, out) == {:error, {:destination_exists, out}}
      assert File.read!(out) == "occupied"
      assert hidden(Snapshot.Capture.dir(home)) == []
    end

    test "a disk without room for the capture, by number, before anything is copied",
         %{pair: pair, home: home, out: out} do
      tight = Keyword.put(opts(), :free_bytes, fn _dir -> {:ok, 1_000} end)

      assert {:error, {:insufficient_space, need, 1_000}} =
               Snapshot.write(home, Recipient.public(pair), out, tight)

      assert need > 1_000
      refute File.exists?(out)
      assert hidden(Snapshot.Capture.dir(home)) == []

      unknown = Keyword.put(opts(), :free_bytes, fn _dir -> {:error, :df_unavailable} end)

      assert Snapshot.write(home, Recipient.public(pair), out, unknown) ==
               {:error, {:free_space_unknown, :df_unavailable}}
    end

    test "a sink that refuses removes nothing of the home and leaves no staging",
         %{pair: pair, home: home} do
      emit = fn _iodata -> {:error, :rail_closed} end

      assert Snapshot.write(home, Recipient.public(pair), emit, opts()) == {:error, :rail_closed}
      assert hidden(Snapshot.Capture.dir(home)) == []
      assert File.exists?(Path.join(home, "memory.db"))
    end
  end

  defp write(home, pair, out), do: Snapshot.write(home, Recipient.public(pair), out, opts())

  defp opts, do: [now: fn -> @created_at end, host: @host]

  defp restore(source, pair, into), do: Snapshot.restore(source, pair, into, restore_opts())

  defp restore_opts, do: [host: @host, keyring_usable?: fn -> true end, now_ms: @now_ms]

  defp seed_home!(home) do
    for {path, file_mode} <- @included do
      write!(home, path, "contents of #{path}\n", file_mode)
    end

    write!(home, "config.toml", config_toml(home), @included["config.toml"])
    write!(home, "plugins/installed.json", ~s({"invented": {"version": "1.0.0"}}\n), 0o644)
    for path <- @excluded, do: write!(home, path, "device-local #{path}\n", 0o600)
    {link, target} = @link
    File.ln_s!(target, Path.join(home, link))
    seed_database!(Path.join(home, "memory.db"))
    :ok = Epoch.write(home, 3)
  end

  defp config_toml(home) do
    """
    [fermix_core.harness]
    approved = true

    [sandbox]
    workspace_root = "#{home}/workspace"
    """
  end

  defp seed_database!(db) do
    {:ok, conn} = Sqlite3.open(db)

    :ok =
      Sqlite3.execute(
        conn,
        "CREATE TABLE unrelated (id INTEGER); INSERT INTO unrelated VALUES (1), (2);"
      )

    :ok = Sqlite3.close(conn)
    File.chmod!(db, 0o644)
  end

  defp rows(db) do
    {:ok, conn} = Sqlite3.open(db, mode: :readonly)
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT COUNT(*) FROM unrelated")
    {:ok, [[count]]} = Sqlite3.fetch_all(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    :ok = Sqlite3.close(conn)
    count
  end

  # Every path under `dir` with its mode, and its bytes except the database's,
  # which two restores rewrite in their own way.
  defp tree(root, dir) do
    dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      path = Path.join(dir, name)
      rel = Path.relative_to(path, root)

      case File.lstat!(path) do
        %{type: :directory} -> [{rel, :dir, mode(path)} | tree(root, path)]
        %{type: :symlink} -> [{rel, :link, File.read_link!(path)}]
        _file -> [{rel, mode(path), contents(rel, path)}]
      end
    end)
  end

  defp contents("memory.db" <> _suffix, _path), do: :database

  defp contents("config.toml", path),
    do: path |> File.read!() |> String.replace(Path.dirname(path), "<root>")

  defp contents(_rel, path), do: File.read!(path)

  defp hidden(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.filter(names, &String.starts_with?(&1, "."))
      {:error, :enoent} -> []
    end
  end

  defp collect(ref, acc) do
    receive do
      {^ref, piece} -> collect(ref, [acc | piece])
    after
      0 -> IO.iodata_to_binary(acc)
    end
  end

  defp sha256_file(path), do: Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower)

  defp write!(home, path, contents, file_mode) do
    file = Path.join(home, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, contents)
    File.chmod!(file, file_mode)
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end
