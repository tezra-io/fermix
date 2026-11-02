defmodule FermixChannels.Desktop.MoveBackIrohEndToEndTest do
  @moduledoc """
  Always On's move back on the receiving desktop, over the real rail (design
  §12.5): one device engine runs two `fermix-iroh` helpers side by side, the
  relay's dial-only one (`Desktop.DeviceSupervisor.dial_children/1`) and the
  return candidate's own listening one under `<home>/candidate`
  (`Home.CandidateSupervisor.children/1`), each with its own key, root and
  sockets; the candidate's endpoint then takes a move session (`ik_move`)
  dialed through the desktop's dial-only helper, and its candidate process
  accepts the offer.

  The children are the device tree's own, in its shape (the dial subtree
  `:rest_for_one`, the candidate subtree beside it under a `:one_for_one`
  parent), with two things given to every helper: the binary, and a relay
  list that never resolves, so nothing leaves the machine. The dial names
  the listener's UDP address, as the other iroh end-to-end tests do.

  Opt-in, because it needs a built helper of protocol 3 (`cargo build
  --release --locked` in a `fermix-iroh` checkout, or the pinned release's
  binary placed at `target/release/fermix-iroh` under a directory):

      FERMIX_IROH_DIR=../fermix-iroh mix test --only iroh_end_to_end

  Run without `FERMIX_IROH_DIR` it fails, never passes empty.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Desktop.DeviceSupervisor
  alias FermixChannels.Home.CandidateSupervisor
  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixChannels.Mobile.Iroh.Relays.Source
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Rail
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Moved
  alias FermixTestSupport.SafeRm

  @moduletag :iroh_end_to_end
  @moduletag timeout: 120_000

  @now ~U[2031-06-01 09:00:00Z]
  @timeout_ms 15_000
  # Never resolves, so nothing leaves the machine for a relay.
  @relay %{"url" => "https://relay.invalid/", "quic_port" => 7842}
  @dial_helper FermixChannels.Desktop.DialHelper
  @candidate_helper FermixChannels.Home.CandidateHelper

  setup do
    dir = System.fetch_env!("FERMIX_IROH_DIR") |> Path.expand()
    helper = Path.join(dir, "target/release/fermix-iroh")
    assert File.regular?(helper), "#{helper} is not built"
    %{helper: helper}
  end

  test "a desktop's dial-only helper and its return candidate's listening helper run side by " <>
         "side, and a move session reaches the candidate",
       ctx do
    root = root!("fx-mbi")
    server = Noise.generate_keypair()
    linked!(root)
    enrolled_return!(root, server.public)

    dial = DeviceSupervisor.dial_children(root) |> with_helper(ctx.helper)
    candidate = CandidateSupervisor.children(root) |> with_helper(ctx.helper)

    tree =
      start_supervised!(%{
        id: :device_tree,
        start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]},
        type: :supervisor
      })

    {:ok, _dial} = Supervisor.start_child(tree, subtree(:dial, dial))
    await_ready(@dial_helper, 200)

    Logger.put_module_level(Helper, :info)
    on_exit(fn -> Logger.delete_module_level(Helper) end)

    {_started, log} =
      with_log([level: :info], fn ->
        {:ok, _candidate} = Supervisor.start_child(tree, subtree(:candidate, candidate))
        await_ready(@candidate_helper, 200)
      end)

    # Two endpoints of one engine, each its own.
    dialer = Helper.status(@dial_helper)
    listener = Helper.status(@candidate_helper)
    assert %{state: :ready, endpoint_id: dialer_id} = dialer
    assert %{state: :ready, endpoint_id: listener_id} = listener
    assert dialer_id != listener_id
    [_all, port] = Regex.run(~r/bound UDP sockets: .*?(?:0\.0\.0\.0|127\.0\.0\.1):(\d+)/, log)

    # The server's move session, through the desktop's own dial-only helper.
    {:ok, noise} = Candidate.noise_keypair(root)

    route = %{
      node_id: listener_id,
      relays: [@relay],
      relays_rev: "0123456789abcdef",
      addrs: ["127.0.0.1:#{port}"]
    }

    assert {:ok, rail} =
             Rail.open(route, :ik_move,
               helper: @dial_helper,
               static_keypair: server,
               remote_static: noise.public
             )

    :ok =
      Rail.send_event(rail, "move_offer", %{
        "move_id" => "mv-20310601T090500Z-7f3a",
        "size_bytes" => 1_024,
        "sha256" => String.duplicate("0", 64),
        "source_epoch" => 5,
        "attempt" => 1
      })

    assert_receive {:rail, ^rail, {:event, %{"t" => "move_accept"}, _bytes}}, @timeout_ms
    assert {:ok, %{"phase" => "receiving", "kind" => "return"}} = Candidate.read_state(root)

    # Both still run: neither helper took the other's place.
    assert %{state: :ready, endpoint_id: ^dialer_id} = Helper.status(@dial_helper)
    assert %{state: :ready, endpoint_id: ^listener_id} = Helper.status(@candidate_helper)
  end

  # Every helper gets the built binary and a relay list that never resolves.
  defp with_helper(children, binary) do
    revisions = Source.parse!(%{"revisions" => [%{"iroh" => "1.3.0", "relays" => [@relay]}]})

    Enum.map(children, fn
      {Helper, opts} ->
        {Helper,
         opts
         |> Keyword.put(:binary_path, binary)
         |> Keyword.put(:revisions, revisions)
         |> Keyword.put(:emit, fn _status, _failures, _class -> :ok end)}

      child ->
        child
    end)
  end

  defp subtree(id, children),
    do: %{
      id: id,
      start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]},
      type: :supervisor
    }

  # A link the relay refuses by name: the desktop is linked, the relay runs
  # and dials nobody.
  defp linked!(root) do
    File.mkdir_p!(Path.dirname(DesktopLink.path(root)))
    File.write!(DesktopLink.path(root), "{}")
    :ok = Moved.write(root, %{epoch: 4, moved_at: @now, to: "north-box"})
  end

  # The return candidate Move back writes, enrolled with the server whose
  # gateway key is `server_pk`.
  defp enrolled_return!(root, server_pk) do
    {:ok, code} =
      EnrollmentCode.encode(%{
        secret: :binary.copy(<<0x5A>>, 32),
        gateway_pk: server_pk,
        node_id: String.duplicate("4f", 32),
        relays: [@relay],
        relays_rev: "0123456789abcdef",
        name: "north-box",
        expires_at: ~U[2031-06-01 09:30:00Z]
      })

    {:ok, state} =
      Candidate.prepare_return(root, {:return, code},
        now: @now,
        role: :device,
        restarts_itself?: true
      )

    :ok = Candidate.drop_code(root)

    :ok =
      Candidate.put_state(
        root,
        Map.merge(state, %{
          "phase" => "enrolled",
          "candidate_id" => "cand-4f2a",
          "enrolled_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "listen_until" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3_600))
        }),
        @now
      )
  end

  defp await_ready(helper, attempts) do
    case Helper.status(helper) do
      %{state: :ready} ->
        # sleep: lets the endpoint settle after `ready`, as the rail's own test does
        Process.sleep(200)

      %{state: state} = status when state in [:failed, :helper_missing] or attempts == 0 ->
        flunk("the helper did not become ready: #{inspect(status)}")

      _starting ->
        # sleep: polls the helper's status, which announces nothing
        Process.sleep(50)
        await_ready(helper, attempts - 1)
    end
  end

  defp root!(prefix) do
    root = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    SafeRm.mark!(root)
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    root
  end
end
