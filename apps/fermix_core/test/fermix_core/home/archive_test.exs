defmodule FermixCore.Home.ArchiveTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Home.Archive
  alias FermixCore.Home.Archive.Manifest
  alias FermixCore.Home.Archive.Seal
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Moved
  alias FermixCore.Memory.Repo.ComputerHistorySql
  alias FermixTestSupport.SafeRm

  @passphrase "invented-harbour-lantern"
  @not_running {:error, :not_running}
  @now 1_793_083_733_000
  @host "macos-aarch64"

  # Everything that makes a home the primary, with the mode each file carries.
  @included %{
    "config.toml" => 0o600,
    "memory.db" => 0o644,
    "memory.db-wal" => 0o644,
    "memory.db-shm" => 0o644,
    "auth.json" => 0o600,
    "secrets/openai_api_key" => 0o600,
    "mobile/devices.toml" => 0o600,
    "mobile/gateway_key" => 0o400,
    "memory/main/MEMORY.md" => 0o644,
    "bootstrap/main/IDENTITY.md" => 0o644,
    "skills/invented-skill/SKILL.md" => 0o644,
    "journals/2026-10-27.md" => 0o640,
    "plugins/installed/invented/1.0.0/bin/run" => 0o755
  }

  @database_files ["memory.db", "memory.db-wal", "memory.db-shm"]

  # An installed plugin names its version through a relative link.
  @link {"plugins/installed/invented/current", "1.0.0"}

  # Device-local: present in the home, never in its archive.
  @excluded [
    "logs/fermix.log",
    "traces/2026-10-27/run.jsonl",
    "daemon.sock",
    "mobile/bridge.sock",
    "auth.json.lock",
    "mobile/.identity-transaction",
    "browser/profiles/default/Cookies",
    "imessage/cursor.json",
    "harness/runs/run-1/stdout.log",
    "grants/grant-1793083733-1.json"
  ]

  setup do
    tmp = SafeRm.make_tmp_dir!("home_archive")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)

    home = Path.join(tmp, "home")
    seed_home!(home)
    out = Path.join(tmp, "out")
    File.mkdir_p!(out)

    %{
      tmp: tmp,
      home: home,
      archive: Path.join(out, "home.fxhome"),
      into: Path.join(tmp, "restored")
    }
  end

  describe "a round trip" do
    test "restores every included file with its bytes and mode at epoch + 1",
         %{home: home, archive: archive, into: into} do
      assert {:ok, created} = create(home, archive)
      assert created.path == archive
      assert created.epoch == 3
      # Plus the epoch and the plugin lockfile the seed writes.
      assert created.files == map_size(@included) + 2
      assert created.bytes == File.stat!(archive).size
      assert created.keyring_secrets == 2
      assert mode(archive) == 0o600

      assert restore(archive, into) ==
               {:ok,
                %{
                  files: created.files,
                  epoch: 4,
                  rewritten: ["sandbox.workspace_root"],
                  kept_paths: ["sandbox.helper"],
                  harness_consent_reset: true,
                  secret_store_switched: false,
                  imessage_disabled: false,
                  keyring_secrets: 2,
                  screen_history_removed: 3,
                  source_host: @host,
                  host: @host,
                  plugins_to_reinstall: []
                }}

      # The database's own files belong to SQLite once the restore has cleared
      # screen history from it; the database is checked below.
      for {path, file_mode} <- @included, path not in @database_files do
        restored = Path.join(into, path)
        assert mode(restored) == file_mode, path

        if path != "config.toml",
          do: assert(File.read!(restored) == File.read!(Path.join(home, path)), path)
      end

      assert mode(Path.join(into, "memory.db")) == @included["memory.db"]

      # The value that named the old home moved and consent was withdrawn;
      # nothing else in the file changed.
      assert File.read!(Path.join(into, "config.toml")) ==
               config_toml(home)
               |> String.replace(~s("#{home}/workspace"), ~s("#{into}/workspace"))
               |> String.replace("approved = true", "approved = false")

      # Screen history went from the restored database and nothing else did; the
      # archived home's own database is untouched.
      assert screen_history_rows(Path.join(into, "memory.db")) == 0
      assert unrelated_rows(Path.join(into, "memory.db")) == 1
      assert screen_history_rows(Path.join(home, "memory.db")) == 3

      {link, target} = @link
      assert File.read_link(Path.join(into, link)) == {:ok, target}

      for path <- @excluded, do: refute(File.exists?(Path.join(into, path)), path)

      assert Epoch.read(into) == {:ok, 4}
      assert Epoch.read(home) == {:ok, 3}
      assert mode(into) == 0o700
      assert mode(Path.join(into, "mobile")) == 0o700
      refute File.exists?(Path.join(into, "moved.json"))
    end

    test "into the path the home was archived from rewrites nothing",
         %{tmp: tmp, home: home, archive: archive} do
      {:ok, _created} = create(home, archive)
      File.rename!(home, Path.join(tmp, "home-before"))

      assert {:ok, %{rewritten: [], epoch: 4}} = restore(archive, home)

      assert File.read!(Path.join(home, "config.toml")) ==
               String.replace(config_toml(home), "approved = true", "approved = false")
    end

    test "leaves only the archive beside the destination", %{home: home, archive: archive} do
      assert {:ok, _created} = create(home, archive)
      assert File.ls!(Path.dirname(archive)) == [Path.basename(archive)]
    end

    test "restores into an existing empty root and makes it 0700",
         %{home: home, archive: archive, into: into} do
      File.mkdir_p!(into)
      File.chmod!(into, 0o755)
      {:ok, _created} = create(home, archive)

      assert {:ok, %{epoch: 4}} = restore(archive, into)
      assert mode(into) == 0o700
    end

    test "on another OS names the installed plugins to reinstall and installs nothing",
         %{home: home, archive: archive, into: into} do
      {:ok, _created} = create(home, archive)

      assert {:ok, restored} = restore(archive, into, host: "linux-x86_64")
      assert restored.source_host == @host
      assert restored.plugins_to_reinstall == ["github", "invented"]
      assert File.read!(Path.join(into, "plugins/installed.json")) == plugin_lockfile()
    end

    test "on a host without a usable keyring moves a keyring home to the file store",
         %{home: home, archive: archive, into: into} do
      {:ok, _created} = create(home, archive)

      assert {:ok, %{secret_store_switched: true}} =
               restore(archive, into, host: "linux-x86_64", keyring_usable?: fn -> false end)

      assert File.read!(Path.join(into, "config.toml")) =~ ~s(secret_store = "file")
    end
  end

  describe "a restore that fails part-way" do
    test "removes every file, link and directory it wrote, and the root it made",
         %{tmp: tmp, into: into} do
      archive =
        craft!(
          tmp,
          [
            {%{path: "a/one", content: "1"}, "1"},
            {%{path: "b/c/two", content: "2"}, "2"}
          ],
          links: [%{path: "b/c/link", target: "two"}, %{path: "a/one/below-a-file", target: "x"}]
        )

      bad = Path.join(into, "a/one/below-a-file")
      assert restore(archive, into) == {:error, {:file, bad, :enotdir}}
      refute File.exists?(into)
    end

    test "leaves an existing root empty", %{tmp: tmp, into: into} do
      File.mkdir_p!(into)

      archive =
        craft!(tmp, [
          {%{path: "a/one", content: "1"}, "1"},
          {%{path: "b/two", content: "2"}, "2"},
          {%{path: "a/one/three", content: "3"}, "3"}
        ])

      assert restore(archive, into) == {:error, {:file, Path.join(into, "a/one/three"), :enotdir}}
      assert File.ls!(into) == []
    end
  end

  describe "what the archive holds" do
    test "manifest first, then every included file and no device-local one",
         %{home: home, archive: archive} do
      {:ok, _created} = create(home, archive)
      {:ok, tar} = Seal.open(File.read!(archive), @passphrase)
      {:ok, names} = :erl_tar.table({:binary, tar})
      names = Enum.map(names, &List.to_string/1)

      assert hd(names) == "manifest.json"

      expected =
        Enum.map(
          Map.keys(@included) ++ ["mobile/primary_epoch", "plugins/installed.json"],
          &("home/" <> &1)
        )

      assert Enum.sort(tl(names)) == Enum.sort(expected)

      {:ok, [{_name, json}]} =
        :erl_tar.extract({:binary, tar}, [:memory, {:files, [~c"manifest.json"]}])

      {:ok, manifest} = Manifest.decode(json)
      assert manifest.primary_epoch == 3
      {link, target} = @link
      assert manifest.links == [%{path: link, target: target}]

      config = Enum.find(manifest.files, &(&1.path == "config.toml"))
      content = File.read!(Path.join(home, "config.toml"))
      assert config.bytes == byte_size(content)
      assert config.sha256 == Base.encode16(:crypto.hash(:sha256, content), case: :lower)
      assert config.mode == 0o600
    end
  end

  describe "create refuses" do
    test "while the daemon that owns the home answers", %{home: home, archive: archive} do
      assert Archive.create(home, @passphrase, to: archive, hello: fn -> {:ok, %{}} end) ==
               {:error, :daemon_running}

      refute File.exists?(archive)
    end

    test "when the probe cannot tell, naming what it saw", %{home: home, archive: archive} do
      assert Archive.create(home, @passphrase, to: archive, hello: fn -> {:error, :eacces} end) ==
               {:error, {:daemon_probe_failed, :eacces}}

      refute File.exists?(archive)
    end

    test "through the daemon socket the CLI's own probe reads" do
      root = short_root!()
      seed_home!(root)
      out = SafeRm.make_tmp_dir!("home_archive_out")
      on_exit(fn -> SafeRm.rm_rf!(out) end)
      archive = Path.join(out, "home.fxhome")
      start_daemon!(Path.join(root, "daemon.sock"))

      assert Archive.create(root, @passphrase, to: archive) == {:error, :daemon_running}
      refute File.exists?(archive)
    end

    test "a home that moved, before reading anything in it", %{home: home, archive: archive} do
      marker = %{epoch: 3, moved_at: ~U[2026-10-27 09:30:00Z], to: "invented-vm"}
      :ok = Moved.write(home, marker)

      assert create(home, archive) == {:error, {:home_moved, marker}}
      refute File.exists?(archive)
      refute File.exists?(archive <> ".tar.partial")
    end

    test "a home whose moved marker cannot be read", %{home: home, archive: archive} do
      marker = Moved.path(home)
      File.write!(marker, "not a marker")

      assert {:error, {:moved_marker_unreadable, {:invalid_marker, ^marker, _detail}}} =
               create(home, archive)

      refute File.exists?(archive)
    end

    test "a home with no primary epoch", %{home: home, archive: archive} do
      SafeRm.rm!(Epoch.path(home))

      assert create(home, archive) == {:error, :epoch_absent}
      refute File.exists?(archive)
    end

    test "a passphrase under twelve bytes", %{home: home, archive: archive} do
      assert Archive.create(home, "eleven-byte", to: archive, hello: fn -> @not_running end) ==
               {:error, :passphrase_too_short}
    end

    test "a destination that exists or lies inside the home", %{home: home, archive: archive} do
      File.write!(archive, "an earlier archive")
      assert create(home, archive) == {:error, {:destination_exists, archive}}
      assert File.read!(archive) == "an earlier archive"

      inside = Path.join(home, "home.fxhome")
      assert create(home, inside) == {:error, {:destination_inside_home, inside}}
    end

    test "a link that could lead out of the home", %{home: home, archive: archive} do
      File.ln_s!("/etc", Path.join(home, "workspace-escape"))

      assert create(home, archive) == {:error, {:unsupported_link, "workspace-escape", "/etc"}}
      refute File.exists?(archive)
    end

    test "a partial file an interrupted export left, and leaves it for the owner",
         %{home: home, archive: archive} do
      stale = archive <> ".tar.partial"
      File.write!(stale, "left by an export that stopped part-way")

      assert create(home, archive) == {:error, {:stale_partial, stale}}
      assert File.read!(stale) == "left by an export that stopped part-way"
      refute File.exists?(archive)
    end

    test "a home that is not a directory", %{tmp: tmp, archive: archive} do
      missing = Path.join(tmp, "missing")
      assert create(missing, archive) == {:error, {:home_not_found, missing}}
    end
  end

  describe "restore refuses" do
    setup %{home: home, archive: archive} do
      {:ok, _created} = create(home, archive)
      :ok
    end

    test "a wrong passphrase and writes nothing", %{archive: archive, into: into} do
      assert Archive.restore(archive, "another-invented-phrase", into) ==
               {:error, :archive_rejected}

      refute File.exists?(into)
    end

    test "one flipped ciphertext byte", %{archive: archive, into: into} do
      sealed = File.read!(archive)
      offset = div(byte_size(sealed), 2)
      <<head::binary-size(offset), byte, tail::binary>> = sealed
      File.write!(archive, <<head::binary, Bitwise.bxor(byte, 0x80), tail::binary>>)

      assert restore(archive, into) == {:error, :archive_rejected}
      refute File.exists?(into)
    end

    test "a root that is not empty and leaves it as it was", %{archive: archive, into: into} do
      File.mkdir_p!(into)
      File.write!(Path.join(into, "keep.txt"), "mine")

      assert restore(archive, into) == {:error, :root_not_empty}
      assert File.ls!(into) == ["keep.txt"]
    end

    test "a passphrase under twelve bytes", %{archive: archive, into: into} do
      assert restore(archive, into, passphrase: "eleven-byte") == {:error, :passphrase_too_short}
    end

    test "an archive that does not exist", %{tmp: tmp, into: into} do
      missing = Path.join(tmp, "missing.fxhome")
      assert restore(missing, into) == {:error, {:file, missing, :enoent}}
    end
  end

  describe "restore of a crafted archive" do
    test "refuses an entry whose bytes do not match the manifest", %{tmp: tmp, into: into} do
      archive =
        craft!(tmp, [
          {%{path: "config.toml", content: "what the manifest hashed"}, "what the tar holds"}
        ])

      assert restore(archive, into) ==
               {:error, {:corrupt_entry, "config.toml"}}

      refute File.exists?(into)
    end

    test "refuses a path that escapes the root", %{tmp: tmp, into: into} do
      archive = craft!(tmp, [{%{path: "../escape", content: "x"}, "x"}])

      assert restore(archive, into) == {:error, {:unsafe_path, "../escape"}}
      refute File.exists?(into)
      refute File.exists?(Path.join(tmp, "escape"))
    end

    test "refuses a manifest beyond its byte bound", %{tmp: tmp, into: into} do
      archive =
        craft!(tmp, [
          {%{path: "memory.db", content: "x", bytes: Manifest.max_total_bytes() + 1}, "x"}
        ])

      max = Manifest.max_total_bytes()

      assert restore(archive, into) ==
               {:error, {:too_many_bytes, max + 1, max}}
    end

    test "refuses a tar entry the manifest does not list", %{tmp: tmp, into: into} do
      archive = craft!(tmp, [{%{path: "config.toml", content: "x"}, "x"}], extra: "home/stowaway")

      assert restore(archive, into) ==
               {:error, {:unlisted_entry, "home/stowaway"}}
    end

    test "refuses a home a newer engine wrote, and writes nothing", %{tmp: tmp, into: into} do
      archive =
        craft!(tmp, [{%{path: "config.toml", content: "x"}, "x"}], engine_version: "99.0.0")

      assert restore(archive, into) ==
               {:error, {:newer_engine, "99.0.0", FermixCore.BuildInfo.product_version()}}

      refute File.exists?(into)

      older =
        craft!(tmp, [{%{path: "config.toml", content: "x"}, "x"}], engine_version: "0.0.1")

      assert {:ok, _restored} = restore(older, into)
    end

    test "refuses a manifest at the highest epoch, which has no next one", %{tmp: tmp, into: into} do
      archive =
        craft!(tmp, [{%{path: "config.toml", content: "x"}, "x"}], epoch: Epoch.max_epoch())

      assert restore(archive, into) == {:error, :epoch_overflow}
      refute File.exists?(into)
    end
  end

  defp create(home, archive),
    do: Archive.create(home, @passphrase, to: archive, hello: fn -> @not_running end, host: @host)

  # This host's facts, pinned: a macOS host whose keyring answers, at a fixed now.
  defp restore(archive, into, opts \\ []) do
    {passphrase, opts} = Keyword.pop(opts, :passphrase, @passphrase)
    defaults = [host: @host, keyring_usable?: fn -> true end, now_ms: @now]
    Archive.restore(archive, passphrase, into, Keyword.merge(defaults, opts))
  end

  defp seed_home!(home) do
    for {path, file_mode} <- @included do
      write!(home, path, "contents of #{path}\n", file_mode)
    end

    write!(home, "config.toml", config_toml(home), @included["config.toml"])
    seed_database!(Path.join(home, "memory.db"))

    # Written after the database, which SQLite would otherwise tidy away.
    for path <- ["memory.db-wal", "memory.db-shm"],
        do: write!(home, path, "contents of #{path}\n", @included[path])

    write!(home, "plugins/installed.json", plugin_lockfile(), 0o644)
    for path <- @excluded, do: write!(home, path, "device-local #{path}\n", 0o600)
    {link, target} = @link
    File.ln_s!(target, Path.join(home, link))
    :ok = Epoch.write(home, 3)
  end

  # Two keyring references, one value under the home and one unrelated path.
  defp config_toml(home) do
    """
    # An invented operator's settings.
    [fermix_core]
    secret_store = "keyring"

    [fermix_core.providers.openai]
    api_key = "@keyring"

    [fermix_channels.telegram]
    bot_token = "@keyring"

    [fermix_core.harness]
    approved = true

    [sandbox]
    workspace_root = "#{home}/workspace"
    helper = "/opt/invented/tool"
    """
  end

  defp plugin_lockfile,
    do: ~s({"invented": {"version": "1.0.0"}, "github": {"version": "2.0.0"}}\n)

  # A real database in rollback-journal mode, so SQLite never reads the seeded
  # `-wal` and `-shm` text beside it: two screen-history events, one summary
  # and one unrelated row.
  defp seed_database!(db) do
    SafeRm.rm!(db)
    {:ok, conn} = Sqlite3.open(db)

    for sql <- [
          ComputerHistorySql.events_schema_sql(),
          ComputerHistorySql.memories_schema_sql(),
          ComputerHistorySql.state_schema_sql(),
          ComputerHistorySql.access_schema_sql(),
          ComputerHistorySql.purges_schema_sql(@now - 86_400_000),
          "CREATE TABLE unrelated (id INTEGER); INSERT INTO unrelated VALUES (1);",
          "INSERT INTO computer_history_events (boot_id, source_seq, ts, type) " <>
            "VALUES ('invented', 1, #{@now - 7_200_000}, 'app_switch'), " <>
            "('invented', 2, #{@now - 3_600_000}, 'app_switch');",
          "INSERT INTO computer_history_memories " <>
            "(created_at, provenance_from_ts, provenance_to_ts, summary, model) " <>
            "VALUES (#{@now - 3_600_000}, #{@now - 7_200_000}, #{@now - 3_600_000}, " <>
            "'invented summary', 'invented-model');"
        ] do
      :ok = Sqlite3.execute(conn, sql)
    end

    :ok = Sqlite3.close(conn)
    File.chmod!(db, @included["memory.db"])
  end

  defp screen_history_rows(db) do
    count(
      db,
      "SELECT (SELECT COUNT(*) FROM computer_history_events) + " <>
        "(SELECT COUNT(*) FROM computer_history_memories)"
    )
  end

  defp unrelated_rows(db), do: count(db, "SELECT COUNT(*) FROM unrelated")

  defp count(db, sql) do
    {:ok, conn} = Sqlite3.open(db, mode: :readonly)
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    {:ok, [[count]]} = Sqlite3.fetch_all(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    :ok = Sqlite3.close(conn)
    count
  end

  defp write!(home, path, contents, file_mode) do
    file = Path.join(home, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, contents)
    File.chmod!(file, file_mode)
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  # Builds a sealed archive by hand: `{entry, tar_content}` pairs, where the
  # manifest hashes `entry.content` and the tar carries `tar_content`.
  defp craft!(tmp, pairs, opts \\ []) do
    files =
      Enum.map(pairs, fn {entry, _tar_content} ->
        %{
          path: entry.path,
          bytes: Map.get(entry, :bytes, byte_size(entry.content)),
          sha256: Base.encode16(:crypto.hash(:sha256, entry.content), case: :lower),
          mode: 0o600
        }
      end)

    header = %{
      primary_epoch: Keyword.get(opts, :epoch, 3),
      home_root: "/home/invented/.fermix",
      host: @host
    }

    manifest =
      header
      |> Manifest.new(files, Keyword.get(opts, :links, []))
      |> Map.update!(:engine_version, &Keyword.get(opts, :engine_version, &1))
      |> Manifest.encode()

    tar_path = Path.join(tmp, "crafted.tar")
    {:ok, tar} = :erl_tar.open(String.to_charlist(tar_path), [:write])
    :ok = :erl_tar.add(tar, manifest, ~c"manifest.json", [])

    for {entry, tar_content} <- pairs do
      :ok = :erl_tar.add(tar, tar_content, String.to_charlist("home/" <> entry.path), [])
    end

    if extra = opts[:extra], do: :ok = :erl_tar.add(tar, "x", String.to_charlist(extra), [])
    :ok = :erl_tar.close(tar)

    {:ok, sealed} = Seal.seal(File.read!(tar_path), @passphrase)
    archive = Path.join(tmp, "crafted.fxhome")
    File.write!(archive, sealed)
    archive
  end

  # A unix socket address is capped at 104 bytes on macOS, so a home that hosts
  # a live daemon socket sits directly under the temp dir.
  defp short_root! do
    root = Path.join(System.tmp_dir!(), "fxa-#{System.unique_integer([:positive, :monotonic])}")
    SafeRm.mark!(root)
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    root
  end

  defp start_daemon!(socket_path) do
    sup = :"archive_test_tasks_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!({Task.Supervisor, name: sup})

    start_supervised!(
      {Fermix.CLI.Daemon,
       name: :"archive_test_daemon_#{System.unique_integer([:positive, :monotonic])}",
       socket_path: socket_path,
       task_supervisor: sup}
    )
  end
end
