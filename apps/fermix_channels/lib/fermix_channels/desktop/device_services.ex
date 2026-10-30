defmodule FermixChannels.Desktop.DeviceServices do
  @moduledoc """
  What a linked desktop serves for its primary beside the relay (M75 D17,
  D18, D19), in the device role: the sign-in loopback forward
  (`Desktop.Loopback`), the snapshot copies (`Desktop.SnapshotStore`) and
  the hand-off's answers (`Desktop.HandoffLink`). The relay hands each the
  primary's events (`Desktop.Relay`'s `@inbound`), so they start before it
  (`Desktop.DeviceSupervisor`).

  `:one_for_one`: each keeps its own state and none depends on another.
  """

  use Supervisor

  alias FermixChannels.Desktop.HandoffLink
  alias FermixChannels.Desktop.Loopback
  alias FermixChannels.Desktop.SnapshotStore

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    home = Keyword.fetch!(opts, :home)

    Supervisor.init(
      [Loopback, {SnapshotStore, home: home}, HandoffLink],
      strategy: :one_for_one
    )
  end
end
