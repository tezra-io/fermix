defmodule FermixCore.Management.HomeMoveKeepTest do
  # M75 decision 4: replacing the server works through the same move.
  # `home.move.start` takes `keep_as_desktop`, true unless said: false when the
  # source is a server being replaced, which then becomes no desktop of the new
  # primary. The choice travels in the request the move worker reads. The
  # start is the server answering a desktop's forward, the one caller it is
  # served to.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Candidates
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]
  @primary %{role: :primary, primary: nil}
  @desktop {:desktop, "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"}
  @passphrase "invented-lantern-orchard"

  setup do
    home = SafeRm.make_tmp_dir!("home_move_keep")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    :ok = Epoch.write(home, 4)
    test = self()

    seams = [
      home: home,
      config: [],
      scheduler: nil,
      now: @now,
      link_status: fn -> %{primary: nil, desktops: [], enrollment: nil} end,
      free_bytes: fn _dir -> {:ok, 1_099_511_627_776} end,
      version: "0.16.0",
      host: "macos-aarch64",
      restarts_itself: true,
      restart: fn ->
        send(test, :restarted)
        :ok
      end,
      save_recipient: fn _recipient -> {:ok, %{}} end
    ]

    {:ok, record} = Candidates.add(home, candidate_attrs(), @now)
    %{home: home, seams: seams, candidate_id: record.candidate_id}
  end

  test "a source is kept as a desktop unless the request says not", ctx do
    params = %{"candidate_id" => ctx.candidate_id, "recovery_passphrase" => @passphrase}

    assert {:ok, %{"keep_as_desktop" => true, "sentence" => sentence}} =
             route("home.move.start", params, ctx.seams)

    assert sentence =~ "restarts in the device role"
    assert {:ok, request} = Move.read_request(ctx.home)
    assert Move.keep_as_desktop?(request)
  end

  test "a server being replaced is moved and kept as nothing", ctx do
    params = %{
      "candidate_id" => ctx.candidate_id,
      "recovery_passphrase" => @passphrase,
      "keep_as_desktop" => false
    }

    assert {:ok, %{"keep_as_desktop" => false, "sentence" => sentence}} =
             route("home.move.start", params, ctx.seams)

    assert_received :restarted
    assert sentence =~ "then serves nothing here"
    assert {:ok, %{"keep_as_desktop" => false} = request} = Move.read_request(ctx.home)
    refute Move.keep_as_desktop?(request)

    # Once it moved, it says it no longer runs the home, not that it is a desktop.
    :ok = Move.put_phase(ctx.home, "done", %{}, @now)
    assert %{"sentence" => done} = Move.view(ctx.home)
    assert done == "This home moved to north-box; this computer no longer runs it."
  end

  test "keep_as_desktop is a boolean, or the request is refused by its field", ctx do
    params = %{
      "candidate_id" => ctx.candidate_id,
      "recovery_passphrase" => @passphrase,
      "keep_as_desktop" => "no"
    }

    assert {:error, :invalid_params, %{"field" => "keep_as_desktop"}} =
             route("home.move.start", params, ctx.seams)

    # On `daemon.sock` even a well-formed start is refused by name.
    assert {:error, :unavailable,
            %{
              "capability" => "home",
              "method" => "home.move.start",
              "sentence" => <<_, _::binary>>
            }} = route("home.move.start", %{params | "keep_as_desktop" => false}, ctx.seams, nil)

    refute_received :restarted
    refute Move.pending?(ctx.home)
  end

  # From a desktop's forward unless `actor` says another caller (nil:
  # `daemon.sock`).
  defp route(method, params, seams, actor \\ @desktop) do
    Router.route(
      %{method: method, protocol_version: Protocol.protocol_version(), params: params},
      engine_role: @primary,
      operation_opts: [home: seams],
      actor: actor
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
      snapshots: nil
    }
  end
end
