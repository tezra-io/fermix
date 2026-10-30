defmodule FermixChannels.Mobile.PairingFromPhoneTest do
  @moduledoc """
  A paired phone opens a pairing window and decides on the phone that asks
  (M75 D16), through real sessions: Noise `IK` for the paired phones, the
  pairing phone's `IKpsk2` and a verified attestation, and the real pair
  manager and device registry.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Attestation
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.PairManager
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Test.AttestationChain, as: Chain
  alias FermixChannels.Test.SessionDriver, as: Driver

  @owner_phone "2a9b8c7d-6e5f-4a3b-9c2d-1e0f9a8b7c6d"
  @second_phone "8e7d6c5b-4a39-4281-9e0f-a1b2c3d4e5f6"
  @new_phone "1508aa90-2d73-4d7f-a49c-1cdedcd4c298"

  setup do
    suffix = System.unique_integer([:positive])
    gateway = Noise.generate_keypair()

    registry =
      start_supervised!(
        {DeviceRegistry,
         name: Module.concat(__MODULE__, "Registry#{suffix}"),
         authorize_device: fn _store, id -> {:ok, %{device_id: id, kind: :phone}} end,
         delete_device: fn _store, _id -> :ok end,
         revoke_requests: fn _id -> :ok end}
      )

    test = self()

    manager =
      start_supervised!({
        PairManager,
        # The window's expiry is delivered by hand (`expire!/2`).
        name: Module.concat(__MODULE__, "PairManager#{suffix}"),
        device_registry: registry,
        ensure_identity: fn ->
          {:ok, %{gateway_public_key: gateway.public, tls_fingerprint: :binary.copy(<<7>>, 32)}}
        end,
        activate_listener: fn _identity -> :ok end,
        persist_device: fn attrs -> {:ok, attrs} end,
        emit_pair: fn _status, _duration_us, _facts -> :ok end,
        status_fetch: fn -> {:ok, %{serials: MapSet.new(), max_age_ms: 86_400_000}} end,
        device_id_generator: fn -> @new_phone end,
        schedule_timer: fn message, _delay ->
          send(test, {:scheduled, message})
          make_ref()
        end,
        cancel_timer: fn _ref -> :ok end
      })

    %{gateway: gateway, registry: registry, manager: manager}
  end

  test "a phone opens a window, sees the request with its SAS, and approves it", ctx do
    {owner, owner_client} = paired_phone!(ctx, @owner_phone)
    {window, owner_client} = start_window!(owner, owner_client, 2)

    {pairing, pairing_client, sas} = request_pairing!(ctx, window)

    {[{pending, <<>>}], owner_client} = Driver.client_receive(owner, owner_client)

    assert pending == %{
             "v" => 2,
             "t" => "pair_pending",
             "seq" => 3,
             "session_id" => window["session_id"],
             "device_name" => "Garden Pixel",
             "model" => "Google Pixel 9",
             "platform" => "android",
             "sas" => sas,
             "expires_in_s" => pending["expires_in_s"]
           }

    assert pending["expires_in_s"] in 1..120

    decide = %{"session_id" => window["session_id"], "approved" => true}
    owner_client = Driver.client_send(owner, owner_client, "pair_decide", decide, 3)

    {[{approved, <<>>}], _pairing_client} = Driver.client_receive(pairing, pairing_client)
    assert approved["t"] == "pair_approved"
    assert approved["device_id"] == @new_phone

    {[{decided, <<>>}], _owner_client} = Driver.client_receive(owner, owner_client)

    assert %{"t" => "pair_decided", "session_id" => session_id, "outcome" => "approved"} =
             decided

    assert session_id == window["session_id"]
    assert PairManager.pending_event(ctx.manager) == :none
  end

  test "a phone denies, and a phone that connects while a request waits hears of it", ctx do
    {owner, owner_client} = paired_phone!(ctx, @owner_phone)
    {window, owner_client} = start_window!(owner, owner_client, 2)
    {pairing, pairing_client, sas} = request_pairing!(ctx, window)

    {[{%{"t" => "pair_pending"}, <<>>}], owner_client} =
      Driver.client_receive(owner, owner_client)

    # A second paired phone says hello while the request waits.
    {second, second_client, after_ack} = paired_phone_with_rest!(ctx, @second_phone)
    assert [{%{"t" => "pair_pending", "sas" => ^sas, "seq" => 2}, <<>>}] = after_ack

    # Another window cannot open while this one is.
    owner_client = Driver.client_send(owner, owner_client, "pair_start", %{}, 3)
    {[{busy, <<>>}], owner_client} = Driver.client_receive(owner, owner_client)
    assert busy["code"] == "pairing_active"

    decide = %{"session_id" => window["session_id"], "approved" => false}
    _owner_client = Driver.client_send(owner, owner_client, "pair_decide", decide, 4)

    assert {:denied, {4003, "pairing denied"}, [{denied, <<>>}], _client} =
             Driver.client_closed(pairing, pairing_client)

    assert denied["t"] == "pair_denied" and denied["reason"] == "denied"

    {[{decided, <<>>}], _second_client} = Driver.client_receive(second, second_client)
    assert decided["outcome"] == "denied"
  end

  test "every phone hears a window that ran out, and one the owner cancelled", ctx do
    {owner, owner_client} = paired_phone!(ctx, @owner_phone)
    {window, owner_client} = start_window!(owner, owner_client, 2)
    {pairing, pairing_client, _sas} = request_pairing!(ctx, window)

    {[{%{"t" => "pair_pending"}, <<>>}], owner_client} =
      Driver.client_receive(owner, owner_client)

    expire!(ctx.manager, window["session_id"])

    assert {:timeout, {4003, "pairing timeout"}, [{%{"reason" => "timeout"}, <<>>}], _client} =
             Driver.client_closed(pairing, pairing_client)

    {[{expired, <<>>}], owner_client} = Driver.client_receive(owner, owner_client)
    assert %{"t" => "pair_decided", "outcome" => "timeout"} = expired

    # The Mac closes the next window: the phone that opened it hears that too.
    {next, owner_client} = start_window!(owner, owner_client, 3)
    assert next["session_id"] != window["session_id"]
    assert :ok = PairManager.cancel(ctx.manager, next["session_id"])

    {[{cancelled, <<>>}], _owner_client} = Driver.client_receive(owner, owner_client)
    assert cancelled["outcome"] == "cancelled"
    assert cancelled["session_id"] == next["session_id"]
  end

  test "a decision on a session this daemon does not hold is refused, and the phone stays",
       ctx do
    {owner, owner_client} = paired_phone!(ctx, @owner_phone)
    decide = %{"session_id" => "5b0c7d2e-8f41-4a6b-9c3d-2e7f1a8b4c60", "approved" => true}
    owner_client = Driver.client_send(owner, owner_client, "pair_decide", decide, 2)

    {[{refusal, <<>>}], owner_client} = Driver.client_receive(owner, owner_client)
    assert refusal["code"] == "unknown_pairing_session"

    {window, owner_client} = start_window!(owner, owner_client, 3)
    no_request = %{"session_id" => window["session_id"], "approved" => true}
    owner_client = Driver.client_send(owner, owner_client, "pair_decide", no_request, 4)
    {[{refusal, <<>>}], _owner_client} = Driver.client_receive(owner, owner_client)
    assert refusal["code"] == "request_missing"
  end

  defp start_window!(owner, owner_client, seq) do
    owner_client = Driver.client_send(owner, owner_client, "pair_start", %{}, seq)
    {[{window, <<>>}], owner_client} = Driver.client_receive(owner, owner_client)
    assert %{"t" => "pair_window", "link" => "fermix://pair?" <> _query} = window
    assert window["expires_in_s"] in 1..120
    {window, owner_client}
  end

  # The pairing phone: IKpsk2 with the window's secret, then a verified
  # pair_request. Answers its driver, its client, and the SAS it shows.
  defp request_pairing!(ctx, window) do
    query = window["link"] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    secret = Base.decode64!(query["secret"])
    assert Base.decode64!(query["gateway_pk"]) == ctx.gateway.public

    keypair = Noise.generate_keypair()
    chain = Chain.chain(%{noise_pk: keypair.public, challenge: Attestation.challenge(secret)})
    trust = Chain.trust(chain)

    driver =
      Driver.start!(
        peer: {127, 0, 0, 1},
        gateway_keypair: ctx.gateway,
        primary_epoch: 4,
        device_registry: ctx.registry,
        pair_manager: ctx.manager,
        discover: fn -> {:ok, []} end,
        iroh_candidate: fn -> :none end,
        verify_pair: fn _manager, _session_id, evidence ->
          Attestation.verify(evidence, trust, DateTime.utc_now())
        end
      )

    assert {:ok, client} =
             Noise.initialize(:initiator, :ikpsk2,
               static_keypair: keypair,
               remote_static: ctx.gateway.public,
               psk: secret
             )

    client = Driver.handshake!(driver, client)

    request = %{
      "device_name" => "Garden Pixel",
      "model" => "Google Pixel 9",
      "app_version" => "1.4.0",
      "platform" => "android",
      "attestation" => %{"kind" => "android_keymint", "cert_lengths" => chain.lengths}
    }

    client = Driver.client_send(driver, client, "pair_request", request, 1, chain.bytes)
    {driver, client, Noise.sas(client)}
  end

  defp paired_phone!(ctx, device_id) do
    {driver, client, []} = paired_phone_with_rest!(ctx, device_id)
    {driver, client}
  end

  # A paired phone's session through IK and hello: its hello_ack, and the
  # events that followed it in the same push.
  defp paired_phone_with_rest!(ctx, device_id) do
    keypair = Noise.generate_keypair()
    manager = ctx.manager

    driver =
      Driver.start!(
        peer: {127, 0, 0, 1},
        gateway_keypair: ctx.gateway,
        primary_epoch: 4,
        device_store: :store,
        device_registry: ctx.registry,
        pair_manager: manager,
        find_device: fn :store, _key -> {:ok, %{device_id: device_id, kind: :phone}} end,
        update_device: fn :store, ^device_id, _attrs ->
          {:ok, %{device_id: device_id, kind: :phone}}
        end,
        hello_ack_builder: fn _state -> {:ok, hello_ack()} end,
        pending_approvals: fn "main" -> [] end,
        pairing_opts: pairing_opts()
      )

    assert {:ok, client} =
             Noise.initialize(:initiator, :ik,
               static_keypair: keypair,
               remote_static: ctx.gateway.public
             )

    client = Driver.handshake!(driver, client)

    hello = %{
      "device_id" => device_id,
      "app_version" => "1.4.0",
      "last_server_seq" => 0,
      "protocol_v" => Protocol.protocol_version()
    }

    client = Driver.client_send(driver, client, "hello", hello, 1)
    {[{ack, <<>>} | rest], client} = Driver.client_receive(driver, client)
    assert ack["t"] == "hello_ack"
    {driver, client, rest}
  end

  # What `mobile.pair.start` reads besides the pair manager: the subtree runs,
  # the listener's port, no discovered address, and no remote route.
  defp pairing_opts do
    test = self()

    [
      config: [enabled: true],
      whereis: fn FermixChannels.Mobile.Supervisor -> test end,
      listener_info: fn _listener -> {:ok, {{0, 0, 0, 0}, 4031}} end,
      discover: fn -> {:ok, []} end,
      host_label: fn -> "studio" end,
      profile: "general",
      iroh_candidate: fn _helper -> :none end
    ]
  end

  defp expire!(manager, session_id) do
    assert_receive {:scheduled, {:pair_expire, ^session_id, _token} = expiry}
    send(manager, expiry)
  end

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
