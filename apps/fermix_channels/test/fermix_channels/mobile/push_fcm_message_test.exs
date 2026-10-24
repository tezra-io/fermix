defmodule FermixChannels.Mobile.Push.FcmMessageTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.DeviceStore.Device
  alias FermixChannels.Mobile.Push
  alias FermixChannels.Mobile.Push.FcmMessage

  @push_vectors_path Application.app_dir(:fermix_core, "priv/mobile/push_vectors.json")

  # The Android app is written against the exported cases, which a second
  # implementation computed, so the engine has to reproduce them byte for byte.
  test "the exported FCM cases are reproduced byte for byte" do
    document = @push_vectors_path |> File.read!() |> Jason.decode!()
    vector = document["vector"]
    fcm = document["fcm"]

    assert fcm["bucket_bytes"] == FcmMessage.bucket_bytes()
    assert fcm["reference"] =~ "apart from the engine"
    assert Enum.map(fcm["cases"], & &1["name"]) == ["message", "approval"]

    device =
      device(
        hex(vector["device_static_public"]),
        hex(vector["apns_key_salt"]),
        "fcm-vector-token"
      )

    for %{"name" => name, "plaintext" => plaintext, "data" => data} <- fcm["cases"] do
      assert {:ok, built} = plaintext(name, Jason.decode!(plaintext))
      assert Jason.encode!(built) == plaintext

      assert {:ok, %{"message" => message}} =
               FcmMessage.build(
                 device,
                 hex(vector["gateway_static_private"]),
                 built,
                 nonce_fun: fn 12 -> hex(vector["nonce"]) end
               )

      assert message["data"] == data
    end
  end

  test "a message is data-only, high priority and kept a day, under the device's token" do
    {device, gateway_private, key} = paired()
    {:ok, plaintext} = FcmMessage.message("main", 7, "the build is green")

    assert {:ok, %{"message" => message}} = FcmMessage.build(device, gateway_private, plaintext)

    assert Map.keys(message) == ["android", "data", "token"]
    assert message["token"] == device.push_token
    assert message["android"] == %{"priority" => "HIGH", "ttl" => "86400s"}
    assert Map.keys(message["data"]) == ["c", "n", "v"]
    assert message["data"]["v"] == "2"
    refute Jason.encode!(message) =~ "the build is green"

    padded = open(key, message["data"])
    assert byte_size(padded) == 2_048

    assert unpad(padded) ==
             ~s({"kind":"message","preview_text":"the build is green","profile_id":"main","server_seq":7})
  end

  test "every push is one bucket whatever it says" do
    {device, gateway_private, _key} = paired()

    sizes =
      for preview <- ["", "ok", String.duplicate("long reply ", 900)] do
        {:ok, plaintext} = FcmMessage.message("main", 1, preview)

        {:ok, %{"message" => %{"data" => data}}} =
          FcmMessage.build(device, gateway_private, plaintext)

        byte_size(data["c"])
      end

    assert Enum.uniq(sizes) == [2_752]
  end

  test "a preview past the bucket is cut at a character and ends with an ellipsis" do
    for unit <- ["a", "é", "👩‍💻", "\"", "\n"] do
      preview = String.duplicate(unit, 3_000)
      assert {:ok, %{"preview_text" => cut} = plaintext} = FcmMessage.message("main", 9, preview)

      assert String.ends_with?(cut, "…")
      assert String.starts_with?(preview, String.trim_trailing(cut, "…"))
      assert {:ok, padded} = FcmMessage.pad(plaintext)
      assert byte_size(padded) == 2_048

      # The cut is the longest that fits: one more character would not.
      longer = String.slice(preview, 0, String.length(cut)) <> "…"
      assert byte_size(Jason.encode!(%{plaintext | "preview_text" => longer})) >= 2_048
    end
  end

  test "an approval carries its id and expiry and nothing else" do
    assert {:ok, plaintext} = FcmMessage.approval("main", "sandbox:3f2a9c1e", 1_793_000_000)

    assert plaintext == %{
             "kind" => "approval",
             "profile_id" => "main",
             "approval_id" => "sandbox:3f2a9c1e",
             "expires_at" => 1_793_000_000
           }
  end

  test "malformed input fails loud at the boundary" do
    {device, gateway_private, _key} = paired()
    {:ok, plaintext} = FcmMessage.message("main", 1, "hi")

    assert {:error, {:invalid_fcm_plaintext, :server_seq, 0}} =
             FcmMessage.message("main", 0, "hi")

    assert {:error, {:invalid_fcm_plaintext, :profile_id}} = FcmMessage.message("", 1, "hi")

    assert {:error, {:invalid_fcm_plaintext, :preview_text}} =
             FcmMessage.message("main", 1, <<255>>)

    assert {:error, {:invalid_fcm_plaintext, :approval_id}} = FcmMessage.approval("main", "", 1)

    assert {:error, {:invalid_fcm_plaintext, :expires_at, -1}} =
             FcmMessage.approval("main", "a", -1)

    assert {:error, {:fcm_plaintext_too_large, _size, 2_047}} =
             FcmMessage.pad(%{
               "kind" => "message",
               "preview_text" => String.duplicate("a", 2_100)
             })

    assert {:error, {:invalid_push_field, :push_token}} =
             FcmMessage.build(%{device | push_token: nil}, gateway_private, plaintext)

    assert {:error, :invalid_push_nonce} =
             FcmMessage.build(device, gateway_private, plaintext, nonce_fun: fn _ -> "short" end)
  end

  defp plaintext("message", map),
    do: FcmMessage.message(map["profile_id"], map["server_seq"], map["preview_text"])

  defp plaintext("approval", map),
    do: FcmMessage.approval(map["profile_id"], map["approval_id"], map["expires_at"])

  defp paired do
    {_gateway_public, gateway_private} = keypair(1)
    {device_public, _device_private} = keypair(2)
    salt = :binary.copy(<<3>>, 32)
    {:ok, key} = Push.derive_key(gateway_private, device_public, salt)
    {device(device_public, salt, "fcm-token-1"), gateway_private, key}
  end

  defp device(noise_pk, salt, token) do
    %Device{
      device_id: "pixel",
      name: "Pixel",
      model: "Google Pixel 9a",
      noise_pk: noise_pk,
      push_token: token,
      created_at: ~U[2026-10-24 00:00:00Z],
      apns_key_salt: salt,
      platform: "android"
    }
  end

  defp open(key, %{"n" => nonce, "c" => sealed}) do
    sealed = Base.decode64!(sealed)
    size = byte_size(sealed) - 16
    <<ciphertext::binary-size(size), tag::binary-size(16)>> = sealed

    :crypto.crypto_one_time_aead(
      :chacha20_poly1305,
      key,
      Base.decode64!(nonce),
      ciphertext,
      <<>>,
      tag,
      false
    )
  end

  defp unpad(padded) do
    [json, zeros] = :binary.split(padded, <<0x80>>)
    assert zeros == :binary.copy(<<0>>, byte_size(zeros))
    json
  end

  defp keypair(byte) do
    private = :binary.copy(<<byte>>, 32)
    {public, ^private} = :crypto.generate_key(:ecdh, :x25519, private)
    {public, private}
  end

  defp hex(value), do: Base.decode16!(value, case: :lower)
end
