defmodule FermixChannels.Mobile.PushTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1, with_log: 1]

  require Logger

  alias FermixChannels.Mobile.DeviceStore.Device
  alias FermixChannels.Mobile.Push
  alias FermixChannels.Mobile.Push.Config
  alias Pigeon.APNS.Notification

  @nonce <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11>>
  @push_vectors_path Application.app_dir(:fermix_core, "priv/mobile/push_vectors.json")

  setup_all do
    assert {:ok, _started} = Application.ensure_all_started(:telemetry)
    :ok
  end

  test "derives the same per-device key from either X25519 side" do
    {gateway_public, gateway_private} = keypair(1)
    {device_public, device_private} = keypair(2)
    salt = :binary.copy(<<3>>, 32)

    assert {:ok, gateway_key} = Push.derive_key(gateway_private, device_public, salt)
    assert {:ok, device_key} = Push.derive_key(device_private, gateway_public, salt)
    assert gateway_key == device_key
    assert byte_size(gateway_key) == 32

    refute gateway_key == :crypto.compute_key(:ecdh, device_public, gateway_private, :x25519)
  end

  # The Swift Notification Service Extension is written against the exported
  # vector and nothing else, so the derivation and the payload have to be pinned
  # by material this repository did not compute with the same code — otherwise
  # both ends agree only because they are the same implementation.
  test "the exported push vector pins the derivation and the payload byte for byte" do
    document = @push_vectors_path |> File.read!() |> Jason.decode!()
    vector = document["vector"]

    assert document["kdf"] =~ "fermix-push-v1"
    assert document["reference"] =~ "Independent"

    gateway_private = hex(vector["gateway_static_private"])
    gateway_public = hex(vector["gateway_static_public"])
    device_private = hex(vector["device_static_private"])
    device_public = hex(vector["device_static_public"])
    salt = hex(vector["apns_key_salt"])
    nonce = hex(vector["nonce"])
    push_key = hex(vector["push_key"])

    assert device_public(gateway_private) == gateway_public
    assert device_public(device_private) == device_public

    assert {:ok, ^push_key} = Push.derive_key(gateway_private, device_public, salt)
    assert {:ok, ^push_key} = Push.derive_key(device_private, gateway_public, salt)

    device = device("device-vector", device_public, salt, "vector-token")

    assert {:ok, notification} =
             Push.build_notification(
               device,
               gateway_private,
               vector["profile_id"],
               vector["preview_text"],
               "io.tezra.fermix",
               nonce_fun: fn 12 -> nonce end
             )

    assert notification.payload == vector["payload"]

    fx = vector["payload"]["fx"]
    assert Base.decode64!(fx["c"]) == hex(vector["sealed"])
    assert decrypt_raw(push_key, fx["n"], fx["c"]) == vector["inner_plaintext"]
  end

  test "push config inspection omits the APNs private key" do
    values = valid_config()
    private_key = Keyword.fetch!(values, :key)
    assert {:ok, config} = Config.new(values)

    inspected = inspect(config)

    assert inspected =~ "FermixChannels.Mobile.Push.Config"
    refute inspected =~ private_key
    refute inspected =~ "PRIVATE KEY"
  end

  test "builds an encrypted mutable APNs preview with no plaintext content" do
    {gateway_public, gateway_private} = keypair(4)
    {device_public, device_private} = keypair(5)
    device = device("device-a", device_public, :binary.copy(<<6>>, 32), "push-token-a")
    preview = "the launch code is 8675309"

    assert {:ok, notification} =
             Push.build_notification(device, gateway_private, "main", preview, "io.tezra.fermix",
               nonce_fun: fn 12 -> @nonce end
             )

    assert %Notification{
             device_token: "push-token-a",
             topic: "io.tezra.fermix",
             payload: %{
               "aps" => %{
                 "alert" => %{"title" => "Fermix", "body" => "New message"},
                 "mutable-content" => 1
               },
               "fx" => %{"n" => nonce_b64, "c" => ciphertext_b64}
             }
           } = notification

    encoded = Jason.encode!(notification.payload)
    refute encoded =~ preview
    refute encoded =~ "main"
    assert byte_size(encoded) <= Push.max_payload_bytes()

    assert {:ok, key} = Push.derive_key(device_private, gateway_public, device.apns_key_salt)

    assert %{"profile_id" => "main", "preview_text" => ^preview} =
             decrypt_preview(key, nonce_b64, ciphertext_b64)
  end

  test "uses the deterministic title-only size rule when an encrypted preview exceeds 4 KiB" do
    {_gateway_public, gateway_private} = keypair(7)
    {device_public, device_private} = keypair(8)
    device = device("device-b", device_public, :binary.copy(<<9>>, 32), "push-token-b")

    assert {:ok, notification} =
             Push.build_notification(
               device,
               gateway_private,
               "main",
               String.duplicate("x", 8_000),
               "io.tezra.fermix",
               nonce_fun: fn 12 -> @nonce end
             )

    assert get_in(notification.payload, ["aps", "alert"]) == %{"title" => "Fermix"}
    refute get_in(notification.payload, ["aps", "alert"]) |> Map.has_key?("body")
    assert byte_size(Jason.encode!(notification.payload)) <= Push.max_payload_bytes()

    assert {:ok, key} =
             Push.derive_key(device_private, device_public(gateway_private), device.apns_key_salt)

    assert %{"profile_id" => "main", "preview_text" => nil} =
             decrypt_preview(
               key,
               get_in(notification.payload, ["fx", "n"]),
               get_in(notification.payload, ["fx", "c"])
             )
  end

  test "suppression decision is pure and prioritizes connected profile sockets" do
    assert {:ok, :suppress_connected} = Push.delivery_decision(true, 0, 10)
    assert {:ok, :suppress_read} = Push.delivery_decision(false, 10, 10)
    assert {:ok, :suppress_read} = Push.delivery_decision(false, 11, 10)
    assert {:ok, :deliver} = Push.delivery_decision(false, 9, 10)
    assert {:error, {:invalid_server_seq, 0}} = Push.delivery_decision(false, 0, 0)
  end

  test "sends exactly one notification per registered device when the profile is offline and unread" do
    {_gateway_public, gateway_private} = keypair(10)
    {first_public, _first_private} = keypair(11)
    {second_public, _second_private} = keypair(12)

    devices = [
      device("device-a", first_public, :binary.copy(<<13>>, 32), "token-a"),
      device("device-b", second_public, :binary.copy(<<14>>, 32), "token-b"),
      device("device-c", second_public, :binary.copy(<<15>>, 32), nil)
    ]

    test_pid = self()

    dispatcher = fn notifications, config ->
      send(test_pid, {:dispatched, notifications, config})
      {:ok, Enum.map(notifications, &%{&1 | response: :success})}
    end

    assert {:ok, %{status: :sent, sent: 2}} =
             Push.notify("main", 44, "hello from Fermix",
               config: valid_config(),
               profile_connected: fn "main" -> {:ok, false} end,
               read_frontier: fn "main" -> {:ok, 43} end,
               list_devices: fn -> {:ok, devices} end,
               load_identity: fn -> {:ok, %{gateway_private_key: gateway_private}} end,
               dispatcher: dispatcher,
               nonce_fun: fn 12 -> @nonce end
             )

    assert_receive {:dispatched, notifications, %Config{environment: :development}}
    assert Enum.map(notifications, & &1.device_token) == ["token-a", "token-b"]
    assert Enum.all?(notifications, &(&1.topic == "io.tezra.fermix"))
  end

  test "connected and already-read profiles suppress dispatch before device or identity access" do
    forbidden = fn -> flunk("suppressed delivery consulted a send-only dependency") end

    common = [
      config: valid_config(),
      list_devices: forbidden,
      load_identity: forbidden,
      dispatcher: fn _, _ -> flunk("suppressed delivery dispatched") end
    ]

    assert {:ok, %{status: :suppressed, reason: :connected, sent: 0}} =
             Push.notify(
               "main",
               8,
               "preview",
               Keyword.merge(common,
                 profile_connected: fn "main" -> {:ok, true} end,
                 read_frontier: fn _ -> flunk("connected state must decide first") end
               )
             )

    assert {:ok, %{status: :suppressed, reason: :read, sent: 0}} =
             Push.notify(
               "main",
               8,
               "preview",
               Keyword.merge(common,
                 profile_connected: fn "main" -> {:ok, false} end,
                 read_frontier: fn "main" -> {:ok, 8} end
               )
             )
  end

  test "returns invalid configuration errors without consulting runtime dependencies" do
    assert {:error, {:invalid_push_config, :topic, :missing}} =
             Push.notify("main", 1, "preview",
               config: Keyword.delete(valid_config(), :topic),
               profile_connected: fn _ -> flunk("invalid config reached presence lookup") end
             )

    assert {:error, {:invalid_push_config, :environment, "staging"}} =
             Push.notify("main", 1, "preview",
               config: Keyword.put(valid_config(), :environment, "staging"),
               profile_connected: fn _ -> flunk("invalid config reached presence lookup") end
             )
  end

  test "disabled push is an explicit no-op that needs no credentials or runtime dependencies" do
    assert {:ok, %{status: :disabled, sent: 0}} =
             Push.notify("main", 1, "preview",
               config: [enabled: false],
               profile_connected: fn _ -> flunk("disabled push checked presence") end,
               read_frontier: fn _ -> flunk("disabled push checked read state") end,
               list_devices: fn -> flunk("disabled push listed devices") end,
               load_identity: fn -> flunk("disabled push loaded identity") end,
               dispatcher: fn _, _ -> flunk("disabled push dispatched") end
             )
  end

  test "returns per-device failures and emits content-free shared telemetry" do
    {_gateway_public, gateway_private} = keypair(16)
    {first_public, _} = keypair(17)
    {second_public, _} = keypair(18)

    devices = [
      device("device-a", first_public, :binary.copy(<<19>>, 32), "token-a"),
      device("device-b", second_public, :binary.copy(<<20>>, 32), "token-b")
    ]

    handler_id = "mobile-push-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:fermix, :channel, :push],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    dispatcher = fn [first, second], _config ->
      {:ok, [%{first | response: :success}, %{second | response: :bad_device_token}]}
    end

    assert {:error, {:push_failed, [%{device_id: "device-b", reason: :bad_device_token}]}} =
             Push.notify("main", 51, "private preview",
               config: valid_config(),
               profile_connected: fn _ -> {:ok, false} end,
               read_frontier: fn _ -> {:ok, 50} end,
               list_devices: fn -> {:ok, devices} end,
               load_identity: fn -> {:ok, %{gateway_private_key: gateway_private}} end,
               dispatcher: dispatcher,
               nonce_fun: fn 12 -> @nonce end
             )

    assert_receive {:telemetry, [:fermix, :channel, :push], %{count: 1, duration_us: sent_us},
                    %{channel: :mobile, status: :sent}}

    assert_receive {:telemetry, [:fermix, :channel, :push], %{count: 1, duration_us: failed_us},
                    %{channel: :mobile, status: :failed}}

    assert sent_us >= 0
    assert failed_us >= 0
  end

  test "malformed dispatcher results expose neither APNs tokens nor response payloads" do
    {_gateway_public, gateway_private} = keypair(26)
    {device_public, _device_private} = keypair(27)
    token = "APNS-PLANTED-TOKEN-DO-NOT-LOG"
    payload_marker = "PLANTED-PUSH-PAYLOAD-DO-NOT-LOG"
    registered = device("device-a", device_public, :binary.copy(<<28>>, 32), token)

    extra = %Notification{
      device_token: token,
      payload: %{"private" => payload_marker},
      response: :success
    }

    count_mismatch =
      notify_with_dispatcher(registered, gateway_private, fn [sent], _config ->
        {:ok, [%{sent | response: :success}, extra]}
      end)

    invalid_result =
      notify_with_dispatcher(registered, gateway_private, fn _notifications, _config -> extra end)

    dispatcher_error =
      notify_with_dispatcher(registered, gateway_private, fn _notifications, _config ->
        {:error, {:apns_failure, extra}}
      end)

    invalid_response =
      notify_with_dispatcher(registered, gateway_private, fn [sent], _config ->
        {:ok, [%{sent | response: extra}]}
      end)

    results = [count_mismatch, invalid_result, dispatcher_error, invalid_response]

    log =
      capture_log(fn ->
        Enum.each(results, &Logger.error("mobile push failed: #{inspect(&1)}"))
      end)

    assert :nomatch == :binary.match(log, token)
    assert :nomatch == :binary.match(log, payload_marker)

    assert count_mismatch ==
             {:error, {:invalid_dispatch_response, :count_mismatch, 2, 1}}

    assert invalid_result == {:error, {:invalid_dispatch_result, :unexpected_shape}}
    assert dispatcher_error == {:error, {:push_dispatch_failed, :apns_failure}}

    assert invalid_response ==
             {:error, {:push_failed, [%{device_id: "device-a", reason: :invalid_response}]}}
  end

  test "caps the registered-device dispatch loop instead of silently dropping devices" do
    {_gateway_public, gateway_private} = keypair(21)
    {device_public, _} = keypair(22)

    devices =
      for index <- 1..(Push.max_devices() + 1) do
        device("device-#{index}", device_public, :binary.copy(<<index>>, 32), "token-#{index}")
      end

    assert {:error, {:too_many_registered_devices, count, max}} =
             Push.notify("main", 1, "preview",
               config: valid_config(),
               profile_connected: fn _ -> {:ok, false} end,
               read_frontier: fn _ -> {:ok, 0} end,
               list_devices: fn -> {:ok, devices} end,
               load_identity: fn -> {:ok, %{gateway_private_key: gateway_private}} end,
               dispatcher: fn _, _ -> flunk("over-cap device set dispatched") end
             )

    assert count == Push.max_devices() + 1
    assert max == Push.max_devices()
  end

  test "derivation and notification validation fail loudly at the public boundary" do
    {_gateway_public, gateway_private} = keypair(23)
    {device_public, _device_private} = keypair(24)
    device = device("device-a", device_public, :binary.copy(<<25>>, 32), "token")

    assert {:error, {:invalid_push_field, :gateway_private_key, 32}} =
             Push.derive_key(<<1>>, device_public, device.apns_key_salt)

    assert {:error, {:invalid_push_field, :topic, nil}} =
             Push.build_notification(device, gateway_private, "main", "preview", nil)

    marker = "PRIVATE-PREVIEW-MUST-NOT-BE-LOGGED"
    oversized = marker <> :binary.copy(<<"x">>, 1_048_577)
    oversized_result = Push.notify("main", 1, oversized, config: [enabled: false])
    wrong_type_result = Push.notify("main", 1, %{private: marker}, config: [enabled: false])

    log =
      capture_log(fn ->
        Logger.error("mobile push failed: #{inspect(oversized_result)}")
        Logger.error("mobile push failed: #{inspect(wrong_type_result)}")
      end)

    assert :nomatch == :binary.match(log, marker)

    assert oversized_result ==
             {:error, {:invalid_preview_text, :too_large, byte_size(oversized), 1_048_576}}

    assert wrong_type_result == {:error, {:invalid_preview_text, :not_binary}}
  end

  test "a raising dependency is reported with its exception type and stacktrace" do
    {result, log} =
      with_log(fn ->
        Push.notify("main", 1, "preview",
          config: valid_config(),
          profile_connected: fn _ -> {:ok, false} end,
          read_frontier: fn _ -> {:ok, 0} end,
          list_devices: fn -> raise KeyError, key: :registered_devices, term: %{} end,
          load_identity: fn -> flunk("a raising dependency continued the delivery") end,
          dispatcher: fn _, _ -> flunk("a raising dependency dispatched") end
        )
      end)

    assert {:error, {:push_dependency_exception, :list_devices, KeyError, message}} = result
    assert message =~ ":registered_devices"

    assert log =~ "mobile push dependency :list_devices raised"
    assert log =~ "KeyError"
    assert log =~ "push_test.exs"
  end

  defp notify_with_dispatcher(device, gateway_private, dispatcher) do
    Push.notify("main", 52, "private preview",
      config: valid_config(),
      profile_connected: fn _ -> {:ok, false} end,
      read_frontier: fn _ -> {:ok, 51} end,
      list_devices: fn -> {:ok, [device]} end,
      load_identity: fn -> {:ok, %{gateway_private_key: gateway_private}} end,
      dispatcher: dispatcher,
      nonce_fun: fn 12 -> @nonce end
    )
  end

  defp valid_config do
    [
      enabled: true,
      team_id: "ABCDE12345",
      key_id: "XYZ987",
      key: X509.PrivateKey.new_ec(:secp256r1) |> X509.PrivateKey.to_pem(),
      topic: "io.tezra.fermix",
      environment: "development",
      timeout_ms: 500
    ]
  end

  defp device(id, noise_pk, salt, token) do
    %Device{
      device_id: id,
      name: id,
      model: "iPhone",
      noise_pk: noise_pk,
      push_token: token,
      created_at: ~U[2026-08-12 00:00:00Z],
      last_seen: nil,
      apns_key_salt: salt
    }
  end

  defp keypair(byte) do
    private = :binary.copy(<<byte>>, 32)
    {public, ^private} = :crypto.generate_key(:ecdh, :x25519, private)
    {public, private}
  end

  defp device_public(private) do
    {public, ^private} = :crypto.generate_key(:ecdh, :x25519, private)
    public
  end

  defp hex(value), do: Base.decode16!(value, case: :lower)

  defp decrypt_preview(key, nonce_b64, ciphertext_b64) do
    key |> decrypt_raw(nonce_b64, ciphertext_b64) |> Jason.decode!()
  end

  defp decrypt_raw(key, nonce_b64, ciphertext_b64) do
    nonce = Base.decode64!(nonce_b64)
    ciphertext_and_tag = Base.decode64!(ciphertext_b64)
    encrypted_size = byte_size(ciphertext_and_tag) - 16
    <<encrypted::binary-size(encrypted_size), tag::binary-size(16)>> = ciphertext_and_tag

    :crypto.crypto_one_time_aead(
      :chacha20_poly1305,
      key,
      nonce,
      encrypted,
      <<>>,
      tag,
      false
    )
  end
end
