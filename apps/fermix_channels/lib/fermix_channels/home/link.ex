defmodule FermixChannels.Home.Link do
  @moduledoc """
  The channels-side implementation of `FermixCore.Home.Link` (M75): the one
  place `fermix_core` reaches the rail through.

  Each callback is owned by the part of the rail that knows its answer:
  `forward/1` and `status/0`'s `primary` by the desktop relay (device role),
  `status/0`'s `desktops` by the primary's desktop peers
  (`FermixChannels.Desktop.Peer`), and `open_enrollment/1`,
  `withdraw_enrollment/0` and `status/0`'s `enrollment` by the enrollment
  window.

  The desktop relay (`FermixChannels.Desktop.Relay`) runs only in a device
  role whose home holds its desktop link, which is also the only engine whose
  daemon forwards: `forward/1` reaches it, and a relay that is not running
  answers `primary_unreachable`. `status/0`'s `primary` is the relay's own
  view, `nil` where no relay runs.
  """

  @behaviour FermixCore.Home.Link

  require Logger

  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Desktop.Relay
  alias FermixChannels.Home.Enrollment
  alias FermixChannels.Mobile.DeviceStore

  @impl true
  def forward(%{method: method} = request, opts) when is_binary(method) and is_list(opts),
    do: Relay.forward(Relay, request, opts)

  @impl true
  def status do
    %{primary: Relay.status(), desktops: desktops(), enrollment: Enrollment.status()}
  end

  # The window runs on the primary alone (`FermixChannels.Home.Enrollment`);
  # any other role answers by name.
  @impl true
  def open_enrollment(kind) when kind in [:manual, :provisioned] do
    if Process.whereis(Enrollment),
      do: Enrollment.open(Enrollment, kind),
      else: {:error, {:unavailable, "Only the primary opens an enrollment code."}}
  end

  # No window runs outside the primary, so there is none to close.
  @impl true
  def withdraw_enrollment do
    if Process.whereis(Enrollment), do: Enrollment.withdraw(), else: :ok
  end

  # Every desktop row the primary holds, with whether its session is up now.
  # A store or registry that is not running (any role but the primary) holds
  # no desktop.
  defp desktops do
    if Process.whereis(DeviceStore) && Process.whereis(FermixChannels.Desktop.Peers),
      do: desktop_rows(DeviceStore.list()),
      else: []
  end

  defp desktop_rows({:ok, devices}) do
    connected = Map.new(Peer.connected(), &{&1.device_id, &1.connected_since})

    for %{kind: :desktop} = device <- devices,
        do: desktop_view(device, Map.get(connected, device.device_id))
  end

  defp desktop_rows({:error, reason}) do
    Logger.warning("home status lists no desktop: the device store answered #{inspect(reason)}")
    []
  end

  defp desktop_view(device, nil) do
    %{
      device_id: device.device_id,
      name: device.name,
      connected: false
    }
  end

  defp desktop_view(device, %DateTime{} = since) do
    %{
      device_id: device.device_id,
      name: device.name,
      connected: true,
      since: since
    }
  end
end
