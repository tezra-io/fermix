defmodule FermixChannels.Test.WebPushDecrypt do
  @moduledoc """
  The receiving half of RFC 8291 for tests: what a phone does with a Web Push
  body the engine sealed. It lives here and not in `lib/`, because the engine
  never decrypts a push.

  It is written from RFC 8291 section 3.4 on its own, so a round trip through
  it checks the engine's derivation against a second reading of the standard
  (RFC 8291's own example pins both to the published bytes).
  """

  @type opened :: %{
          plaintext: binary(),
          record: binary(),
          rs: pos_integer(),
          salt: <<_::128>>,
          sender_public: <<_::520>>
        }

  @doc "Opens `body` with the phone's P-256 private key and its 16-byte auth secret."
  @spec decrypt(binary(), <<_::256>>, <<_::128>>) :: {:ok, opened()} | {:error, term()}
  def decrypt(body, ua_private, auth)
      when is_binary(body) and byte_size(ua_private) == 32 and byte_size(auth) == 16 do
    with {:ok, header, sealed} <- split_header(body),
         {:ok, record} <- open(header, sealed, ua_private, auth),
         {:ok, plaintext} <- unpad(record) do
      {:ok,
       %{
         plaintext: plaintext,
         record: record,
         rs: header.rs,
         salt: header.salt,
         sender_public: header.keyid
       }}
    end
  end

  defp split_header(<<salt::binary-16, rs::32, 65, keyid::binary-65, sealed::binary>>)
       when byte_size(sealed) > 16,
       do: {:ok, %{salt: salt, rs: rs, keyid: keyid}, sealed}

  defp split_header(_body), do: {:error, :bad_header}

  defp open(header, sealed, ua_private, auth) do
    {ua_public, _private} = :crypto.generate_key(:ecdh, :secp256r1, ua_private)
    ecdh_secret = :crypto.compute_key(:ecdh, header.keyid, ua_private, :secp256r1)
    prk_key = hmac(auth, ecdh_secret)
    ikm = hmac(prk_key, "WebPush: info" <> <<0>> <> ua_public <> header.keyid <> <<1>>)
    prk = hmac(header.salt, ikm)
    <<cek::binary-16, _cek_rest::binary>> = hmac(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>)
    <<nonce::binary-12, _nonce_rest::binary>> = hmac(prk, "Content-Encoding: nonce" <> <<0, 1>>)

    ciphertext_size = byte_size(sealed) - 16
    <<ciphertext::binary-size(ciphertext_size), tag::binary-16>> = sealed

    case :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false) do
      :error -> {:error, :decrypt_failed}
      record when is_binary(record) -> {:ok, record}
    end
  end

  # The last non-zero octet is the delimiter, and RFC 8291 section 4 allows
  # only 0x02 there (one record).
  defp unpad(record) do
    case String.trim_trailing(record, <<0>>) do
      "" -> {:error, :bad_delimiter}
      trimmed -> split_delimiter(trimmed, byte_size(trimmed) - 1)
    end
  end

  defp split_delimiter(trimmed, size) do
    case trimmed do
      <<plaintext::binary-size(size), 2>> -> {:ok, plaintext}
      _other -> {:error, :bad_delimiter}
    end
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
