defmodule FermixChannels.Home.MoveEndToEndTest do
  @moduledoc """
  M75 §7 with the real helper: a candidate enrolls with a primary, and the
  primary's home moves to it, each session carried by real `fermix-iroh`
  processes (helper protocol 4).

  The candidate is an Always On server: its endpoint binds the fixed port it
  is given, it enrolls with its address hint, and the move worker dials it
  the way a desktop's engine does, through its dial-only helper at the
  address the candidate's record holds, never a test's own dial. The hint is
  the loopback one, given through the candidate's own seam: a tailnet
  address cannot reach a listener on this machine, and the interfaces stay
  the test's.

  The primary listens with its home's key behind its bridge, which serves the
  enrollment prelude (`Home.EnrollmentResponder` through `Mobile.Session`). The
  candidate listens with its own key, rooted at `<home>/candidate`, behind a
  bridge that serves the move prelude alone (`Home.MoveResponder`), and the
  candidate process (`Home.Candidate`) dials the primary through that same
  helper. The move worker (`Home.MoveWorker`) dials the candidate through a
  dial-only helper, as a device-role engine does. Every dial is direct, at
  the listener's UDP address (no relay can be trusted locally by the released
  helper); a route's relays never resolve, so the move runs with its relay
  unreachable and the hint alone.

  Opt-in, because it needs the helper built from a `fermix-iroh` checkout
  (`cargo build --release --locked`):

      FERMIX_IROH_DIR=../fermix-iroh mix test --only iroh_end_to_end

  Run without `FERMIX_IROH_DIR` it fails, never passes empty.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Home.Candidate, as: CandidateProcess
  alias FermixChannels.Home.Enrollment
  alias FermixChannels.Home.EnrollmentResponder
  alias FermixChannels.Home.MoveResponder
  alias FermixChannels.Home.MoveWorker
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Iroh.Bridge
  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixChannels.Mobile.Iroh.Key
  alias FermixChannels.Mobile.Iroh.Relays.Source
  alias FermixChannels.Test.HomeMove
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidates
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Role
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixTestSupport.SafeRm

  @moduletag :iroh_end_to_end
  @moduletag timeout: 180_000

  @relay %{"url" => "https://relay.invalid/", "quic_port" => 7842}

  setup do
    dir = System.fetch_env!("FERMIX_IROH_DIR") |> Path.expand()
    binary = Path.join(dir, "target/release/fermix-iroh")
    assert File.regular?(binary), "#{binary} is not built"

    revisions = Source.parse!(%{"revisions" => [%{"iroh" => "1.3.0", "relays" => [@relay]}]})
    Logger.put_module_level(Helper, :info)
    on_exit(fn -> Logger.delete_module_level(Helper) end)
    %{binary: binary, revisions: revisions}
  end

  test "a candidate enrolls and the home moves to it, over real helpers", ctx do
    primary = start_primary(ctx)
    {:ok, %{code: code}} = Enrollment.open(primary.enrollment)

    candidate = start_candidate(ctx, code, primary)
    %{"candidate_id" => candidate_id} = HomeMove.await_phase(candidate.home, "enrolled")
    refute File.exists?(Candidate.path(candidate.home, "code"))

    {:ok, _started} =
      Move.start(
        primary.root,
        %{role: :primary, primary: nil},
        candidate_id,
        Recipient.public(Recipient.generate()),
        HomeMove.start_opts()
      )

    dialer = start_helper(ctx, :dial, short_root("fx-e2e-s"), [])

    # The server enrolled with its hint, at the port it was told to bind.
    assert candidate.port == candidate.bind_port
    hint = "127.0.0.1:#{candidate.bind_port}"
    assert {:ok, [%{addrs: [^hint]}]} = Candidates.list(primary.root, HomeMove.now())

    opts = HomeMove.worker_opts(primary.root, candidate, connect: nil, helper: dialer)
    :ok = Task.await(Task.async(fn -> MoveWorker.run(opts) end), 120_000)

    # The worker records `committed`; the ending is the relaunched desktop's to
    # say, at its boot.
    assert {:ok, %{"phase" => "committed", "epoch" => 5}} = Move.read_phase(primary.root)
    assert :ok = Move.finish_at_boot(primary.root, :device)
    assert {:ok, %{"phase" => "done", "epoch" => 5}} = Move.read_phase(primary.root)
    assert {:ok, %{to: "north-box"}} = Moved.read(primary.root)
    # The desktop the source became dials its server there too.
    assert {:ok, %{primary: %{addrs: [^hint]}}} = DesktopLink.read(primary.root)
    assert {:ok, %{role: :primary}} = Role.configured(candidate.home)
    assert {:ok, 5} = Epoch.read(candidate.home)
    assert File.read!(Key.path(candidate.home)) == File.read!(Key.path(primary.root))
    refute Candidate.present?(candidate.home)
  end

  # -- the primary ------------------------------------------------------------

  defp start_primary(ctx) do
    root = short_root("fx-e2e-p")
    :ok = Epoch.write(root, 4)
    {:ok, _identity} = Identity.ensure(root: root)
    # A keychain profile of its own: the move stores this computer's key there.
    profile = ~s([fermix_core]\nprofile = "#{Path.basename(root)}"\n\n)
    File.write!(Path.join(root, "config.toml"), profile <> "[sandbox]\nmode = \"strict\"\n")
    suffix = System.unique_integer([:positive])
    store = :"e2e_move_store_#{suffix}"
    start_supervised!({DeviceStore, root: root, name: store}, id: :primary_store)
    enrollment = :"e2e_move_enrollment_#{suffix}"

    session_opts = [
      identity_root: root,
      responders: %{ikpsk2_enroll: {EnrollmentResponder, [enrollment: enrollment]}}
    ]

    {helper, port} = start_listener(ctx, root, session_opts, :primary)

    start_supervised!(
      {Enrollment,
       name: enrollment,
       home: root,
       helper: helper,
       device_store: store,
       clock: &HomeMove.now/0,
       host_name: fn -> {:ok, "studio-mac"} end},
      id: :enrollment
    )

    %{root: root, enrollment: enrollment, helper: helper, port: port}
  end

  # -- the candidate ----------------------------------------------------------

  defp start_candidate(ctx, code, primary) do
    home = Path.join(short_root("fx-e2e-c"), "h")
    {:ok, _code} = Candidate.enroll(home, code, now: HomeMove.now())
    name = :"e2e_move_candidate_#{System.unique_integer([:positive])}"

    session_opts = [phone_modes: [], responders: %{ik_move: {MoveResponder, [candidate: name]}}]
    bind_port = free_udp_port()

    {helper, port} =
      start_listener(ctx, Candidate.dir(home), session_opts, :candidate,
        bind_port: bind_port,
        interfaces: fn -> {:ok, []} end
      )

    %{endpoint_id: node_id} = Helper.status(helper)
    %{endpoint_id: primary_node} = Helper.status(primary.helper)
    test = self()

    start_supervised!(
      {CandidateProcess,
       name: name,
       home: home,
       helper: helper,
       clock: &HomeMove.now/0,
       schedule: fn message, delay ->
         send(test, {:scheduled, message, delay})
         make_ref()
       end,
       restart: fn -> :ok end,
       rail_opts: [connect: fn -> dial(helper, primary_node, primary.port) end],
       hints: fn -> ["127.0.0.1:#{bind_port}"] end,
       restore_opts: [host: "linux-aarch64", keyring_usable?: fn -> false end],
       host: %{"name" => "north-box", "os" => "linux", "arch" => "aarch64", "version" => "9.9.9"}},
      id: :candidate
    )

    %{home: home, node_id: node_id, port: port, bind_port: bind_port}
  end

  # -- helpers ----------------------------------------------------------------

  # A listening helper rooted at `root` (its key at `root/mobile/iroh_key`)
  # behind a bridge with `session_opts`; answers it and its UDP port.
  defp start_listener(ctx, root, session_opts, id, helper_opts \\ []) do
    socket = Bridge.socket_path(root)

    connections =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: {id, :connections})

    bridge =
      start_supervised!(
        {Bridge,
         name: nil,
         socket_path: socket,
         connection_supervisor: connections,
         connection_opts: [session_opts: session_opts]},
        id: {id, :bridge}
      )

    {helper, log} =
      with_log([level: :info], fn ->
        start_helper(
          ctx,
          :listen,
          root,
          [bridge_socket: socket, bridge: bridge, id: {id, :helper}] ++ helper_opts
        )
      end)

    [_all, port] = Regex.run(~r/bound UDP sockets: .*?(?:0\.0\.0\.0|127\.0\.0\.1):(\d+)/, log)
    {helper, String.to_integer(port)}
  end

  defp start_helper(ctx, mode, root, opts) do
    helper =
      start_supervised!(
        {Helper,
         [
           name: nil,
           mode: mode,
           root: root,
           binary_path: ctx.binary,
           revisions: ctx.revisions,
           identity_exists?: fn -> true end,
           list_devices: fn _store -> {:ok, []} end,
           emit: fn _status, _failures, _class -> :ok end
         ] ++ Keyword.drop(opts, [:id])},
        id: Keyword.get(opts, :id, {mode, root})
      )

    await_ready(helper, 200)
    helper
  end

  defp dial(helper, node_id, port) do
    target = %{node_id: node_id, relays: [@relay], addrs: ["127.0.0.1:#{port}"]}

    case Helper.dial(helper, target) do
      {:ok, socket, _path} -> {:ok, socket}
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_ready(helper, attempts) do
    case Helper.status(helper) do
      %{state: :ready} ->
        # sleep: the helper's endpoint binds its sockets just after ready
        Process.sleep(200)

      %{state: state} = status when state in [:failed, :helper_missing] or attempts == 0 ->
        flunk("the helper did not become ready: #{inspect(status)}")

      _starting ->
        # sleep: polls the helper's status, which announces readiness to nobody
        Process.sleep(50)
        await_ready(helper, attempts - 1)
    end
  end

  # A UDP port nothing holds now, for the server's fixed one (never 4033,
  # which a Fermix running on this machine may hold).
  defp free_udp_port do
    {:ok, socket} = :gen_udp.open(0, ip: {0, 0, 0, 0})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_udp.close(socket)
    port
  end

  defp short_root(prefix) do
    root = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    SafeRm.mark!(root)
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    root
  end
end
