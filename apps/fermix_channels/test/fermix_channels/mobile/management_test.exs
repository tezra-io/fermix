defmodule FermixChannels.Mobile.ManagementTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Mobile.Management
  alias FermixChannels.Mobile.PairManager

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
      pair_manager: :pair,
      listener: :listener,
      mdns_advertiser: :mdns,
      device_store: :store,
      refusal: fn :store -> :none end,
      whereis: fn :pair -> self() end,
      listener_status: fn :listener -> {:listening, {{0, 0, 0, 0}, 4_031}} end,
      mdns_status: fn :mdns -> :advertising end,
      discover: fn ->
        {:ok,
         [
           %{address: "192.168.1.8", interface: "en0", scope: :lan},
           %{address: "100.64.1.2", interface: "utun4", scope: :tailnet}
         ]}
      end,
      list_devices: fn :store -> {:ok, [%{}]} end,
      latest_pair: fn :pair -> :none end,
      load_identity: fn [] -> {:ok, %{gateway_public_key: <<7::256>>}} end
    ]

    assert {:ok, status} = Management.status(opts)
    assert status.enabled
    assert status.started
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

  describe "v1 pairing sessions over a real PairManager" do
    setup do
      clock = start_supervised!({Agent, fn -> 50_000 end})

      manager =
        start_supervised!(
          {PairManager,
           name: nil,
           clock: fn -> Agent.get(clock, & &1) end,
           wall_clock: fn -> ~U[2026-09-26 12:00:00Z] end,
           schedule_timer: fn _message, _delay -> make_ref() end,
           cancel_timer: fn _ref -> :ok end,
           ensure_identity: fn ->
             {:ok, %{gateway_public_key: <<1::256>>, tls_fingerprint: <<2::256>>}}
           end,
           activate_listener: fn _identity -> :ok end,
           persist_device: fn device -> {:ok, device} end,
           emit_pair: fn _status, _duration_us -> :ok end,
           session_id_generator: fn -> "pair-session" end,
           device_id_generator: fn -> "device-id" end,
           secret_generator: fn -> <<3::256>> end,
           salt_generator: fn -> <<4::256>> end}
        )

      opts = [
        config: [enabled: true],
        pair_manager: manager,
        listener: :listener,
        device_store: :store,
        refusal: fn :store -> :none end,
        listener_info: fn :listener -> {:ok, {{0, 0, 0, 0}, 40_321}} end,
        discover: fn -> {:ok, [%{address: "192.168.1.8", interface: "en0", scope: :lan}]} end,
        host_label: fn -> "workstation" end
      ]

      %{clock: clock, manager: manager, opts: opts}
    end

    test "start answers the waiting view and the pairing link, never the secret alone", ctx do
      assert {:ok, result} = Management.pair_start(ctx.opts)
      assert Map.keys(result) |> Enum.sort() == [:session, :uri]

      assert result.session == %{
               session_id: "pair-session",
               state: :awaiting_scan,
               ttl_ms: 120_000,
               request: nil,
               outcome: nil,
               failure: nil
             }

      query = result.uri |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert String.starts_with?(result.uri, "fermix://pair?")
      assert query["port"] == "40321"
      assert Base.decode64!(query["secret"]) == <<3::256>>

      assert {:error, :pairing_active} = Management.pair_start(ctx.opts)
    end

    test "get counts the window down and shows the phone that asked", ctx do
      assert {:ok, _started} = Management.pair_start(ctx.opts)
      Agent.update(ctx.clock, &(&1 + 2_000))

      assert {:ok, %{state: :awaiting_scan, ttl_ms: 118_000}} =
               Management.pair_get("pair-session", ctx.opts)

      submit_request(ctx)

      assert {:ok, view} = Management.pair_get("pair-session", ctx.opts)
      assert view.state == :awaiting_decision
      assert view.ttl_ms == 118_000
      assert view.outcome == nil
      assert view.failure == nil

      assert view.request == %{
               device_name: "Pixel 9 Pro",
               model: "Google Pixel 9 Pro",
               platform: nil,
               app_version: "1.0.0",
               sas: "481062",
               build_role: nil,
               boot_state: nil,
               attestation: :unavailable
             }
    end

    test "approve ends approved with the new device id and keeps who was approved", ctx do
      assert {:ok, _started} = Management.pair_start(ctx.opts)
      submit_request(ctx)

      assert {:ok, view} = Management.pair_decide("pair-session", true, ctx.opts)
      assert view.state == :approved
      assert view.ttl_ms == nil
      assert view.outcome == %{device_id: "device-id"}
      assert view.failure == nil
      assert view.request.device_name == "Pixel 9 Pro"
      assert {:ok, ^view} = Management.pair_get("pair-session", ctx.opts)
    end

    test "deny ends denied", ctx do
      assert {:ok, _started} = Management.pair_start(ctx.opts)
      submit_request(ctx)

      assert {:ok, %{state: :denied, outcome: %{reason: :denied}, failure: nil, ttl_ms: nil}} =
               Management.pair_decide("pair-session", false, ctx.opts)
    end

    test "a decision with no phone waiting is refused and leaves the window open", ctx do
      assert {:ok, _started} = Management.pair_start(ctx.opts)

      assert {:error, :request_missing} = Management.pair_decide("pair-session", true, ctx.opts)
      assert {:error, :request_missing} = Management.pair_decide("pair-session", false, ctx.opts)
      assert {:ok, %{state: :awaiting_scan}} = Management.pair_get("pair-session", ctx.opts)
    end

    test "approving a phone that already disconnected fails the session", ctx do
      assert {:ok, _started} = Management.pair_start(ctx.opts)
      socket = spawn(fn -> receive do: (:stop -> :ok) end)
      submit_request(ctx, socket)
      monitor = Process.monitor(socket)
      send(socket, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^socket, _reason}

      assert {:ok, view} = Management.pair_decide("pair-session", true, ctx.opts)
      assert view.state == :failed
      assert view.failure == %{reason: :device_disconnected}
      assert view.outcome == nil
      assert view.ttl_ms == nil
    end

    test "cancel ends cancelled, and cancelling a finished session changes nothing", ctx do
      assert {:ok, _started} = Management.pair_start(ctx.opts)

      assert {:ok, cancelled} = Management.pair_cancel("pair-session", ctx.opts)
      assert cancelled.state == :cancelled
      assert cancelled.outcome == %{reason: :cancelled}
      assert {:ok, ^cancelled} = Management.pair_cancel("pair-session", ctx.opts)
      assert {:ok, ^cancelled} = Management.pair_decide("pair-session", true, ctx.opts)
    end

    test "an approved session stays approved when cancelled afterwards", ctx do
      assert {:ok, _started} = Management.pair_start(ctx.opts)
      submit_request(ctx)
      assert {:ok, approved} = Management.pair_decide("pair-session", true, ctx.opts)

      assert {:ok, ^approved} = Management.pair_cancel("pair-session", ctx.opts)
    end

    test "the end of the window reads as expired with a timeout outcome", ctx do
      assert {:ok, _started} = Management.pair_start(ctx.opts)
      Agent.update(ctx.clock, &(&1 + PairManager.max_ttl_ms()))

      assert {:ok, %{state: :expired, outcome: %{reason: :timeout}, ttl_ms: nil}} =
               Management.pair_get("pair-session", ctx.opts)
    end

    test "five failed handshakes fail the session as rate limited", ctx do
      assert {:ok, _started} = Management.pair_start(ctx.opts)

      for _attempt <- 1..5, do: PairManager.record_failure(ctx.manager, "pair-session")

      assert {:ok, %{state: :failed, failure: %{reason: :rate_limited}, outcome: nil}} =
               Management.pair_get("pair-session", ctx.opts)
    end

    test "an id the daemon does not retain is unknown to every verb", ctx do
      assert {:error, :unknown_pairing_session} = Management.pair_get("other", ctx.opts)
      assert {:error, :unknown_pairing_session} = Management.pair_decide("other", true, ctx.opts)
      assert {:error, :unknown_pairing_session} = Management.pair_cancel("other", ctx.opts)
    end

    test "status names the open window, then the newest finished one", ctx do
      status_opts =
        ctx.opts ++
          [
            whereis: fn manager when manager == ctx.manager -> manager end,
            listener_status: fn :listener -> {:listening, {{0, 0, 0, 0}, 40_321}} end,
            mdns_status: fn _mdns -> :advertising end,
            list_devices: fn :store -> {:ok, []} end,
            load_identity: fn [] -> {:error, {:identity_artifact_missing, "gateway_key"}} end
          ]

      assert {:ok, %{pairing: nil}} = Management.status(status_opts)

      assert {:ok, _started} = Management.pair_start(ctx.opts)

      assert {:ok, %{pairing: %{session_id: "pair-session", state: :awaiting_scan}}} =
               Management.status(status_opts)

      assert {:ok, _cancelled} = Management.pair_cancel("pair-session", ctx.opts)

      assert {:ok, %{pairing: %{session_id: "pair-session", state: :cancelled}}} =
               Management.status(status_opts)
    end
  end

  describe "v1 refusals" do
    test "with the channel off every verb refuses before any process call" do
      off = [config: [enabled: false]] ++ unreachable_processes()

      assert {:error, :mobile_disabled} = Management.pair_start(off)
      assert {:error, :mobile_disabled} = Management.pair_get("pair-session", off)
      assert {:error, :mobile_disabled} = Management.pair_decide("pair-session", true, off)
      assert {:error, :mobile_disabled} = Management.pair_cancel("pair-session", off)
      assert {:error, :mobile_disabled} = Management.devices_revoke("device-id", off)
      assert {:ok, []} = Management.devices_list(off)
    end

    test "a surface refused this boot is named, before any process call" do
      refused =
        [config: [enabled: true], device_store: :store] ++
          Keyword.put(unreachable_processes(), :refusal, fn :store -> {:error, :bad_store} end)

      assert {:error, :mobile_surface_refused} = Management.pair_start(refused)
      assert {:error, :mobile_surface_refused} = Management.pair_get("pair-session", refused)

      assert {:error, :mobile_surface_refused} =
               Management.pair_decide("pair-session", false, refused)

      assert {:error, :mobile_surface_refused} = Management.pair_cancel("pair-session", refused)
      assert {:error, :mobile_surface_refused} = Management.devices_revoke("device-id", refused)
      assert {:ok, []} = Management.devices_list(refused)
    end

    # A settings write enables the channel at once, but the subtree starts
    # only at the next boot: until then there is no process to call.
    test "an enabled channel that has not started yet is named, before any process call" do
      not_started =
        [config: [enabled: true], pair_manager: :pair, device_store: :store] ++
          Keyword.merge(unreachable_processes(),
            refusal: fn :store -> :none end,
            whereis: fn :pair -> nil end
          )

      assert {:error, :mobile_not_started} = Management.pair_start(not_started)
      assert {:error, :mobile_not_started} = Management.pair_get("pair-session", not_started)

      assert {:error, :mobile_not_started} =
               Management.pair_decide("pair-session", true, not_started)

      assert {:error, :mobile_not_started} = Management.pair_cancel("pair-session", not_started)
      assert {:error, :mobile_not_started} = Management.devices_revoke("device-id", not_started)
      assert {:ok, []} = Management.devices_list(not_started)
    end

    test "an identity step failure is named and its reason logged" do
      reason = {:identity_incomplete, ["/home/o/.fermix/mobile/tls.crt"]}

      log =
        capture_log(fn ->
          assert {:error, :identity_unavailable} =
                   Management.pair_start(
                     start_opts(open_pair: fn :pair -> {:error, {:identity, reason}} end)
                   )
        end)

      assert log =~ "mobile pairing could not start"
      assert log =~ "identity_incomplete"
    end

    # The identity guard reads the trust store to tell a first pairing from a
    # lost identity; a store it cannot read says nothing about the identity.
    test "a trust store the identity guard cannot read is named for the store" do
      reason = {:identity, {:device_store_unavailable, {:devices_decode_failed, :bad}}}

      log =
        capture_log(fn ->
          assert {:error, :device_store_unavailable} =
                   Management.pair_start(start_opts(open_pair: fn :pair -> {:error, reason} end))
        end)

      assert log =~ "(device_store_unavailable)"
      assert log =~ "devices_decode_failed"
    end

    test "a listener that cannot start is named, whether at activation or afterwards" do
      eaddrinuse = {:shutdown, {:failed_to_start_child, :listener, :eaddrinuse}}

      log =
        capture_log(fn ->
          assert {:error, :listener_unavailable} =
                   Management.pair_start(
                     start_opts(open_pair: fn :pair -> {:error, {:listener, eaddrinuse}} end)
                   )
        end)

      assert log =~ "eaddrinuse"
      test_pid = self()

      capture_log(fn ->
        assert {:error, :listener_unavailable} =
                 Management.pair_start(
                   start_opts(
                     listener_info: fn :listener -> {:error, :not_listening} end,
                     cancel_pair: fn :pair, "pair-session" ->
                       send(test_pid, :window_closed)
                       :ok
                     end
                   )
                 )
      end)

      assert_received :window_closed
    end

    test "a second window and any failure outside the two steps pass through unchanged" do
      assert {:error, :pairing_active} =
               Management.pair_start(
                 start_opts(open_pair: fn :pair -> {:error, :pairing_active} end)
               )

      # The step decides, not the spelling: an untagged identity-shaped reason
      # is not an identity refusal.
      for reason <- [
            {:invalid_generated_id, ""},
            :invalid_random_bytes,
            {:unsafe_permissions, "/home/o/.fermix/mobile/gateway_key", 0o644, 0o600}
          ] do
        assert {:error, ^reason} =
                 Management.pair_start(start_opts(open_pair: fn :pair -> {:error, reason} end))
      end
    end
  end

  describe "devices_list/1" do
    test "rows are oldest first, carry the v1 fields, and never key or token material" do
      newer = device("22222222-2222-4222-8222-222222222222", ~U[2026-09-02 12:00:00Z], "token")
      older = device("11111111-1111-4111-8111-111111111111", ~U[2026-09-01 12:00:00Z], nil)

      assert {:ok, [first, second]} =
               Management.devices_list(
                 serving_opts(list_devices: fn :store -> {:ok, [newer, older]} end)
               )

      assert first == %{
               device_id: older.device_id,
               name: "Pixel",
               model: "Google Pixel 9 Pro",
               platform: nil,
               signer_role: nil,
               boot_state: nil,
               push_registered: false,
               created_at: "2026-09-01T12:00:00Z",
               last_seen: nil
             }

      assert second.device_id == newer.device_id
      assert second.push_registered

      for row <- [first, second], key <- [:noise_pk, :push_token, :apns_key_salt] do
        refute Map.has_key?(row, key)
      end
    end

    test "at most 64 rows are listed" do
      devices =
        for index <- 1..65 do
          created_at = DateTime.add(~U[2026-09-01 00:00:00Z], index, :second)
          device("device-#{index}", created_at, nil)
        end

      assert {:ok, rows} =
               Management.devices_list(
                 serving_opts(list_devices: fn :store -> {:ok, devices} end)
               )

      assert length(rows) == 64
      assert List.first(rows).device_id == "device-1"
      assert List.last(rows).device_id == "device-64"
    end

    test "an enabled channel that has not started yet lists nothing, without a process call" do
      opts =
        serving_opts(
          whereis: fn :pair -> nil end,
          list_devices: fn _store -> flunk("the device store is not running") end
        )

      assert {:ok, []} = Management.devices_list(opts)
    end

    test "a failing device store is an error, not an empty list" do
      assert {:error, :disk_full} =
               Management.devices_list(
                 serving_opts(list_devices: fn :store -> {:error, :disk_full} end)
               )
    end
  end

  describe "devices_revoke/1" do
    test "revokes through the registry and names an unknown device" do
      test_pid = self()

      revoke = fn :registry, id ->
        send(test_pid, {:revoked, id})
        if id == "known", do: :ok, else: {:error, {:device_not_found, id}}
      end

      opts = serving_opts(device_registry: :registry, revoke_device: revoke)

      assert {:ok, %{device_id: "known"}} = Management.devices_revoke("known", opts)
      assert_received {:revoked, "known"}
      assert {:error, :device_not_found} = Management.devices_revoke("unknown", opts)
    end
  end

  describe "status/1" do
    test "with the channel off it answers from config alone, without a process call" do
      opts =
        [
          config: [enabled: false, port: 4_040, bind: "100.64.1.2", advertise_mdns: true],
          device_store: :store,
          load_identity: fn [] -> {:error, {:identity_artifact_missing, "gateway_key"}} end
        ] ++ Keyword.put(unreachable_processes(), :refusal, fn :store -> :none end)

      assert {:ok, status} = Management.status(opts)

      assert status == %{
               enabled: false,
               started: false,
               refused: false,
               listener: %{status: :down, port: 4_040, bind: "100.64.1.2", candidates: []},
               mdns: :disabled,
               tailnet: %{detected: false, candidates: []},
               identity: %{present: false, fingerprint: nil},
               apns: %{enabled: false, credentials: :missing},
               paired_devices: 0,
               protocol_version: FermixChannels.Mobile.Protocol.protocol_version(),
               pairing: nil
             }
    end

    test "a refused surface or a subtree not started yet answers without a process call" do
      identity = fn [] -> {:ok, %{gateway_public_key: <<7::256>>}} end
      base = [config: [enabled: true], device_store: :store, load_identity: identity]

      refused =
        base ++ Keyword.put(unreachable_processes(), :refusal, fn :store -> {:error, :bad} end)

      not_started =
        base ++
          Keyword.merge(unreachable_processes(),
            refusal: fn :store -> :none end,
            whereis: fn _manager -> nil end
          )

      for {opts, refused?} <- [{refused, true}, {not_started, false}] do
        assert {:ok, status} = Management.status(opts)
        assert status.enabled
        refute status.started
        assert status.refused == refused?
        assert status.listener == %{status: :down, port: 4_031, bind: "0.0.0.0", candidates: []}
        assert status.mdns == :down
        assert status.paired_devices == 0
        assert status.pairing == nil
        assert status.identity.present
      end
    end

    test "while running, a read that fails is an error, never an empty fact" do
      running = fn override ->
        serving_opts(Keyword.merge([list_devices: fn :store -> {:ok, []} end], override))
      end

      assert {:ok, _status} = Management.status(running.([]))

      assert {:error, :eperm} =
               Management.status(running.(discover: fn -> {:error, :eperm} end))

      assert {:error, {:device_store_unavailable, :disk_full}} =
               Management.status(running.(list_devices: fn :store -> {:error, :disk_full} end))

      timeout = fn :pair -> exit({:timeout, {GenServer, :call, [:pair, :latest, 5_000]}}) end

      assert {:error, {:dependency_exit, :latest_pair, {:timeout, _call}}} =
               Management.status(running.(latest_pair: timeout))
    end

    test "a running channel reports the listener, reachability, devices and window" do
      record = %{
        session_id: "pair-session",
        status: :rate_limited,
        remaining_ms: nil,
        request: nil,
        device_id: nil
      }

      opts =
        serving_opts(
          config: [enabled: true, advertise_mdns: false, push: [enabled: false]],
          listener_status: fn :listener -> {:listening, {{0, 0, 0, 0}, 40_321}} end,
          discover: fn ->
            {:ok,
             [
               %{address: "192.168.1.8", interface: "en0", scope: :lan},
               %{address: "100.64.1.2", interface: "utun4", scope: :tailnet}
             ]}
          end,
          list_devices: fn :store -> {:ok, [%{}, %{}]} end,
          latest_pair: fn :pair -> {:ok, record} end,
          load_identity: fn [] -> {:ok, %{gateway_public_key: <<7::256>>}} end
        )

      assert {:ok, status} = Management.status(opts)
      assert status.enabled
      assert status.started
      refute status.refused

      assert status.listener == %{
               status: :ready,
               port: 40_321,
               bind: "0.0.0.0",
               candidates: ["wss://192.168.1.8:40321/ws", "wss://100.64.1.2:40321/ws"]
             }

      assert status.mdns == :disabled
      assert status.tailnet == %{detected: true, candidates: ["100.64.1.2"]}
      assert status.paired_devices == 2
      assert status.pairing == %{session_id: "pair-session", state: :failed}
      assert status.identity == %{present: true, fingerprint: grouped_sha256(<<7::256>>)}
    end

    test "the identity fingerprint is the grouped SHA-256 of the gateway key" do
      fingerprint = grouped_sha256(<<7::256>>)
      groups = String.split(fingerprint, " ")

      assert length(groups) == 16
      assert Enum.all?(groups, &Regex.match?(~r/\A[0-9a-f]{4}\z/, &1))
    end

    test "missing, incomplete or unreadable identity reads as absent" do
      for result <- [
            {:error, :missing},
            {:error, {:identity_incomplete, ["/home/o/.fermix/mobile/tls.crt"]}},
            {:error, {:identity_unreadable, "/home/o/.fermix/mobile", :eacces}}
          ] do
        opts = [
          config: [enabled: false],
          device_store: :store,
          refusal: fn :store -> :none end,
          load_identity: fn [] -> result end
        ]

        assert {:ok, %{identity: %{present: false, fingerprint: nil}}} = Management.status(opts)
      end
    end
  end

  defp submit_request(ctx, socket \\ self()) do
    assert {:ok, _request} =
             PairManager.submit_request(ctx.manager, "pair-session", %{
               name: "Pixel 9 Pro",
               model: "Google Pixel 9 Pro",
               app_version: "1.0.0",
               noise_pk: <<5::256>>,
               sas: "481062",
               socket_pid: socket
             })
  end

  defp start_opts(overrides) do
    window = %{
      session_id: "pair-session",
      secret: <<3::256>>,
      identity: %{gateway_public_key: <<1::256>>, tls_fingerprint: <<2::256>>},
      opened_at_ms: 0,
      expires_at_ms: 120_000
    }

    Keyword.merge(
      [
        config: [enabled: true],
        pair_manager: :pair,
        listener: :listener,
        device_store: :store,
        refusal: fn :store -> :none end,
        whereis: fn :pair -> self() end,
        open_pair: fn :pair -> {:ok, window} end,
        listener_info: fn :listener -> {:ok, {{0, 0, 0, 0}, 40_321}} end,
        discover: fn -> {:ok, []} end,
        host_label: fn -> "workstation" end,
        cancel_pair: fn :pair, "pair-session" -> :ok end
      ],
      overrides
    )
  end

  defp serving_opts(overrides) do
    Keyword.merge(
      [
        config: [enabled: true],
        pair_manager: :pair,
        listener: :listener,
        mdns_advertiser: :mdns,
        device_store: :store,
        refusal: fn :store -> :none end,
        whereis: fn :pair -> self() end,
        listener_status: fn :listener -> :dormant end,
        mdns_status: fn :mdns -> :disabled end,
        discover: fn -> {:ok, []} end,
        latest_pair: fn :pair -> :none end,
        load_identity: fn [] -> {:error, :missing} end
      ],
      overrides
    )
  end

  # Every process-backed seam fails the test: a verb that must answer before
  # reaching the mobile subtree proves it by never calling one.
  defp unreachable_processes do
    unreachable = fn name -> fn _args -> flunk("#{name} must not be called") end end

    [
      refusal: unreachable.(:refusal),
      whereis: unreachable.(:whereis),
      open_pair: unreachable.(:open_pair),
      pair_session: fn _manager, _id -> flunk("pair_session must not be called") end,
      approve_pair: fn _manager, _id -> flunk("approve_pair must not be called") end,
      deny_pair: fn _manager, _id -> flunk("deny_pair must not be called") end,
      cancel_pair: fn _manager, _id -> flunk("cancel_pair must not be called") end,
      revoke_device: fn _registry, _id -> flunk("revoke_device must not be called") end,
      list_devices: unreachable.(:list_devices),
      listener_status: unreachable.(:listener_status),
      listener_info: unreachable.(:listener_info),
      mdns_status: unreachable.(:mdns_status),
      latest_pair: unreachable.(:latest_pair),
      discover: fn -> flunk("discover must not be called") end
    ]
  end

  defp device(device_id, created_at, push_token) do
    %{
      device_id: device_id,
      name: "Pixel",
      model: "Google Pixel 9 Pro",
      noise_pk: <<5::256>>,
      push_token: push_token,
      created_at: created_at,
      last_seen: nil,
      apns_key_salt: <<6::256>>
    }
  end

  defp grouped_sha256(key) do
    :sha256
    |> :crypto.hash(key)
    |> Base.encode16(case: :lower)
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join(" ", &Enum.join/1)
  end
end
