defmodule FermixChannels.Mobile.WebPush.VectorsTest do
  @moduledoc """
  Holds the engine to `priv/mobile/webpush_vectors.json`, the contract the
  Android app tests its decryption against: RFC 8291's own example, and one
  Fermix message the engine sealed with the phone's private key beside it.
  """
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.WebPush.Encryption
  alias FermixChannels.Mobile.WebPush.Payload
  alias FermixChannels.Test.WebPushDecrypt

  @path Application.app_dir(:fermix_core, "priv/mobile/webpush_vectors.json")
  @kinds %{"message" => :message, "approval" => :approval}

  setup_all do
    %{vectors: @path |> File.read!() |> Jason.decode!()}
  end

  defp b64(value), do: Base.url_decode64!(value, padding: false)

  test "RFC 8291's published example reproduces", %{vectors: %{"rfc8291_example" => rfc}} do
    assert {:ok, body} =
             Encryption.seal_record(
               b64(rfc["padded_plaintext"]),
               b64(rfc["ua_public"]),
               b64(rfc["auth_secret"]),
               salt: b64(rfc["salt"]),
               ephemeral_key: {b64(rfc["as_public"]), b64(rfc["as_private"])}
             )

    assert body == b64(rfc["body"])
    assert rfc["rs"] == 4_096
  end

  test "the Fermix message is the engine's own plaintext and body, byte for byte",
       %{vectors: %{"fermix_message" => case_b}} do
    payload = case_b["payload"]

    assert {:ok, plaintext} =
             Payload.encode(%{
               kind: Map.fetch!(@kinds, payload["kind"]),
               profile_id: payload["profile_id"],
               server_seq: payload["server_seq"],
               preview_text: payload["preview_text"]
             })

    assert plaintext == case_b["plaintext"]

    assert {:ok, body} =
             Encryption.encrypt(
               plaintext,
               b64(case_b["phone_public"]),
               b64(case_b["auth_secret"]),
               salt: b64(case_b["salt"]),
               ephemeral_key: {b64(case_b["sender_public"]), b64(case_b["sender_private"])}
             )

    assert body == b64(case_b["body"])
    assert byte_size(body) == case_b["body_size"]
    assert case_b["body_size"] == Encryption.body_size()
    assert case_b["padded_size"] == Encryption.padded_size()

    assert {:ok, opened} =
             WebPushDecrypt.decrypt(
               body,
               b64(case_b["phone_private"]),
               b64(case_b["auth_secret"])
             )

    assert opened.plaintext == plaintext
    assert opened.rs == case_b["rs"]
    assert b64(case_b["phone_public"]) == public_key(b64(case_b["phone_private"]))
    assert b64(case_b["sender_public"]) == public_key(b64(case_b["sender_private"]))
  end

  # The vectors carry only what the engine seals with: no signing key and no
  # signed pass, since the relay holds Google's sending right (M99 §14).
  test "the vectors name no signing key of the home's own", %{vectors: vectors} do
    assert Map.keys(vectors) --
             ~w(source encoding content_coding key_schedule rfc8291_example fermix_message) ==
             []

    refute Map.has_key?(vectors, "vapid")
  end

  # The uncompressed P-256 public point of a private scalar.
  defp public_key(private) do
    {public, ^private} = :crypto.generate_key(:ecdh, :secp256r1, private)
    public
  end
end
