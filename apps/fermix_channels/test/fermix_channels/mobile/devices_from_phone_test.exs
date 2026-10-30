defmodule FermixChannels.Mobile.DevicesFromPhoneTest do
  @moduledoc """
  M75: a phone lists and revokes the owner's devices (`devices_list` ->
  `devices`, `device_revoke {device_id}` -> `devices`), as `mobile.devices.list`
  and `mobile.devices.revoke` do, so a stolen computer can be revoked from the
  phone in the owner's pocket. Through the real Noise `IK` session and codec;
  the management facade's two calls are this test's.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Desktop.Supervisor, as: DesktopSupervisor
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Test.SessionDriver, as: Driver

  @phone_id "2a9b8c7d-6e5f-4a3b-9c2d-1e0f9a8b7c6d"
  @desktop_id "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"
  @seen ~U[2026-10-21 08:00:00Z]

  @phone_row %{
    device_id: @phone_id,
    name: "Garden phone",
    model: "Pixel 9",
    kind: :phone,
    executor: nil,
    created_at: "2026-09-01T10:00:00Z",
    last_seen: "2026-10-21T08:00:00Z"
  }
  @desktop_row %{
    device_id: @desktop_id,
    name: "Studio Mac",
    model: "macOS desktop",
    kind: :desktop,
    executor: true,
    created_at: "2026-10-20T09:00:00Z",
    last_seen: nil
  }

  setup do
    suffix = System.unique_integer([:positive])
    peers = Module.concat(__MODULE__, "Peers#{suffix}")
    peer_supervisor = Module.concat(__MODULE__, "PeerSupervisor#{suffix}")

    start_supervised!(
      {DesktopSupervisor, name: nil, registry: peers, peer_supervisor: peer_supervisor}
    )

    registry =
      start_supervised!(
        {DeviceRegistry,
         name: Module.concat(__MODULE__, "Registry#{suffix}"),
         authorize_device: fn _store, id -> {:ok, row(id)} end,
         delete_device: fn _store, _id -> :ok end,
         revoke_requests: fn _id -> :ok end}
      )

    {:ok, rows} = Agent.start_link(fn -> [@phone_row, @desktop_row] end)

    %{
      gateway: Noise.generate_keypair(),
      phone: Noise.generate_keypair(),
      desktop: Noise.generate_keypair(),
      peers: peers,
      peer_supervisor: peer_supervisor,
      registry: registry,
      rows: rows
    }
  end

  test "a phone lists the owner's devices, itself marked", ctx do
    {driver, client} = ready!(ctx, ctx.phone, @phone_id)
    client = Driver.client_send(driver, client, "devices_list", %{}, 2)

    assert {[{%{"t" => "devices", "devices" => devices}, <<>>}], _client} =
             Driver.client_receive(driver, client)

    assert devices == [
             %{
               "device_id" => @phone_id,
               "name" => "Garden phone",
               "model" => "Pixel 9",
               "kind" => "phone",
               "created_at" => "2026-09-01T10:00:00Z",
               "last_seen" => "2026-10-21T08:00:00Z",
               "this_device" => true
             },
             %{
               "device_id" => @desktop_id,
               "name" => "Studio Mac",
               "model" => "macOS desktop",
               "kind" => "desktop",
               "created_at" => "2026-10-20T09:00:00Z",
               "executor" => true,
               "this_device" => false
             }
           ]
  end

  test "a phone revokes a desktop and hears the devices that are left", ctx do
    {driver, client} = ready!(ctx, ctx.phone, @phone_id)
    client = Driver.client_send(driver, client, "device_revoke", %{"device_id" => @desktop_id}, 2)

    assert {[{%{"t" => "devices", "devices" => [%{"device_id" => @phone_id}]}, <<>>}], _client} =
             Driver.client_receive(driver, client)

    assert_received {:revoked, @desktop_id}
  end

  test "an id no device has is refused by name, and the session stays open", ctx do
    {driver, client} = ready!(ctx, ctx.phone, @phone_id)
    client = Driver.client_send(driver, client, "device_revoke", %{"device_id" => "dev-404"}, 2)

    assert {[{%{"t" => "error", "code" => "device_not_found"}, <<>>}], client} =
             Driver.client_receive(driver, client)

    client = Driver.client_send(driver, client, "devices_list", %{}, 3)

    assert {[{%{"t" => "devices"}, <<>>}], _client} = Driver.client_receive(driver, client)
  end

  test "a desktop neither lists nor revokes devices", ctx do
    {driver, client} = ready!(ctx, ctx.desktop, @desktop_id)
    client = Driver.client_send(driver, client, "devices_list", %{}, 2)

    assert {[{%{"t" => "error", "code" => "unsupported_event"}, <<>>}], _client} =
             Driver.client_receive(driver, client)

    refute_received {:revoked, _id}
  end

  # A paired device's session through IK and hello, its hello_ack read.
  defp ready!(ctx, keypair, device_id) do
    keys = %{ctx.phone.public => @phone_id, ctx.desktop.public => @desktop_id}
    test = self()
    rows = ctx.rows
    supervisor = ctx.peer_supervisor

    driver =
      Driver.start!(
        peer: {127, 0, 0, 1},
        gateway_keypair: ctx.gateway,
        primary_epoch: 4,
        device_store: :store,
        device_registry: ctx.registry,
        desktop_peers: ctx.peers,
        desktop_peer_supervisor: supervisor,
        start_desktop_peer: &Peer.start(supervisor, Keyword.put(&1, :families, %{})),
        find_device: fn :store, key -> {:ok, row(Map.fetch!(keys, key))} end,
        update_device: fn :store, id, %{last_seen: _seen} -> {:ok, row(id)} end,
        wall_clock: fn -> @seen end,
        hello_ack_builder: fn _state -> {:ok, hello_ack()} end,
        pending_approvals: fn "main" -> [] end,
        pairing_pending: fn -> :none end,
        devices_list: fn -> {:ok, Agent.get(rows, & &1)} end,
        device_revoke: fn id ->
          if Agent.get(rows, fn list -> Enum.any?(list, &(&1.device_id == id)) end) do
            send(test, {:revoked, id})
            Agent.update(rows, fn list -> Enum.reject(list, &(&1.device_id == id)) end)
            {:ok, %{device_id: id}}
          else
            {:error, :device_not_found}
          end
        end
      )

    {:ok, client} =
      Noise.initialize(:initiator, :ik,
        static_keypair: keypair,
        remote_static: ctx.gateway.public
      )

    client = Driver.handshake!(driver, client)

    hello = %{
      "device_id" => device_id,
      "app_version" => "0.17.0",
      "last_server_seq" => 0,
      "protocol_v" => Protocol.protocol_version()
    }

    client = Driver.client_send(driver, client, "hello", hello, 1)

    assert {[{%{"t" => "hello_ack", "seq" => 1}, <<>>} | _rest], client} =
             Driver.client_receive(driver, client)

    {driver, client}
  end

  defp row(@desktop_id),
    do: %{device_id: @desktop_id, name: "Studio Mac", kind: :desktop, executor: true}

  defp row(id), do: %{device_id: id, name: "Garden phone", kind: :phone}

  defp hello_ack do
    {min_version, max_version} = Protocol.supported_version_range()

    %{
      "session_id" => "phone-session",
      "min_version" => min_version,
      "max_version" => max_version,
      "profiles" => [%{"id" => "main", "name" => "Fermix"}],
      "candidates" => [],
      "history_head_seq" => 0,
      "read_up_to_seq" => 0,
      "caps" => %{"commands" => [], "max_media_bytes" => 20_971_520},
      "primary_epoch" => 4
    }
  end
end
