defmodule FermixChannels.Mobile.WebPush.EncryptionTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.WebPush.Encryption
  alias FermixChannels.Test.WebPushDecrypt

  # RFC 8291 section 5 and Appendix A, cut from the published text
  # (https://www.rfc-editor.org/rfc/rfc8291.txt) by script, whitespace removed.
  @rfc %{
    plaintext: "V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24",
    as_public:
      "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
    as_private: "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw",
    ua_public:
      "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
    ua_private: "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94",
    salt: "DGv6ra1nlYgDCS1FRnbzlw",
    auth_secret: "BTBZMqHH6r4Tts7J_aSIgg",
    header:
      "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
    padded_plaintext: "V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24C",
    ciphertext: "8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ",
    body:
      "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocI" <>
        "nmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVW" <>
        "GNWQexSgSxsj_Qulcy4a-fN"
  }

  # P-256's field prime.
  @p 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF

  defp b64(value), do: Base.url_decode64!(value, padding: false)
  defp rfc(key), do: b64(Map.fetch!(@rfc, key))

  defp phone do
    {public, private} = :crypto.generate_key(:ecdh, :secp256r1)
    %{public: public, private: private, auth: :crypto.strong_rand_bytes(16)}
  end

  describe "RFC 8291 Appendix A" do
    test "the published example reproduces byte for byte through the record sealer" do
      assert rfc(:padded_plaintext) == rfc(:plaintext) <> <<2>>

      assert {:ok, body} =
               Encryption.seal_record(
                 rfc(:padded_plaintext),
                 rfc(:ua_public),
                 rfc(:auth_secret),
                 salt: rfc(:salt),
                 ephemeral_key: {rfc(:as_public), rfc(:as_private)}
               )

      assert body == rfc(:body)
      assert binary_part(body, 0, 86) == rfc(:header)
      assert binary_part(body, 86, byte_size(body) - 86) == rfc(:ciphertext)
      # Header, 41 bytes of text, the delimiter and the tag. (The RFC's sample
      # request says `Content-Length: 145`; the body it prints is 144 bytes.)
      assert byte_size(body) == 86 + 41 + 1 + 16
    end

    test "the published body opens with the receiver's key" do
      assert {:ok, opened} =
               WebPushDecrypt.decrypt(rfc(:body), rfc(:ua_private), rfc(:auth_secret))

      assert opened.plaintext == "When I grow up, I want to be a watermelon"
      assert opened.rs == 4_096
      assert opened.sender_public == rfc(:as_public)
    end
  end

  describe "encrypt/4" do
    test "every body is 2,150 bytes, whatever the plaintext's length" do
      %{public: public, auth: auth} = phone()

      assert Encryption.padded_size() == 2_048
      assert Encryption.body_size() == 2_150

      for size <- [0, 1, 42, 1_000, 2_046, 2_047] do
        assert {:ok, body} = Encryption.encrypt(:binary.copy("a", size), public, auth)
        assert byte_size(body) == 2_150
      end
    end

    test "the record is the plaintext, the 0x02 delimiter and zeros, 2,048 bytes in all" do
      %{public: public, private: private, auth: auth} = phone()
      plaintext = ~s({"v":1,"kind":"message"})

      assert {:ok, body} = Encryption.encrypt(plaintext, public, auth)
      assert {:ok, opened} = WebPushDecrypt.decrypt(body, private, auth)

      assert opened.plaintext == plaintext
      assert byte_size(opened.record) == 2_048
      zeros = 2_048 - byte_size(plaintext) - 1
      assert opened.record == plaintext <> <<2>> <> :binary.copy(<<0>>, zeros)
    end

    test "the header carries the salt, a record size above the record, and the sender's key" do
      %{public: public, private: private, auth: auth} = phone()
      salt = :crypto.strong_rand_bytes(16)
      {sender_public, sender_private} = :crypto.generate_key(:ecdh, :secp256r1)

      assert {:ok, body} =
               Encryption.encrypt("hello", public, auth,
                 salt: salt,
                 ephemeral_key: {sender_public, sender_private}
               )

      assert <<^salt::binary-16, rs::32, 65, ^sender_public::binary-65, _sealed::binary>> = body
      assert rs == 4_096
      assert rs > 2_048 + 16
      assert {:ok, %{plaintext: "hello"}} = WebPushDecrypt.decrypt(body, private, auth)
    end

    test "each call draws a fresh salt and a fresh sender key" do
      %{public: public, private: private, auth: auth} = phone()

      assert {:ok, first} = Encryption.encrypt("same", public, auth)
      assert {:ok, second} = Encryption.encrypt("same", public, auth)

      assert binary_part(first, 0, 16) != binary_part(second, 0, 16)
      assert binary_part(first, 21, 65) != binary_part(second, 21, 65)
      assert {:ok, %{plaintext: "same"}} = WebPushDecrypt.decrypt(first, private, auth)
      assert {:ok, %{plaintext: "same"}} = WebPushDecrypt.decrypt(second, private, auth)
    end

    test "the auth secret is part of the key: another one does not open the body" do
      %{public: public, private: private, auth: auth} = phone()

      assert {:ok, body} = Encryption.encrypt("sealed", public, auth)
      assert {:error, :decrypt_failed} = WebPushDecrypt.decrypt(body, private, <<0::128>>)
    end

    test "a plaintext that would not leave room for the delimiter is refused" do
      %{public: public, auth: auth} = phone()

      assert {:error, :plaintext_too_large} =
               Encryption.encrypt(:binary.copy("a", 2_048), public, auth)
    end
  end

  describe "refusals" do
    test "a phone key that is not an uncompressed P-256 point is refused, never raised" do
      %{public: <<4, x::256, y::256>>, auth: auth} = phone()

      not_points = [
        binary_part(<<4, x::256, y::256>>, 0, 64),
        <<4, x::256, y::256, 0>>,
        <<2, x::256>>,
        <<3, x::256, y::256>>,
        <<4, x::256, rem(y + 1, @p)::256>>,
        <<4, @p::256, y::256>>,
        <<4, x::256, @p::256>>,
        <<4, 0::512>>,
        ""
      ]

      for p256dh <- not_points do
        assert {:error, :invalid_p256dh} = Encryption.encrypt("x", p256dh, auth)
      end
    end

    # The check `encrypt/4` makes, asked on its own when a phone subscribes.
    test "valid_point?/1 holds a phone key to the check encrypt/4 makes" do
      %{public: <<4, x::256, y::256>> = public} = phone()

      assert Encryption.valid_point?(public)
      assert Encryption.valid_point?(rfc(:ua_public))

      for not_point <- [
            <<4, x::256, rem(y + 1, @p)::256>>,
            <<4, 1::256, 1::256>>,
            <<4, @p::256, y::256>>,
            <<4, x::256, @p::256>>,
            <<4, 0::512>>,
            <<3, x::256, y::256>>,
            binary_part(public, 0, 64),
            ""
          ] do
        refute Encryption.valid_point?(not_point), inspect(not_point)
      end
    end

    test "an auth secret that is not 16 bytes is refused" do
      %{public: public} = phone()

      for auth <- ["", <<0::120>>, <<0::136>>] do
        assert {:error, :invalid_auth} = Encryption.encrypt("x", public, auth)
      end
    end

    test "the test seams are checked, and an unknown option is refused" do
      %{public: public, auth: auth} = phone()

      assert {:error, {:invalid_option, :salt}} =
               Encryption.encrypt("x", public, auth, salt: <<0::120>>)

      assert {:error, {:invalid_option, :ephemeral_key}} =
               Encryption.encrypt("x", public, auth, ephemeral_key: {<<4, 0::512>>, <<1::248>>})

      assert {:error, {:invalid_option, :ephemeral_key}} =
               Encryption.encrypt("x", public, auth, ephemeral_key: :not_a_pair)

      assert {:error, {:unknown_options, [:padding]}} =
               Encryption.encrypt("x", public, auth, padding: 0)
    end
  end
end
