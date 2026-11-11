defmodule FermixCore.Home.Candidate.ActivationTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Home.AlwaysOnRelease
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidate.Activation
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Config
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Status
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.ComputerHistorySql
  alias FermixCore.Plugins.Dist.Reinstall
  alias FermixCore.Setup.MachineFile
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]
  @recovery "fxsnap1.AAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
  # The computer a move leaves, and another computer of the home.
  @mac "5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d"
  @other "0f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"

  setup do
    tmp = SafeRm.make_tmp_dir!("activation")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)

    source = Path.join(tmp, "source")
    File.mkdir_p!(Path.join(source, "journals"))

    File.write!(
      Path.join(source, "config.toml"),
      """
      [fermix_core.engine]
      role = "device"

      [fermix_core.meetings]
      recordings = "#{source}/workspace/meetings"

      [sandbox]
      workspace_root = "#{source}/workspace"

      [fermix_channels.imessage]
      enabled = true
      """
    )

    # The source's own machine file, which no stream carries (M97 §4).
    File.write!(MachineFile.path(source), "[sandbox]\nmode = \"strict\"\n")

    File.write!(Path.join([source, "journals", "day.md"]), "an invented day\n")
    :ok = Epoch.write(source, 6)

    home = Path.join(tmp, "candidate-home")
    {:ok, code} = EnrollmentCode.encode(code_facts())

    {:ok, _code} =
      Candidate.enroll(home, code,
        destination: %{"s3_bucket" => "invented-bucket-91", "s3_region" => "eu-north-1"},
        now: @now
      )

    {:ok, pair} = Candidate.recipient_pair(home)
    incoming = Candidate.incoming_path(home)

    {:ok, _written} =
      Snapshot.write(source, Recipient.public(pair), incoming, host: "macos-aarch64")

    %{tmp: tmp, source: source, home: home, pair: pair, incoming: incoming}
  end

  test "stages the stream one epoch up, settled for this home", ctx do
    {:ok, destination} = Candidate.destination(ctx.home)

    assert {:ok, 7} =
             Activation.stage(
               ctx.home,
               ctx.incoming,
               ctx.pair,
               %{"destination" => destination, "recovery_recipient" => @recovery},
               restore_opts()
             )

    staging = Candidate.staging_path(ctx.home)
    config = File.read!(Path.join(staging, "config.toml"))

    assert config =~ ~s(role = "primary")
    refute config =~ ~s(role = "device")
    assert config =~ ~s(recordings = "#{ctx.home}/workspace/meetings")
    assert config =~ ~s(s3_bucket = "invented-bucket-91")
    assert config =~ ~s(s3_region = "eu-north-1")
    refute config =~ "s3_credentials"
    assert config =~ ~s(recipient = "#{@recovery}")
    # M97 §4: no setting of the computer the home left comes with it, neither
    # its machine file nor what an earlier engine kept in its settings (an
    # iMessage switch there would refuse the load off a Mac).
    assert MachineFile.strip(config) == {config, []}
    refute File.exists?(MachineFile.path(staging))
    assert {:ok, 7} = Epoch.read(staging)
    assert File.read!(Path.join([staging, "journals", "day.md"])) == "an invented day\n"

    # Still a candidate until the staged home is renamed into place.
    assert File.read!(Path.join(ctx.home, "config.toml")) =~ ~s(role = "candidate")
  end

  # E1: a bucket the server's infrastructure set is signed with the
  # instance role, which the moved settings say explicitly; a storage address
  # or access keys the computer set by hand are dropped, since the instance
  # role signs alone.
  test "an infrastructure-set destination says to sign with the instance role", ctx do
    File.write!(
      Path.join(ctx.source, "config.toml"),
      """
      [fermix_core.engine]
      role = "device"

      [fermix_core.snapshots]
      s3_bucket = "invented-hand-set-bucket"
      s3_endpoint = "https://s3.invented.test"
      s3_access_key_id = "@file"
      s3_secret_access_key = "@file"
      """
    )

    SafeRm.rm!(ctx.incoming)

    {:ok, _written} =
      Snapshot.write(ctx.source, Recipient.public(ctx.pair), ctx.incoming, host: "macos-aarch64")

    destination = %{
      "s3_bucket" => "invented-bucket-91",
      "s3_region" => "eu-north-1",
      "s3_credentials" => "instance_role"
    }

    assert {:ok, 7} =
             Activation.stage(
               ctx.home,
               ctx.incoming,
               ctx.pair,
               %{"destination" => destination, "recovery_recipient" => @recovery},
               restore_opts()
             )

    config = File.read!(Path.join(Candidate.staging_path(ctx.home), "config.toml"))
    assert config =~ ~s(s3_bucket = "invented-bucket-91")
    assert config =~ ~s(s3_credentials = "instance_role")
    refute config =~ "invented-hand-set-bucket"
    refute config =~ "s3_endpoint"
    refute config =~ "s3_access_key_id"
    refute config =~ "s3_secret_access_key"
    assert {:ok, %{credentials: :instance_role}} = config |> snapshots_section() |> Config.s3()
  end

  # The stream again, from a source whose settings are `text`.
  defp stage_snapshots!(ctx, text) do
    File.write!(
      Path.join(ctx.source, "config.toml"),
      "[fermix_core.engine]\nrole = \"device\"\n\n" <> text
    )

    SafeRm.rm!(ctx.incoming)

    {:ok, _written} =
      Snapshot.write(ctx.source, Recipient.public(ctx.pair), ctx.incoming, host: "macos-aarch64")

    :ok
  end

  defp staged_config!(ctx, destination) do
    assert {:ok, 7} =
             Activation.stage(
               ctx.home,
               ctx.incoming,
               ctx.pair,
               %{"destination" => destination, "recovery_recipient" => @recovery},
               restore_opts()
             )

    File.read!(Path.join(Candidate.staging_path(ctx.home), "config.toml"))
  end

  defp snapshots_section(config) do
    {:ok, parsed} = TomlElixir.decode(config)
    parsed |> get_in(["fermix_core", "snapshots"]) |> Config.normalize()
  end

  # The instance role signs for the one server whose infrastructure set the
  # bucket. Wherever else the home becomes the primary, its bucket and signing
  # stay behind; a bucket set by hand with access keys travels as it was.
  describe "the last server's instance-role signing" do
    test "is left behind by a move to a server its infrastructure gave no bucket", ctx do
      stage_snapshots!(ctx, """
      [fermix_core.snapshots]
      interval_hours = 12
      s3_bucket = "invented-last-server-bucket"
      s3_region = "eu-north-1"
      s3_credentials = "instance_role"
      """)

      config = staged_config!(ctx, %{})

      refute config =~ "s3_bucket"
      refute config =~ "s3_region"
      refute config =~ "s3_credentials"
      assert config =~ "interval_hours = 12"
    end

    test "gives way to a bucket a move names by hand, signed with access keys", ctx do
      stage_snapshots!(ctx, """
      [fermix_core.snapshots]
      s3_bucket = "invented-last-server-bucket"
      s3_region = "eu-north-1"
      s3_credentials = "instance_role"
      """)

      config =
        staged_config!(ctx, %{"s3_bucket" => "invented-by-hand", "s3_region" => "eu-west-1"})

      assert config =~ ~s(s3_bucket = "invented-by-hand")
      assert config =~ ~s(s3_region = "eu-west-1")
      refute config =~ "invented-last-server-bucket"
      refute config =~ "s3_credentials"
    end

    test "a bucket set by hand with access keys travels as it was", ctx do
      stage_snapshots!(ctx, """
      [fermix_core.snapshots]
      s3_bucket = "invented-hand-set-bucket"
      s3_region = "eu-north-1"
      s3_endpoint = "https://s3.invented.test"
      """)

      config = staged_config!(ctx, %{})

      assert config =~ ~s(s3_bucket = "invented-hand-set-bucket")
      assert config =~ ~s(s3_endpoint = "https://s3.invented.test")
    end
  end

  test "the keychain's secrets the stream carried land in the file store, referenced as files",
       ctx do
    File.write!(
      Path.join(ctx.source, "config.toml"),
      """
      [fermix_core.providers.anthropic]
      api_key = "@keyring"

      [fermix_channels.telegram]
      bot_token = "@keyring"
      """
    )

    SafeRm.rm!(ctx.incoming)

    {:ok, _written} =
      Snapshot.write(ctx.source, Recipient.public(ctx.pair), ctx.incoming,
        host: "macos-aarch64",
        extra_files: [{"secrets/ANTHROPIC_API_KEY", "sk-ant-invented"}]
      )

    assert {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{}, restore_opts())

    staging = Candidate.staging_path(ctx.home)
    config = File.read!(Path.join(staging, "config.toml"))
    assert config =~ "[fermix_core.providers.anthropic]\napi_key = \"@file\""
    # Not carried, so still a keychain reference the new primary reports missing.
    assert config =~ "[fermix_channels.telegram]\nbot_token = \"@keyring\""
    secret = Path.join(staging, "secrets/ANTHROPIC_API_KEY")
    assert File.read!(secret) == "sk-ant-invented"
    assert Bitwise.band(File.stat!(secret).mode, 0o777) == 0o600
  end

  test "activation asks the new primary's first boot for a snapshot at once", ctx do
    {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{}, restore_opts())
    assert :ok = Activation.activate(ctx.home)

    assert {:ok, %{run_at_boot: true}} = Status.read(ctx.home)
  end

  # Plugins installed for another system are installed again by the new
  # primary's first boot (`Plugins.Dist.Reinstall`): the staged home names
  # them, and the name list moves into place with it.
  test "the plugins the stream brought from another system wait to be installed again", ctx do
    File.mkdir_p!(Path.join(ctx.source, "plugins"))

    File.write!(
      Path.join(ctx.source, "plugins/installed.json"),
      ~s({"invented-notes": {"version": "1.0.0"}, "invented-tasks": {"version": "2.1.0"}})
    )

    SafeRm.rm!(ctx.incoming)

    {:ok, _written} =
      Snapshot.write(ctx.source, Recipient.public(ctx.pair), ctx.incoming, host: "macos-aarch64")

    assert {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{}, restore_opts())
    assert :ok = Activation.activate(ctx.home)

    plugins = Path.join(ctx.home, "plugins")

    assert %{"pending" => ["invented-notes", "invented-tasks"]} =
             Jason.decode!(File.read!(Reinstall.path(plugins)))
  end

  test "from a computer of the same system nothing waits", ctx do
    File.mkdir_p!(Path.join(ctx.source, "plugins"))
    File.write!(Path.join(ctx.source, "plugins/installed.json"), ~s({"invented-notes": {}}))
    SafeRm.rm!(ctx.incoming)

    {:ok, _written} =
      Snapshot.write(ctx.source, Recipient.public(ctx.pair), ctx.incoming, host: "linux-aarch64")

    assert {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{}, restore_opts())
    refute File.exists?(Reinstall.path(Path.join(Candidate.staging_path(ctx.home), "plugins")))
  end

  test "a Mac takes none of another computer's own settings either", ctx do
    assert {:ok, 7} =
             Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{},
               host: "macos-aarch64",
               keyring_usable?: fn -> true end
             )

    config = File.read!(Path.join(Candidate.staging_path(ctx.home), "config.toml"))
    assert MachineFile.strip(config) == {config, []}
  end

  # Always On's switch is the home's own setting, not this computer's
  # (`Home.AlwaysOnRelease`): the settings file the move renames into place
  # last carries it to the new primary.
  test "the home's Always On switch travels to the new primary", ctx do
    File.write!(
      Path.join(ctx.source, "config.toml"),
      "\n[fermix_core.always_on]\nenabled = true\n",
      [:append]
    )

    SafeRm.rm!(ctx.incoming)

    {:ok, _written} =
      Snapshot.write(ctx.source, Recipient.public(ctx.pair), ctx.incoming, host: "macos-aarch64")

    {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{}, restore_opts())

    assert File.read!(Path.join(Candidate.staging_path(ctx.home), "config.toml")) =~
             "[fermix_core.always_on]\nenabled = true"

    assert :ok = Activation.activate(ctx.home)
    assert File.read!(Path.join(ctx.home, "config.toml")) =~ ~s(role = "primary")
    assert AlwaysOnRelease.available_in(ctx.home, :prod) == {:ok, true}
  end

  # The candidate's own switch, on while it waits for the move, goes with
  # the candidate's settings: the new primary's is the home's.
  test "a home whose switch is off is off on the new primary", ctx do
    assert AlwaysOnRelease.available_in(ctx.home, :prod) == {:ok, true}

    {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{}, restore_opts())
    assert :ok = Activation.activate(ctx.home)

    assert AlwaysOnRelease.available_in(ctx.home, :prod) == {:ok, false}
  end

  test "a stream to another key stages nothing", ctx do
    other = Recipient.generate()

    assert {:error, _reason} =
             Activation.stage(ctx.home, ctx.incoming, other, %{}, restore_opts())

    refute File.exists?(Candidate.staging_path(ctx.home))
  end

  test "activation renames the staged home into place, settings last, then drops the candidate",
       ctx do
    {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{}, restore_opts())
    File.mkdir_p!(Path.join(ctx.home, "journals"))
    File.write!(Path.join([ctx.home, "journals", "own.md"]), "the candidate's own\n")

    assert :ok = Activation.activate(ctx.home)

    assert File.read!(Path.join(ctx.home, "config.toml")) =~ ~s(role = "primary")
    assert {:ok, 7} = Epoch.read(ctx.home)
    assert File.read!(Path.join([ctx.home, "journals", "day.md"])) == "an invented day\n"
    refute File.exists?(Path.join([ctx.home, "journals", "own.md"]))
    refute Candidate.present?(ctx.home)
    # The moved settings replaced the candidate's; the machine is still the
    # Always On server its enrollment made it.
    assert Candidate.server?(ctx.home)
  end

  test "a crash in the middle is finished by the next boot of either role", ctx do
    {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{}, restore_opts())
    {:ok, state} = Candidate.read_state(ctx.home)
    :ok = Candidate.put_state(ctx.home, Map.put(state, "phase", "activating"), @now)

    # Some entries were in place when it stopped; the settings were not.
    staging = Candidate.staging_path(ctx.home)
    File.rename!(Path.join(staging, "journals"), Path.join(ctx.home, "journals"))
    assert {:error, :activation_unfinished} = Activation.finish_activation(ctx.home)

    assert :ok = Activation.activate(ctx.home)
    assert File.read!(Path.join(ctx.home, "config.toml")) =~ ~s(role = "primary")
    refute Candidate.present?(ctx.home)
  end

  test "a primary's boot removes a candidate directory its activation left", ctx do
    {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{}, restore_opts())
    {:ok, state} = Candidate.read_state(ctx.home)
    :ok = Candidate.put_state(ctx.home, Map.put(state, "phase", "activating"), @now)
    staging = Candidate.staging_path(ctx.home)

    for entry <- File.ls!(staging),
        do: File.rename!(Path.join(staging, entry), Path.join(ctx.home, entry))

    assert :ok = Activation.finish_activation(ctx.home)
    refute Candidate.present?(ctx.home)
    assert :ok = Activation.finish_activation(ctx.home)
  end

  test "a primary's boot leaves a candidate in any other phase alone", ctx do
    assert :ok = Activation.finish_activation(ctx.home)
    assert Candidate.present?(ctx.home)
  end

  # M97 §8.4: the computer a move leaves stays as a linked computer, and the
  # move names it (`"device_id"`). The notes the home made on it as its own
  # machine (""), with their reads, purges and row, are staged as that
  # computer's, in one transaction, before anything of the staged home is in
  # use. A thread is the home's; another computer's notes keep their computer.
  describe "the home's own history notes" do
    test "are staged as the notes of the computer the move left, once", ctx do
      :ok = seed_history!(ctx.source)
      :ok = recapture!(ctx)
      facts = %{"device_id" => @mac}
      staged = Path.join(Candidate.staging_path(ctx.home), "memory.db")

      expected = %{
        notes: [[@mac, "session"], [@other, "session"], ["", "thread"]],
        reads: [[@mac]],
        intervals: [[@mac]],
        rows: [[@other, 2], [@mac, 2]]
      }

      assert {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, facts, restore_opts())
      assert machines(staged) == expected

      # Staged again from the same stream, and the step run again over its
      # own work: nothing changes.
      assert {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, facts, restore_opts())
      assert machines(staged) == expected

      assert {:ok, %{notes: 0, reads: 0, intervals: 0, rows: 0}} =
               with_conn(staged, &ComputerHistorySql.rename_machine(&1, "", @mac))

      assert machines(staged) == expected
    end

    test "a move that names no computer stages them as they were", ctx do
      :ok = seed_history!(ctx.source)
      :ok = recapture!(ctx)

      assert {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{}, restore_opts())

      assert %{notes: [["", "session"], [@other, "session"], ["", "thread"]], reads: [[""]]} =
               machines(Path.join(Candidate.staging_path(ctx.home), "memory.db"))
    end

    test "a store from before notes named their machine is staged as it was", ctx do
      db = Path.join(ctx.source, "memory.db")
      {:ok, conn} = Sqlite3.open(db)
      :ok = Sqlite3.execute(conn, ComputerHistorySql.memories_schema_sql())

      :ok =
        Sqlite3.execute(
          conn,
          "INSERT INTO computer_history_memories " <>
            "(created_at, provenance_from_ts, provenance_to_ts, summary, model) " <>
            "VALUES (1, 1, 2, 'an invented sitting', 'invented-model')"
        )

      :ok = Sqlite3.close(conn)
      :ok = recapture!(ctx)
      facts = %{"device_id" => @mac}

      assert {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, facts, restore_opts())
      staged = Path.join(Candidate.staging_path(ctx.home), "memory.db")

      assert rows(staged, "SELECT summary FROM computer_history_memories") == [
               ["an invented sitting"]
             ]
    end
  end

  # The source's notes as a Mac that recorded itself writes them, through the
  # engine's own store. It is written in a folder of its own and checkpointed,
  # and only its database file goes in the home: the store's connection closes
  # after it stops, so its `-wal` and `-shm` would go while the capture walks.
  defp seed_history!(source) do
    repo = :"activation_history_#{System.unique_integer([:positive])}"
    seed = Path.join([Path.dirname(source), "seed", "memory.db"])
    File.mkdir_p!(Path.dirname(seed))
    start_supervised!({Repo, name: repo, enabled: true, database_path: seed}, id: repo)

    for {computer, n} <- [{"", 1}, {@other, 2}] do
      {:ok, {:written, _id}} =
        Repo.computer_history_home(:insert_note, [note(n), computer, "#{n}-4:#{n}", 9_000],
          server: repo
        )

      :ok = Repo.computer_history_home(:record_delivered, [computer, 2], server: repo)
    end

    {:ok, _id} =
      Repo.computer_history_insert_memory(Map.put(note(3), :kind, "thread"), server: repo)

    read = %{ts: 9_000, sink: "recall_activity", result_count: 1, computer_id: ""}
    :ok = Repo.computer_history_record_access(read, server: repo)

    {:ok, _purged} =
      Repo.computer_history_home(:purge_notes, [8_000, 8_500, 9_000, ""], server: repo)

    :ok = stop_supervised!(repo)

    with_conn(seed, fn conn ->
      {:ok, stmt} = Sqlite3.prepare(conn, "PRAGMA wal_checkpoint(TRUNCATE)")
      {:row, [0, _log, _done]} = Sqlite3.step(conn, stmt)
      Sqlite3.release(conn, stmt)
    end)

    File.cp!(seed, Path.join(source, "memory.db"))
  end

  defp note(n) do
    %{
      created_at: 9_000,
      provenance_from_ts: n * 1_000,
      provenance_to_ts: n * 1_000 + 500,
      summary: "an invented sitting #{n}",
      model: "invented-model",
      event_count: 3
    }
  end

  # The setup's capture had no store in it: the stream is taken again.
  defp recapture!(ctx) do
    SafeRm.rm!(ctx.incoming)

    {:ok, _written} =
      Snapshot.write(ctx.source, Recipient.public(ctx.pair), ctx.incoming, host: "macos-aarch64")

    :ok
  end

  defp machines(db) do
    %{
      notes: rows(db, "SELECT computer_id, kind FROM computer_history_memories ORDER BY id"),
      reads: rows(db, "SELECT computer_id FROM computer_history_access"),
      intervals: rows(db, "SELECT computer_id FROM computer_history_purges"),
      rows:
        rows(
          db,
          "SELECT computer_id, delivered_mark FROM computer_history_computers ORDER BY computer_id"
        )
    }
  end

  defp rows(db, sql) do
    with_conn(db, fn conn ->
      {:ok, stmt} = Sqlite3.prepare(conn, sql)
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      :ok = Sqlite3.release(conn, stmt)
      rows
    end)
  end

  defp with_conn(db, fun) do
    {:ok, conn} = Sqlite3.open(db)

    try do
      fun.(conn)
    after
      Sqlite3.close(conn)
    end
  end

  defp restore_opts, do: [host: "linux-aarch64", keyring_usable?: fn -> false end]

  defp code_facts do
    %{
      secret: :binary.copy(<<0x5A>>, 32),
      gateway_pk: :binary.copy(<<0x3C>>, 32),
      node_id: String.duplicate("4f", 32),
      relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
      relays_rev: "0123456789abcdef",
      name: "orchard-mini",
      expires_at: ~U[2031-05-04 10:10:00Z]
    }
  end
end
