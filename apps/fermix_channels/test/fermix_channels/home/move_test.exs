defmodule FermixChannels.Home.MoveTest do
  # M75 §7.2: a whole move between two real homes in one VM. Real: both
  # homes on disk, the primary's enrollment window and session, the
  # candidate process and its move responder behind its own bridge socket,
  # Noise IK/IKpsk2 through Mobile.Rail, the snapshot capture and restore,
  # the activation's renames. Stood in for: the iroh dial (a bridge socket),
  # the restarts (messages to the test) and the timers (never fired).
  use ExUnit.Case, async: true

  alias FermixChannels.Home.Candidate, as: CandidateProcess
  alias FermixChannels.Home.Enrollment
  alias FermixChannels.Home.MoveWorker
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Iroh.Key
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Rail
  alias FermixChannels.Test.DesktopRail
  alias FermixChannels.Test.HomeMove
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Role
  alias FermixCore.Home.Snapshot
  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @passphrase "invented-lantern-orchard"
  @destination %{"s3_bucket" => "invented-bucket-91", "s3_region" => "eu-north-1"}
  @primary_record %{role: :primary, primary: nil}

  setup do
    primary = HomeMove.primary!()
    {:ok, %{code: code}} = Enrollment.open(primary.enrollment)
    home = HomeMove.candidate_home!(code, destination: @destination)
    candidate = HomeMove.start_candidate!(home, primary)
    %{"candidate_id" => candidate_id} = HomeMove.await_phase(home, "enrolled")

    {:ok, started} =
      Move.start(primary.root, @primary_record, candidate_id, @passphrase, HomeMove.start_opts())

    TelemetryCapture.attach([[:fermix, :home, :move]], move_id: started.move_id)
    %{primary: primary, candidate: candidate, home: home, started: started}
  end

  test "the home moves: the source is retired and linked, the candidate is the primary", ctx do
    source = ctx.primary.root
    run_worker(source, ctx.candidate)

    # The source: retired, linked, its desktop key its own; the ending is
    # the relaunched desktop's to say.
    assert_received :source_restart
    assert {:ok, %{to: "north-box", epoch: 4}} = Moved.read(source)
    assert {:ok, %{"phase" => "committed", "epoch" => 5}} = Move.read_phase(source)
    assert :ok = Move.finish_at_boot(source, :device)
    assert {:ok, %{"phase" => "done", "epoch" => 5}} = Move.read_phase(source)
    refute File.exists?(Path.join(Move.dir(source), "request.json"))
    assert {:ok, %{role: :device, primary: "north-box"}} = Role.configured(source)
    assert {:ok, link} = DesktopLink.read(source)
    assert link.epoch == 5
    assert link.primary.name == "north-box"
    assert link.primary.gateway_pk == ctx.primary.gateway.public
    assert link.primary.node_id == ctx.primary.node_id
    assert {:ok, desktop_key} = DesktopLink.read_key(source)

    # The candidate: activated at epoch + 1 with the destination facts.
    assert_received {:scheduled, :restart, _delay}
    home = ctx.home
    refute Candidate.present?(home)
    assert {:ok, 5} = Epoch.read(home)
    assert {:ok, %{role: :primary}} = Role.configured(home)

    config = File.read!(Path.join(home, "config.toml"))
    assert config =~ "# the owner's note"
    assert config =~ ~s(workspace_root = "#{home}/workspace")
    assert config =~ ~s(s3_bucket = "invented-bucket-91")
    assert config =~ ~s(s3_region = "eu-north-1")
    refute config =~ "s3_credentials"
    assert config =~ ~s(recipient = "#{ctx.started.recovery_recipient}")
    assert File.read!(Path.join([home, "journals", "day.md"])) == "an invented day\n"

    # The identity bundle moved; the desktop's row travelled, its key did not.
    assert File.read!(Key.path(home)) == File.read!(Key.path(source))
    assert {:ok, devices} = DeviceStore.list(root: home)
    assert [%{kind: :desktop, device_id: id, noise_pk: pk}] = devices
    assert id == link.device_id
    assert pk == desktop_key.public
    refute File.exists?(DesktopLink.key_path(home))
    refute File.exists?(Path.join([home, "mobile", "candidates.json"]))
    assert {:ok, _snapshot_view} = File.ls(home)

    # Each side bracketed its part.
    move_id = ctx.started.move_id

    assert_received {:telemetry, [:fermix, :home, :move], _m,
                     %{phase: :started, side: :source, move_id: ^move_id}}

    assert_received {:telemetry, [:fermix, :home, :move], _m,
                     %{phase: :finished, side: :source, result: :done}}

    assert_received {:telemetry, [:fermix, :home, :move], _m,
                     %{phase: :started, side: :candidate}}

    assert_received {:telemetry, [:fermix, :home, :move], _m,
                     %{phase: :finished, side: :candidate, result: :done, epoch: 5}}
  end

  test "a refusal before move_ready aborts: nothing was retired, the primary is back", ctx do
    source = ctx.primary.root
    request_file = Path.join(Move.dir(source), "request.json")
    # The candidate re-enrolled under another key: what it accepts with is not
    # what the source encrypted to.
    request = Jason.decode!(File.read!(request_file))
    request = put_in(request["candidate"]["recipient"], Base.encode64(:binary.copy(<<7>>, 32)))
    File.write!(request_file, Jason.encode!(request))

    run_worker(source, ctx.candidate)

    assert_received :source_restart
    assert Moved.read(source) == :absent
    assert {:ok, %{role: :primary}} = Role.configured(source)
    assert {:ok, %{"phase" => "undoing", "sentence" => sentence}} = Move.read_phase(source)
    assert sentence =~ "north-box refused the move (move_mismatch"
    assert :ok = Move.finish_at_boot(source, :primary)
    assert {:ok, %{"phase" => "aborted", "sentence" => ^sentence}} = Move.read_phase(source)
    refute File.exists?(request_file)
    refute File.exists?(DesktopLink.key_path(source))
    assert {:ok, []} = DeviceStore.list(root: source)
    refute Move.pending?(source)

    # The candidate was never told to commit: it is still a candidate.
    assert Candidate.present?(ctx.home)
    assert {:ok, %{role: :candidate}} = Role.configured(ctx.home)

    assert_received {:telemetry, [:fermix, :home, :move], _m,
                     %{phase: :finished, side: :source, result: :aborted, error_class: :refused}}
  end

  test "a source that spent its attempts aborts without dialing", ctx do
    source = ctx.primary.root

    :ok =
      Move.put_phase(source, "streaming", %{"attempts" => Move.max_attempts()}, HomeMove.now())

    run_worker(source, ctx.candidate, connect: fn _route -> flunk("dialed") end)

    assert {:ok, %{role: :primary}} = Role.configured(source)
    assert {:ok, %{"phase" => "undoing"}} = Move.read_phase(source)
  end

  describe "a source that stopped after the marker" do
    setup ctx do
      ready = stage_by_hand(ctx)
      Map.put(ctx, :ready, ready)
    end

    test "resumes: the candidate answers move_ready and commits", ctx do
      source = ctx.primary.root
      # Staged and ready, the candidate is still a candidate: only
      # move_commit activates it.
      assert {:ok, %{role: :candidate}} = Role.configured(ctx.home)
      assert Candidate.present?(ctx.home)

      retire_by_hand(source, ctx)
      run_worker(source, ctx.candidate)

      assert {:ok, %{"phase" => "committed", "epoch" => 5}} = Move.read_phase(source)
      assert {:ok, %{role: :primary}} = Role.configured(ctx.home)
      refute Candidate.present?(ctx.home)
      assert {:ok, _link} = DesktopLink.read(source)
    end

    test "resumes across a candidate restart while staged", ctx do
      source = ctx.primary.root
      retire_by_hand(source, ctx)
      HomeMove.restart_candidate!(ctx.candidate, ctx.primary)
      HomeMove.await_phase(ctx.home, "staged")

      run_worker(source, ctx.candidate)

      assert {:ok, %{"phase" => "committed"}} = Move.read_phase(source)
      assert {:ok, 5} = Epoch.read(ctx.home)
    end

    # The candidate activated and is gone (its endpoint went with candidate/):
    # the moved identity answering the desktop at the ready epoch is the proof.
    test "a lost move_done is found out from the new primary itself", ctx do
      source = ctx.primary.root
      retire_by_hand(source, ctx)
      commit_by_hand(ctx)
      refute Candidate.present?(ctx.home)
      new_primary = HomeMove.new_primary!(ctx.home)
      moved_node = ctx.primary.node_id

      connect = fn
        %{node_id: ^moved_node} -> DesktopRail.bridge_connect(new_primary)
        _candidate -> DesktopRail.bridge_connect(ctx.candidate.bridge_socket)
      end

      run_worker(source, ctx.candidate, connect: connect)
      assert {:ok, %{"phase" => "committed", "epoch" => 5}} = Move.read_phase(source)
      assert_received :source_restart
    end

    test "a candidate that never answers leaves the move committed, with its sentence", ctx do
      source = ctx.primary.root
      retire_by_hand(source, ctx)

      unreachable = fn _route -> fn -> {:error, :econnrefused} end end
      run_worker(source, ctx.candidate, connect: unreachable)

      assert {:ok, %{"phase" => "committing", "sentence" => sentence}} = Move.read_phase(source)
      assert sentence =~ "north-box has not confirmed the move"
      refute_received :source_restart
      assert Move.pending?(source)
      assert {:ok, %{role: :device}} = Role.configured(source)
    end
  end

  test "the keychain's secrets ride inside the move and land in the new primary's file store",
       ctx do
    source = ctx.primary.root
    profile = keychain_reference!(source)

    :ok =
      SecretWriter.put(:anthropic_api_key, "sk-ant-invented", profile: profile, store: :keyring)

    run_worker(source, ctx.candidate)

    assert_received :source_restart
    config = File.read!(Path.join(ctx.home, "config.toml"))
    assert config =~ "[fermix_core.providers.anthropic]\napi_key = \"@file\""
    secret = Path.join(ctx.home, "secrets/ANTHROPIC_API_KEY")
    assert File.read!(secret) == "sk-ant-invented"
    assert Bitwise.band(File.stat!(secret).mode, 0o777) == 0o600

    # Never in clear on the source's disk, nor in its phase file.
    refute File.exists?(Path.join(source, "secrets/ANTHROPIC_API_KEY"))
    refute File.read!(Path.join(Move.dir(source), "phase.json")) =~ "sk-ant-invented"
  end

  test "a keychain value Fermix cannot read stops the move before anything is captured",
       ctx do
    source = ctx.primary.root
    _profile = keychain_reference!(source)

    run_worker(source, ctx.candidate, connect: fn _route -> flunk("dialed") end)

    assert {:ok, %{"phase" => "undoing", "sentence" => sentence}} = Move.read_phase(source)
    assert sentence =~ "anthropic_api_key"
    {:ok, %{"move_id" => move_id}} = Move.read_phase(source)
    refute File.exists?(Move.snapshot_path(source, move_id))
    assert {:ok, %{role: :primary}} = Role.configured(source)
    assert {:ok, %{"phase" => "enrolled"}} = Candidate.read_state(ctx.home)
  end

  test "a failed attempt sends the same capture again rather than capturing anew", ctx do
    source = ctx.primary.root
    test = self()
    {:ok, dials} = Agent.start_link(fn -> 0 end)

    connect = fn _route ->
      case Agent.get_and_update(dials, &{&1, &1 + 1}) do
        0 -> fn -> {:error, :econnrefused} end
        _later -> DesktopRail.bridge_connect(ctx.candidate.bridge_socket)
      end
    end

    counted = [
      host: "macos-aarch64",
      now: fn ->
        send(test, :captured)
        HomeMove.now()
      end
    ]

    run_worker(source, ctx.candidate, connect: connect, snapshot_opts: counted)

    assert_received :source_restart
    assert_received :captured
    refute_received :captured
    assert {:ok, %{"phase" => "committed", "attempts" => 2}} = Move.read_phase(source)
    assert {:ok, 5} = Epoch.read(ctx.home)
  end

  test "a request file that cannot be read is named, and nothing else changes", ctx do
    source = ctx.primary.root
    File.write!(Path.join(Move.dir(source), "request.json"), "{")

    run_worker(source, ctx.candidate, connect: fn _route -> flunk("dialed") end)

    refute_received :source_restart
    assert {:ok, %{"phase" => "requested", "sentence" => sentence}} = Move.read_phase(source)
    assert sentence =~ "could not be read"
    assert {:ok, %{role: :device}} = Role.configured(source)
  end

  test "a candidate refuses an offer its disk has no room for, before any byte moves", ctx do
    tight =
      HomeMove.start_candidate_process!(ctx.home, free_bytes: fn _dir -> {:ok, 1_000} end)

    facts = %{
      "move_id" => ctx.started.move_id,
      "size_bytes" => 10_000,
      "sha256" => String.duplicate("0", 64),
      "source_epoch" => 4,
      "attempt" => 1
    }

    assert {:error, "move_failed", sentence} = CandidateProcess.offer(tight, facts)
    assert sentence =~ "give its disk more space"
    assert {:ok, %{"phase" => "enrolled"}} = Candidate.read_state(ctx.home)
  end

  test "an activation that fails part-way is tried again, and resume says so until it is done",
       ctx do
    ctx = Map.put(ctx, :ready, stage_by_hand(ctx))
    retire_by_hand(ctx.primary.root, ctx)

    # The candidate's own `journals` cannot be set aside: a name in the way.
    File.mkdir_p!(Path.join(ctx.home, "journals"))
    File.write!(Path.join([ctx.home, "journals", "own.md"]), "the candidate's own\n")
    File.mkdir_p!(Path.join([Candidate.dir(ctx.home), "replaced", "journals", "blocker"]))

    {:ok, request} = Move.read_request(ctx.primary.root)
    {:ok, rail} = open_move(ctx, request["candidate"])
    :ok = Rail.send_event(rail, "move_commit", %{"move_id" => request["move_id"]})

    assert_receive {:rail, ^rail, {:event, %{"t" => "error", "code" => "move_failed"}, _b}},
                   10_000

    assert_receive {:scheduled, :activate, delay}, 10_000
    assert delay >= 1_000

    assert {:ok, %{"phase" => "activating", "sentence" => sentence}} =
             Candidate.read_state(ctx.home)

    assert sentence =~ "tries again"

    # A resume hears it is not done yet, so the source keeps resuming.
    {:ok, rail} = open_move(ctx, request["candidate"])
    :ok = Rail.send_event(rail, "move_resume", %{"move_id" => request["move_id"]})

    assert_receive {:rail, ^rail, {:event, %{"t" => "error", "code" => "move_failed"}, _b}},
                   10_000

    # The name in the way goes; the next try finishes it.
    SafeRm.rm_rf!(Path.join(Candidate.dir(ctx.home), "replaced"))
    send(Process.whereis(ctx.candidate.name), :activate)
    assert_receive {:scheduled, :restart, _delay}, 10_000
    refute Candidate.present?(ctx.home)
    assert {:ok, %{role: :primary}} = Role.configured(ctx.home)
  end

  # A late offer, on a session its source gave up on, must not discard a staged
  # home the source may already have retired for.
  test "a staged candidate refuses an offer older than the move it holds", ctx do
    _ready = stage_by_hand(ctx)
    {:ok, request} = Move.read_request(ctx.primary.root)

    for {move_id, attempt} <- [{request["move_id"], 1}, {"mv-000000000000aaaaaaaa", 9}] do
      {:ok, rail} = open_move(ctx, request["candidate"])

      :ok =
        Rail.send_event(rail, "move_offer", %{
          "move_id" => move_id,
          "size_bytes" => 1,
          "sha256" => String.duplicate("0", 64),
          "source_epoch" => 4,
          "attempt" => attempt
        })

      assert_receive {:rail, ^rail, {:event, %{"t" => "error", "code" => "move_mismatch"}, _b}},
                     10_000

      assert_receive {:rail, ^rail, {:closed, {:remote, 4003, "move move_mismatch"}}}, 10_000
    end

    assert {:ok, %{"phase" => "staged"}} = Candidate.read_state(ctx.home)
    assert File.dir?(Candidate.staging_path(ctx.home))
  end

  test "a second move_commit after the home is in place is answered as the first", ctx do
    _ready = stage_by_hand(ctx)
    commit_by_hand(ctx)
    refute Candidate.present?(ctx.home)

    assert {:ok, 5} =
             FermixChannels.Home.Candidate.commit(ctx.candidate.name, ctx.started.move_id)
  end

  test "the candidate takes a move only from the primary it enrolled with", ctx do
    {:ok, request} = Move.read_request(ctx.primary.root)
    stranger = %{ctx | primary: %{ctx.primary | gateway: Noise.generate_keypair()}}

    # Closed before its handshake completes: a stranger never gets a session.
    assert {:error, {:remote, 1002, _text}} = open_move(stranger, request["candidate"])
  end

  test "a candidate that stopped part-way through activation finishes it at its next start",
       ctx do
    _ready = stage_by_hand(ctx)
    {:ok, state} = Candidate.read_state(ctx.home)
    :ok = Candidate.put_state(ctx.home, Map.put(state, "phase", "activating"), HomeMove.now())
    staging = Candidate.staging_path(ctx.home)
    File.rename!(Path.join(staging, "journals"), Path.join(ctx.home, "journals"))

    HomeMove.restart_candidate!(ctx.candidate, ctx.primary)
    assert_receive {:scheduled, :restart, _delay}, 10_000
    refute Candidate.present?(ctx.home)
    assert {:ok, %{role: :primary}} = Role.configured(ctx.home)
  end

  # -- helpers ----------------------------------------------------------------

  # The worker runs in a task of its own, as under its supervisor; its
  # restart still reaches the test (`HomeMove.worker_opts/3`).
  defp run_worker(source, candidate, overrides \\ []) do
    opts = HomeMove.worker_opts(source, candidate, overrides)
    :ok = Task.await(Task.async(fn -> MoveWorker.run(opts) end), 60_000)
  end

  # The source's part up to move_ready, played by the test over the rail as
  # the worker plays it, then left: what a source that stopped there leaves.
  defp stage_by_hand(ctx) do
    source = ctx.primary.root
    {:ok, request} = Move.read_request(source)
    desktop_by_hand(source)
    candidate = request["candidate"]
    path = Move.snapshot_path(source, request["move_id"])
    recipient = %{salt: :crypto.strong_rand_bytes(16), public_key: candidate.recipient}
    {:ok, written} = Snapshot.write(source, recipient, path, host: "macos-aarch64")

    {:ok, rail} = open_move(ctx, candidate)

    :ok =
      Rail.send_event(rail, "move_offer", %{
        "move_id" => request["move_id"],
        "size_bytes" => written.size,
        "sha256" => written.sha256,
        "source_epoch" => 4,
        "recovery_recipient" => request["recovery_recipient"],
        "attempt" => 1
      })

    assert_receive {:rail, ^rail, {:event, %{"t" => "move_accept"}, _bytes}}, 10_000
    send_file(rail, request["move_id"], path)
    :ok = Rail.send_event(rail, "move_end", %{"move_id" => request["move_id"]})
    assert_receive {:rail, ^rail, {:event, %{"t" => "move_ready", "epoch" => 5}, _bytes}}, 30_000
    :ok = Rail.close(rail)
    HomeMove.await_phase(ctx.home, "staged")
    5
  end

  # The desktop's key and row, which the worker writes before it captures.
  defp desktop_by_hand(source) do
    keypair = Noise.generate_keypair()
    :ok = DesktopLink.write_key(source, keypair.private)

    {:ok, device} =
      DeviceStore.add(
        %{
          device_id: "0d3f8a7e-5c21-4b9e-8f60-2a4c6e8b1d37",
          name: "studio-mac",
          model: "macOS desktop",
          noise_pk: keypair.public,
          created_at: HomeMove.now(),
          kind: :desktop
        },
        root: source
      )

    :ok = Move.put_phase(source, "streaming", %{"device_id" => device.device_id}, HomeMove.now())
  end

  # What the worker writes after move_ready and before move_commit.
  defp retire_by_hand(source, ctx) do
    :ok = Move.put_phase(source, "streaming", %{"ready_epoch" => ctx.ready}, HomeMove.now())
    :ok = Moved.write(source, %{epoch: 4, moved_at: HomeMove.now(), to: "north-box"})
  end

  defp commit_by_hand(ctx) do
    {:ok, request} = Move.read_request(ctx.primary.root)
    {:ok, rail} = open_move(ctx, request["candidate"])
    :ok = Rail.send_event(rail, "move_commit", %{"move_id" => request["move_id"]})
    assert_receive {:rail, ^rail, {:event, %{"t" => "move_done", "epoch" => 5}, _bytes}}, 30_000
  end

  # A keychain reference in the source's settings, under a profile of this
  # test's own in the stub store.
  defp keychain_reference!(source) do
    profile = "move-#{System.unique_integer([:positive])}"
    config = Path.join(source, "config.toml")

    File.write!(
      config,
      File.read!(config) <>
        "\n[fermix_core]\nprofile = \"#{profile}\"\n\n" <>
        "[fermix_core.providers.anthropic]\napi_key = \"@keyring\"\n"
    )

    profile
  end

  defp open_move(ctx, candidate) do
    Rail.open(
      %{node_id: candidate.node_id, relays: candidate.relays, relays_rev: "0123456789abcdef"},
      :ik_move,
      static_keypair: ctx.primary.gateway,
      remote_static: candidate.noise_pk,
      connect: DesktopRail.bridge_connect(ctx.candidate.bridge_socket)
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
