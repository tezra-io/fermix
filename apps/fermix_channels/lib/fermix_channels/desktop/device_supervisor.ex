defmodule FermixChannels.Desktop.DeviceSupervisor do
  @moduledoc """
  What a device-role engine runs to reach its primary over the rail (M75 §2,
  §6), and to receive the home back from it (Always On's move back): only the
  device role starts it (`FermixCore.Home.Role`'s device-only list, through
  the one filter `Role.children/2`).

  `:one_for_one` over its subtrees, so none takes another down:

  - **This computer's invocations** (`Desktop.Invoke`, M97 §6.2) when
    `device/desktop.json` exists: what its server asks of it, a sibling of
    the dial subtree so a helper or relay restart ends no running one.

  - **The app's voice socket** (M97 §9.2) when `device/desktop.json` exists
    and this boot serves the realtime socket (a daemon run's boot profile,
    never `mix test`): `realtime.sock` at its usual path, its calls carried
    to the server by `Desktop.CallBridge` (`LocalVoiceSocket`'s bridged
    configuration), a sibling of the dial subtree too, so a relay restart
    closes no app connection and a call resumes on the next session. No
    session runs here; on the primary, after a move back, the same path is
    served by the primary's own sessions (`FermixCore.Realtime.Supervisor`).

  - **The dial subtree** (`children/1`'s `:dial`, `:rest_for_one`): one list,
    in start order, each with the condition under which this boot starts it
    (`dial_children/1`), and before them the dial-only `Iroh.Helper` (helper
    protocol 3, a fresh in-memory key, no bridge) they dial through, started
    only when one of them starts. While a move this home started is pending
    (`FermixCore.Home.Move.pending?/1`): the move worker
    (`FermixChannels.Home.MoveWorker`), its source. While this computer joins
    a home and has no link yet (`FermixCore.Home.Join.present?/1`, M97
    §3.1): the joiner (`FermixChannels.Desktop.Join`). When
    `device/desktop.json` exists: the desktop's services
    (`Desktop.DeviceServices`), then the desktop relay (`Desktop.Relay`). The
    users dial through the helper, so its restart takes them down with it,
    and the relay reconnects on its own backoff.
  - **The candidate subtree** (`FermixChannels.Home.CandidateSupervisor`)
    while this home receives a move back: started with the tree when
    `candidate/` exists, and on a running tree by `start_candidate/2`
    (`FermixCore.Home.Link`'s `start_return/1`), stopped by
    `stop_candidate/1` (Cancel). It is `:temporary`: one that gave up, or
    could not start (logged), stays down until the next start of the engine
    or of the return, and never restarts its way into the relay.
  """

  use Supervisor

  require Logger

  alias FermixChannels.Desktop.CallBridge
  alias FermixChannels.Desktop.Invoke
  alias FermixChannels.Desktop.Relay
  alias FermixChannels.Home.CandidateSupervisor
  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixCore.Computers.Capabilities.Browser, as: BrowserCapability
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Join
  alias FermixCore.Home.Move
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Realtime.LocalVoiceSocket
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Setup.ConfigStore

  @helper FermixChannels.Desktop.DialHelper
  @dial FermixChannels.Desktop.DialSupervisor

  @doc "The registered name of the dial-only helper the rail's users dial through."
  @spec helper() :: atom()
  def helper, do: @helper

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    root = Keyword.get_lazy(opts, :root, &ConfigStore.fermix_home/0)
    Supervisor.init(children(root), strategy: :one_for_one)
  end

  @doc """
  This boot's subtrees for the home at `root`: this computer's invocations
  (`Desktop.Invoke`), the app's bridged voice socket when `voice?` (this
  boot serves the realtime socket) and the dial subtree when the home is
  linked, the dial subtree alone while a move this home started is pending,
  the candidate subtree when the home holds a candidate; none at all when it
  needs none.
  """
  @spec children(Path.t(), boolean()) :: [Supervisor.child_spec()]
  def children(root, voice? \\ realtime_socket?())
      when is_binary(root) and root != "" and is_boolean(voice?) do
    dial =
      case dial_children(root) do
        [] -> []
        children -> [dial_spec(children)]
      end

    # Beside the dial subtree, never inside it: a helper or relay restart
    # ends no running invocation (M97 §5.2). Started first, so it takes the
    # server's requests from the session's first frame.
    linked? = File.regular?(DesktopLink.path(root))
    invoke = if linked?, do: [invoke_spec(root)], else: []
    voice = if linked? and voice?, do: [voice_spec(root)], else: []
    serving = invoke ++ voice ++ dial

    if Candidate.present?(root), do: serving ++ [candidate_spec(root)], else: serving
  end

  @doc """
  The dial subtree's children for the home at `root`: the rail's users this
  home needs, after the helper they dial through; none at all when it needs
  none.
  """
  @spec dial_children(Path.t()) :: [Supervisor.child_spec() | {module(), keyword()}]
  def dial_children(root) when is_binary(root) and root != "" do
    linked? = File.regular?(DesktopLink.path(root))

    users =
      for {start?, child} <- [
            # One line per child, in start order; the relay comes last.
            {Move.pending?(root), {FermixChannels.Home.MoveWorker, home: root, helper: @helper}},
            {Join.present?(root) and not linked?,
             {FermixChannels.Desktop.Join, home: root, helper: @helper}},
            {linked?, {FermixChannels.Desktop.DeviceServices, home: root}},
            {linked?, {Relay, root: root, helper: @helper}}
          ],
          start?,
          do: child

    if users == [], do: [], else: [{Helper, name: @helper, mode: :dial, root: root} | users]
  end

  @doc """
  Starts the candidate subtree for the candidate under `root` on the running
  device tree `supervisor`: `:ok` once it runs, as it may already;
  `{:error, :no_device_tree}` when no device tree runs here, `{:error,
  reason}` when the subtree could not start (logged).
  """
  @spec start_candidate(GenServer.server(), Path.t()) :: :ok | {:error, term()}
  def start_candidate(supervisor \\ __MODULE__, root) when is_binary(root) and root != "" do
    case GenServer.whereis(supervisor) do
      nil -> {:error, :no_device_tree}
      pid -> started(Supervisor.start_child(pid, candidate_spec(root)))
    end
  end

  defp started({:ok, pid}) when is_pid(pid), do: :ok
  defp started({:error, {:already_started, _pid}}), do: :ok
  defp started({:ok, :undefined}), do: {:error, :not_started}
  defp started({:error, _reason} = error), do: error

  @doc """
  Stops the candidate subtree on the device tree `supervisor` (Cancel). One
  that is not running, or no device tree, is nothing to stop.
  """
  @spec stop_candidate(GenServer.server()) :: :ok
  def stop_candidate(supervisor \\ __MODULE__) do
    case GenServer.whereis(supervisor) do
      nil -> :ok
      pid -> stopped(Supervisor.terminate_child(pid, CandidateSupervisor))
    end
  end

  defp stopped(:ok), do: :ok
  defp stopped({:error, :not_found}), do: :ok

  @doc false
  # The candidate subtree's start: one that cannot start is logged and
  # ignored, so the device tree it starts under always starts.
  @spec start_candidate_subtree(Path.t()) :: Supervisor.on_start() | :ignore
  def start_candidate_subtree(root) do
    case CandidateSupervisor.start_link(home: root) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.error(
          "the move back to this computer could not start receiving: #{inspect(reason)}; " <>
            "it starts again with Fermix"
        )

        :ignore
    end
  end

  defp dial_spec(children),
    do: %{
      id: :dial,
      start: {Supervisor, :start_link, [children, [strategy: :rest_for_one, name: @dial]]},
      type: :supervisor
    }

  # Every option explicit, none read from application environment on the
  # way: this computer's switches are read from its own machine file at each
  # request, and one that cannot be read refuses everything
  # (`Invoke.switches_in/1`); its sandbox and its browser are this engine's
  # own, as its live settings hold them, at each request.
  defp invoke_spec(root),
    do:
      Supervisor.child_spec(
        {Invoke,
         home: root,
         switches: Invoke.switches_in(root),
         sandbox: &SandboxConfig.current/0,
         browser: &BrowserCapability.local/0,
         capabilities: Invoke.capabilities(),
         clock: &DateTime.utc_now/0,
         relay: Relay},
        []
      )

  # The boot profile of a daemon run turns the realtime socket on
  # (`FermixCore.BootProfile.prepare/2`); `mix test` and a tree-less verb
  # serve none.
  defp realtime_socket?,
    do: Application.get_env(:fermix_core, :realtime_socket_enabled, false) == true

  # The app's `realtime.sock`, its calls bridged to the server (M97 §9.2).
  defp voice_spec(root),
    do:
      Supervisor.child_spec(
        {LocalVoiceSocket,
         socket_path: RealtimeConfig.socket_path(root),
         name: LocalVoiceSocket,
         bridge: {CallBridge, relay: Relay}},
        id: :voice_bridge
      )

  defp candidate_spec(root),
    do: %{
      id: CandidateSupervisor,
      start: {__MODULE__, :start_candidate_subtree, [root]},
      restart: :temporary,
      type: :supervisor
    }
end
