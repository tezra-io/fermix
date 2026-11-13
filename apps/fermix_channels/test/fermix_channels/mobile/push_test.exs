defmodule FermixChannels.Mobile.PushTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1, with_log: 1]

  require Logger

  alias FermixChannels.Mobile.DeviceStore.Device
  alias FermixChannels.Mobile.Push
  alias FermixChannels.Mobile.Push.Config
  alias FermixChannels.Mobile.WebPush.Key, as: WebPushKey
  alias FermixTestSupport.TelemetryCapture
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

  # The reason a bad key is refused with reaches the log at boot and at every
  # push, and a DER decoder's own words quote the bytes it could not match.
  test "a key the decoder cannot read is refused by class, never quoting its bytes" do
    der = <<4, 3, 0xFE, 0xED, 0xFA>>

    pem =
      "-----BEGIN EC PRIVATE KEY-----\n#{Base.encode64(der)}\n-----END EC PRIVATE KEY-----\n"

    assert {:error, {:invalid_push_config, :key, :invalid_pem}} =
             Config.new(Keyword.put(valid_config(), :key, pem))
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
               connected_devices: fn "main" -> {:ok, []} end,
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

  # Who is away is decided phone by phone, so the registered phones are listed;
  # nothing that sends is touched.
  test "connected phones and already-read rows suppress dispatch before identity access" do
    {device_public, _device_private} = keypair(29)
    phone = device("device-a", device_public, :binary.copy(<<29>>, 32), "token-a")
    forbidden = fn -> flunk("suppressed delivery consulted a send-only dependency") end

    common = [
      config: valid_config(),
      list_devices: fn -> {:ok, [phone]} end,
      load_identity: forbidden,
      dispatcher: fn _, _ -> flunk("suppressed delivery dispatched") end
    ]

    assert {:ok, %{status: :suppressed, reason: :connected, sent: 0}} =
             Push.notify(
               "main",
               8,
               "preview",
               Keyword.merge(common,
                 connected_devices: fn "main" -> {:ok, ["device-a"]} end,
                 read_frontier: fn _ -> flunk("connected state must decide first") end
               )
             )

    assert {:ok, %{status: :suppressed, reason: :read, sent: 0}} =
             Push.notify(
               "main",
               8,
               "preview",
               Keyword.merge(common,
                 connected_devices: fn "main" -> {:ok, []} end,
                 read_frontier: fn "main" -> {:ok, 8} end
               )
             )
  end

  # FEAT-2: an approval waits for a phone that is not connected; the push that
  # says so carries no content, the way an oversized preview already does.
  test "an approval push is content-free and goes only to an away profile" do
    {_gateway_public, gateway_private} = keypair(30)
    {device_public, device_private} = keypair(31)
    device = device("device-a", device_public, :binary.copy(<<32>>, 32), "token-a")
    test_pid = self()

    dispatcher = fn notifications, _config ->
      send(test_pid, {:dispatched, notifications})
      {:ok, Enum.map(notifications, &%{&1 | response: :success})}
    end

    assert {:ok, %{status: :sent, sent: 1}} =
             Push.notify_approval("main",
               config: valid_config(),
               connected_devices: fn "main" -> {:ok, []} end,
               read_frontier: fn _ -> flunk("an approval is no timeline row") end,
               list_devices: fn -> {:ok, [device]} end,
               load_identity: fn -> {:ok, %{gateway_private_key: gateway_private}} end,
               dispatcher: dispatcher,
               nonce_fun: fn 12 -> @nonce end
             )

    assert_receive {:dispatched, [notification]}

    assert get_in(notification.payload, ["aps", "alert"]) ==
             %{"title" => "Fermix", "body" => "Approval needed"}

    assert {:ok, key} =
             Push.derive_key(device_private, device_public(gateway_private), device.apns_key_salt)

    assert %{"profile_id" => "main", "preview_text" => nil} =
             decrypt_preview(
               key,
               get_in(notification.payload, ["fx", "n"]),
               get_in(notification.payload, ["fx", "c"])
             )

    assert {:ok, %{status: :suppressed, reason: :connected, sent: 0}} =
             Push.notify_approval("main",
               config: valid_config(),
               connected_devices: fn "main" -> {:ok, ["device-a"]} end,
               list_devices: fn -> {:ok, [device]} end,
               load_identity: fn -> flunk("a connected phone loaded the identity") end
             )

    assert {:ok, %{status: :disabled, sent: 0}} =
             Push.notify_approval("main",
               config: [enabled: false],
               connected_devices: fn _ -> {:ok, []} end,
               list_devices: fn -> {:ok, [device]} end,
               load_identity: fn -> flunk("an iPhone was sent with APNs off") end
             )
  end

  # The APNs config is the APNs route's alone: an away iPhone it cannot reach
  # fails with the config's own reason, before any credential is loaded.
  test "an invalid APNs config fails an away iPhone with the config's reason" do
    {device_public, _device_private} = keypair(34)
    iphone = device("device-a", device_public, :binary.copy(<<34>>, 32), "token-a")

    common = [
      connected_devices: fn _ -> {:ok, []} end,
      read_frontier: fn _ -> {:ok, 0} end,
      list_devices: fn -> {:ok, [iphone]} end,
      load_identity: fn -> flunk("an invalid config loaded the identity") end,
      dispatcher: fn _, _ -> flunk("an invalid config dispatched") end
    ]

    assert {:error, {:invalid_push_config, :topic, :missing}} =
             Push.notify(
               "main",
               1,
               "preview",
               Keyword.put(common, :config, Keyword.delete(valid_config(), :topic))
             )

    assert {:error, {:invalid_push_config, :environment, "staging"}} =
             Push.notify(
               "main",
               1,
               "preview",
               Keyword.put(common, :config, Keyword.put(valid_config(), :environment, "staging"))
             )
  end

  # APNs off switches off the APNs route alone: with no away phone holding a
  # Web Push subscription there is nothing to send, and nothing that sends is
  # touched.
  test "with APNs off and no away phone subscribed, push is disabled and needs no credentials" do
    {device_public, _device_private} = keypair(33)
    iphone = device("device-a", device_public, :binary.copy(<<33>>, 32), "token-a")

    assert {:ok, %{status: :disabled, sent: 0}} =
             Push.notify("main", 1, "preview",
               config: [enabled: false],
               connected_devices: fn _ -> {:ok, []} end,
               read_frontier: fn _ -> flunk("disabled push checked read state") end,
               list_devices: fn -> {:ok, [iphone]} end,
               load_identity: fn -> flunk("disabled push loaded identity") end,
               dispatcher: fn _, _ -> flunk("disabled push dispatched") end,
               web_push_key: fn -> flunk("disabled push loaded the Web Push key") end,
               web_push_send: fn _, _, _, _ -> flunk("disabled push sent a Web Push") end
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
               connected_devices: fn _ -> {:ok, []} end,
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
               connected_devices: fn _ -> {:ok, []} end,
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
          connected_devices: fn _ -> {:ok, []} end,
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

  # An Android phone is pushed through Web Push: one that registered only a
  # token (an older app's push_register) holds no subscription, and is refused
  # by name with a typed reason, never sent through APNs.
  describe "Android phones" do
    setup do
      {_gateway_public, gateway_private} = keypair(40)
      {android_public, _android_private} = keypair(41)
      {iphone_public, _iphone_private} = keypair(42)
      salt = :binary.copy(<<43>>, 32)

      android = %{device("pixel", android_public, salt, "android-token") | platform: "android"}
      iphone = %{device("iphone", iphone_public, salt, "apns-token") | platform: "ios"}

      %{gateway_private: gateway_private, android: android, iphone: iphone}
    end

    test "an Android phone is refused by name and type while the iPhones are pushed", ctx do
      test_pid = self()

      apns = fn notifications, _config ->
        send(test_pid, {:apns, Enum.map(notifications, & &1.device_token)})
        {:ok, Enum.map(notifications, &%{&1 | response: :success})}
      end

      legacy = %{ctx.iphone | device_id: "old-iphone", push_token: "apns-legacy", platform: nil}

      {result, log} =
        with_log(fn ->
          notify_phones(ctx, [ctx.android, ctx.iphone, legacy], dispatcher: apns)
        end)

      assert {:ok, %{status: :sent, sent: 2}} = result
      assert_receive {:apns, ["apns-token", "apns-legacy"]}

      assert log =~ "[warning]"

      assert log =~
               "mobile push refused pixel {:no_web_push_subscription, :android}: " <>
                 "an Android phone is pushed through Web Push, and this one holds no " <>
                 "subscription; nothing was sent"

      refute log =~ "android-token"
    end

    test "with only Android phones registered nothing is sent, each refused", ctx do
      second = %{ctx.android | device_id: "pixel-2", push_token: "android-token-2"}

      {result, log} =
        with_log(fn ->
          notify_phones(ctx, [ctx.android, second],
            load_identity: fn -> flunk("nothing to send loaded the identity") end,
            dispatcher: fn _, _ -> flunk("an Android phone was sent to APNs") end
          )
        end)

      assert {:ok, %{status: :unconfigured_platform, sent: 0}} = result
      assert log =~ "mobile push refused pixel {:no_web_push_subscription, :android}"
      assert log =~ "mobile push refused pixel-2 {:no_web_push_subscription, :android}"
    end

    test "an approval reaches only the iPhones", ctx do
      test_pid = self()

      apns = fn notifications, _config ->
        send(test_pid, {:apns, Enum.map(notifications, & &1.device_token)})
        {:ok, Enum.map(notifications, &%{&1 | response: :success})}
      end

      {result, log} =
        with_log(fn ->
          Push.notify_approval("main",
            config: valid_config(),
            connected_devices: fn "main" -> {:ok, []} end,
            list_devices: fn -> {:ok, [ctx.android, ctx.iphone]} end,
            load_identity: fn -> {:ok, %{gateway_private_key: ctx.gateway_private}} end,
            dispatcher: apns
          )
        end)

      assert {:ok, %{status: :sent, sent: 1}} = result
      assert_receive {:apns, ["apns-token"]}
      assert log =~ "mobile push refused pixel {:no_web_push_subscription, :android}"
    end
  end

  # M99: a phone holding a Web Push subscription is pushed through it, each
  # phone that is not connected at that moment is pushed on its own, and APNs
  # being off switches off the APNs route alone.
  describe "Web Push" do
    setup do
      {_gateway_public, gateway_private} = keypair(50)
      {phone_public, _phone_private} = keypair(51)
      salt = :binary.copy(<<52>>, 32)
      {web_public, web_private} = :crypto.generate_key(:ecdh, :prime256v1)

      iphone = %{device("iphone", phone_public, salt, "apns-iphone") | platform: "ios"}
      key = %WebPushKey{private: web_private, public: web_public}

      %{
        gateway_private: gateway_private,
        iphone: iphone,
        iphone_2: %{iphone | device_id: "iphone-2", push_token: "apns-iphone-2"},
        pixel: subscribed("pixel", phone_public, salt),
        pixel_2: subscribed("pixel-2", phone_public, salt),
        pixel_3: subscribed("pixel-3", phone_public, salt),
        key: key
      }
    end

    test "only the phones that are not connected are pushed, on both routes", ctx do
      phones = [ctx.iphone, ctx.iphone_2, ctx.pixel, ctx.pixel_2]

      assert {:ok, %{status: :sent, sent: 2}} =
               web_notify(ctx, phones,
                 connected_devices: fn "main" -> {:ok, ["iphone", "pixel"]} end
               )

      assert_receive {:apns, ["apns-iphone-2"]}
      assert_receive {:web_push, "fcm-pixel-2", plaintext, 86_400, [key: key]}
      assert key == ctx.key

      assert Jason.decode!(plaintext) == %{
               "v" => 1,
               "kind" => "message",
               "profile_id" => "main",
               "server_seq" => 52,
               "preview_text" => "hi"
             }

      refute_received {:web_push, _token, _plaintext, _ttl, _opts}
      refute_received {:apns, _tokens}
    end

    test "a subscribed phone is pushed with APNs off, and no iPhone is", ctx do
      assert {:ok, %{status: :sent, sent: 1}} =
               web_notify(ctx, [ctx.iphone, ctx.pixel],
                 config: [enabled: false],
                 load_identity: fn -> flunk("an iPhone was sent with APNs off") end,
                 dispatcher: fn _, _ -> flunk("an iPhone was sent with APNs off") end
               )

      assert_receive {:web_push, "fcm-pixel", _plaintext, 86_400, _opts}
      refute_received {:web_push, _token, _plaintext, _ttl, _opts}
    end

    test "with APNs off and every subscribed phone connected, nothing is sent", ctx do
      silent = [
        config: [enabled: false],
        connected_devices: fn _ -> {:ok, ["pixel"]} end,
        read_frontier: fn _ -> flunk("disabled push read the frontier") end,
        load_identity: fn -> flunk("an iPhone was sent with APNs off") end,
        web_push_key: fn -> flunk("a connected phone loaded the Web Push key") end,
        web_push_send: fn _, _, _, _ -> flunk("a connected phone was pushed") end
      ]

      assert {:ok, %{status: :disabled, sent: 0}} =
               web_notify(ctx, [ctx.iphone, ctx.pixel], silent)

      assert {:ok, %{status: :disabled, sent: 0}} =
               Push.notify_approval(
                 "main",
                 Keyword.merge(silent, list_devices: fn -> {:ok, [ctx.iphone, ctx.pixel]} end)
               )
    end

    test "each phone takes its own route once", ctx do
      assert {:ok, %{status: :sent, sent: 3}} =
               web_notify(ctx, [ctx.pixel, ctx.iphone, ctx.pixel_2])

      assert_receive {:apns, ["apns-iphone"]}
      assert_receive {:web_push, first, _plaintext, 86_400, _opts}
      assert_receive {:web_push, second, _plaintext, 86_400, _opts}
      assert Enum.sort([first, second]) == ["fcm-pixel", "fcm-pixel-2"]
      refute_received {:web_push, _token, _plaintext, _ttl, _opts}
      refute_received {:apns, _tokens}
    end

    test "a row already read is pushed to nobody", ctx do
      assert {:ok, %{status: :suppressed, reason: :read, sent: 0}} =
               web_notify(ctx, [ctx.iphone, ctx.pixel],
                 read_frontier: fn _ -> {:ok, 52} end,
                 dispatcher: fn _, _ -> flunk("a read row reached APNs") end,
                 web_push_key: fn -> flunk("a read row loaded the Web Push key") end,
                 web_push_send: fn _, _, _, _ -> flunk("a read row was pushed") end
               )
    end

    test "an approval carries no content", ctx do
      assert {:ok, %{status: :sent, sent: 1}} =
               Push.notify_approval(
                 "main",
                 Keyword.merge(web_opts(ctx, [ctx.pixel]),
                   read_frontier: fn _ -> flunk("an approval is no timeline row") end
                 )
               )

      assert_receive {:web_push, "fcm-pixel", plaintext, 300, _opts}

      assert Jason.decode!(plaintext) == %{
               "v" => 1,
               "kind" => "approval",
               "profile_id" => "main",
               "server_seq" => nil,
               "preview_text" => nil
             }
    end

    # An alert that an approval waits is noise once the approval expired: it
    # lives as long as the caller says the approval waits, at most a day.
    test "an approval's push lives its own wait, capped at a day; a row's lives a day", ctx do
      approval = fn opts ->
        Push.notify_approval("main", Keyword.merge(web_opts(ctx, [ctx.pixel]), opts))
      end

      assert {:ok, %{status: :sent, sent: 1}} = approval.(ttl_s: 60)
      assert_receive {:web_push, "fcm-pixel", _plaintext, 60, _opts}

      assert {:ok, %{status: :sent, sent: 1}} = approval.(ttl_s: 200_000)
      assert_receive {:web_push, "fcm-pixel", _plaintext, 86_400, _opts}

      for invalid <- [0, -5, 1.5, "60"] do
        assert {:error, {:invalid_ttl_s, ^invalid}} =
                 approval.(
                   ttl_s: invalid,
                   connected_devices: fn _ -> flunk("an invalid ttl reached presence") end
                 )
      end

      assert {:ok, %{status: :sent, sent: 1}} = web_notify(ctx, [ctx.pixel], ttl_s: 60)
      assert_receive {:web_push, "fcm-pixel", _plaintext, 86_400, _opts}
      refute_received {:web_push, _token, _plaintext, _ttl, _opts}
    end

    test "a subscribed phone is pushed while the APNs config is invalid", ctx do
      assert {:ok, %{status: :sent, sent: 1}} =
               web_notify(ctx, [ctx.pixel],
                 config: Keyword.delete(valid_config(), :topic),
                 load_identity: fn -> flunk("no iPhone needed the identity") end
               )

      assert_receive {:web_push, "fcm-pixel", _plaintext, 86_400, _opts}
    end

    test "an invalid APNs config fails the iPhone and still sends the subscribed phone", ctx do
      {result, log} =
        with_log(fn ->
          web_notify(ctx, [ctx.iphone, ctx.pixel],
            config: Keyword.delete(valid_config(), :topic),
            load_identity: fn -> flunk("an invalid config loaded the identity") end,
            dispatcher: fn _, _ -> flunk("an invalid config dispatched") end
          )
        end)

      assert {:error,
              {:push_failed,
               [%{device_id: "iphone", reason: {:invalid_push_config, :topic, :missing}}]}} =
               result

      assert_receive {:web_push, "fcm-pixel", _plaintext, 86_400, _opts}
      assert [_once] = Regex.scan(~r/mobile push could not use its APNs config/, log)
    end

    test "an invalid APNs config with no registered phone is no push's business", ctx do
      assert {:ok, %{status: :no_registered_devices, sent: 0}} =
               web_notify(ctx, [], config: Keyword.delete(valid_config(), :topic))

      assert {:ok, %{status: :suppressed, reason: :connected, sent: 0}} =
               web_notify(ctx, [ctx.iphone],
                 config: Keyword.delete(valid_config(), :topic),
                 connected_devices: fn _ -> {:ok, ["iphone"]} end
               )
    end

    test "a subscription that is gone or refuses this key is dropped; a busy service's is not",
         ctx do
      answers = %{
        "fcm-pixel" => {:error, :gone},
        "fcm-pixel-2" => {:error, :sender_refused},
        "fcm-pixel-3" => {:error, {:unavailable, {:http, 503}}}
      }

      test_pid = self()

      {result, log} =
        with_log(fn ->
          web_notify(ctx, [ctx.pixel, ctx.pixel_2, ctx.pixel_3],
            web_push_send: fn subscription, _plaintext, _ttl, _opts ->
              Map.fetch!(answers, subscription.token)
            end,
            update_device: fn device_id, attrs ->
              send(test_pid, {:update_device, device_id, attrs})
              {:ok, ctx.pixel}
            end
          )
        end)

      assert {:error,
              {:push_failed,
               [
                 %{device_id: "pixel", reason: :gone},
                 %{device_id: "pixel-2", reason: :sender_refused},
                 %{device_id: "pixel-3", reason: {:unavailable, {:http, 503}}}
               ]}} = result

      cleared = %{push_token: nil, push_service: nil, push_p256dh: nil, push_auth: nil}
      assert_receive {:update_device, "pixel", ^cleared}
      assert_receive {:update_device, "pixel-2", ^cleared}
      refute_received {:update_device, _device_id, _attrs}

      assert log =~ "mobile Web Push dropped pixel's subscription: the push service says"
      assert log =~ "mobile Web Push dropped pixel-2's subscription: the push service refused"
      refute log =~ "dropped pixel-3"
      refute log =~ "fcm-pixel"
    end

    test "a missing key fails the Web Push phones and still sends the iPhones", ctx do
      {result, log} =
        with_log(fn ->
          web_notify(ctx, [ctx.iphone, ctx.pixel, ctx.pixel_2],
            web_push_key: fn -> {:error, :absent} end,
            web_push_send: fn _, _, _, _ -> flunk("a Web Push was sent with no key") end
          )
        end)

      assert {:error,
              {:push_failed,
               [
                 %{device_id: "pixel", reason: {:web_push_key, :absent}},
                 %{device_id: "pixel-2", reason: {:web_push_key, :absent}}
               ]}} = result

      assert_receive {:apns, ["apns-iphone"]}
      assert [_once] = Regex.scan(~r/mobile Web Push has no key/, log)
    end

    test "one push telemetry event per phone, the APNs leg's own event", ctx do
      TelemetryCapture.attach([[:fermix, :channel, :push]], :emitter)

      assert {:error, {:push_failed, [%{device_id: "pixel-2", reason: :gone}]}} =
               web_notify(ctx, [ctx.iphone, ctx.pixel, ctx.pixel_2],
                 web_push_send: fn subscription, _plaintext, _ttl, _opts ->
                   if subscription.token == "fcm-pixel-2", do: {:error, :gone}, else: :ok
                 end,
                 update_device: fn _id, _attrs -> {:ok, ctx.pixel_2} end
               )

      for status <- [:sent, :sent, :failed] do
        assert_receive {:telemetry, [:fermix, :channel, :push], %{count: 1, duration_us: us},
                        %{channel: :mobile, status: ^status}}

        assert us >= 0
      end

      refute_received {:telemetry, _event, _measurements, _metadata}
    end

    test "a send that does not finish in time is killed and counted against its phone", ctx do
      TelemetryCapture.attach([[:fermix, :channel, :push]], :emitter)

      {result, log} =
        with_log(fn ->
          web_notify(ctx, [ctx.iphone, ctx.pixel],
            web_push_timeout_ms: 1,
            web_push_send: fn _, _, _, _ ->
              receive do
                :never_sent -> :ok
              end
            end
          )
        end)

      assert {:error, {:push_failed, [%{device_id: "pixel", reason: :timeout}]}} = result
      assert_receive {:apns, ["apns-iphone"]}
      assert log =~ "mobile Web Push to pixel did not finish"

      assert_receive {:telemetry, [:fermix, :channel, :push], _measurements, %{status: :sent}}
      assert_receive {:telemetry, [:fermix, :channel, :push], _measurements, %{status: :failed}}
    end
  end

  defp web_notify(ctx, devices, opts \\ []) do
    Push.notify("main", 52, "hi", Keyword.merge(web_opts(ctx, devices), opts))
  end

  # Every seam a push reaches, the Web Push sender a stub that reports to the
  # test: no network, no waiting.
  defp web_opts(ctx, devices) do
    test_pid = self()

    [
      config: valid_config(),
      connected_devices: fn _ -> {:ok, []} end,
      read_frontier: fn _ -> {:ok, 51} end,
      list_devices: fn -> {:ok, devices} end,
      load_identity: fn -> {:ok, %{gateway_private_key: ctx.gateway_private}} end,
      dispatcher: fn notifications, _config ->
        send(test_pid, {:apns, Enum.map(notifications, & &1.device_token)})
        {:ok, Enum.map(notifications, &%{&1 | response: :success})}
      end,
      web_push_key: fn -> {:ok, ctx.key} end,
      web_push_send: fn subscription, plaintext, ttl_s, opts ->
        send(test_pid, {:web_push, subscription.token, plaintext, ttl_s, opts})
        :ok
      end,
      update_device: fn _id, _attrs -> flunk("a registration was cleared") end
    ]
  end

  defp subscribed(id, noise_pk, salt) do
    {p256dh, _private} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      device(id, noise_pk, salt, "fcm-#{id}")
      | platform: "android",
        push_service: "fcm",
        push_p256dh: p256dh,
        push_auth: :crypto.strong_rand_bytes(16)
    }
  end

  defp notify_phones(ctx, devices, opts) do
    Push.notify(
      "main",
      52,
      "hi",
      Keyword.merge(
        [
          config: valid_config(),
          connected_devices: fn _ -> {:ok, []} end,
          read_frontier: fn _ -> {:ok, 51} end,
          list_devices: fn -> {:ok, devices} end,
          load_identity: fn -> {:ok, %{gateway_private_key: ctx.gateway_private}} end
        ],
        opts
      )
    )
  end

  defp notify_with_dispatcher(device, gateway_private, dispatcher) do
    Push.notify("main", 52, "private preview",
      config: valid_config(),
      connected_devices: fn _ -> {:ok, []} end,
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
