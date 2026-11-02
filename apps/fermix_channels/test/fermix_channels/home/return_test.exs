defmodule FermixChannels.Home.ReturnTest do
  @moduledoc """
  Always On's move back, end to end in one VM (design §3, §10, §11.2): a home
  moves from a Mac to a server, then the Mac takes it back. Epochs: the Mac
  at 4, the server at 5, the Mac back at 6.

  Real: both homes on disk, the forward move as `Home.MoveTest` runs it, the
  server's enrollment window and session, the Mac's return candidate (the
  candidate process of kind `return`, written by `Candidate.prepare_return/3`)
  behind its own bridge, `home.move.start` on the server as the Mac forwards
  it (the recovery passphrase checked against the key the forward move
  carried, the server kept as nothing), the server's move worker, Noise
  through `Mobile.Rail`, the capture, the return's staging and its in-place
  activation. Stood in for: the iroh dial (bridge sockets), the restarts and
  the timers (messages to the test), the boots (each one's own step is run:
  `Candidate.finish_activation/1` and `Home.Return.done/2` for the Mac's
  primary boot, `Move.finish_at_boot/2` for the server's).

  Every state the tests stop in is checked for at most one primary among the
  two homes, and never a Mac whose settings say primary beside its marker.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Home.Enrollment
  alias FermixChannels.Home.MoveWorker
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Iroh.Key
  alias FermixChannels.Mobile.Rail
  alias FermixChannels.Test.DesktopRail
  alias FermixChannels.Test.HomeMove
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidate.Activation
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Return
  alias FermixCore.Home.Role
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Recovery
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router
  alias FermixTestSupport.TelemetryCapture

  @moduletag timeout: 120_000

  @now HomeMove.now()
  @primary %{role: :primary, primary: nil}
  @passphrase "invented-lighthouse-meridian"
  @mac_host %{"name" => "studio-mac", "os" => "darwin", "arch" => "aarch64", "version" => "9.9.9"}

  setup do
    mac = HomeMove.primary!()
    own_paths!(mac.root)
    {:ok, recipient} = Recovery.set(@passphrase, config: [], save_recipient: &{:ok, &1})

    # Forward: the Mac moves to the server and stays as its desktop.
    {:ok, %{code: code}} = Enrollment.open(mac.enrollment, :manual)
    server_root = HomeMove.candidate_home!(code)
    to_server = HomeMove.start_candidate!(server_root, mac)
    %{"candidate_id" => to_server_id} = HomeMove.await_phase(server_root, "enrolled")
    {:ok, _move} = Move.start(mac.root, @primary, to_server_id, recipient, HomeMove.start_opts())
    run_worker(mac.root, to_server)
    assert_received :source_restart
    assert_received {:scheduled, :restart, _delay}
    :ok = Move.finish_at_boot(mac.root, :device)

    # The server's first boot as the primary, and a day of its own.
    :ok = Candidate.finish_activation(server_root)
    server = HomeMove.serve!(server_root, name: "north-box")
    File.write!(Path.join([server_root, "journals", "on-the-server.md"]), "a day there\n")
    assert {:ok, %{role: :device}} = Role.configured(mac.root)
    assert {:ok, 5} = Epoch.read(server_root)

    %{mac: mac, server: server, recipient: recipient}
  end

  test "the home comes back: the Mac is the one primary at N+2, the server is marked", ctx do
    back = move_back!(ctx)
    assert {:ok, %{"move_id" => move_id}} = move_now(ctx, back, @passphrase)
    TelemetryCapture.attach([[:fermix, :home, :move]], move_id: move_id)
    assert_received :server_restart
    one_primary!(ctx)

    run_worker(ctx.server.root, back)

    # The server: marked for the Mac, committed, kept as nothing.
    assert_received :source_restart
    assert {:ok, %{to: "studio-mac", epoch: 5}} = Moved.read(ctx.server.root)
    assert {:ok, %{"phase" => "committed", "epoch" => 6}} = Move.read_phase(ctx.server.root)
    assert :ok = Move.finish_at_boot(ctx.server.root, :device)
    assert {:ok, %{role: :device, primary: "studio-mac"}} = Role.configured(ctx.server.root)
    refute File.exists?(DesktopLink.path(ctx.server.root))

    # The Mac: the primary at 6 in place, its own paths kept.
    assert_received {:scheduled, :restart, _delay}
    mac = ctx.mac.root
    refute Candidate.present?(mac)
    assert Moved.read(mac) == :absent
    assert {:ok, %{role: :primary}} = Role.configured(mac)
    assert {:ok, 6} = Epoch.read(mac)
    assert File.read!(Path.join([mac, "journals", "on-the-server.md"])) == "a day there\n"
    assert File.read!(Path.join([mac, "browser", "profiles", "owner", "Cookies"])) == "cookies"
    assert File.read!(Path.join([mac, "imessage", "cursor"])) == "rowid 4411"
    assert File.read!(Key.path(mac)) == File.read!(Key.path(ctx.server.root))
    refute File.exists?(DesktopLink.path(mac))
    refute File.exists?(DesktopLink.key_path(mac))
    # Its own desktop row is gone from the list it took back.
    assert {:ok, []} = DeviceStore.list(root: mac)
    assert File.read!(Path.join(mac, "config.toml")) =~ ~s(workspace_root = "#{mac}/workspace")
    one_primary!(ctx)

    # The Mac's first boot as the primary records that it took Fermix back.
    assert :ok = Candidate.finish_activation(mac)
    assert :ok = Return.done(mac, @now)
    assert {:ok, %{moved_at: @now, epoch: 6, from: "north-box"}} = Return.read(mac)

    assert_received {:telemetry, [:fermix, :home, :move], _m,
                     %{phase: :finished, side: :source, result: :done}}

    assert_received {:telemetry, [:fermix, :home, :move], _m,
                     %{phase: :finished, side: :candidate, result: :done, epoch: 6}}
  end

  test "a recovery passphrase that is not the one set is refused by the server", ctx do
    back = move_back!(ctx)

    assert {:error, :invalid_params, %{"field" => "recovery_passphrase", "sentence" => sentence}} =
             move_now(ctx, back, "invented-but-not-the-one-set")

    assert sentence == "That is not the recovery passphrase you set."
    refute_received :server_restart
    refute Move.pending?(ctx.server.root)
    assert {:ok, %{role: :primary}} = Role.configured(ctx.server.root)
    assert {:ok, %{"phase" => "enrolled"}} = Candidate.read_state(ctx.mac.root)
    one_primary!(ctx)
  end

  test "a Mac with too little disk refuses the offer by name, and the server is the primary again",
       ctx do
    back = move_back!(ctx, free_bytes: fn _dir -> {:ok, 1_000} end)
    assert {:ok, _started} = move_now(ctx, back, @passphrase)

    run_worker(ctx.server.root, back)

    assert {:ok, %{"phase" => "undoing", "sentence" => sentence}} =
             Move.read_phase(ctx.server.root)

    assert sentence =~ "studio-mac refused the move (move_failed: This Mac needs about"
    assert sentence =~ "make room on its disk, then move back again"
    assert Moved.read(ctx.server.root) == :absent
    assert :ok = Move.finish_at_boot(ctx.server.root, :primary)
    assert {:ok, %{role: :primary}} = Role.configured(ctx.server.root)

    # The Mac is as it was, still enrolled: Try again needs nothing new.
    assert {:ok, %{role: :device}} = Role.configured(ctx.mac.root)
    assert {:ok, _marker} = Moved.read(ctx.mac.root)
    assert {:ok, %{"phase" => "enrolled"}} = Candidate.read_state(ctx.mac.root)
    one_primary!(ctx)
  end

  test "the Mac's engine down through the server's commit: the resume finds the staged home",
       ctx do
    back = move_back!(ctx)
    assert {:ok, _started} = move_now(ctx, back, @passphrase)
    stage_by_hand!(ctx, back, 1)
    # The server wrote its marker, and its move_commit found no engine.
    retire_by_hand!(ctx)
    one_primary!(ctx)

    HomeMove.restart_candidate!(back, ctx.server)
    HomeMove.await_phase(ctx.mac.root, "staged")
    run_worker(ctx.server.root, back)

    assert {:ok, %{"phase" => "committed", "epoch" => 6}} = Move.read_phase(ctx.server.root)
    assert_receive {:scheduled, :restart, _delay}, 10_000
    assert {:ok, %{role: :primary}} = Role.configured(ctx.mac.root)
    assert {:ok, 6} = Epoch.read(ctx.mac.root)
    one_primary!(ctx)
  end

  test "a dropped connection: the next attempt sends the same capture again", ctx do
    back = move_back!(ctx)
    assert {:ok, _started} = move_now(ctx, back, @passphrase)
    {:ok, dials} = Agent.start_link(fn -> 0 end)

    connect = fn _route ->
      case Agent.get_and_update(dials, &{&1, &1 + 1}) do
        0 -> fn -> {:error, :econnreset} end
        _later -> DesktopRail.bridge_connect(back.bridge_socket)
      end
    end

    run_worker(ctx.server.root, back, connect: connect)

    assert {:ok, %{"phase" => "committed", "attempts" => 2}} = Move.read_phase(ctx.server.root)
    assert {:ok, 6} = Epoch.read(ctx.mac.root)
    one_primary!(ctx)
  end

  test "the late offer of an attempt the server gave up on never discards the staged home",
       ctx do
    back = move_back!(ctx)
    assert {:ok, _started} = move_now(ctx, back, @passphrase)
    stage_by_hand!(ctx, back, 2)
    {:ok, request} = Move.read_request(ctx.server.root)

    {:ok, rail} = open_move(ctx, back, request["candidate"])

    :ok =
      Rail.send_event(rail, "move_offer", %{
        "move_id" => request["move_id"],
        "size_bytes" => 1,
        "sha256" => String.duplicate("0", 64),
        "source_epoch" => 5,
        "attempt" => 1
      })

    assert_receive {:rail, ^rail, {:event, %{"t" => "error", "code" => "move_mismatch"}, _b}},
                   10_000

    assert {:ok, %{"phase" => "staged"}} = Candidate.read_state(ctx.mac.root)
    assert File.dir?(Candidate.staging_path(ctx.mac.root))
    one_primary!(ctx)
  end

  describe "a stop on the Mac after a durable write is finished by its next start" do
    test "written but not yet enrolled; enrolled; receiving", ctx do
      # Written by Move back, then the engine stopped before its candidate
      # ran: the next start enrolls it.
      back = move_back!(ctx, start: false)
      one_primary!(ctx)
      back = start_back!(ctx, back)
      assert {:ok, %{"phase" => "enrolled"}} = Candidate.read_state(ctx.mac.root)

      # Enrolled, then stopped: still enrolled, and the move goes on.
      HomeMove.restart_candidate!(back, ctx.server)
      HomeMove.await_phase(ctx.mac.root, "enrolled")
      assert {:ok, _started} = move_now(ctx, back, @passphrase)

      # Receiving the first attempt, then stopped: the server's attempt
      # failed, and its second is taken.
      receiving_by_hand!(ctx, back)
      HomeMove.restart_candidate!(back, ctx.server)
      HomeMove.await_phase(ctx.mac.root, "receiving")
      one_primary!(ctx)
      run_worker(ctx.server.root, back)

      assert {:ok, %{"phase" => "committed", "attempts" => 2}} =
               Move.read_phase(ctx.server.root)

      assert {:ok, %{role: :primary}} = Role.configured(ctx.mac.root)
      one_primary!(ctx)
    end

    for stop <- [:a, :b, :c, :d, :e] do
      test "putting the home in place, stopped after step #{stop}: the device's next start " <>
             "finishes it",
           ctx do
        back = activating_stopped_at!(ctx, unquote(stop))
        assert {:ok, %{role: :device}} = Role.configured(ctx.mac.root)

        HomeMove.restart_candidate!(back, ctx.server)
        assert_receive {:scheduled, :restart, _delay}, 10_000
        assert {:ok, %{role: :primary}} = Role.configured(ctx.mac.root)
        assert {:ok, 6} = Epoch.read(ctx.mac.root)
        refute Candidate.present?(ctx.mac.root)
        one_primary!(ctx)
      end
    end

    test "putting the home in place, stopped after its settings went in: the primary's boot " <>
           "finishes it",
         ctx do
      activating_stopped_at!(ctx, :f)
      assert {:ok, %{role: :primary}} = Role.configured(ctx.mac.root)

      assert :ok = Candidate.finish_activation(ctx.mac.root)
      refute Candidate.present?(ctx.mac.root)
      assert :ok = Return.done(ctx.mac.root, @now)
      assert {:ok, %{epoch: 6}} = Return.read(ctx.mac.root)
      one_primary!(ctx)
    end
  end

  describe "a stop on the server after a durable write never makes two primaries" do
    test "after its marker, before the commit reached the Mac: the resume commits", ctx do
      back = move_back!(ctx)
      assert {:ok, _started} = move_now(ctx, back, @passphrase)
      stage_by_hand!(ctx, back, 1)
      retire_by_hand!(ctx)
      one_primary!(ctx)

      run_worker(ctx.server.root, back)
      assert {:ok, %{"phase" => "committed"}} = Move.read_phase(ctx.server.root)
      assert {:ok, %{role: :primary}} = Role.configured(ctx.mac.root)
      one_primary!(ctx)
    end

    test "after the commit, its move_done lost: it stays retired and never undoes", ctx do
      back = move_back!(ctx)
      assert {:ok, _started} = move_now(ctx, back, @passphrase)
      stage_by_hand!(ctx, back, 1)
      retire_by_hand!(ctx)
      commit_by_hand!(ctx, back)
      :ok = Move.put_phase(ctx.server.root, "committing", %{}, @now)
      assert {:ok, %{role: :primary}} = Role.configured(ctx.mac.root)

      # The Mac's candidate is gone with its home in place: nothing answers
      # the resume, and a server kept as nothing has no key to ask the Mac
      # itself with.
      unreachable = fn _route -> fn -> {:error, :econnrefused} end end
      run_worker(ctx.server.root, back, connect: unreachable)

      assert {:ok, %{"phase" => "committing", "sentence" => sentence}} =
               Move.read_phase(ctx.server.root)

      assert sentence =~ "studio-mac has not confirmed the move"
      assert {:ok, _marker} = Moved.read(ctx.server.root)
      assert {:ok, %{role: :device}} = Role.configured(ctx.server.root)
      one_primary!(ctx)
    end
  end

  # -- the steps ----------------------------------------------------------------

  # Move back pressed on the Mac: the server opens a manual code (what the
  # Mac's forwarded `home.enroll.open` does), the Mac writes its return
  # candidate and its record of the return, and its candidate enrolls with
  # the server (`start: false` stops before that, as an engine that stopped).
  defp move_back!(ctx, opts \\ []) do
    {:ok, %{code: code}} = Enrollment.open(ctx.server.enrollment, :manual)

    {:ok, _state} =
      Candidate.prepare_return(ctx.mac.root, {:return, code},
        now: @now,
        role: :device,
        restarts_itself?: true
      )

    :ok = Return.write(ctx.mac.root, %{from: "north-box", started_at: @now, primary_epoch: 5})
    back = %{opts: Keyword.delete(opts, :start)}
    if Keyword.get(opts, :start, true), do: start_back!(ctx, back), else: back
  end

  defp start_back!(ctx, back) do
    started =
      HomeMove.start_candidate!(
        ctx.mac.root,
        ctx.server,
        [host: @mac_host, restore_opts: [host: "macos-aarch64"]] ++ back.opts
      )

    %{"candidate_id" => id} = HomeMove.await_phase(ctx.mac.root, "enrolled")
    Map.merge(back, Map.put(started, :candidate_id, id))
  end

  # Move now on the Mac: the server's own `home.move.start`, as the Mac's
  # link forwards it, the server kept as nothing.
  defp move_now(ctx, back, passphrase) do
    test = self()
    {:ok, link} = DesktopLink.read(ctx.mac.root)

    seams = [
      home: ctx.server.root,
      config: [recipient: Recipient.encode(ctx.recipient)],
      scheduler: nil,
      now: @now,
      link_status: fn -> %{primary: nil, desktops: [], enrollment: nil} end,
      host: "linux-aarch64",
      restart: fn ->
        send(test, :server_restart)
        :ok
      end,
      save_recipient: fn _recipient -> flunk("a second key was kept") end
    ]

    params = %{
      "candidate_id" => back.candidate_id,
      "recovery_passphrase" => passphrase,
      "keep_as_desktop" => false
    }

    Router.route(
      %{method: "home.move.start", protocol_version: Protocol.protocol_version(), params: params},
      engine_role: @primary,
      operation_opts: [home: seams ++ HomeMove.start_opts()],
      actor: {:desktop, link.device_id}
    )
  end

  defp run_worker(source, candidate, overrides \\ []) do
    opts =
      HomeMove.worker_opts(
        source,
        candidate,
        [snapshot_opts: [host: "linux-aarch64"]] ++ overrides
      )

    :ok = Task.await(Task.async(fn -> MoveWorker.run(opts) end), 60_000)
  end

  # The server's part up to move_ready, played over the rail as its worker
  # plays it, at `attempt`, then left: what a server that stopped there
  # leaves.
  defp stage_by_hand!(ctx, back, attempt) do
    {:ok, request} = Move.read_request(ctx.server.root)
    {path, written} = capture!(ctx, request)
    {:ok, rail} = offer!(ctx, back, request, written, attempt)
    send_file(rail, request["move_id"], path)
    :ok = Rail.send_event(rail, "move_end", %{"move_id" => request["move_id"]})
    assert_receive {:rail, ^rail, {:event, %{"t" => "move_ready", "epoch" => 6}, _bytes}}, 30_000
    :ok = Rail.close(rail)
    HomeMove.await_phase(ctx.mac.root, "staged")
    :ok = Move.put_phase(ctx.server.root, "streaming", %{"attempts" => attempt}, @now)
  end

  # The server's first attempt, accepted, then cut off mid-stream.
  defp receiving_by_hand!(ctx, back) do
    {:ok, request} = Move.read_request(ctx.server.root)
    {:ok, rail} = offer!(ctx, back, request, %{size: 1_024, sha256: String.duplicate("0", 64)}, 1)
    :ok = Rail.close(rail)
    HomeMove.await_phase(ctx.mac.root, "receiving")
    :ok = Move.put_phase(ctx.server.root, "streaming", %{"attempts" => 1}, @now)
  end

  defp offer!(ctx, back, request, stream, attempt) do
    {:ok, rail} = open_move(ctx, back, request["candidate"])

    :ok =
      Rail.send_event(rail, "move_offer", %{
        "move_id" => request["move_id"],
        "size_bytes" => stream.size,
        "sha256" => stream.sha256,
        "source_epoch" => 5,
        "recovery_recipient" => request["recovery_recipient"],
        "attempt" => attempt
      })

    assert_receive {:rail, ^rail, {:event, %{"t" => "move_accept"}, _bytes}}, 10_000
    {:ok, rail}
  end

  defp capture!(ctx, request) do
    path = Move.snapshot_path(ctx.server.root, request["move_id"])
    recipient = %{salt: :crypto.strong_rand_bytes(16), public_key: request["candidate"].recipient}
    {:ok, written} = Snapshot.write(ctx.server.root, recipient, path, host: "linux-aarch64")
    {path, written}
  end

  # What the server's worker writes after move_ready and before move_commit.
  defp retire_by_hand!(ctx) do
    :ok = Move.put_phase(ctx.server.root, "streaming", %{"ready_epoch" => 6}, @now)
    :ok = Moved.write(ctx.server.root, %{epoch: 5, moved_at: @now, to: "studio-mac"})
  end

  defp commit_by_hand!(ctx, back) do
    {:ok, request} = Move.read_request(ctx.server.root)
    {:ok, rail} = open_move(ctx, back, request["candidate"])
    :ok = Rail.send_event(rail, "move_commit", %{"move_id" => request["move_id"]})
    assert_receive {:rail, ^rail, {:event, %{"t" => "move_done", "epoch" => 6}, _bytes}}, 30_000
  end

  # The Mac staged and the server committed; the Mac's activation then
  # stopped right after `step` (`Activation.activate/3`'s own seam), as an
  # engine stopped there would leave it.
  defp activating_stopped_at!(ctx, step) do
    back = move_back!(ctx)
    assert {:ok, _started} = move_now(ctx, back, @passphrase)
    stage_by_hand!(ctx, back, 1)
    retire_by_hand!(ctx)

    # The candidate process waits, staged, for a commit; this one is played
    # by hand and stops part-way.
    {:ok, state} = Candidate.read_state(ctx.mac.root)
    :ok = Candidate.put_state(ctx.mac.root, %{state | "phase" => "activating"}, @now)
    {:ok, _entries} = Activation.record_entries(ctx.mac.root)
    stop = fn done -> if stopped?(done, step), do: throw(:stopped), else: :ok end
    assert catch_throw(Activation.activate(ctx.mac.root, :return, after_step: stop)) == :stopped
    one_primary!(ctx)
    back
  end

  defp stopped?({kind, _rel}, kind), do: true
  defp stopped?({kind, _entry, _what}, kind), do: true
  defp stopped?(step, step), do: true
  defp stopped?(_done, _step), do: false

  # -- facts ----------------------------------------------------------------------

  # At most one of the two homes would boot as the primary, and the Mac's
  # settings never say primary beside its marker (a home that would refuse
  # to boot).
  defp one_primary!(ctx) do
    primaries = for root <- [ctx.mac.root, ctx.server.root], primary?(root), do: root
    assert length(primaries) <= 1, "two primaries: #{inspect(primaries)}"
    refute primary_config?(ctx.mac.root) and Moved.read(ctx.mac.root) != :absent
  end

  defp primary?(root), do: Role.configured(root) == {:ok, %{role: :primary, primary: nil}}

  defp primary_config?(root),
    do: File.read!(Path.join(root, "config.toml")) =~ ~s(role = "primary")

  # What only this Mac owns, which no stream carries and every return keeps.
  defp own_paths!(root) do
    for {rel, contents} <- [
          {"browser/profiles/owner/Cookies", "cookies"},
          {"imessage/cursor", "rowid 4411"}
        ] do
      File.mkdir_p!(Path.dirname(Path.join(root, rel)))
      File.write!(Path.join(root, rel), contents)
    end
  end

  defp open_move(ctx, back, candidate) do
    Rail.open(
      %{node_id: candidate.node_id, relays: candidate.relays, relays_rev: "0123456789abcdef"},
      :ik_move,
      static_keypair: ctx.server.gateway,
      remote_static: candidate.noise_pk,
      connect: DesktopRail.bridge_connect(back.bridge_socket)
    )
  end

  defp send_file(rail, move_id, path) do
    path
    |> File.stream!(60 * 1_024)
    |> Stream.with_index()
    |> Enum.each(fn {bytes, index} ->
      :ok = Rail.send_event(rail, "move_chunk", %{"move_id" => move_id, "index" => index}, bytes)
    end)
  end
end
