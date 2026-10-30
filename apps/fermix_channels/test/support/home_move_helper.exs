defmodule FermixChannels.Test.HomeMove do
  @moduledoc """
  A primary, a candidate and a move between them in one test VM (M75 §7).

  What runs is the engine's own: the primary's enrollment window
  (`Home.Enrollment`) behind `Mobile.Session` with real Noise on the real
  iroh bridge socket (`Iroh.Bridge`), the candidate process
  (`Home.Candidate`) with its own bridge serving the move
  (`Home.MoveResponder`), and the source's move worker (`Home.MoveWorker`).
  Each home is a real home on disk. Stood in for: the iroh dial (a rail
  connects to a bridge socket and writes the helper's preamble), the primary's
  rail status (an endpoint id, ready), the restart (a message to the test) and
  timers (a message to the test, never fired by themselves).
  """

  import ExUnit.Callbacks, only: [start_supervised!: 2]

  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Desktop.Supervisor, as: DesktopSupervisor
  alias FermixChannels.Home.Candidate, as: CandidateProcess
  alias FermixChannels.Home.Enrollment
  alias FermixChannels.Home.EnrollmentResponder
  alias FermixChannels.Home.MoveResponder
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Iroh.Bridge
  alias FermixChannels.Mobile.Iroh.Key
  alias FermixChannels.Test.DesktopRail
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Epoch

  @now ~U[2031-05-04 10:00:00Z]
  @plenty 1_099_511_627_776

  def now, do: @now

  @doc "`Move.start/5`'s options: the clock, and readiness facts that ask nothing of the host."
  def start_opts do
    [
      now: @now,
      free_bytes: fn _dir -> {:ok, @plenty} end,
      version: "0.16.0",
      host: "macos-aarch64"
    ]
  end

  defmodule RailStatus do
    @moduledoc false
    # Answers `Iroh.Helper.status/1` with a fixed status.
    use GenServer

    def start_link(status), do: GenServer.start_link(__MODULE__, status)

    @impl true
    def init(status), do: {:ok, status}

    @impl true
    def handle_call(:status, _from, status), do: {:reply, status, status}
  end

  @doc """
  A primary's home at `:epoch` (4), its gateway identity and iroh key, a
  config naming a path inside it, its device store, its enrollment window
  (its timers through `:schedule` when given) and its bridge. Answers the
  facts a test needs.
  """
  def primary!(opts \\ []) do
    root = DesktopRail.root!("fx-hp")
    File.mkdir_p!(root)
    :ok = Epoch.write(root, Keyword.get(opts, :epoch, 4))
    {:ok, identity} = Identity.ensure(root: root)
    {:ok, %{endpoint_id: node_id}} = Key.ensure(root)

    File.write!(
      Path.join(root, "config.toml"),
      "# the owner's note\n[sandbox]\nworkspace_root = \"#{root}/workspace\"\n"
    )

    File.mkdir_p!(Path.join(root, "journals"))
    File.write!(Path.join([root, "journals", "day.md"]), "an invented day\n")

    suffix = System.unique_integer([:positive])
    clock = start_supervised!({Agent, fn -> @now end}, id: {:clock, suffix})
    store = :"home_move_store_#{suffix}"
    start_supervised!({DeviceStore, root: root, name: store}, id: {:store, suffix})

    rail =
      start_supervised!({RailStatus, %{state: :ready, endpoint_id: node_id}},
        id: {:rail, suffix}
      )

    enrollment = :"home_move_enrollment_#{suffix}"

    start_supervised!(
      {Enrollment,
       [
         name: enrollment,
         home: root,
         helper: rail,
         device_store: store,
         clock: fn -> Agent.get(clock, & &1) end,
         host_name: fn -> {:ok, "studio-mac"} end
       ] ++ Keyword.take(opts, [:schedule])},
      id: {:enrollment, suffix}
    )

    bridge_socket = bridge!(root, suffix, enrollment_session_opts(root, enrollment))

    %{
      root: root,
      node_id: node_id,
      gateway: %{private: identity.gateway_private_key, public: identity.gateway_public_key},
      enrollment: enrollment,
      clock: clock,
      store: store,
      bridge_socket: bridge_socket
    }
  end

  defp enrollment_session_opts(root, enrollment) do
    [
      identity_root: root,
      responders: %{ikpsk2_enroll: {EnrollmentResponder, [enrollment: enrollment]}}
    ]
  end

  defp bridge!(root, suffix, session_opts) do
    connections =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: {:connections, suffix})

    socket = Path.join(root, "b.sock")

    start_supervised!(
      {Bridge,
       name: nil,
       socket_path: socket,
       connection_supervisor: connections,
       connection_opts: [session_opts: session_opts]},
      id: {:bridge, suffix}
    )

    socket
  end

  @doc """
  The engine a candidate became, serving the moved identity from `home`: its
  real device store (where the moved desktop row is) behind a primary's
  session on a bridge of its own, as `FermixChannels.Test.DesktopRail` stands
  one up. Answers the bridge socket.
  """
  def new_primary!(home) do
    suffix = System.unique_integer([:positive])
    store = :"home_move_new_store_#{suffix}"
    registry = :"home_move_new_registry_#{suffix}"
    peers = :"home_move_new_peers_#{suffix}"
    peer_supervisor = :"home_move_new_peer_sup_#{suffix}"

    start_supervised!({DeviceStore, root: home, name: store}, id: {:new_store, suffix})

    start_supervised!(
      {DeviceRegistry,
       name: registry,
       device_store: store,
       revoke_requests: fn _id -> :ok end,
       relays_changed: fn -> :ok end},
      id: {:new_registry, suffix}
    )

    start_supervised!(
      {DesktopSupervisor,
       name: nil,
       registry: peers,
       peer_supervisor: peer_supervisor,
       tunnel_supervisor: :"home_move_new_tunnels_#{suffix}"},
      id: {:new_desktop, suffix}
    )

    bridge!(home, suffix,
      identity_root: home,
      device_store: store,
      device_registry: registry,
      iroh_helper: :home_move_no_helper,
      profile_name: "Orbit",
      history_head: fn "main" -> {:ok, 0} end,
      read_frontier: fn "main" -> {:ok, 0} end,
      pending_approvals: fn _profile -> [] end,
      pairing_pending: fn -> :none end,
      discover: fn -> {:ok, []} end,
      desktop_peers: peers,
      desktop_peer_supervisor: peer_supervisor,
      start_desktop_peer: &Peer.start(peer_supervisor, Keyword.put(&1, :families, %{}))
    )
  end

  @doc "Moves the primary's clock on by `seconds`."
  def advance!(primary, seconds),
    do: Agent.update(primary.clock, &DateTime.add(&1, seconds, :second))

  @doc "A fresh home made a candidate with `code`, the destination facts given."
  def candidate_home!(code, opts \\ []) do
    home = Path.join(DesktopRail.root!("fx-hc"), "h")

    {:ok, _code} =
      Candidate.enroll(home, code,
        destination: Keyword.get(opts, :destination),
        instance: Keyword.get(opts, :instance),
        now: @now
      )

    home
  end

  @doc """
  Starts the candidate process for `home`, reaching `primary` for its
  enrollment, and its own bridge serving the move. Timers and the restart
  come to the test as `{:scheduled, message, delay}` and `:candidate_restart`.
  """
  def start_candidate!(home, primary, opts \\ []) do
    test = self()
    suffix = System.unique_integer([:positive])
    name = :"home_move_candidate_#{suffix}"

    start_supervised!(
      {CandidateProcess,
       name: name,
       home: home,
       clock: fn -> Keyword.get(opts, :now, @now) end,
       schedule: fn message, delay ->
         send(test, {:scheduled, message, delay})
         make_ref()
       end,
       restart: fn ->
         send(test, :candidate_restart)
         :ok
       end,
       rail_opts: [connect: DesktopRail.bridge_connect(primary.bridge_socket)],
       restore_opts: [host: "linux-aarch64", keyring_usable?: fn -> false end],
       free_bytes: Keyword.get(opts, :free_bytes, fn _dir -> {:ok, @plenty} end),
       host: %{"name" => "north-box", "os" => "linux", "arch" => "aarch64", "version" => "9.9.9"}},
      id: {:candidate, suffix}
    )

    session_opts = [phone_modes: [], responders: %{ik_move: {MoveResponder, [candidate: name]}}]
    socket = bridge!(Candidate.dir(home), suffix, session_opts)
    %{name: name, home: home, bridge_socket: socket}
  end

  @doc """
  A second candidate process over `home` with no bridge of its own, for a test
  that calls it directly (`:free_bytes`). Answers its name.
  """
  def start_candidate_process!(home, opts) do
    suffix = System.unique_integer([:positive])
    name = :"home_move_candidate_process_#{suffix}"

    start_supervised!(
      {CandidateProcess,
       name: name,
       home: home,
       clock: fn -> @now end,
       schedule: fn _message, _delay -> make_ref() end,
       restart: fn -> :ok end,
       free_bytes: Keyword.fetch!(opts, :free_bytes),
       host: %{"name" => "north-box", "os" => "linux", "arch" => "aarch64", "version" => "9.9.9"}},
      id: {:candidate_process, suffix}
    )

    name
  end

  @doc "Stops and starts the candidate process again, as an engine restart would."
  def restart_candidate!(candidate, primary) do
    :ok = GenServer.stop(candidate.name)
    # start_supervised! restarts nothing on its own: the child was stopped
    # normally and its spec is :permanent under the test supervisor, which
    # starts it again; wait for the new process.
    await(fn -> Process.whereis(candidate.name) end)
    _ = primary
    candidate
  end

  @doc "Waits until the candidate's recorded phase is `phase` (10 s)."
  def await_phase(home, phase) do
    await(fn ->
      case Candidate.read_state(home) do
        {:ok, %{"phase" => ^phase} = state} -> state
        _other -> nil
      end
    end)
  end

  @doc "Polls `fun` until it answers something other than nil, for 10 s."
  def await(fun, attempts \\ 1_000) do
    case fun.() do
      nil when attempts == 0 ->
        raise "the awaited state never came"

      nil ->
        # sleep: polls state a process writes and announces to nobody
        Process.sleep(10)
        await(fun, attempts - 1)

      value ->
        value
    end
  end

  @doc "The move worker's options for the source `root` reaching `candidate`."
  def worker_opts(root, candidate, overrides \\ []) do
    test = self()

    Keyword.merge(
      [
        home: root,
        connect: fn _route -> DesktopRail.bridge_connect(candidate.bridge_socket) end,
        clock: fn -> @now end,
        sleep: fn _ms -> :ok end,
        restart: fn ->
          send(test, :source_restart)
          :ok
        end,
        snapshot_opts: [host: "macos-aarch64"],
        resume_for_ms: 0
      ],
      overrides
    )
  end
end
