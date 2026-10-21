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
      emit_pair: fn status, duration_us, facts ->
        send(test_pid, {:pair_telemetry, status, duration_us})
        send(test_pid, {:pair_facts, status, facts})
        :ok
      end,
      status_fetch: &fresh_statuses/0,
      session_id_generator: fn -> "pair-session" end,
      device_id_generator: fn -> "device-id" end,
      secret_generator: fn -> <<2::256>> end,
      salt_generator: fn -> <<3::256>> end
    ]

    manager = start_supervised!({PairManager, opts})
    %{clock: clock, manager: manager, opts: opts}
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
    assert persisted.platform == "android"
    assert persisted.signer_role == :development
    assert persisted.version_code == 42
    assert persisted.boot_state == :verified
    assert persisted.device_locked == true
    refute Map.has_key?(persisted, :secret)
    refute Map.has_key?(persisted, :session_id)
    refute Map.has_key?(persisted, :sas)

    assert {:ok, %{approved: true, device: ^approved}} = Task.await(decision)
    assert_receive {:mobile_pair_decision, "pair-session", {:ok, ^approved}}
    assert_receive {:pair_telemetry, :approved, 0}

    assert_receive {:pair_facts, :approved,
                    %{platform: :android, attestation: :verified, signer_role: :development}}

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

  test "device text that could rewrite the operator's approval prompt never enters the window",
       ctx do
    assert {:ok, _window} = PairManager.open(ctx.manager)

    assert {:error, {:invalid_pair_request, {:name, :control_characters}}} =
             submit(ctx, %{name: "\e[2K\rApproved: iPhone 16 Pro"})

    # U+009B is the single-byte C1 introducer; terminals honour it like ESC-[.
    assert {:error, {:invalid_pair_request, {:model, :control_characters}}} =
             submit(ctx, %{model: "iPhone\u{009B}2K"})

    assert {:error, {:invalid_pair_request, {:app_version, :invalid_utf8}}} =
             submit(ctx, %{app_version: <<0xFF, 0xFE>>})

    assert {:ok, %{request: nil}} = PairManager.current(ctx.manager)
  end

  # The owner reads the platform beside the code to compare, so only the
  # phone's own two words enter the window.
  test "a request names the platform the phone runs on, one of the two a phone can be", ctx do
    assert {:ok, _window} = PairManager.open(ctx.manager)

    for platform <- ["windows", "", nil] do
      assert {:error, {:invalid_pair_request, :platform}} =
               submit(ctx, %{platform: platform})
    end

    assert {:ok, %{platform: "android"}} = submit(ctx, %{platform: "android"})

    assert {:ok, %{request: %{platform: "android"}}} =
             PairManager.session(ctx.manager, "pair-session")
  end

  # M51 D3: only a phone whose attestation was verified reaches the owner, and
  # what the verification found travels with its request to the device row.
  test "a request without verified attestation facts is refused at intake", ctx do
    assert {:ok, _window} = PairManager.open(ctx.manager)

    for attestation <- [
          nil,
          %{},
          %{facts() | boot_state: :unverified},
          %{facts() | device_locked: false},
          %{facts() | signer_role: :stranger},
          %{facts() | platform: "ios"}
        ] do
      assert {:error, {:invalid_pair_request, :attestation}} =
               submit(ctx, %{attestation: attestation})
    end

    assert {:ok, %{request: nil}} = PairManager.current(ctx.manager)
    assert {:ok, %{attestation: %{signer_role: :development}}} = submit(ctx, %{})
  end

  test "one intake bound rejects oversized device text before the owner is prompted", ctx do
    assert {:ok, _window} = PairManager.open(ctx.manager)

    assert {:error, {:invalid_pair_request, {:name, :too_long}}} =
             submit(ctx, %{name: String.duplicate("a", 129)})

    assert {:error, {:invalid_pair_request, {:model, :too_long}}} =
             submit(ctx, %{model: String.duplicate("b", 129)})

    assert {:error, {:invalid_pair_request, {:app_version, :too_long}}} =
             submit(ctx, %{app_version: String.duplicate("c", 129)})

    assert {:ok, request} = submit(ctx, %{name: String.duplicate("a", 128)})
    assert byte_size(request.name) == 128
  end

  test "approving after the phone disconnects closes the window instead of writing an orphan device",
       ctx do
    assert {:ok, _window} = PairManager.open(ctx.manager)
    socket = spawn(fn -> receive do: (:stop -> :ok) end)
    assert {:ok, _request} = submit(ctx, %{socket_pid: socket})
    stop_socket(socket)

    assert {:error, :device_disconnected} = PairManager.approve(ctx.manager, "pair-session")
    refute_receive {:device_persisted, _device}
    assert_receive {:pair_telemetry, :device_disconnected, 0}

    # The phone never learns a device id, so the ceremony is over: nothing is
    # left to approve, and the CLI's cleanup cancel is a no-op.
    assert :none = PairManager.current(ctx.manager)

    assert {:ok, %{status: :device_disconnected}} =
             PairManager.session(ctx.manager, "pair-session")

    assert :ok = PairManager.cancel(ctx.manager, "pair-session")
    refute_receive {:pair_telemetry, _status, _duration_us}
  end

  test "cancelling an expired window is a clean no-op while deny still fails loud", ctx do
    assert {:ok, window} = PairManager.open(ctx.manager)
    Agent.update(ctx.clock, fn _ -> window.expires_at_ms end)

    assert :ok = PairManager.cancel(ctx.manager, "pair-session")
    assert_receive {:pair_telemetry, :expired, 120_000_000}
    assert {:error, :session_not_found} = PairManager.deny(ctx.manager, "pair-session")
  end

  test "cancelling a live window is terminal for the waiting device", ctx do
    assert {:ok, _window} = PairManager.open(ctx.manager)
    assert {:ok, _request} = submit(ctx, %{})

    decision =
      Task.async(fn -> PairManager.await_decision(ctx.manager, "pair-session", 1_000) end)

    assert_waiter_registered(ctx.manager, :decision_waiter)

    assert :ok = PairManager.cancel(ctx.manager, "pair-session")
    assert {:error, :cancelled} = Task.await(decision)
    assert_receive {:mobile_pair_decision, "pair-session", {:error, :cancelled}}
    assert_receive {:pair_telemetry, :cancelled, 0}
    assert :none = PairManager.current(ctx.manager)
  end

  # One noisy peer on the network must not be able to abort pairing for the
  # owner's phone (SEC-8): its fifth failure refuses that address alone.
  test "the fifth failed handshake from one address refuses that address only", ctx do
    assert {:ok, _window} = PairManager.open(ctx.manager)
    noisy = {192, 168, 1, 66}

    for count <- 1..4 do
      assert {:ok, ^count} = PairManager.record_failure(ctx.manager, "pair-session", noisy)
    end

    assert {:error, :rate_limited} =
             PairManager.record_failure(ctx.manager, "pair-session", noisy)

    assert :none = PairManager.current(ctx.manager, noisy)
    assert {:ok, %{session_id: "pair-session"}} = PairManager.current(ctx.manager, {10, 0, 0, 2})
    refute_receive {:pair_telemetry, :rate_limited, _duration_us}

    # A refused address stays refused for the rest of this window only.
    assert {:error, :rate_limited} =
             PairManager.record_failure(ctx.manager, "pair-session", noisy)

    assert {:ok, 1} = PairManager.record_failure(ctx.manager, "pair-session", {10, 0, 0, 3})
  end

  # M62 §7: an iroh peer is a key that costs nothing to replace, so failures
  # summed over every iroh peer refuse iroh peers for the rest of the window,
  # and nobody else.
  test "past 64 failures from iroh peers, iroh peers get no window; addresses still do", ctx do
    assert {:ok, _window} = PairManager.open(ctx.manager)

    for n <- 1..64 do
      peer = {:iroh, n |> Integer.to_string() |> String.pad_leading(64, "0")}
      assert {:ok, 1} = PairManager.record_failure(ctx.manager, "pair-session", peer)
    end

    fresh = {:iroh, String.duplicate("f", 64)}
    assert :none = PairManager.current(ctx.manager, fresh)
    assert {:ok, %{session_id: "pair-session"}} = PairManager.current(ctx.manager, {10, 0, 0, 2})
    assert {:ok, %{status: :awaiting_scan}} = PairManager.session(ctx.manager, "pair-session")
  end

  # R1-5: handshake garbage needs neither the pairing secret nor the gateway
  # key, so a window-wide failure budget let anyone with a few addresses end
  # every window before the owner's phone scanned it.
  test "failed handshakes from any number of addresses never close the window", ctx do
    assert {:ok, _window} = PairManager.open(ctx.manager)
    fail_from_many_addresses(ctx)

    refute_received {:pair_telemetry, _status, _duration_us}
    assert {:ok, %{status: :awaiting_scan}} = PairManager.session(ctx.manager, "pair-session")
    assert :none = PairManager.current(ctx.manager, {192, 168, 1, 1})
    assert {:ok, %{session_id: "pair-session"}} = PairManager.current(ctx.manager, {10, 0, 0, 2})

    assert {:ok, _request} = submit(ctx, %{})
    assert {:ok, _device} = PairManager.approve(ctx.manager, "pair-session")
  end

  # Without a window-wide close nothing else bounds how many addresses a
  # window remembers; an address past the bound is simply not counted.
  test "the addresses one window remembers are bounded", ctx do
    assert {:ok, _window} = PairManager.open(ctx.manager)
    bound = PairManager.max_tracked_sources()
    assert bound == 1_024

    for host <- 1..bound do
      source = {10, 1, div(host, 256), rem(host, 256)}
      assert {:ok, 1} = PairManager.record_failure(ctx.manager, "pair-session", source)
    end

    untracked = {10, 9, 9, 9}

    for _attempt <- 1..6 do
      assert {:ok, 0} = PairManager.record_failure(ctx.manager, "pair-session", untracked)
    end

    assert {:ok, _window} = PairManager.current(ctx.manager, untracked)
    assert map_size(:sys.get_state(ctx.manager).window.failures_by_source) == bound

    # An address already remembered is still counted to its refusal.
    known = {10, 1, 0, 1}

    for count <- 2..4 do
      assert {:ok, ^count} = PairManager.record_failure(ctx.manager, "pair-session", known)
    end

    assert {:error, :rate_limited} =
             PairManager.record_failure(ctx.manager, "pair-session", known)
  end

  # Once a phone is waiting for the owner, nothing a stranger sends may end the
  # ceremony; the owner's decision is the only gate left (SEC-8).
  test "no failure closes a window whose request awaits the owner's decision", ctx do
    assert {:ok, _window} = PairManager.open(ctx.manager)
    assert {:ok, _request} = submit(ctx, %{})
    fail_from_many_addresses(ctx)

    refute_receive {:pair_telemetry, :rate_limited, _duration_us}
    assert {:ok, %{status: :awaiting_decision}} = PairManager.session(ctx.manager, "pair-session")
    assert {:ok, _device} = PairManager.approve(ctx.manager, "pair-session")
  end

  # The phone lost its network without a FIN while the owner decided: its new
  # connection, proven by the same Noise key, takes the request over instead of
  # being refused as a second request (STB-13).
  test "the same phone reconnecting takes over its waiting request", ctx do
    assert {:ok, _window} = PairManager.open(ctx.manager)
    stale = spawn(fn -> receive do: (:stop -> :ok) end)
    assert {:ok, _request} = submit(ctx, %{socket_pid: stale, sas: "111111"})

    assert {:ok, %{sas: "222222"}} = submit(ctx, %{socket_pid: self(), sas: "222222"})
    assert_socket_replaced(stale)

    assert {:ok, %{request: %{sas: "222222"}}} =
             PairManager.session(ctx.manager, "pair-session")

    assert {:ok, device} = PairManager.approve(ctx.manager, "pair-session")
    assert_receive {:mobile_pair_decision, "pair-session", {:ok, ^device}}
  end

  test "a different phone still cannot replace the waiting request", ctx do
    assert {:ok, _window} = PairManager.open(ctx.manager)
    assert {:ok, _request} = submit(ctx, %{})

    assert {:error, :request_pending} = submit(ctx, %{noise_pk: <<9::256>>, sas: "333333"})
    assert {:ok, %{request: %{sas: "047291"}}} = PairManager.session(ctx.manager, "pair-session")
  end

  # The phone and the management wire name each ending with one word; the
  # phone's Expired screen keys on `timeout` (FEAT-9).
  test "the phone is told a window that ran out ended in timeout", ctx do
    assert {:ok, window} = PairManager.open(ctx.manager)
    assert {:ok, _request} = submit(ctx, %{})
    Agent.update(ctx.clock, fn _ -> window.expires_at_ms end)

    assert :none = PairManager.current(ctx.manager)
    assert_receive {:mobile_pair_decision, "pair-session", {:error, :timeout}}
    assert {:ok, %{status: :expired}} = PairManager.session(ctx.manager, "pair-session")
  end

  test "each ending has one word on every wire" do
    assert PairManager.outcome_reason(:approved) == :approved
    assert PairManager.outcome_reason(:denied) == :denied
    assert PairManager.outcome_reason(:expired) == :timeout
    assert PairManager.outcome_reason(:cancelled) == :cancelled
    assert PairManager.outcome_reason(:device_disconnected) == :device_disconnected

    # Failed handshakes refuse only their own address and never end a window.
    assert_raise FunctionClauseError, fn -> PairManager.outcome_reason(:rate_limited) end
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

  test "identity or listener activation failure never opens a pairing window, named by step" do
    identity_failure =
      start_supervised!(
        {PairManager,
         name: :pair_identity_failure,
         ensure_identity: fn -> {:error, :identity_broken} end,
         activate_listener: fn _identity -> flunk("listener must not run") end},
        id: :pair_identity_failure
      )

    assert {:error, {:identity, :identity_broken}} = PairManager.open(identity_failure)
    assert :none = PairManager.current(identity_failure)

    guard_failure =
      start_supervised!(
        {PairManager,
         name: :pair_guard_failure,
         identity_guard: fn -> {:error, :identity_state_unreadable} end,
         ensure_identity: fn -> flunk("identity must not be ensured") end},
        id: :pair_guard_failure
      )

    assert {:error, {:identity, :identity_state_unreadable}} = PairManager.open(guard_failure)
    assert :none = PairManager.current(guard_failure)

    listener_failure =
      start_supervised!(
        {PairManager,
         name: :pair_listener_failure,
         ensure_identity: fn -> {:ok, %{identity: true}} end,
         activate_listener: fn _identity -> {:error, :bind_failed} end},
        id: :pair_listener_failure
      )

    assert {:error, {:listener, :bind_failed}} = PairManager.open(listener_failure)
    assert :none = PairManager.current(listener_failure)
  end

  test "generated ids and random bytes keep their own errors, untagged", ctx do
    bad_id =
      start_supervised!(
        {PairManager, Keyword.merge(ctx.opts, name: nil, session_id_generator: fn -> "" end)},
        id: :pair_bad_id
      )

    assert {:error, {:invalid_generated_id, ""}} = PairManager.open(bad_id)

    bad_secret =
      start_supervised!(
        {PairManager, Keyword.merge(ctx.opts, name: nil, secret_generator: fn -> <<1>> end)},
        id: :pair_bad_secret
      )

    assert {:error, :invalid_random_bytes} = PairManager.open(bad_secret)
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
         activate_listener: fn _identity -> :ok end,
         status_fetch: &fresh_statuses/0},
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

    assert {:error, {:identity, {:identity_missing_for_paired_devices, 1}}} =
             PairManager.open(manager)

    assert {:ok, paths} = Identity.paths(root: root)
    assert {:error, :enoent} = File.lstat(paths.gateway_key)
    assert {:error, :enoent} = File.lstat(paths.tls_key)
    assert {:error, :enoent} = File.lstat(paths.tls_cert)
  end

  # The default id generator wrote uppercase hex, which the trust store refuses
  # as an invalid UUID, so every approval through the real store failed.
  test "an approval through the real trust store persists a canonical device id" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("pair-canonical-id")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)

    manager =
      start_supervised!(
        {PairManager,
         name: nil,
         root: root,
         device_store: nil,
         ensure_identity: fn -> {:ok, %{gateway_public_key: <<1::256>>}} end,
         activate_listener: fn _identity -> :ok end,
         emit_pair: fn _status, _duration_us, _facts -> :ok end,
         status_fetch: &fresh_statuses/0},
        id: make_ref()
      )

    assert {:ok, window} = PairManager.open(manager)

    assert {:ok, _request} =
             PairManager.submit_request(manager, window.session_id, request_attrs())

    monitor = Process.monitor(manager)
    assert {:ok, device} = PairManager.approve(manager, window.session_id)
    assert device.device_id == String.downcase(device.device_id)
    assert {:ok, [_stored]} = DeviceStore.list(root: root)

    # The store's file was written from the manager's own process, and any
    # linked exit stops the manager: the write links it to nothing.
    refute_receive {:DOWN, ^monitor, :process, ^manager, _reason}, 200
  end

  # The half-open case the takeover cannot reach: the owner approved while the
  # phone was unreachable, so the row exists and the phone never learned its
  # id. Approving the same phone again must not be refused as a duplicate.
  test "re-approving a phone whose first approval never reached it replaces the orphan" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("pair-orphan")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)

    orphan = %{
      device_id: "91d72be6-c253-4b73-8598-91c03f66b9d0",
      name: "Phone",
      model: "iPhone17,1",
      noise_pk: <<4::256>>,
      push_token: nil,
      created_at: ~U[2026-08-12 20:00:00Z],
      last_seen: nil,
      apns_key_salt: <<3::256>>
    }

    assert {:ok, _device} = DeviceStore.add(orphan, root: root)

    manager =
      start_supervised!(
        {PairManager,
         name: nil,
         root: root,
         device_store: nil,
         ensure_identity: fn -> {:ok, %{gateway_public_key: <<1::256>>}} end,
         activate_listener: fn _identity -> :ok end,
         emit_pair: fn _status, _duration_us, _facts -> :ok end,
         status_fetch: &fresh_statuses/0},
        id: make_ref()
      )

    assert {:ok, window} = PairManager.open(manager)

    assert {:ok, _request} =
             PairManager.submit_request(manager, window.session_id, request_attrs())

    assert {:ok, device} = PairManager.approve(manager, window.session_id)
    refute device.device_id == orphan.device_id
    assert {:ok, [stored]} = DeviceStore.list(root: root)
    assert stored.device_id == device.device_id
  end

  describe "session/2 walks every state of the pairing ceremony" do
    test "an open window without a request awaits the scan and counts down", ctx do
      assert {:ok, _window} = PairManager.open(ctx.manager)

      assert {:ok, record} = PairManager.session(ctx.manager, "pair-session")

      assert record == %{
               session_id: "pair-session",
               status: :awaiting_scan,
               remaining_ms: @ttl_ms,
               request: nil,
               device_id: nil,
               refusal: nil
             }

      advance(ctx, 1_500)
      assert {:ok, %{remaining_ms: 118_500}} = PairManager.session(ctx.manager, "pair-session")
    end

    test "a submitted request awaits the owner's decision without the socket", ctx do
      assert {:ok, _window} = PairManager.open(ctx.manager)
      assert {:ok, _request} = submit(ctx, %{})

      assert {:ok, %{status: :awaiting_decision, request: request, device_id: nil}} =
               PairManager.session(ctx.manager, "pair-session")

      assert request.name == "Sujeeth's iPhone"
      assert request.sas == "047291"
      refute Map.has_key?(request, :socket_pid)
    end

    test "approval is retained with the device id and the request it approved", ctx do
      assert {:ok, _window} = PairManager.open(ctx.manager)
      assert {:ok, _request} = submit(ctx, %{})
      assert {:ok, _device} = PairManager.approve(ctx.manager, "pair-session")

      assert {:ok, record} = PairManager.session(ctx.manager, "pair-session")
      assert record.status == :approved
      assert record.device_id == "device-id"
      assert record.remaining_ms == nil
      assert record.request.name == "Sujeeth's iPhone"
    end

    test "denial is retained", ctx do
      assert {:ok, _window} = PairManager.open(ctx.manager)
      assert {:ok, _request} = submit(ctx, %{})
      assert :ok = PairManager.deny(ctx.manager, "pair-session")

      assert {:ok, %{status: :denied, remaining_ms: nil, device_id: nil}} =
               PairManager.session(ctx.manager, "pair-session")
    end

    test "the end of the window reads as expired even before its timer fires", ctx do
      assert {:ok, window} = PairManager.open(ctx.manager)
      Agent.update(ctx.clock, fn _ -> window.expires_at_ms end)

      assert {:ok, %{status: :expired, remaining_ms: nil}} =
               PairManager.session(ctx.manager, "pair-session")

      assert_receive {:pair_telemetry, :expired, 120_000_000}
    end

    test "cancel is retained as cancelled", ctx do
      assert {:ok, _window} = PairManager.open(ctx.manager)
      assert :ok = PairManager.cancel(ctx.manager, "pair-session")

      assert {:ok, %{status: :cancelled, remaining_ms: nil}} =
               PairManager.session(ctx.manager, "pair-session")
    end

    test "an id this manager never opened is unknown", ctx do
      assert :unknown = PairManager.session(ctx.manager, "pair-session")
      assert {:ok, _window} = PairManager.open(ctx.manager)
      assert :unknown = PairManager.session(ctx.manager, "another-session")
    end

    test "a second window is refused while one is open and allowed once it closed", ctx do
      assert {:ok, _window} = PairManager.open(ctx.manager)
      assert {:error, :pairing_active} = PairManager.open(ctx.manager)
      assert :ok = PairManager.cancel(ctx.manager, "pair-session")
      assert {:ok, _window} = PairManager.open(ctx.manager)
    end
  end

  describe "a refused attestation ends the session" do
    # MILESTONE_51_MANAGEMENT_MOBILE_PAIRING §4: a refused proof never reaches
    # the owner; the session ends failed, and everything waiting on it learns
    # why in the phone's own word.
    test "a refused proof closes the window as failed with the check that refused it", ctx do
      assert {:ok, _window} = PairManager.open(ctx.manager)
      waiter = Task.async(fn -> PairManager.await_request(ctx.manager, "pair-session", 1_000) end)
      assert_waiter_registered(ctx.manager, :request_waiter)

      assert :ok =
               PairManager.refuse(
                 ctx.manager,
                 "pair-session",
                 refusal(:attestation, :root_of_trust)
               )

      assert {:error, :attestation} = Task.await(waiter)
      assert :none = PairManager.current(ctx.manager)

      assert {:ok, record} = PairManager.session(ctx.manager, "pair-session")
      assert record.status == :attestation
      assert record.request == nil
      assert record.remaining_ms == nil
      assert record.refusal == %{reason: :attestation, check: :root_of_trust}

      assert_receive {:pair_telemetry, :attestation, 0}

      assert_receive {:pair_facts, :attestation,
                      %{platform: :android, attestation: :refused, signer_role: nil}}

      refute_receive {:device_persisted, _device}
    end

    test "an unusable status list and an unsupported platform end it the same way", ctx do
      for {reason, check, platform, attestation} <- [
            {:attestation_unavailable, :revocation, "android", :unavailable},
            {:platform_unsupported, :platform, "ios", :refused}
          ] do
        manager =
          start_supervised!({PairManager, Keyword.put(ctx.opts, :name, nil)}, id: make_ref())

        assert {:ok, %{session_id: session_id}} = PairManager.open(manager)

        refusal = %{refusal(reason, check) | platform: platform}
        assert :ok = PairManager.refuse(manager, session_id, refusal)

        assert {:ok, %{status: ^reason, refusal: %{reason: ^reason, check: ^check}}} =
                 PairManager.session(manager, session_id)

        assert PairManager.outcome_reason(reason) == reason
        assert_receive {:pair_facts, ^reason, %{attestation: ^attestation}}
      end
    end

    # A phone waiting for the owner proved the pairing secret; another phone's
    # refused proof cannot end that ceremony.
    test "a refusal while a phone waits for the owner leaves its ceremony open", ctx do
      assert {:ok, _window} = PairManager.open(ctx.manager)
      assert {:ok, _request} = submit(ctx, %{})

      assert {:error, :request_pending} =
               PairManager.refuse(ctx.manager, "pair-session", refusal(:attestation, :chain))

      assert {:ok, %{status: :awaiting_decision}} =
               PairManager.session(ctx.manager, "pair-session")
    end

    test "a refusal names one of the three reasons and a closed window refuses nothing", ctx do
      assert {:error, :session_not_found} =
               PairManager.refuse(ctx.manager, "pair-session", refusal(:attestation, :key))

      assert {:ok, _window} = PairManager.open(ctx.manager)

      assert_raise FunctionClauseError, fn ->
        PairManager.refuse(ctx.manager, "pair-session", refusal(:denied, :key))
      end
    end
  end

  describe "the attestation status list" do
    # M51 §6.2 check 7: Google's list is fetched out of band when a window
    # opens, never on the phone's request, and used only while fresh.
    test "opening a window fetches the list once and serves it while it is fresh", ctx do
      test_pid = self()
      manager = status_manager(ctx, fn -> send(test_pid, :fetched) && listed(["abc"]) end)

      assert {:ok, %{session_id: session_id}} = PairManager.open(manager)
      assert_receive :fetched
      assert {:ok, serials} = await_statuses(manager, session_id)
      assert MapSet.member?(serials, "abc")

      assert :ok = PairManager.cancel(manager, session_id)
      assert {:ok, %{session_id: second}} = PairManager.open(manager)
      refute_receive :fetched
      assert {:ok, ^serials} = PairManager.attestation_statuses(manager, second)
    end

    test "a list that goes stale within the next window is fetched again when it opens", ctx do
      test_pid = self()
      manager = status_manager(ctx, fn -> send(test_pid, :fetched) && listed([], 600_000) end)

      assert {:ok, %{session_id: first}} = PairManager.open(manager)
      assert_receive :fetched
      assert {:ok, _serials} = await_statuses(manager, first)
      assert :ok = PairManager.cancel(manager, first)

      advance(ctx, 600_000 - 60_000)
      assert {:ok, _window} = PairManager.open(manager)
      assert_receive :fetched
    end

    # The second window's refresh fails: the list it holds is used until its
    # max-age, then it is stale, and the request fetches nothing.
    test "a list past its max-age is stale and nothing fetches it on the request", ctx do
      test_pid = self()

      results =
        start_supervised!({Agent, fn -> [listed([], 600_000), {:error, :timeout}] end},
          id: :results
        )

      manager =
        status_manager(ctx, fn ->
          send(test_pid, :fetched)
          Agent.get_and_update(results, fn [next | rest] -> {next, rest} end)
        end)

      assert {:ok, %{session_id: first}} = PairManager.open(manager)
      assert_receive :fetched
      assert {:ok, _serials} = await_statuses(manager, first)
      assert :ok = PairManager.cancel(manager, first)

      advance(ctx, 600_000 - 60_000)
      assert {:ok, %{session_id: second}} = PairManager.open(manager)
      assert_receive :fetched
      assert {:ok, _serials} = await_statuses(manager, second)

      advance(ctx, 60_001)
      assert {:error, :status_list_stale} = PairManager.attestation_statuses(manager, second)
      refute_receive :fetched
    end

    test "a failed fetch leaves no list: the request is told so, and fetches nothing", ctx do
      test_pid = self()

      manager =
        status_manager(ctx, fn ->
          send(test_pid, :fetched)
          {:error, :status_list_too_large}
        end)

      assert {:ok, %{session_id: session_id}} = PairManager.open(manager)
      assert_receive :fetched
      assert {:error, :status_list_missing} = await_statuses(manager, session_id)
      refute_receive :fetched
    end

    test "a request waits for a fetch in flight, a bounded time", ctx do
      test_pid = self()

      manager =
        status_manager(ctx, fn ->
          send(test_pid, {:fetching, self()})

          receive do
            {:release, result} -> result
          end
        end)

      assert {:ok, %{session_id: session_id}} = PairManager.open(manager)
      assert_receive {:fetching, fetcher}
      assert_receive {:timer_armed, _ref, {:status_fetch_deadline, _token}, 20_000}

      waiting = Task.async(fn -> PairManager.attestation_statuses(manager, session_id) end)
      assert_receive {:timer_armed, _ref, {:status_wait_timeout, _token} = timeout, 10_000}
      send(fetcher, {:release, listed(["abc"])})
      assert {:ok, serials} = Task.await(waiting)
      assert MapSet.member?(serials, "abc")
      send(manager, timeout)

      assert :ok = PairManager.cancel(manager, session_id)
      advance(ctx, 86_400_000)
      assert {:ok, %{session_id: second}} = PairManager.open(manager)
      assert_receive {:fetching, _second_fetcher}
      late = Task.async(fn -> PairManager.attestation_statuses(manager, second) end)
      assert_receive {:timer_armed, _ref, {:status_wait_timeout, _token} = expired_wait, 10_000}
      send(manager, expired_wait)
      assert {:error, :status_list_wait_timeout} = Task.await(late)
    end

    test "a fetch that outlives its deadline is stopped and leaves no list", ctx do
      test_pid = self()

      manager =
        status_manager(ctx, fn ->
          send(test_pid, {:fetching, self()})

          receive do
            :never -> listed([])
          end
        end)

      assert {:ok, %{session_id: session_id}} = PairManager.open(manager)
      assert_receive {:fetching, fetcher}
      monitor = Process.monitor(fetcher)
      assert_receive {:timer_armed, _ref, {:status_fetch_deadline, _token} = deadline, 20_000}

      waiting = Task.async(fn -> PairManager.attestation_statuses(manager, session_id) end)
      assert_receive {:timer_armed, _ref, {:status_wait_timeout, _token}, 10_000}
      send(manager, deadline)

      assert {:error, :status_list_missing} = Task.await(waiting)
      assert_receive {:DOWN, ^monitor, :process, ^fetcher, _reason}
    end

    test "a manager that stops ends its fetch in flight", ctx do
      test_pid = self()

      manager =
        status_manager(ctx, fn ->
          send(test_pid, {:fetching, self()})

          receive do
            :never -> listed([])
          end
        end)

      assert {:ok, _window} = PairManager.open(manager)
      assert_receive {:fetching, fetcher}
      monitor = Process.monitor(fetcher)
      stop_supervised!(:status_manager)
      assert_receive {:DOWN, ^monitor, :process, ^fetcher, _reason}
    end

    # The manager traps exits only so terminate/2 stops a fetch on shutdown;
    # the exit of any other process linked to it, for any reason, stops it,
    # loudly.
    test "a linked process that crashes stops the manager with a log line", ctx do
      monitor = Process.monitor(ctx.manager)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          spawn(fn ->
            Process.link(ctx.manager)
            exit(:linked_crash)
          end)

          assert_receive {:DOWN, ^monitor, :process, _pid, {:linked_exit, :linked_crash}}
        end)

      assert log =~ "mobile pairing manager stopped: a linked process exited: :linked_crash"
    end

    test "only a window's own socket asks for the list", ctx do
      assert {:error, :session_not_found} =
               PairManager.attestation_statuses(ctx.manager, "pair-session")
    end
  end

  describe "finished sessions are retained, bounded" do
    test "the bounds are eight sessions and five minutes" do
      assert PairManager.max_retained() == 8
      assert PairManager.retention_ms() == 300_000
    end

    test "only the eight newest finished sessions stay readable", ctx do
      manager = counted_manager(ctx)

      for index <- 1..9 do
        id = "pair-#{index}"
        assert {:ok, %{session_id: ^id}} = PairManager.open(manager)
        assert :ok = PairManager.cancel(manager, id)
      end

      assert :unknown = PairManager.session(manager, "pair-1")

      for index <- 2..9 do
        assert {:ok, %{status: :cancelled}} = PairManager.session(manager, "pair-#{index}")
      end
    end

    test "a finished session is readable for five minutes and no longer", ctx do
      assert {:ok, _window} = PairManager.open(ctx.manager)
      assert :ok = PairManager.cancel(ctx.manager, "pair-session")

      advance(ctx, PairManager.retention_ms())
      assert {:ok, %{status: :cancelled}} = PairManager.session(ctx.manager, "pair-session")

      advance(ctx, 1)
      assert :unknown = PairManager.session(ctx.manager, "pair-session")
      assert :none = PairManager.latest(ctx.manager)
    end
  end

  describe "latest/1" do
    test "is none before any window opened", ctx do
      assert :none = PairManager.latest(ctx.manager)
    end

    test "prefers the open window over the newest finished session", ctx do
      manager = counted_manager(ctx)

      assert {:ok, %{session_id: "pair-1"}} = PairManager.open(manager)
      assert :ok = PairManager.cancel(manager, "pair-1")
      assert {:ok, %{session_id: "pair-1", status: :cancelled}} = PairManager.latest(manager)

      assert {:ok, %{session_id: "pair-2"}} = PairManager.open(manager)
      assert {:ok, %{session_id: "pair-2", status: :awaiting_scan}} = PairManager.latest(manager)

      assert :ok = PairManager.cancel(manager, "pair-2")
      assert {:ok, %{session_id: "pair-2", status: :cancelled}} = PairManager.latest(manager)
    end
  end

  defp advance(ctx, ms), do: Agent.update(ctx.clock, &(&1 + ms))

  defp counted_manager(ctx) do
    ids = start_supervised!({Agent, fn -> 0 end}, id: :session_ids)
    next_id = fn -> "pair-#{Agent.get_and_update(ids, &{&1 + 1, &1 + 1})}" end

    opts =
      Keyword.merge(ctx.opts,
        name: :"pair_manager_#{System.unique_integer([:positive])}",
        session_id_generator: next_id
      )

    start_supervised!({PairManager, opts}, id: :counted_manager)
  end

  defp status_manager(ctx, fetch) do
    opts =
      Keyword.merge(ctx.opts,
        name: :"pair_manager_#{System.unique_integer([:positive])}",
        status_fetch: fetch
      )

    start_supervised!({PairManager, opts}, id: :status_manager)
  end

  defp listed(serials, max_age_ms \\ 86_400_000),
    do: {:ok, %{serials: MapSet.new(serials), max_age_ms: max_age_ms}}

  # The fetch runs beside the manager, so the first read can come before it
  # lands: a read made while it is in flight waits for it.
  defp await_statuses(manager, session_id) do
    PairManager.attestation_statuses(manager, session_id)
  end

  defp refusal(reason, check), do: %{reason: reason, check: check, platform: "android"}

  # Ten addresses, five failures each: twice what once closed a window.
  defp fail_from_many_addresses(ctx) do
    for host <- 1..10, _attempt <- 1..5 do
      PairManager.record_failure(ctx.manager, "pair-session", {192, 168, 1, host})
    end
  end

  defp assert_socket_replaced(socket) do
    monitor = Process.monitor(socket)
    assert {:messages, [{:mobile_replaced, replacement}]} = Process.info(socket, :messages)
    assert replacement == self()
    send(socket, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^socket, _reason}
  end

  defp stop_socket(socket) do
    monitor = Process.monitor(socket)
    send(socket, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^socket, _reason}
  end

  defp submit(ctx, overrides) do
    PairManager.submit_request(ctx.manager, "pair-session", request_attrs(overrides))
  end

  defp request_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "Sujeeth's iPhone",
        model: "iPhone17,1",
        app_version: "1.0",
        platform: "android",
        noise_pk: <<4::256>>,
        sas: "047291",
        attestation: facts(),
        socket_pid: self()
      },
      overrides
    )
  end

  # What a verified attestation tells the owner (`Mobile.Attestation.verify/3`).
  defp facts do
    %{
      platform: "android",
      security_level: :trusted_environment,
      signer_role: :development,
      version_code: 42,
      boot_state: :verified,
      device_locked: true
    }
  end

  defp fresh_statuses, do: {:ok, %{serials: MapSet.new(), max_age_ms: 86_400_000}}

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
