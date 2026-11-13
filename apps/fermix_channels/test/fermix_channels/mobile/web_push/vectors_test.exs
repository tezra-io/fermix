defmodule FermixChannels.Mobile.WebPush.VectorsTest do
  @moduledoc """
  Holds the engine to `priv/mobile/webpush_vectors.json`, the contract the
  Android app tests its decryption against: RFC 8291's own example, one Fermix
  message the engine sealed, and one VAPID header.
  """
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.WebPush.Encryption
  alias FermixChannels.Mobile.WebPush.Payload
  alias FermixChannels.Mobile.WebPush.Vapid
  alias FermixChannels.Test.WebPushDecrypt

  @path Application.app_dir(:fermix_core, "priv/mobile/webpush_vectors.json")
  @kinds %{"message" => :message, "approval" => :approval}

  setup_all do
    %{vectors: @path |> File.read!() |> Jason.decode!()}
  end

  defp b64(value), do: Base.url_decode64!(value, padding: false)

  defp jwt_parts(authorization) do
    [_whole, token, k] =
      Regex.run(~r/\Avapid t=([A-Za-z0-9_.-]+), k=([A-Za-z0-9_-]+)\z/, authorization)

    [header, claims, signature] = String.split(token, ".")

    %{
      signing_input: header <> "." <> claims,
      header: b64(header),
      claims: b64(claims),
      signature: b64(signature),
      k: k
    }
  end

  defp verifies?(%{signing_input: input, signature: <<r::256, s::256>>}, public) do
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    :crypto.verify(:ecdsa, :sha256, input, der, [public, :secp256r1])
  end

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
    assert {:ok, b64(case_b["phone_public"])} == Vapid.public_key(b64(case_b["phone_private"]))
    assert {:ok, b64(case_b["sender_public"])} == Vapid.public_key(b64(case_b["sender_private"]))
  end

  test "the VAPID case: the engine signs the same claims, and the example verifies",
       %{vectors: %{"vapid" => vapid}} do
    private = b64(vapid["signing_private"])
    public = b64(vapid["signing_public"])

    assert {:ok, ^public} = Vapid.public_key(private)
    assert vapid["exp"] == vapid["now"] + 43_200

    assert {:ok, fresh} = Vapid.authorization(private, public, vapid["aud"], vapid["now"])
    fresh = jwt_parts(fresh)
    example = jwt_parts(vapid["example_authorization"])

    for parts <- [fresh, example] do
      assert parts.header == vapid["jwt_header"]
      assert parts.claims == vapid["claims"]
      assert b64(parts.k) == public
      assert verifies?(parts, public)
    end

    assert Jason.decode!(vapid["claims"]) == %{
             "aud" => vapid["aud"],
             "exp" => vapid["exp"],
             "sub" => vapid["sub"]
           }
  end
end
