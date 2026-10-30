defmodule FermixChannels.Home.CandidateSupervisor do
  @moduledoc """
  What a `candidate`-role engine runs (M75 §2, B4), and the only channels
  child it runs (`FermixCore.Home.Role.candidate_keeps/0`): its own iroh
  endpoint and the candidate process, all under `<home>/candidate/`.

  `:rest_for_one`, in start order:

    1. the bridge's connection supervisor;
    2. the bridge socket (`Iroh.Bridge`, `<home>/candidate/mobile/bridge.sock`),
       whose connections serve the move's prelude alone
       (`FermixChannels.Home.MoveResponder`; no phone or pairing mode);
    3. the iroh helper in listen mode with the candidate's own key and its own
       root (`<home>/candidate`: key at `mobile/iroh_key`, dial sockets beside
       it), on the launch relays, since no device has acknowledged any other;
       it also dials the primary for the enrollment;
    4. the candidate process (`FermixChannels.Home.Candidate`).
  """

  use Supervisor

  alias FermixChannels.Home.Candidate
  alias FermixChannels.Home.MoveResponder
  alias FermixChannels.Mobile.Iroh.Bridge
  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixCore.Home.Candidate, as: Files
  alias FermixCore.Setup.ConfigStore

  @connections FermixChannels.Home.CandidateConnections
  @bridge FermixChannels.Home.CandidateBridge
  @helper FermixChannels.Home.CandidateHelper

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    home = Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
    Supervisor.init(children(home), strategy: :rest_for_one)
  end

  @doc "The candidate's children for the home at `home`, in start order."
  @spec children(Path.t()) :: [Supervisor.child_spec() | {module(), keyword()}]
  def children(home) when is_binary(home) and home != "" do
    root = Files.dir(home)
    socket = Bridge.socket_path(root)

    [
      {DynamicSupervisor, name: @connections, strategy: :one_for_one},
      {Bridge,
       name: @bridge,
       socket_path: socket,
       connection_supervisor: @connections,
       connection_opts: [
         session_opts: [
           phone_modes: [],
           responders: %{ik_move: {MoveResponder, [candidate: Candidate]}}
         ]
       ]},
      {Helper,
       name: @helper,
       mode: :listen,
       root: root,
       bridge_socket: socket,
       bridge: @bridge,
       identity_exists?: fn -> true end,
       list_devices: fn _store -> {:ok, []} end},
      {Candidate, home: home, helper: @helper}
    ]
  end
end
