defmodule FermixCore.Home.MoveTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.Candidates
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Role
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Setup.ConfigStore
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]
  @passphrase "invented-lantern-orchard"
  @primary %{role: :primary, primary: nil}

  setup do
    home = SafeRm.make_tmp_dir!("move")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    :ok = Epoch.write(home, 4)

    File.write!(
      Path.join(home, "config.toml"),
      "# the owner's note\n[sandbox]\nmode = \"strict\"\n"
    )

    {:ok, candidate} = Candidates.add(home, candidate_attrs(), @now)
    %{home: home, candidate: candidate}
  end

  test "start writes the request and hands the home to the device role", ctx do
    assert {:ok, started} =
             Move.start(ctx.home, @primary, ctx.candidate.candidate_id, @passphrase, opts())

    assert "mv-" <> _hex = started.move_id
    assert started.candidate.name == "north-box"
    assert {:ok, recipient} = Recipient.decode(started.recovery_recipient)
    assert Bitwise.band(File.stat!(Move.dir(ctx.home)).mode, 0o777) == 0o700

    assert {:ok, request} = Move.read_request(ctx.home)
    assert request["move_id"] == started.move_id
    assert request["source_epoch"] == 4
    assert request["candidate"].noise_pk == ctx.candidate.noise_pk
    assert request["recovery_recipient"] == Recipient.encode(recipient)
    refute File.read!(Path.join([Move.dir(ctx.home), "request.json"])) =~ @passphrase

    assert {:ok, %{"phase" => "requested", "candidate" => "north-box"}} =
             Move.read_phase(ctx.home)

    assert Move.pending?(ctx.home)

    config = File.read!(Path.join(ctx.home, "config.toml"))
    assert config =~ "# the owner's note"
    assert config =~ ~s(mode = "strict")
    assert {:ok, %{role: :device}} = Role.configured(ctx.home)

    assert %{"phase" => "requested", "candidate" => "north-box", "sentence" => sentence} =
             Move.view(ctx.home)

    assert sentence =~ "starts when Fermix restarts"
  end

  test "start refuses what it cannot move, and writes nothing", ctx do
    id = ctx.candidate.candidate_id

    assert {:error, {:not_primary, :device}} =
             Move.start(ctx.home, %{role: :device, primary: nil}, id, @passphrase, opts())

    assert {:error, {:unknown_candidate, "cand-0"}} =
             Move.start(ctx.home, @primary, "cand-0", @passphrase, opts())

    assert {:error, :passphrase_too_short} =
             Move.start(ctx.home, @primary, id, "short", opts())

    later = DateTime.add(@now, 24 * 3_600, :second)

    assert {:error, {:unknown_candidate, ^id}} =
             Move.start(ctx.home, @primary, id, @passphrase, opts(now: later))

    :ok = Moved.write(ctx.home, %{epoch: 4, moved_at: @now, to: "elsewhere"})

    assert {:error, {:not_primary, :device}} =
             Move.start(ctx.home, @primary, id, @passphrase, opts())

    refute File.exists?(Move.dir(ctx.home))
    assert {:ok, %{role: :device}} = Role.configured(ctx.home)
    refute File.read!(Path.join(ctx.home, "config.toml")) =~ "role ="
  end

  test "a move a device is running is not started again; a stale request is replaced", ctx do
    id = ctx.candidate.candidate_id
    {:ok, first} = Move.start(ctx.home, @primary, id, @passphrase, opts())

    :ok = Move.put_phase(ctx.home, "streaming", %{}, @now)

    assert {:error, {:move_pending, "streaming"}} =
             Move.start(ctx.home, @primary, id, @passphrase, opts())

    :ok = Move.put_phase(ctx.home, "requested", %{}, @now)
    assert {:ok, second} = Move.start(ctx.home, @primary, id, @passphrase, opts())
    refute second.move_id == first.move_id

    :ok = Move.put_phase(ctx.home, "aborted", %{"sentence" => "It was undone."}, @now)
    refute Move.pending?(ctx.home)
    assert %{"phase" => "aborted", "sentence" => "It was undone."} = Move.view(ctx.home)
  end

  test "start refuses while the readiness report blocks, and writes nothing", ctx do
    id = ctx.candidate.candidate_id
    tight = opts(free_bytes: fn _dir -> {:ok, 1_000} end)

    assert {:error, {:not_ready, [sentence]}} =
             Move.start(ctx.home, @primary, id, @passphrase, tight)

    assert sentence =~ "make room first"
    assert Move.error_sentence({:not_ready, [sentence]}) =~ "make room first"
    refute File.exists?(Move.dir(ctx.home))
    refute File.read!(Path.join(ctx.home, "config.toml")) =~ "role ="
  end

  test "an ending is published by the engine that survives the restart", ctx do
    id = ctx.candidate.candidate_id
    {:ok, _started} = Move.start(ctx.home, @primary, id, @passphrase, opts())

    assert Move.moving_to(ctx.home) == {:ok, "north-box"}

    # The worker records committed and restarts; the relaunched device says done.
    :ok = Move.put_phase(ctx.home, "committed", %{"epoch" => 5}, @now)
    assert Move.moving_to(ctx.home) == {:ok, "north-box"}
    refute Move.pending?(ctx.home)
    assert %{"phase" => "committed", "sentence" => committed} = Move.view(ctx.home)
    assert committed =~ "restarting"
    assert :ok = Move.finish_at_boot(ctx.home, :primary)
    assert {:ok, %{"phase" => "committed"}} = Move.read_phase(ctx.home)
    assert :ok = Move.finish_at_boot(ctx.home, :device)
    assert {:ok, %{"phase" => "done", "epoch" => 5}} = Move.read_phase(ctx.home)
    assert Move.moving_to(ctx.home) == :none

    # An undone move: the relaunched primary says aborted, keeping the reason.
    :ok = Move.put_phase(ctx.home, "undoing", %{"sentence" => "north-box refused it."}, @now)
    assert :ok = Move.finish_at_boot(ctx.home, :device)
    assert {:ok, %{"phase" => "undoing"}} = Move.read_phase(ctx.home)
    assert :ok = Move.finish_at_boot(ctx.home, :primary)

    assert {:ok, %{"phase" => "aborted", "sentence" => "north-box refused it."}} =
             Move.read_phase(ctx.home)

    # A crash between the role write and the record leaves aborting: the same.
    :ok = Move.put_phase(ctx.home, "aborting", %{}, @now)
    assert :ok = Move.finish_at_boot(ctx.home, :primary)
    assert {:ok, %{"phase" => "aborted"}} = Move.read_phase(ctx.home)
  end

  test "the engine role is one line changed, every other byte kept", ctx do
    :ok = ConfigStore.put_engine_role(ctx.home, :device)
    :ok = ConfigStore.put_engine_role(ctx.home, :primary)

    assert File.read!(Path.join(ctx.home, "config.toml")) ==
             "# the owner's note\n[sandbox]\nmode = \"strict\"\n\n[fermix_core.engine]\nrole = \"primary\"\n"

    assert Bitwise.band(File.stat!(Path.join(ctx.home, "config.toml")).mode, 0o777) == 0o600
    assert {:ok, [role: :primary]} = ConfigStore.engine_config(ctx.home)
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        now: @now,
        free_bytes: fn _dir -> {:ok, 1_099_511_627_776} end,
        version: "0.16.0",
        host: "macos-aarch64"
      ],
      extra
    )
  end

  defp candidate_attrs do
    %{
      name: "north-box",
      os: "linux",
      arch: "aarch64",
      version: "9.9.9",
      node_id: String.duplicate("ab", 32),
      relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
      noise_pk: :binary.copy(<<1>>, 32),
      recipient: :binary.copy(<<2>>, 32),
      instance: nil,
      snapshots: nil
    }
  end
end
