defmodule FermixChannels.Mobile.ManagementTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Management

  test "begin_pairing returns a canonical secret-bearing URI and terminal QR only" do
    identity = %{
      gateway_public_key: <<1::256>>,
      tls_fingerprint: <<2::256>>
    }

    opts = [
      config: [enabled: true],
      pair_manager: :pair,
      listener: :listener,
      open_pair: fn :pair ->
        {:ok,
         %{
           session_id: "session-id",
           secret: <<3::256>>,
           identity: identity,
           opened_at_ms: 1_000,
           expires_at_ms: 121_000
         }}
      end,
      listener_info: fn :listener -> {:ok, {{0, 0, 0, 0}, 40_321}} end,
      discover: fn ->
        {:ok, [%{address: "192.168.1.8", interface: "en0", scope: :lan}]}
      end,
      host_label: fn -> "workstation" end
    ]

    assert {:ok, result} = Management.begin_pairing(opts)
    assert result.session_id == "session-id"
    assert result.expires_in_s == 120
    assert String.starts_with?(result.uri, "fermix://pair?")
    assert String.contains?(result.qr, "██")
    refute Map.has_key?(result, :secret)

    query = result.uri |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["v"] == "1"
    assert query["port"] == "40321"
    assert query["name"] == "workstation"
    assert Jason.decode!(query["candidates"]) == ["192.168.1.8"]
    assert Base.decode64!(query["gateway_pk"]) == <<1::256>>
    assert Base.decode64!(query["secret"]) == <<3::256>>
    assert query["tls_fp"] == Base.encode16(<<2::256>>, case: :lower)
  end

  test "begin_pairing closes its window when local QR setup fails" do
    test_pid = self()

    assert {:error, :listener_down} =
             Management.begin_pairing(
               config: [enabled: true],
               pair_manager: :pair,
               listener: :listener,
               open_pair: fn :pair ->
                 {:ok,
                  %{
                    session_id: "session-id",
                    secret: <<3::256>>,
                    identity: %{
                      gateway_public_key: <<1::256>>,
                      tls_fingerprint: <<2::256>>
                    },
                    opened_at_ms: 0,
                    expires_at_ms: 120_000
                  }}
               end,
               listener_info: fn :listener -> {:error, :listener_down} end,
               cancel_pair: fn :pair, "session-id" ->
                 send(test_pid, :cancelled)
                 :ok
               end
             )

    assert_receive :cancelled
  end

  test "approval, device listing, and revocation preserve facade boundaries" do
    device = %{
      device_id: "11111111-1111-4111-8111-111111111111",
      name: "Phone",
      model: "iPhone",
      created_at: ~U[2026-08-12 12:00:00Z],
      last_seen: nil
    }

    device_id = device.device_id

    assert {:ok, %{approved: true, device_id: ^device_id, name: "Phone"}} =
             Management.decide_pairing("session", true,
               config: [enabled: true],
               pair_manager: :pair,
               approve_pair: fn :pair, "session" -> {:ok, device} end
             )

    assert {:ok, %{devices: [listed]}} =
             Management.list_devices(
               config: [enabled: true],
               device_store: :store,
               list_devices: fn :store -> {:ok, [device]} end
             )

    assert listed == %{
             device_id: device.device_id,
             name: "Phone",
             created_at: "2026-08-12T12:00:00Z",
             last_seen: nil
           }

    test_pid = self()

    assert {:ok, %{device_id: ^device_id}} =
             Management.revoke_device(device.device_id,
               config: [enabled: true],
               device_registry: :registry,
               revoke_device: fn :registry, id ->
                 send(test_pid, {:revoked, id})
                 :ok
               end
             )

    assert_received {:revoked, ^device_id}
  end

  test "revoking an unknown device yields the wire vocabulary, not a registry tuple" do
    # The raw {:device_not_found, id} tuple would reach the CLI as an
    # inspect() dump; the facade flattens it so `fermix devices revoke` can
    # render its typed message. The id is already in the caller's hands.
    assert {:error, :device_not_found} =
             Management.revoke_device("22222222-2222-4222-8222-222222222222",
               config: [enabled: true],
               device_registry: :registry,
               revoke_device: fn :registry, id -> {:error, {:device_not_found, id}} end
             )
  end

  test "cancel_pairing closes the daemon-owned window" do
    test_pid = self()

    assert {:ok, %{cancelled: true}} =
             Management.cancel_pairing("session",
               config: [enabled: true],
               pair_manager: :pair,
               cancel_pair: fn :pair, "session" ->
                 send(test_pid, :cancelled)
                 :ok
               end
             )

    assert_received :cancelled
  end

  test "status reports configured lifecycle state without network probes" do
    opts = [
      config: [enabled: true, advertise_mdns: true, port: 4_031, push: [enabled: false]],
      listener: :listener,
      mdns_advertiser: :mdns,
      device_store: :store,
      listener_status: fn :listener -> {:listening, {{0, 0, 0, 0}, 4_031}} end,
      mdns_status: fn :mdns -> :advertising end,
      discover: fn ->
        {:ok,
         [
           %{address: "192.168.1.8", interface: "en0", scope: :lan},
           %{address: "100.64.1.2", interface: "utun4", scope: :tailnet}
         ]}
      end,
      list_devices: fn :store -> {:ok, [%{}]} end
    ]

    assert {:ok, status} = Management.status(opts)
    assert status.enabled
    assert status.listener.status == :ready
    assert status.mdns == :advertising
    assert status.tailnet.detected
    assert status.tailnet.candidates == ["100.64.1.2"]
    assert status.apns == %{enabled: false, credentials: :missing}
    assert status.paired_devices == 1
  end

  test "health requires enabled listener, strict identity, and reports paired count" do
    opts = [
      config: [enabled: true],
      listener: :listener,
      device_store: :store,
      listener_status: fn :listener -> {:listening, {{127, 0, 0, 1}, 4_031}} end,
      load_identity: fn _opts -> {:ok, :identity} end,
      list_devices: fn :store -> {:ok, [%{}, %{}]} end
    ]

    assert {:ok, %{listener: :ready, identity: :ready, paired_devices: 2}} =
             Management.health(opts)
  end

  test "health fails closed while disabled or dormant" do
    assert {:error, :mobile_disabled} = Management.health(config: [enabled: false])

    assert {:error, :listener_down} =
             Management.health(
               config: [enabled: true],
               listener: :listener,
               listener_status: fn :listener -> :dormant end
             )
  end

  # The un-stubbed world every fresh install and upgrader lives in: the flag is
  # off, so no PairManager/DeviceStore/Listener process exists. Each entry
  # point must refuse with :mobile_disabled BEFORE any process call — without
  # the gate these surfaced as raw `{:dependency_exit, _, {:noproc, _}}`
  # tuples, and the CLI's "mobile channel is off" copy was unreachable from a
  # real daemon.
  test "every entry point refuses :mobile_disabled with the flag off and no subtree" do
    off = [config: [enabled: false]]

    assert {:error, :mobile_disabled} = Management.begin_pairing(off)
    assert {:error, :mobile_disabled} = Management.await_pairing("session", 1_000, off)
    assert {:error, :mobile_disabled} = Management.decide_pairing("session", true, off)
    assert {:error, :mobile_disabled} = Management.decide_pairing("session", false, off)
    assert {:error, :mobile_disabled} = Management.cancel_pairing("session", off)
    assert {:error, :mobile_disabled} = Management.list_devices(off)
    assert {:error, :mobile_disabled} = Management.revoke_device("device-id", off)
    assert {:error, :mobile_disabled} = Management.status(off)
  end

  test "health surfaces missing or invalid identity and device-store failures" do
    base = [
      config: [enabled: true],
      listener: :listener,
      device_store: :store,
      listener_status: fn :listener -> {:listening, {{127, 0, 0, 1}, 4_031}} end
    ]

    assert {:error, {:identity_unavailable, :missing}} =
             Management.health(base ++ [load_identity: fn _opts -> {:error, :missing} end])

    assert {:error, {:identity_unavailable, :unsafe_permissions}} =
             Management.health(
               base ++ [load_identity: fn _opts -> {:error, :unsafe_permissions} end]
             )

    assert {:error, {:device_store_unavailable, :disk_full}} =
             Management.health(
               base ++
                 [
                   load_identity: fn _opts -> {:ok, :identity} end,
                   list_devices: fn :store -> {:error, :disk_full} end
                 ]
             )
  end
end
