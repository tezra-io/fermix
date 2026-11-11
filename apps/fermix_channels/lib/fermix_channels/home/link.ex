defmodule FermixChannels.Home.Link do
  @moduledoc """
  The channels-side implementation of `FermixCore.Home.Link` (M75): the one
  place `fermix_core` reaches the rail through.

  Each callback is owned by the part of the rail that knows its answer:
  `forward/1` and `status/0`'s `primary` by the desktop relay (device role),
  `status/0`'s `desktops` by the primary's desktop peers
  (`FermixChannels.Desktop.Peer`), and `open_enrollment/1`,
  `withdraw_enrollment/0`, `open_join/0`, `approve_join/1`, `deny_join/0`,
  `forget_candidate/1` and `status/0`'s
  `enrollment` by the enrollment window, `drop_desktop_row/2` and
  `home_desktops/1` by the device store of the home they name, read from its
  file, `announce_computers/1` by each open session's computer family
  (`FermixChannels.Desktop.ComputerFamily`), and `start_return/1` and
  `stop_return/0` by the device tree
  (`FermixChannels.Desktop.DeviceSupervisor`), whose candidate subtree
  receives a move back beside the relay.

  The desktop relay (`FermixChannels.Desktop.Relay`) runs only in a device
  role whose home holds its desktop link, which is also the only engine whose
  daemon forwards: `forward/1` reaches it, and a relay that is not running
  answers `primary_unreachable`. `status/0`'s `primary` is the relay's own
  view, `nil` where no relay runs.
  """

  @behaviour FermixCore.Home.Link

  require Logger

  alias FermixChannels.Desktop.ComputerFamily
  alias FermixChannels.Desktop.DeviceSupervisor
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
  # with no window running here, none opens, said in words an owner reads.
  @impl true
  def open_enrollment(returning) when is_binary(returning) or is_nil(returning) do
    if Process.whereis(Enrollment),
      do: Enrollment.open(Enrollment, returning),
      else: {:error, {:unavailable, "Fermix cannot open a code here right now."}}
  end

  @impl true
  def open_join do
    if Process.whereis(Enrollment),
      do: Enrollment.open(Enrollment, nil, :computer),
      else: {:error, {:unavailable, "Fermix cannot open a code here right now."}}
  end

  # The window that holds the computer is the primary's alone.
  @impl true
  def approve_join(sas) when is_binary(sas) do
    if Process.whereis(Enrollment),
      do: Enrollment.approve(Enrollment, sas),
      else: {:error, :none}
  end

  @impl true
  def deny_join do
    if Process.whereis(Enrollment), do: Enrollment.deny(Enrollment), else: :ok
  end

  # No window runs outside the primary, so there is none to close.
  @impl true
  def withdraw_enrollment do
    if Process.whereis(Enrollment), do: Enrollment.withdraw(Enrollment), else: :ok
  end

  # The held candidates are the primary's window's to write.
  @impl true
  def forget_candidate(candidate_id) when is_binary(candidate_id) do
    if Process.whereis(Enrollment),
      do: Enrollment.forget(Enrollment, candidate_id),
      else: {:error, {:unavailable, "Fermix cannot forget a server here right now."}}
  end

  # A staged home's list, by its root: never the running store's.
  @impl true
  def drop_desktop_row(root, <<_::256>> = noise_pk) when is_binary(root) and root != "" do
    case DeviceStore.find_by_noise_pk(noise_pk, root: root) do
      {:ok, %{kind: :desktop, device_id: id}} -> DeviceStore.delete(id, root: root)
      {:ok, %{device_id: id}} -> {:error, {:not_a_desktop, id}}
      {:error, {:noise_identity_not_found, _key}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def home_desktops(root) when is_binary(root) and root != "" do
    case DeviceStore.list(root: root) do
      {:ok, devices} ->
        {:ok, for(%{kind: :desktop} = row <- devices, do: Map.take(row, [:device_id, :name]))}

      {:error, _reason} = error ->
        error
    end
  end

  # The primary's computer rows (M97 §3.2), with whether each session is up;
  # where the store or the peers are not running they are not known, which
  # is never read as none.
  @impl true
  def computer_rows do
    if Process.whereis(DeviceStore) && Process.whereis(FermixChannels.Desktop.Peers),
      do: computer_rows(DeviceStore.list()),
      else: {:error, :not_running}
  end

  # A live view that started asks every open session's family to say its
  # facts again; with no peers running there is no session to ask.
  @impl true
  def announce_computers(registry) when is_atom(registry) do
    if Process.whereis(FermixChannels.Desktop.Peers),
      do: ComputerFamily.announce(registry, FermixChannels.Desktop.Peers),
      else: :ok
  end

  defp computer_rows({:ok, devices}) do
    connected = Map.new(Peer.connected(), &{&1.device_id, &1.connected_since})

    {:ok,
     for(%{kind: :desktop} = row <- devices, do: computer_row(row, connected[row.device_id]))}
  end

  defp computer_rows({:error, _reason} = error), do: error

  defp computer_row(row, since) do
    %{
      device_id: row.device_id,
      name: row.name,
      platform: row.platform,
      last_seen: row.last_seen,
      backups: row.backups,
      connected: since != nil,
      since: since
    }
  end

  # The store serializes its writes; a name another computer holds, compared
  # without case, is refused against the rows as they stand.
  @impl true
  def rename_computer(device_id, name) when is_binary(device_id) and is_binary(name) do
    with {:ok, devices} <- DeviceStore.list(),
         {:ok, _row} <- computer(devices, device_id),
         :ok <- free_name(devices, device_id, name),
         {:ok, row} <- DeviceStore.update(device_id, %{name: name}) do
      {:ok, computer_row(row, connected_since(device_id))}
    end
  end

  defp computer(devices, device_id) do
    case Enum.find(devices, &(&1.device_id == device_id and &1.kind == :desktop)) do
      nil -> {:error, {:not_found, device_id}}
      row -> {:ok, row}
    end
  end

  defp free_name(devices, device_id, name) do
    taken =
      Enum.any?(
        devices,
        &(&1.device_id != device_id and String.downcase(&1.name) == String.downcase(name))
      )

    if taken, do: {:error, {:name_taken, name}}, else: :ok
  end

  defp connected_since(device_id) do
    case Peer.lookup(device_id) do
      {:ok, _peer, %{connected_since: since}} -> since
      {:error, :not_connected} -> nil
    end
  end

  @impl true
  def start_return(home) when is_binary(home) and home != "",
    do: DeviceSupervisor.start_candidate(home)

  @impl true
  def stop_return, do: DeviceSupervisor.stop_candidate()

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
