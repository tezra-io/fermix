defmodule FermixChannels.Desktop.DeviceServices do
  @moduledoc """
  What a linked desktop serves for its primary beside the relay (M75 D17,
  D19, M97 §5.1), in the device role: the sign-in loopback forward
  (`Desktop.Loopback`), the snapshot copies (`Desktop.SnapshotStore`) and the
  media fetches (`Desktop.MediaFetches`), each family of the link in a process
  of its own. The relay hands each the primary's events (`Desktop.Relay`'s
  `@inbound`) and never waits on one, so they start before it
  (`Desktop.DeviceSupervisor`).

  `:one_for_one`: each keeps its own state and none depends on another, so
  one that dies is restarted alone and the relay's session stays up.
  """

  use Supervisor

  alias FermixChannels.Desktop.Loopback
  alias FermixChannels.Desktop.MediaFetches
  alias FermixChannels.Desktop.SnapshotStore

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    home = Keyword.fetch!(opts, :home)

    Supervisor.init(
      [Loopback, {SnapshotStore, home: home}, {MediaFetches, home: home}],
      strategy: :one_for_one
    )
  end
end
