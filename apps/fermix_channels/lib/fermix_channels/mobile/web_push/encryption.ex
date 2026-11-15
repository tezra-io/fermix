defmodule FermixChannels.Mobile.WebPush.Encryption do
  @moduledoc """
  Web Push message encryption (RFC 8291) in the `aes128gcm` content coding
  (RFC 8188), one record. Pure.

  The body is the content coding's header and one sealed record:

      salt (16) | rs (4, big-endian) = 4096 | idlen (1) = 65 | keyid (65) | ciphertext and tag

  `keyid` is the sender's ephemeral P-256 public key in uncompressed form, made
  fresh for each message, and the salt is fresh too. The record is the
  plaintext, the 0x02 delimiter and zero bytes, and is always
  `padded_size/0` (2,048) bytes, so every body is `body_size/0` (2,150) bytes
  and its length tells the push service nothing about the message. A plaintext
  longer than 2,047 bytes is refused.

  The phone's key must be an uncompressed P-256 point on the curve (RFC 8291
  section 7), and its auth secret 16 bytes; anything else is refused before
  any key agreement.

  The key schedule is RFC 8291 section 3.4, HKDF-SHA256 written out as HMACs:

      PRK_key = HMAC(auth, ECDH(as_private, ua_public))
      IKM     = HMAC(PRK_key, "WebPush: info" || 0x00 || ua_public || as_public || 0x01)
      PRK     = HMAC(salt, IKM)
      CEK     = HMAC(PRK, "Content-Encoding: aes128gcm" || 0x00 || 0x01)[0..15]
      NONCE   = HMAC(PRK, "Content-Encoding: nonce" || 0x00 || 0x01)[0..11]

  `:salt` (16 bytes) and `:ephemeral_key` (`{public65, private32}`) are test
  seams only; production draws both from `:crypto` on every call.
  """

  @salt_size 16
  @auth_size 16
  @tag_size 16
  @padded_size 2_048
  @max_plaintext @padded_size - 1
  @record_size 4_096
  @key_id_size 65
  @header_size @salt_size + 4 + 1 + @key_id_size
  @body_size @header_size + @padded_size + @tag_size
  @options [:salt, :ephemeral_key]

  # P-256 (FIPS 186-4 D.1.2.3): y^2 = x^3 - 3x + b over the prime field p.
  @p 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
  @b 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B

  @type error ::
          :plaintext_too_large
          | :invalid_p256dh
          | :invalid_auth
          | {:invalid_option, :salt | :ephemeral_key}
          | {:unknown_options, [atom()]}

  @doc "The size of the one record before sealing: plaintext, delimiter and padding."
  @spec padded_size() :: pos_integer()
  def padded_size, do: @padded_size

  @doc "The size of every body `encrypt/4` returns."
  @spec body_size() :: pos_integer()
  def body_size, do: @body_size

  @doc """
  Whether `p256dh` is a phone key `encrypt/4` takes: an uncompressed P-256
  point, 65 bytes whose first is 0x04, both coordinates in the field and on
  the curve (RFC 8291 section 7). The check `encrypt/4` makes, asked when a
  phone subscribes.
  """
  @spec valid_point?(binary()) :: boolean()
  def valid_point?(p256dh) when is_binary(p256dh), do: valid_p256dh(p256dh) == :ok

  @doc """
  Seals `plaintext` to the phone's `p256dh` key and `auth` secret as one
  `body_size/0` body.
  """
  @spec encrypt(plaintext :: binary(), p256dh :: <<_::520>>, auth :: <<_::128>>, keyword()) ::
          {:ok, binary()} | {:error, error()}
  def encrypt(plaintext, p256dh, auth, opts \\ [])
      when is_binary(plaintext) and is_binary(p256dh) and is_binary(auth) and is_list(opts) do
    case byte_size(plaintext) do
      size when size > @max_plaintext -> {:error, :plaintext_too_large}
      size -> seal_record(pad(plaintext, size), p256dh, auth, opts)
    end
  end

  @doc false
  # Seals an already padded record as it stands. `encrypt/4` is the API and
  # always pads to `padded_size/0`; this exists so RFC 8291's own example, whose
  # record is the plaintext and the delimiter alone, can be reproduced byte for
  # byte.
  @spec seal_record(binary(), binary(), binary(), keyword()) ::
          {:ok, binary()} | {:error, error()}
  def seal_record(record, p256dh, auth, opts)
      when is_binary(record) and byte_size(record) + @tag_size < @record_size and
             is_binary(p256dh) and is_binary(auth) and is_list(opts) do
    with :ok <- known_options(opts),
         :ok <- valid_p256dh(p256dh),
         :ok <- valid_auth(auth),
         {:ok, salt} <- salt(opts),
         {:ok, {as_public, as_private}} <- ephemeral_key(opts),
         {:ok, ecdh_secret} <- agree(p256dh, as_private) do
      {cek, nonce} = derive(ecdh_secret, auth, p256dh, as_public, salt)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, record, <<>>, true)

      {:ok,
       <<salt::binary, @record_size::32, @key_id_size, as_public::binary, ciphertext::binary,
         tag::binary>>}
    end
  end

  defp pad(plaintext, size),
    do: IO.iodata_to_binary([plaintext, 2, :binary.copy(<<0>>, @padded_size - size - 1)])

  defp known_options(opts) do
    case Keyword.keys(opts) -- @options do
      [] -> :ok
      unknown -> {:error, {:unknown_options, unknown}}
    end
  end

  # RFC 8291 section 7: not the point at infinity (an uncompressed encoding
  # cannot be), both coordinates in the field, and on the curve.
  defp valid_p256dh(<<4, x::256, y::256>>) when x < @p and y < @p do
    if on_curve?(x, y), do: :ok, else: {:error, :invalid_p256dh}
  end

  defp valid_p256dh(_p256dh), do: {:error, :invalid_p256dh}

  defp on_curve?(x, y), do: Integer.mod(y * y - (x * x * x - 3 * x + @b), @p) == 0

  defp valid_auth(auth) when byte_size(auth) == @auth_size, do: :ok
  defp valid_auth(_auth), do: {:error, :invalid_auth}

  defp salt(opts) do
    case Keyword.fetch(opts, :salt) do
      :error -> {:ok, :crypto.strong_rand_bytes(@salt_size)}
      {:ok, salt} when is_binary(salt) and byte_size(salt) == @salt_size -> {:ok, salt}
      {:ok, _other} -> {:error, {:invalid_option, :salt}}
    end
  end

  defp ephemeral_key(opts) do
    case Keyword.fetch(opts, :ephemeral_key) do
      :error -> {:ok, :crypto.generate_key(:ecdh, :secp256r1)}
      {:ok, {<<4, _::binary-64>>, <<_::256>>} = pair} -> {:ok, pair}
      {:ok, _other} -> {:error, {:invalid_option, :ephemeral_key}}
    end
  end

  # The point was checked above, so OpenSSL accepts it; should it refuse one
  # anyway, its raise is this function's refusal rather than the caller's crash.
  defp agree(p256dh, as_private) do
    {:ok, :crypto.compute_key(:ecdh, p256dh, as_private, :secp256r1)}
  rescue
    ErlangError -> {:error, :invalid_p256dh}
  end

  defp derive(ecdh_secret, auth, ua_public, as_public, salt) do
    prk_key = hmac(auth, ecdh_secret)
    ikm = hmac(prk_key, ["WebPush: info", 0, ua_public, as_public, 1])
    prk = hmac(salt, ikm)
    <<cek::binary-16, _cek_rest::binary>> = hmac(prk, ["Content-Encoding: aes128gcm", 0, 1])
    <<nonce::binary-12, _nonce_rest::binary>> = hmac(prk, ["Content-Encoding: nonce", 0, 1])
    {cek, nonce}
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
