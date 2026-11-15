defmodule FermixCore.Home.LocalReturnTest do
  # Restore here (Always On's move back design §8): the computer the home
  # left takes it back from its own copy of the server's snapshots. The
  # passphrase alone opens a copy (its header carries the salt); the newest
  # copy whose key id the passphrase derives is the one restored, and a
  # passphrase that opens none is refused before a byte is decrypted. Then
  # the copy is staged as a return's, put in place of the retired copy and the
  # engine restarts. Real: both homes on disk, the copies, the restore, the
  # staging's settling and the activation's renames. Stood in for: the
  # restart (a message to the test).
  use ExUnit.Case, async: true

  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.LocalReturn
  alias FermixCore.Home.Moved
  alias FermixCore.Home.MoveTelemetry
  alias FermixCore.Home.Readable
  alias FermixCore.Home.Return
  alias FermixCore.Home.Role
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Capture
  alias FermixCore.Home.Snapshot.Format
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixTestSupport.CraftedSnapshot
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2031-06-01 09:00:00Z]
  @passphrase "invented-lighthouse-meridian"

  setup do
    tmp = SafeRm.make_tmp_dir!("local_return")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    mac = retired_mac!(Path.join(tmp, "mac"))
    server = server_home!(Path.join(tmp, "server"))
    %{tmp: tmp, mac: mac, server: server}
  end

  test "the newest copy the passphrase opens is chosen, and one it opens none of is refused",
       ctx do
    {:ok, old_pair} = Recipient.from_passphrase(@passphrase)
    {:ok, other} = Recipient.from_passphrase("another-invented-passphrase")

    older = copy!(ctx, ~U[2031-05-31 02:00:00Z], old_pair)
    _newest_other = copy!(ctx, ~U[2031-06-01 02:00:00Z], other)
    newer = copy!(ctx, ~U[2031-05-31 14:00:00Z], old_pair)

    assert {:ok, chosen} = LocalReturn.choose(ctx.mac, @passphrase)
    assert chosen.name == Path.basename(newer)
    assert chosen.path == newer
    assert chosen.at == ~U[2031-05-31 14:00:00Z]
    assert Recipient.matches?(chosen.pair, old_pair)
    refute inspect(chosen) =~ Base.encode64(chosen.pair.secret_key)

    assert LocalReturn.choose(ctx.mac, "a-wrong-passphrase-entirely") ==
             {:error, :wrong_passphrase}

    assert LocalReturn.choose(ctx.mac, "short") == {:error, :passphrase_too_short}
    assert LocalReturn.choose(ctx.mac, nil) == {:error, :passphrase_not_text}
    assert File.exists?(older)
  end

  test "a copy that is no snapshot is passed over, and none at all is said", ctx do
    File.mkdir_p!(Capture.dir(ctx.mac))
    File.write!(Path.join(Capture.dir(ctx.mac), "20310601T020000Z-e5.fxsnap"), "not a snapshot")
    assert LocalReturn.choose(ctx.mac, @passphrase) == {:error, :wrong_passphrase}

    empty = Path.join(ctx.tmp, "empty")
    File.mkdir_p!(empty)
    assert LocalReturn.choose(empty, @passphrase) == {:error, :no_copy}
  end

  test "the copy is put in place of the retired one, then the engine restarts, with its " <>
         "bookends",
       ctx do
    {:ok, pair} = Recipient.from_passphrase(@passphrase)
    copy!(ctx, ~U[2031-06-01 02:00:00Z], pair)
    {:ok, chosen} = LocalReturn.choose(ctx.mac, @passphrase)
    TelemetryCapture.attach([MoveTelemetry.event()], :emitter)

    assert {:ok, %{"restored" => true, "epoch" => 6}} =
             LocalReturn.restore(ctx.mac, Map.put(chosen, :from, "north-box"), opts())

    assert_received :restarted

    assert {:ok, %{role: :primary}} = Role.configured(ctx.mac)
    assert {:ok, 6} = Epoch.read(ctx.mac)
    assert Moved.read(ctx.mac) == :absent
    refute Candidate.present?(ctx.mac)
    assert File.read!(Path.join([ctx.mac, "journals", "day.md"])) == "a day on the server\n"
    assert File.read!(Path.join([ctx.mac, "browser", "profiles", "owner", "Cookies"])) == "kept"
    refute File.exists?(Path.join(ctx.mac, "chatgpt_host.json"))
    # The copy itself stays, as every copy this computer keeps does.
    assert File.exists?(chosen.path)

    # Review m3: the return's record names the copy put in place, which the
    # primary it made tells once.
    assert {:ok, %{restored: restored, from: "north-box"}} = Return.read(ctx.mac)
    assert restored == chosen.name

    assert_received {:telemetry, _event, _measurements,
                     %{phase: :started, side: :candidate, move_id: "local-" <> stamp}}

    assert stamp == Integer.to_string(DateTime.to_unix(@now))

    assert_received {:telemetry, _event, _measurements,
                     %{phase: :finished, result: :done, move_id: "local-" <> ^stamp}}
  end

  test "a copy that does not restore leaves the restore failed, in words, and no restart",
       ctx do
    {:ok, pair} = Recipient.from_passphrase(@passphrase)
    path = copy!(ctx, ~U[2031-06-01 02:00:00Z], pair)
    {:ok, chosen} = LocalReturn.choose(ctx.mac, @passphrase)
    # The copy is cut short after its header was read.
    File.write!(path, binary_part(File.read!(path), 0, Format.header_bytes() + 10))

    assert {:error, {:refused, sentence}} =
             LocalReturn.restore(ctx.mac, Map.put(chosen, :from, "north-box"), opts())

    assert sentence ==
             "The backup on this computer could not be restored here; Fermix's log says why."

    refute_received :restarted

    assert {:ok, %{"kind" => "local", "phase" => "failed", "sentence" => ^sentence}} =
             Candidate.read_state(ctx.mac)

    assert {:ok, %{role: :device}} = Role.configured(ctx.mac)
    assert {:ok, _marker} = Moved.read(ctx.mac)
    assert Return.read(ctx.mac) == :absent
  end

  # M97 D16: a copy in a newer format than this computer's Fermix reads is
  # refused before anything is written, and the owner reads what to do.
  test "a copy in a newer format says to update Fermix on this computer first", ctx do
    {:ok, pair} = Recipient.from_passphrase(@passphrase)
    File.mkdir_p!(Capture.dir(ctx.mac))
    path = Path.join(Capture.dir(ctx.mac), Snapshot.name(~U[2031-06-01 02:00:00Z], 5))
    newer = Readable.home_format() + 1
    CraftedSnapshot.write!(path, Recipient.public(pair), ctx.server, home_format: newer)
    {:ok, chosen} = LocalReturn.choose(ctx.mac, @passphrase)

    assert LocalReturn.restore(ctx.mac, Map.put(chosen, :from, "north-box"), opts()) ==
             {:error, {:refused, Readable.refusal_sentence()}}

    refute_received :restarted
    assert {:ok, %{role: :device}} = Role.configured(ctx.mac)
    refute File.exists?(Candidate.staging_path(ctx.mac))
  end

  test "an engine that would not start again on its own is refused before anything", ctx do
    {:ok, pair} = Recipient.from_passphrase(@passphrase)
    copy!(ctx, ~U[2031-06-01 02:00:00Z], pair)
    {:ok, chosen} = LocalReturn.choose(ctx.mac, @passphrase)

    assert {:error, {:refused, sentence}} =
             LocalReturn.restore(
               ctx.mac,
               Map.put(chosen, :from, "north-box"),
               Keyword.put(opts(), :restarts_itself?, false)
             )

    assert sentence =~ "Install it as a service first."
    refute Candidate.present?(ctx.mac)
  end

  defp opts do
    test = self()

    [
      now: @now,
      role: :device,
      restarts_itself?: true,
      restore_opts: [host: "macos-aarch64"],
      restart: fn ->
        send(test, :restarted)
        :ok
      end
    ]
  end

  # A copy of the server's home this computer keeps, written for `pair`.
  defp copy!(ctx, at, pair) do
    File.mkdir_p!(Capture.dir(ctx.mac))
    path = Path.join(Capture.dir(ctx.mac), Snapshot.name(at, 5))

    {:ok, _written} =
      Snapshot.write(ctx.server, Recipient.public(pair), path,
        host: "linux-aarch64",
        now: fn -> at end
      )

    path
  end

  defp retired_mac!(mac) do
    File.mkdir_p!(Path.join([mac, "browser", "profiles", "owner"]))
    File.mkdir_p!(Path.join(mac, "journals"))

    File.write!(Path.join(mac, "config.toml"), """
    [fermix_core.engine]
    role = "device"

    [fermix_core]
    secret_store = "file"
    """)

    File.write!(Path.join([mac, "browser", "profiles", "owner", "Cookies"]), "kept")
    File.write!(Path.join(mac, "chatgpt_host.json"), "stale")
    File.write!(Path.join([mac, "journals", "day.md"]), "a retired day\n")
    :ok = Moved.write(mac, %{epoch: 4, moved_at: @now, to: "north-box"})
    mac
  end

  defp server_home!(server) do
    File.mkdir_p!(Path.join(server, "journals"))

    File.write!(Path.join(server, "config.toml"), """
    [fermix_core.engine]
    role = "primary"
    """)

    File.write!(Path.join([server, "journals", "day.md"]), "a day on the server\n")
    :ok = Epoch.write(server, 5)
    server
  end
end
