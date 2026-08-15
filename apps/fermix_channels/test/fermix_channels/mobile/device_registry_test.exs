defmodule FermixChannels.Mobile.DeviceRegistryTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.DeviceRegistry

  setup do
    registry =
      start_supervised!(
        {DeviceRegistry,
         name: :"mobile_registry_#{System.unique_integer([:positive])}",
         authorize_device: fn _store, device_id -> {:ok, %{device_id: device_id}} end,
         delete_device: fn _store, _device_id -> :ok end}
      )

    %{registry: registry}
  end

  test "attaches a Bandit-owned socket and exposes profile-scoped presence", %{registry: registry} do
    socket = socket_process()

    assert :ok = DeviceRegistry.attach(registry, "device-b", socket, profile_id: "work")
    assert {:ok, ^socket} = DeviceRegistry.lookup(registry, "device-b")

    assert [
             %{device_id: "device-b", pid: ^socket, profile_id: "work"}
           ] = DeviceRegistry.list(registry)

    assert [] = DeviceRegistry.connected(registry, "main")
    assert [{"device-b", ^socket}] = DeviceRegistry.connected(registry, "work")
  end

  test "a concurrent reconnect atomically wins and stale cleanup cannot remove it", %{
    registry: registry
  } do
    old_socket = socket_process()
    new_socket = socket_process()
    assert :ok = DeviceRegistry.attach(registry, "device-a", old_socket)

    old_ref = :sys.get_state(registry).by_device["device-a"].ref
    assert :ok = DeviceRegistry.attach(registry, "device-a", new_socket)
    assert_receive {:socket_message, ^old_socket, {:mobile_replaced, ^new_socket}}

    # Both forms of stale cleanup are possible in production: Bandit invokes
    # terminate/2 on the old socket, and a monitor DOWN may already be queued.
    assert :ok = DeviceRegistry.detach(registry, "device-a", old_socket)
    send(registry, {:DOWN, old_ref, :process, old_socket, :normal})
    assert {:ok, ^new_socket} = DeviceRegistry.lookup(registry, "device-a")
  end

  test "a socket DOWN removes only its current registration", %{registry: registry} do
    socket = socket_process()
    assert :ok = DeviceRegistry.attach(registry, "device-a", socket)

    Process.exit(socket, :kill)

    assert_eventually(fn ->
      DeviceRegistry.lookup(registry, "device-a") == {:error, :not_connected}
    end)
  end

  test "revocation and delivery use messages understood by SocketHandler", %{registry: registry} do
    first = socket_process()
    second = socket_process()
    assert :ok = DeviceRegistry.attach(registry, "a", first)
    assert :ok = DeviceRegistry.attach(registry, "b", second, profile_id: "other")

    event = %{"t" => "notice", "kind" => "info", "text" => "ready"}
    assert :ok = DeviceRegistry.send_device_event(registry, "a", event)
    assert_receive {:socket_message, ^first, {:mobile_event, ^event}}

    assert {:error, :not_connected} =
             DeviceRegistry.send_device_event(registry, "missing", event)

    assert 1 = DeviceRegistry.send_profile_event(registry, "main", event)
    assert_receive {:socket_message, ^first, {:mobile_event, ^event}}
    refute_receive {:socket_message, ^second, {:mobile_event, ^event}}

    event = %{type: "text_done", text: "done"}
    assert :ok = DeviceRegistry.send_device_event(registry, "a", event)
    assert_receive {:socket_message, ^first, {:mobile_event, ^event}}
    assert 1 = DeviceRegistry.send_profile_event(registry, "other", event)
    assert_receive {:socket_message, ^second, {:mobile_event, ^event}}

    assert :ok = DeviceRegistry.revoke(registry, "a")
    assert_receive {:socket_message, ^first, {:mobile_revoked, "a"}}
    assert {:error, :not_connected} = DeviceRegistry.lookup(registry, "a")
    assert :ok = DeviceRegistry.revoke(registry, "offline")
  end

  test "refuses a dead socket and one socket claiming two device identities", %{
    registry: registry
  } do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, :normal}

    assert {:error, :socket_not_alive} = DeviceRegistry.attach(registry, "dead", dead)

    socket = socket_process()
    assert :ok = DeviceRegistry.attach(registry, "first", socket)

    assert {:error, {:socket_already_attached, "first"}} =
             DeviceRegistry.attach(registry, "second", socket)
  end

  test "authorization is serialized at attach and rejects a deleted device" do
    test_pid = self()

    registry =
      start_supervised!(
        {DeviceRegistry,
         name: :"authorized_registry_#{System.unique_integer([:positive])}",
         device_store: :store,
         authorize_device: fn :store, "revoked" ->
           send(test_pid, :authorization_checked)
           {:error, {:device_not_found, "revoked"}}
         end},
        id: make_ref()
      )

    socket = socket_process()

    assert {:error, {:device_not_authorized, {:device_not_found, "revoked"}}} =
             DeviceRegistry.attach(registry, "revoked", socket)

    assert_receive :authorization_checked
    assert {:error, :not_connected} = DeviceRegistry.lookup(registry, "revoked")
  end

  test "revocation persists deletion before closing the current socket" do
    test_pid = self()

    registry =
      start_supervised!(
        {DeviceRegistry,
         name: :"revoking_registry_#{System.unique_integer([:positive])}",
         device_store: :store,
         authorize_device: fn :store, id -> {:ok, %{device_id: id}} end,
         delete_device: fn :store, "device" ->
           send(test_pid, :device_deleted)
           :ok
         end},
        id: make_ref()
      )

    socket = socket_process()
    assert :ok = DeviceRegistry.attach(registry, "device", socket)
    assert :ok = DeviceRegistry.revoke(registry, "device")
    assert_receive :device_deleted
    assert_receive {:socket_message, ^socket, {:mobile_revoked, "device"}}
    assert {:error, :not_connected} = DeviceRegistry.lookup(registry, "device")
  end

  test "a retry after durable deletion still closes stale presence and reports not found" do
    registry =
      start_supervised!(
        {DeviceRegistry,
         name: :"retry_registry_#{System.unique_integer([:positive])}",
         device_store: :store,
         authorize_device: fn :store, id -> {:ok, %{device_id: id}} end,
         delete_device: fn :store, id -> {:error, {:device_not_found, id}} end},
        id: make_ref()
      )

    socket = socket_process()
    assert :ok = DeviceRegistry.attach(registry, "device", socket)

    assert {:error, {:device_not_found, "device"}} =
             DeviceRegistry.revoke(registry, "device")

    assert_receive {:socket_message, ^socket, {:mobile_revoked, "device"}}
    assert {:error, :not_connected} = DeviceRegistry.lookup(registry, "device")

    assert {:error, {:device_not_found, "missing"}} =
             DeviceRegistry.revoke(registry, "missing")
  end

  test "ready-frame authorization is serialized with revocation" do
    calls = start_supervised!({Agent, fn -> 0 end})

    registry =
      start_supervised!(
        {DeviceRegistry,
         name: :"frame_auth_registry_#{System.unique_integer([:positive])}",
         device_store: :store,
         authorize_device: fn :store, id ->
           case Agent.get_and_update(calls, &{&1, &1 + 1}) do
             0 -> {:ok, %{device_id: id}}
             1 -> {:error, {:device_not_found, id}}
           end
         end,
         delete_device: fn :store, _id -> :ok end},
        id: make_ref()
      )

    socket = socket_process()
    assert :ok = DeviceRegistry.attach(registry, "device", socket)

    assert {:error, {:device_not_authorized, {:device_not_found, "device"}}} =
             DeviceRegistry.authorized?(registry, "device", socket)

    assert_receive {:socket_message, ^socket, {:mobile_revoked, "device"}}
    assert {:error, :not_connected} = DeviceRegistry.lookup(registry, "device")
  end

  defp socket_process do
    test_pid = self()

    pid =
      spawn(fn ->
        receive_messages(test_pid)
      end)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    pid
  end

  defp receive_messages(test_pid) do
    receive do
      :stop ->
        :ok

      message ->
        send(test_pid, {:socket_message, self(), message})
        receive_messages(test_pid)
    after
      5_000 -> :ok
    end
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end
end
