defmodule FermixCore.Home.Archive.Seal do
  @moduledoc """
  The encryption of a home archive: the whole tar as one AES-256-GCM blob under
  a key derived from a passphrase the owner holds.

      "FXHOME1\\n" | salt (16 bytes) | nonce (12 bytes) | ciphertext | tag (16 bytes)

  The key is PBKDF2-HMAC-SHA256 over the passphrase and the random salt,
  600,000 rounds, 32 bytes. The 36-byte header is the additional
  authenticated data, so the magic, the salt and the nonce are covered by the
  tag along with the content.

  Every way an archive can fail to open (a wrong passphrase, a wrong magic, a
  blob too short to hold a header and a tag, any changed byte) is one answer,
  `:archive_rejected`. Telling them apart would only tell a guesser which guess
  came closer.

  The archive carries the identity bundle, so the passphrase is the owner root
  (M75 D19): whoever holds it can stand up a primary every paired phone trusts.

  OTP's AEAD is one-shot and refuses an input of 2^31 bytes or more, so the
  plaintext is bounded below that (`max_plaintext_bytes/0`), and the whole of
  it is held in memory while it is sealed or opened.
  """

  @magic "FXHOME1\n"
  @salt_bytes 16
  @nonce_bytes 12
  @tag_bytes 16
  @key_bytes 32
  @rounds 600_000
  @min_passphrase_bytes 12
  @max_plaintext_bytes 2_000_000_000
  @header_bytes byte_size(@magic) + @salt_bytes + @nonce_bytes

  @type open_error :: :passphrase_too_short | :archive_rejected

  @doc "The fewest bytes a passphrase may have."
  @spec min_passphrase_bytes() :: pos_integer()
  def min_passphrase_bytes, do: @min_passphrase_bytes

  @doc "The largest plaintext one seal can hold."
  @spec max_plaintext_bytes() :: pos_integer()
  def max_plaintext_bytes, do: @max_plaintext_bytes

  @doc "The largest sealed blob `open/2` can hold: the plaintext bound plus header and tag."
  @spec max_sealed_bytes() :: pos_integer()
  def max_sealed_bytes, do: @header_bytes + @max_plaintext_bytes + @tag_bytes

  @doc "Seals `plaintext` under `passphrase`: the header, the ciphertext and the tag."
  @spec seal(binary(), binary()) ::
          {:ok, iodata()}
          | {:error, :passphrase_too_short | {:too_many_bytes, non_neg_integer(), pos_integer()}}
  def seal(plaintext, passphrase) when is_binary(plaintext) and is_binary(passphrase) do
    with :ok <- long_enough(passphrase),
         :ok <- within_plaintext_bound(byte_size(plaintext)) do
      salt = :crypto.strong_rand_bytes(@salt_bytes)
      nonce = :crypto.strong_rand_bytes(@nonce_bytes)
      header = @magic <> salt <> nonce

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key(passphrase, salt),
          nonce,
          plaintext,
          header,
          @tag_bytes,
          true
        )

      {:ok, [header, ciphertext, tag]}
    end
  end

  @doc "Opens a sealed blob, answering the plaintext or `:archive_rejected`."
  @spec open(binary(), binary()) :: {:ok, binary()} | {:error, open_error()}
  def open(sealed, passphrase) when is_binary(sealed) and is_binary(passphrase) do
    with :ok <- long_enough(passphrase) do
      decrypt(sealed, passphrase)
    end
  end

  defp decrypt(
         <<@magic, salt::binary-size(@salt_bytes), nonce::binary-size(@nonce_bytes),
           body::binary>> = sealed,
         passphrase
       )
       when byte_size(body) >= @tag_bytes do
    header = binary_part(sealed, 0, @header_bytes)
    ciphertext = binary_part(body, 0, byte_size(body) - @tag_bytes)
    tag = binary_part(body, byte_size(body) - @tag_bytes, @tag_bytes)
    key = key(passphrase, salt)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, header, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :archive_rejected}
    end
  end

  defp decrypt(_sealed, _passphrase), do: {:error, :archive_rejected}

  defp key(passphrase, salt),
    do: :crypto.pbkdf2_hmac(:sha256, passphrase, salt, @rounds, @key_bytes)

  defp long_enough(passphrase) when byte_size(passphrase) >= @min_passphrase_bytes, do: :ok
  defp long_enough(_passphrase), do: {:error, :passphrase_too_short}

  defp within_plaintext_bound(bytes) when bytes <= @max_plaintext_bytes, do: :ok

  defp within_plaintext_bound(bytes),
    do: {:error, {:too_many_bytes, bytes, @max_plaintext_bytes}}
end
