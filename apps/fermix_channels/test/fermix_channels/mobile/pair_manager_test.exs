defmodule FermixChannels.Mobile.PairManagerTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.PairManager

  @ttl_ms 120_000

  setup do
    test_pid = self()
    clock = start_supervised!({Agent, fn -> 10_000 end})

    timer = fn message, delay ->
      ref = make_ref()
      send(test_pid, {:timer_armed, ref, message, delay})
      ref
    end

    cancel_timer = fn ref ->
      send(test_pid, {:timer_cancelled, ref})
      :ok
    end

    opts = [
      name: :"pair_manager_#{System.unique_integer([:positive])}",
      clock: fn -> Agent.get(clock, & &1) end,
      wall_clock: fn -> ~U[2026-08-12 20:00:00Z] end,
      schedule_timer: timer,
      cancel_timer: cancel_timer,
      ensure_identity: fn ->
        send(test_pid, :identity_ensured)
        {:ok, %{gateway_public_key: <<1::256>>}}
      end,
      activate_listener: fn identity ->
        send(test_pid, {:listener_activated, identity})
        :ok
      end,
      persist_device: fn device ->
        send(test_pid, {:device_persisted, device})
        {:ok, Map.put(device, :persisted, true)}
      end,
      emit_pair: fn status, duration_us ->
        send(test_pid, {:pair_telemetry, status, duration_us})
        :ok
      end,
      session_id_generator: fn -> "pair-session" end,
      device_id_generator: fn -> "device-id" end,
      secret_generator: fn -> <<2::256>> end,
      salt_generator: fn -> <<3::256>> end
    ]

    manager = start_supervised!({PairManager, opts})
    %{clock: clock, manager: manager}
  end

  test "opens one bounded in-memory window after identity and listener activation", ctx do
    assert {:ok, window} = PairManager.open(ctx.manager)
    assert window.session_id == "pair-session"
    assert window.secret == <<2::256>>
    assert window.expires_at_ms == 10_000 + @ttl_ms

    assert_receive :identity_ensured
    assert_receive {:listener_activated, %{gateway_public_key: <<1::256>>}}
    assert_receive {:timer_armed, _ref, {:pair_expire, "pair-session", _token}, @ttl_ms}
    refute_receive {:device_persisted, _device}
    assert {:error, :pairing_active} = PairManager.open(ctx.manager)
  end

  test "submits one request, wakes the terminal waiter, and persists only approved device data",
       ctx do
    assert {:ok, _window} = PairManager.open(ctx.manager)

    waiter = Task.async(fn -> PairManager.await_request(ctx.manager, "pair-session", 1_000) end)
    assert_waiter_registered(ctx.manager, :request_waiter)

    assert {:ok, request} =
             PairManager.submit_request(ctx.manager, "pair-session", request_attrs())

    assert request.name == "Sujeeth's iPhone"
    refute Map.has_key?(request, :socket_pid)
    assert {:ok, ^request} = Task.await(waiter)

    decision =
      Task.async(fn -> PairManager.await_decision(ctx.manager, "pair-session", 1_000) end)

    assert_waiter_registered(ctx.manager, :decision_waiter)

    assert {:ok, approved} = PairManager.approve(ctx.manager, "pair-session")
    assert approved.persisted
    assert approved.device_id == "device-id"

    assert_receive {:device_persisted, persisted}
    assert persisted.name == "Sujeeth's iPhone"
    assert persisted.noise_pk == <<4::256>>
    assert persisted.apns_key_salt == <<3::256>>
    assert persisted.created_at == ~U[2026-08-12 20:00:00Z]
    refute Map.has_key?(persisted, :secret)
    refute Map.has_key?(persisted, :session_id)
    refute Map.has_key?(persisted, :sas)

    assert {:ok, %{approved: true, device: ^approved}} = Task.await(decision)
    assert_receive {:mobile_pair_decision, "pair-session", {:ok, ^approved}}
    assert_receive {:pair_telemetry, :approved, 0}
    assert :none = PairManager.current(ctx.manager)
  end

  test "denial is terminal, wakes the device, and never persists", ctx do
    assert {:ok, _window} = PairManager.open(ctx.manager)

    assert {:ok, _request} =
             PairManager.submit_request(ctx.manager, "pair-session", request_attrs())

    decision =
      Task.async(fn -> PairManager.await_decision(ctx.manager, "pair-session", 1_000) end)

    assert_waiter_registered(ctx.manager, :decision_waiter)

    assert :ok = PairManager.deny(ctx.manager, "pair-session")
    assert {:error, :denied} = Task.await(decision)
    assert_receive {:mobile_pair_decision, "pair-session", {:error, :denied}}
    assert_receive {:pair_telemetry, :denied, 0}
    refute_receive {:device_persisted, _device}
    assert :none = PairManager.current(ctx.manager)
  end

  test "the fifth failed handshake closes the window with no persistent lockout", ctx do
    assert {:ok, _window} = PairManager.open(ctx.manager)

    for count <- 1..4 do
      assert {:ok, ^count} = PairManager.record_failure(ctx.manager, "pair-session")
    end

    assert {:error, :rate_limited} = PairManager.record_failure(ctx.manager, "pair-session")
    assert_receive {:pair_telemetry, :rate_limited, 0}
    assert :none = PairManager.current(ctx.manager)

    # A new explicit owner command starts a fresh bounded window.
    assert {:ok, _window} = PairManager.open(ctx.manager)
  end

  test "expiry is deterministic and stale expiry messages cannot close a newer window", ctx do
    assert {:ok, first} = PairManager.open(ctx.manager)
    Agent.update(ctx.clock, fn _ -> first.expires_at_ms end)

    assert :none = PairManager.current(ctx.manager)
    assert_receive {:pair_telemetry, :expired, 120_000_000}

    assert {:ok, second} = PairManager.open(ctx.manager)
    send(ctx.manager, {:pair_expire, first.session_id, make_ref()})
    assert {:ok, %{session_id: session_id}} = PairManager.current(ctx.manager)
    assert session_id == second.session_id
  end

  test "identity or listener activation failure never opens a pairing window" do
    identity_failure =
      start_supervised!(
        {PairManager,
         name: :pair_identity_failure,
         ensure_identity: fn -> {:error, :identity_broken} end,
         activate_listener: fn _identity -> flunk("listener must not run") end},
        id: :pair_identity_failure
      )

    assert {:error, :identity_broken} = PairManager.open(identity_failure)
    assert :none = PairManager.current(identity_failure)

    listener_failure =
      start_supervised!(
        {PairManager,
         name: :pair_listener_failure,
         ensure_identity: fn -> {:ok, %{identity: true}} end,
         activate_listener: fn _identity -> {:error, :bind_failed} end},
        id: :pair_listener_failure
      )

    assert {:error, :bind_failed} = PairManager.open(listener_failure)
    assert :none = PairManager.current(listener_failure)
  end

  test "missing identity is generated only while the durable device store is pristine" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("pair-pristine-identity")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)

    manager =
      start_supervised!(
        {PairManager,
         name: nil,
         root: root,
         device_store: nil,
         activate_listener: fn _identity -> :ok end},
        id: make_ref()
      )

    assert {:ok, _window} = PairManager.open(manager)
    assert {:ok, identity} = Identity.load(root: root)
    assert byte_size(identity.gateway_private_key) == 32
  end

  test "missing identity with paired devices fails loud instead of rotating keys" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("pair-lost-identity")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)

    attrs = %{
      device_id: "91d72be6-c253-4b73-8598-91c03f66b9d0",
      name: "Phone",
      model: "iPhone17,1",
      noise_pk: <<4::256>>,
      push_token: nil,
      created_at: ~U[2026-08-12 20:00:00Z],
      last_seen: nil,
      apns_key_salt: <<3::256>>
    }

    assert {:ok, _device} = DeviceStore.add(attrs, root: root)

    manager =
      start_supervised!(
        {PairManager,
         name: nil,
         root: root,
         device_store: nil,
         activate_listener: fn _identity -> flunk("listener must stay dormant") end},
        id: make_ref()
      )

    assert {:error, {:identity_missing_for_paired_devices, 1}} = PairManager.open(manager)
    assert {:ok, paths} = Identity.paths(root: root)
    assert {:error, :enoent} = File.lstat(paths.gateway_key)
    assert {:error, :enoent} = File.lstat(paths.tls_key)
    assert {:error, :enoent} = File.lstat(paths.tls_cert)
  end

  defp request_attrs do
    %{
      name: "Sujeeth's iPhone",
      model: "iPhone17,1",
      app_version: "1.0",
      noise_pk: <<4::256>>,
      sas: "047291",
      socket_pid: self()
    }
  end

  defp assert_waiter_registered(manager, key, attempts \\ 50)
  defp assert_waiter_registered(_manager, _key, 0), do: flunk("waiter was not registered")

  defp assert_waiter_registered(manager, key, attempts) do
    if get_in(:sys.get_state(manager), [:window, key]) do
      :ok
    else
      Process.sleep(5)
      assert_waiter_registered(manager, key, attempts - 1)
    end
  end
end
