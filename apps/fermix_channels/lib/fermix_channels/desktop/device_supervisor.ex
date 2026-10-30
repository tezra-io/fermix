defmodule FermixChannels.Desktop.DeviceSupervisor do
  @moduledoc """
  What a device-role engine runs to reach its primary over the rail (M75 §2,
  §6): only the device role starts it (`FermixCore.Home.Role`'s device-only
  list, through the one filter `Role.children/2`).

  Its children are one list, in start order, each with the condition under
  which this boot starts it (`children/1`), and before them the dial-only
  `Iroh.Helper` (helper protocol 3, a fresh in-memory key, no bridge) they
  dial through, started only when one of them starts.

  - While a move this home started is pending (`FermixCore.Home.Move.pending?/1`):
    the move worker (`FermixChannels.Home.MoveWorker`), its source.
  - When `device/desktop.json` exists: the receipts of the actions this
    desktop runs for its primary (`Desktop.Receipts`, which the executor
    reads), the desktop's services (`Desktop.DeviceServices`), then the
    desktop relay (`Desktop.Relay`).

  `:rest_for_one`: the users dial through the helper, so its restart takes
  them down with it, and the relay reconnects on its own backoff.
  """

  use Supervisor

  alias FermixChannels.Desktop.Receipts
  alias FermixChannels.Desktop.Relay
  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Move
  alias FermixCore.Setup.ConfigStore

  @helper FermixChannels.Desktop.DialHelper

  @doc "The registered name of the dial-only helper the rail's users dial through."
  @spec helper() :: atom()
  def helper, do: @helper

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    root = Keyword.get_lazy(opts, :root, &ConfigStore.fermix_home/0)
    Supervisor.init(children(root), strategy: :rest_for_one)
  end

  @doc """
  This boot's children for the home at `root`: the rail's users this home
  needs, after the helper they dial through; none at all when it needs none.
  """
  @spec children(Path.t()) :: [Supervisor.child_spec() | {module(), keyword()}]
  def children(root) when is_binary(root) and root != "" do
    linked? = File.regular?(DesktopLink.path(root))

    users =
      for {start?, child} <- [
            # One line per child, in start order; the relay comes last.
            {Move.pending?(root), {FermixChannels.Home.MoveWorker, home: root, helper: @helper}},
            {linked?, {Receipts, home: root}},
            {linked?, {FermixChannels.Desktop.DeviceServices, home: root}},
            {linked?, {Relay, root: root, helper: @helper}}
          ],
          start?,
          do: child

    if users == [], do: [], else: [{Helper, name: @helper, mode: :dial, root: root} | users]
  end
end
