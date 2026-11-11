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

  alias Exqlite.Sqlite3
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
  alias FermixCore.Memory.Repo

  @now ~U[2031-05-04 10:00:00Z]
  @plenty 1_099_511_627_776
  # When the history notes `history!/3` writes were made (epoch ms).
  @history_ts 1_935_000_000_000

  def now, do: @now

  @doc "`Move.start/5`'s options: the clock, and readiness facts that ask nothing of the host."
  def start_opts do
    [
      now: @now,
      free_bytes: fn _dir -> {:ok, @plenty} end,
      version: "9.9.9",
      host: "macos-aarch64",
      restarts_itself: true
    ]
  end

  defmodule RailStatus do
    @moduledoc false
    # Answers `Iroh.Helper.status/1` and `await_ready/2` with a fixed status.
    use GenServer

    def start_link(status), do: GenServer.start_link(__MODULE__, status)

    @impl true
    def init(status), do: {:ok, status}

    @impl true
    def handle_call(message, _from, status) when message in [:status, :await_ready],
      do: {:reply, status, status}

    # The endpoint's direct address hints (`Iroh.Helper.hints/1`): a status
    # may name some, else none.
    def handle_call(:hints, _from, status), do: {:reply, Map.get(status, :hints, []), status}
  end

  defmodule WakingRail do
    @moduledoc false
    # A rail asleep until the test wakes it: `Iroh.Helper.status/1` says
    # dormant, `await_ready/2` tells the test it waits (`{:awaited, rail}`) and
    # is answered once the test calls `wake/2` with the status it settles at.
    use GenServer

    def start_link(test), do: GenServer.start_link(__MODULE__, test)
    def wake(rail, status), do: GenServer.cast(rail, {:wake, status})

    @impl true
    def init(test), do: {:ok, %{test: test, status: %{state: :dormant}, waiting: []}}

    @impl true
    def handle_call(:status, _from, state), do: {:reply, state.status, state}

    def handle_call(:await_ready, from, %{status: %{state: :dormant}} = state) do
      send(state.test, {:awaited, self()})
      {:noreply, %{state | waiting: [from | state.waiting]}}
    end

    def handle_call(:await_ready, _from, state), do: {:reply, state.status, state}

    @impl true
    def handle_cast(:activate, state), do: {:noreply, state}

    def handle_cast({:wake, status}, state) do
      Enum.each(state.waiting, &GenServer.reply(&1, status))
      {:noreply, %{state | status: status, waiting: []}}
    end
  end

  @doc """
  A primary's home at `:epoch` (4), its gateway identity and iroh key, a
  config naming a path inside it and a keychain profile of its own (the stub
  keychain is one table for the VM, and a move's source stores its desktop
  key there), its device store, its enrollment window
  (its timers through `:schedule`, and what it tells the Always On watch
  through `:status_changed`, when given) and its bridge. Answers the
  facts a test needs.
  """
  def primary!(opts \\ []) do
    root = DesktopRail.root!("fx-hp")
    File.mkdir_p!(root)
    :ok = Epoch.write(root, Keyword.get(opts, :epoch, 4))

    File.write!(
      Path.join(root, "config.toml"),
      "# the owner's note\n[fermix_core]\nprofile = \"#{Path.basename(root)}\"\n\n" <>
        "[fermix_core.meetings]\nrecordings = \"#{root}/workspace/meetings\"\n"
    )

    File.mkdir_p!(Path.join(root, "journals"))
    File.write!(Path.join([root, "journals", "day.md"]), "an invented day\n")
    serve!(root, opts)
  end

  @doc """
  `primary!/1`'s engine for a home that is the primary already (one a move
  made the primary, say): its identity and iroh key as the home holds them,
  its device store, its enrollment window and its bridge. Options as
  `primary!/1`'s but `:epoch`, and `:name`, the host name its codes carry
  ("studio-mac" unless said).
  """
  def serve!(root, opts \\ []) do
    {:ok, identity} = Identity.ensure(root: root)
    {:ok, %{endpoint_id: node_id}} = Key.ensure(root)
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
         host_name: fn -> {:ok, Keyword.get(opts, :name, "studio-mac")} end
       ] ++ Keyword.take(opts, [:schedule, :status_changed])},
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
        now: @now
      )

    home
  end

  @doc """
  Starts the candidate process for `home`, reaching `primary` for its
  enrollment, and its own bridge serving the move. Timers and the restart
  come to the test as `{:scheduled, message, delay}` and `:candidate_restart`.
  Options: `:now`, `:free_bytes`, and the candidate's own `:host` facts,
  `:restore_opts` (a Linux server's unless said), `:hints` (its endpoint's
  address hints, a 0-arity function; none unless said), `:connect` (its
  dial, the primary's bridge unless said) and `:helper` (what answers its
  rail's status; none unless said).
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
       rail_opts: [
         connect: Keyword.get(opts, :connect, DesktopRail.bridge_connect(primary.bridge_socket))
       ],
       helper: Keyword.get(opts, :helper),
       hints: Keyword.get(opts, :hints, fn -> [] end),
       restore_opts:
         Keyword.get(opts, :restore_opts, host: "linux-aarch64", keyring_usable?: fn -> false end),
       free_bytes: Keyword.get(opts, :free_bytes, fn _dir -> {:ok, @plenty} end),
       host:
         Keyword.get(opts, :host, %{
           "name" => "north-box",
           "os" => "linux",
           "arch" => "aarch64",
           "version" => "9.9.9"
         })},
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

  @doc """
  Writes the computer-history notes of the home at `root` (its `memory.db`)
  through the engine's own store (M97 §8.4): a note of the machine `own` (the
  machine whose notes a move carries: `""` on a home that recorded itself), a
  note of each computer in `others`, a thread (the home's), a read and a purge
  of `own`'s notes, and each machine's row with a delivered mark of 2; with
  `off: true`, the owner's request from chat, still pending, that `own` (a
  computer) switch its history off. The store is written in a folder of its
  own and checkpointed, and only its database file is put in the home: the
  store's connection closes after it stops, so its `-wal` and `-shm` would go
  while a capture walks the home.
  """
  def history!(root, own, others, opts \\ []) do
    repo = :"home_move_history_#{System.unique_integer([:positive])}"
    seed = Path.join(DesktopRail.root!("fx-hist"), "memory.db")
    File.mkdir_p!(Path.dirname(seed))
    start_supervised!({Repo, name: repo, enabled: true, database_path: seed}, id: repo)

    for {computer, n} <- Enum.with_index([own | others], 1) do
      note = history_note(n, "an invented sitting #{n}")
      sitting = "#{n}-#{n + 3}:#{note.provenance_from_ts}"

      {:ok, {:written, _id}} =
        Repo.computer_history_home(:insert_note, [note, computer, sitting, @history_ts],
          server: repo
        )

      :ok = Repo.computer_history_home(:record_delivered, [computer, 2], server: repo)
    end

    thread = Map.merge(history_note(9, "an invented thread"), %{kind: "thread", subject: "Trip"})
    {:ok, _id} = Repo.computer_history_insert_memory(thread, server: repo)
    read = %{ts: @history_ts, sink: "recall_activity", result_count: 1, computer_id: own}
    :ok = Repo.computer_history_record_access(read, server: repo)
    purge = [@history_ts + 100, @history_ts + 200, @history_ts + 300, own]
    {:ok, _purged} = Repo.computer_history_home(:purge_notes, purge, server: repo)

    if Keyword.get(opts, :off, false),
      do: :ok = Repo.computer_history_home(:request_off, [own, @history_ts], server: repo)

    :ok = ExUnit.Callbacks.stop_supervised!(repo)
    :ok = checkpointed(seed)
    File.cp!(seed, Path.join(root, "memory.db"))
  end

  # Every committed row in the database file itself, on a connection of its own.
  defp checkpointed(db) do
    {:ok, conn} = Sqlite3.open(db)

    try do
      {:ok, stmt} = Sqlite3.prepare(conn, "PRAGMA wal_checkpoint(TRUNCATE)")
      {:row, [0, _log, _done]} = Sqlite3.step(conn, stmt)
      Sqlite3.release(conn, stmt)
    after
      Sqlite3.close(conn)
    end
  end

  @doc """
  Which machine each history row of the home at `root` names: its notes as
  `{computer_id, kind}`, the machines of its reads and its purges, and each
  machine's row as `{computer_id, delivered_mark}`, and the machines an off
  request is pending for.
  """
  def history(root) do
    rows = fn sql -> history_rows(Path.join(root, "memory.db"), sql) end

    %{
      notes:
        rows.("SELECT computer_id, kind FROM computer_history_memories ORDER BY id")
        |> Enum.map(&List.to_tuple/1),
      reads: rows.("SELECT computer_id FROM computer_history_access") |> List.flatten(),
      intervals: rows.("SELECT computer_id FROM computer_history_purges") |> List.flatten(),
      rows:
        rows.(
          "SELECT computer_id, delivered_mark FROM computer_history_computers " <>
            "ORDER BY computer_id"
        )
        |> Enum.map(&List.to_tuple/1),
      offs:
        rows.(
          "SELECT computer_id FROM computer_history_computers WHERE off_requested_at IS NOT NULL"
        )
        |> List.flatten()
    }
  end

  defp history_note(n, summary) do
    from = @history_ts - 10_000 * n

    %{
      created_at: @history_ts,
      provenance_from_ts: from,
      provenance_to_ts: from + 5_000,
      summary: summary,
      model: "invented-model",
      event_count: 3
    }
  end

  defp history_rows(db, sql) do
    {:ok, conn} = Sqlite3.open(db, mode: :readonly)

    try do
      {:ok, stmt} = Sqlite3.prepare(conn, sql)
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      :ok = Sqlite3.release(conn, stmt)
      rows
    after
      Sqlite3.close(conn)
    end
  end
end
