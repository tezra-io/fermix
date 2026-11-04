defmodule FermixCore.Home.Snapshot.Recipient do
  @moduledoc """
  Who a snapshot is encrypted to (M75 B7): an X25519 key pair, and the text a
  primary keeps in `[fermix_core.snapshots] recipient`.

      fxsnap1.<salt>.<public key>

  both parts unpadded base64url, the salt 16 bytes and the public key 32.

  **From the recovery passphrase.** `derive/2` runs PBKDF2-HMAC-SHA256 over the
  passphrase and the salt, 600,000 rounds (the stage-1 archive seal's, so one
  passphrase costs a guesser the same either way), into the 32-byte X25519
  private key, and answers the pair. The primary keeps only the encoded public
  half: it writes snapshots on its own cadence without ever holding the
  passphrase, and a restore re-derives the private half from the passphrase and
  the salt the snapshot's header carries. The passphrase is never stored.

  **One-time pairs.** `generate/0` makes a fresh pair from random bytes, for the
  move (M75 §7.2): the candidate answers `move_accept` with its public half and
  restores the stream with the private half, which never leaves it. Its salt is
  random too and derives nothing; it is there so every recipient has the one
  shape and the one encoding.

  **Key id.** The first 8 bytes of the SHA-256 of the public key. A snapshot's
  header names it, so a restore tells a wrong passphrase from a damaged file
  before it decrypts a byte.
  """

  @prefix "fxsnap1"
  @salt_bytes 16
  @key_bytes 32
  @key_id_bytes 8
  @rounds 600_000
  @min_passphrase_bytes 12

  @typedoc "The public half and the salt it was derived with: what a primary keeps."
  @type t :: %{salt: <<_::128>>, public_key: <<_::256>>}
  @typedoc "A recipient with its private half: what a restore decrypts with."
  @type pair :: %{salt: <<_::128>>, public_key: <<_::256>>, secret_key: <<_::256>>}

  @doc "The fewest bytes a recovery passphrase may have (the archive seal's bound)."
  @spec min_passphrase_bytes() :: pos_integer()
  def min_passphrase_bytes, do: @min_passphrase_bytes

  @doc "The salt length in bytes."
  @spec salt_bytes() :: pos_integer()
  def salt_bytes, do: @salt_bytes

  @doc "The key id length in bytes."
  @spec key_id_bytes() :: pos_integer()
  def key_id_bytes, do: @key_id_bytes

  @doc """
  The pair `passphrase` and `salt` derive. Refuses a passphrase under
  #{@min_passphrase_bytes} bytes as `:passphrase_too_short`.
  """
  @spec derive(binary(), binary()) :: {:ok, pair()} | {:error, :passphrase_too_short}
  def derive(passphrase, salt)
      when is_binary(passphrase) and is_binary(salt) and byte_size(salt) == @salt_bytes do
    if byte_size(passphrase) >= @min_passphrase_bytes do
      private = :crypto.pbkdf2_hmac(:sha256, passphrase, salt, @rounds, @key_bytes)
      {:ok, pair(salt, private)}
    else
      {:error, :passphrase_too_short}
    end
  end

  @doc "A pair derived from `passphrase` under a new random salt."
  @spec from_passphrase(binary()) :: {:ok, pair()} | {:error, :passphrase_too_short}
  def from_passphrase(passphrase) when is_binary(passphrase),
    do: derive(passphrase, :crypto.strong_rand_bytes(@salt_bytes))

  @doc "A fresh one-time pair from random bytes, for the move."
  @spec generate() :: pair()
  def generate do
    pair(:crypto.strong_rand_bytes(@salt_bytes), :crypto.strong_rand_bytes(@key_bytes))
  end

  @doc "The public half of a recipient or a pair: what may be stored and shared."
  @spec public(t() | pair()) :: t()
  def public(%{salt: salt, public_key: public_key})
      when byte_size(salt) == @salt_bytes and byte_size(public_key) == @key_bytes,
      do: %{salt: salt, public_key: public_key}

  @doc "The 8-byte id of a public key, which a snapshot header names."
  @spec key_id(<<_::256>>) :: <<_::64>>
  def key_id(public_key) when is_binary(public_key) and byte_size(public_key) == @key_bytes,
    do: binary_part(:crypto.hash(:sha256, public_key), 0, @key_id_bytes)

  @doc "The text a primary keeps: `fxsnap1.<salt>.<public key>`, base64url without padding."
  @spec encode(t() | pair()) :: String.t()
  def encode(recipient) do
    %{salt: salt, public_key: public_key} = public(recipient)
    Enum.join([@prefix, b64(salt), b64(public_key)], ".")
  end

  @doc """
  Reads the text `encode/1` writes, refusing anything else as
  `:invalid_recipient`.
  """
  @spec decode(term()) :: {:ok, t()} | {:error, :invalid_recipient}
  def decode(text) when is_binary(text) do
    with [@prefix, salt64, public64] <- String.split(text, "."),
         {:ok, salt} <- Base.url_decode64(salt64, padding: false),
         {:ok, public_key} <- Base.url_decode64(public64, padding: false),
         true <- byte_size(salt) == @salt_bytes and byte_size(public_key) == @key_bytes do
      {:ok, %{salt: salt, public_key: public_key}}
    else
      _invalid -> {:error, :invalid_recipient}
    end
  end

  def decode(_text), do: {:error, :invalid_recipient}

  @doc "Whether `pair` holds the private half of `recipient`."
  @spec matches?(pair(), t() | pair()) :: boolean()
  def matches?(%{secret_key: _secret, public_key: public_key}, %{public_key: public_key}),
    do: true

  def matches?(_pair, _recipient), do: false

  defp pair(salt, private) do
    {public_key, secret_key} = :crypto.generate_key(:ecdh, :x25519, private)
    %{salt: salt, public_key: public_key, secret_key: secret_key}
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
