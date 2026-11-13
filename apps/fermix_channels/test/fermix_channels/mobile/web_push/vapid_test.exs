defmodule FermixChannels.Mobile.WebPush.VapidTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.WebPush.Vapid

  # RFC 8292 Figure 1, cut from the published text by script (whitespace
  # removed); the same script verified it with Python's `cryptography`.
  @rfc_token "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiJ9.eyJhdWQiOiJodHRwczovL3B1c2guZXhhbXBsZS5uZXQiLCJleHAiOjE0NTM1MjM3NjgsInN1YiI6Im1haWx0bzpwdXNoQGV4YW1wbGUuY29tIn0.i3CYb7t4xfxCDquptFOepC9GAu_HLGkMlMuCGSK2rpiUfnK9ojFwDXb1JrErtmysazNjjvW2L9OkSSHzvoD1oA"
  @rfc_key "BA1Hxzyi1RUM1b5wjxsn7nGxAszw2u61m164i3MrAIxHF6YK5h4SDYic-dRuU_RCPCfA5aq9ojSwk5Y2EmClBPs"

  @n 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
  @aud "https://fcm.googleapis.com"
  @now 1_794_268_800

  defp b64(value), do: Base.url_decode64!(value, padding: false)

  defp key_pair do
    {public, private} = :crypto.generate_key(:ecdh, :secp256r1)
    %{public: public, private: private}
  end

  # A JWS ES256 signature is r || s, 32 bytes each; `:crypto.verify/5` wants
  # the DER `ECDSA-Sig-Value`.
  defp verifies?(token, public) do
    [header, claims, signature] = String.split(token, ".")
    <<r::256, s::256>> = b64(signature)
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    :crypto.verify(:ecdsa, :sha256, header <> "." <> claims, der, [public, :secp256r1])
  end

  defp parse(header_value) do
    [_whole, token, k] =
      Regex.run(~r/\Avapid t=([A-Za-z0-9_.-]+), k=([A-Za-z0-9_-]+)\z/, header_value)

    [header, claims, signature] = String.split(token, ".")
    %{token: token, k: k, header: b64(header), claims: b64(claims), signature: b64(signature)}
  end

  test "the verifier this file uses accepts RFC 8292's published token" do
    assert verifies?(@rfc_token, b64(@rfc_key))
  end

  describe "authorization/4" do
    test "the header value is `vapid t=<jwt>, k=<public key>`" do
      %{public: public, private: private} = key_pair()

      assert {:ok, value} = Vapid.authorization(private, public, @aud, @now)
      parsed = parse(value)

      assert parsed.k == Base.url_encode64(public, padding: false)
      assert b64(parsed.k) == public
      # base64url without padding: 65 bytes are 87 characters.
      assert byte_size(parsed.k) == 87
    end

    test "the JWT's header and claims are the exact bytes, exp twelve hours on" do
      %{public: public, private: private} = key_pair()

      assert {:ok, value} = Vapid.authorization(private, public, @aud, @now)
      parsed = parse(value)

      assert parsed.header == ~s({"typ":"JWT","alg":"ES256"})

      assert parsed.claims ==
               ~s({"aud":"https://fcm.googleapis.com","exp":#{@now + 43_200},"sub":"https://fermix.ai"})
    end

    test "the signature is 64 raw bytes and verifies under the public key" do
      %{public: public, private: private} = key_pair()
      %{public: other} = key_pair()

      assert {:ok, value} = Vapid.authorization(private, public, @aud, @now)
      %{token: token, signature: signature} = parse(value)

      assert byte_size(signature) == 64
      assert verifies?(token, public)
      refute verifies?(token, other)
    end

    test "a claim changed after signing no longer verifies" do
      %{public: public, private: private} = key_pair()

      assert {:ok, value} = Vapid.authorization(private, public, @aud, @now)
      [header, _claims, signature] = String.split(parse(value).token, ".")

      forged =
        ~s({"aud":"https://fcm.googleapis.com","exp":#{@now + 86_400},"sub":"https://fermix.ai"})

      refute verifies?(
               header <> "." <> Base.url_encode64(forged, padding: false) <> "." <> signature,
               public
             )
    end

    test "a public key that is not the private key's is refused" do
      %{private: private} = key_pair()
      %{public: other} = key_pair()

      assert {:error, :key_mismatch} = Vapid.authorization(private, other, @aud, @now)
    end

    test "a private scalar outside 1..n-1, or of the wrong size, is refused" do
      %{public: public} = key_pair()

      for private <- [<<0::256>>, <<@n::256>>, <<@n + 1::256>>, <<1::248>>, <<1::264>>] do
        assert {:error, :invalid_private_key} = Vapid.authorization(private, public, @aud, @now)
      end
    end

    test "the audience must be an origin exactly as `audience/1` writes it" do
      %{public: public, private: private} = key_pair()

      for audience <- [
            "https://fcm.googleapis.com/",
            "https://FCM.googleapis.com",
            "http://fcm.googleapis.com",
            ""
          ] do
        assert {:error, :invalid_audience} = Vapid.authorization(private, public, audience, @now)
      end
    end

    test "a negative time is refused" do
      %{public: public, private: private} = key_pair()
      assert {:error, :invalid_time} = Vapid.authorization(private, public, @aud, -1)
    end
  end

  describe "public_key/1" do
    test "derives the uncompressed point of a private scalar" do
      %{public: public, private: private} = key_pair()

      assert {:ok, ^public} = Vapid.public_key(private)
      assert {:error, :invalid_private_key} = Vapid.public_key(<<0::256>>)
      assert {:error, :invalid_private_key} = Vapid.public_key("short")
    end
  end

  describe "audience/1" do
    test "is the scheme and host of an https endpoint, with a port only when it is not 443" do
      assert {:ok, "https://fcm.googleapis.com"} =
               Vapid.audience("https://fcm.googleapis.com/fcm/send/abc:DEF_123")

      assert {:ok, "https://push.example.net:8443"} =
               Vapid.audience("https://Push.Example.NET:8443/p/xyz")

      assert {:ok, "https://fcm.googleapis.com"} = Vapid.audience("https://fcm.googleapis.com")
    end

    test "anything but an https URL with a host name is refused" do
      for url <- [
            "http://fcm.googleapis.com/fcm/send/abc",
            "https:///fcm/send/abc",
            "https://user@fcm.googleapis.com/fcm/send/abc",
            "https://[::1]/p",
            "fcm.googleapis.com/fcm/send/abc",
            "not a url",
            ""
          ] do
        assert {:error, :invalid_endpoint} = Vapid.audience(url)
      end
    end
  end
end
