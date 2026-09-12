defmodule FermixChannels.Mobile.Noise.Cipher do
  @moduledoc false

  @max_nonce 18_446_744_073_709_551_615
  @tag_bytes 16

  @enforce_keys [:key, :nonce]
  defstruct [:key, :nonce]

  @type t :: %__MODULE__{key: binary() | nil, nonce: non_neg_integer()}

  @spec empty() :: t()
  def empty, do: %__MODULE__{key: nil, nonce: 0}

  @spec initialize(binary()) :: t()
  def initialize(<<key::binary-size(32)>>), do: %__MODULE__{key: key, nonce: 0}

  @spec has_key?(t()) :: boolean()
  def has_key?(%__MODULE__{key: key}), do: not is_nil(key)

  @spec encrypt(t(), binary(), binary()) :: {:ok, binary(), t()} | {:error, term()}
  def encrypt(%__MODULE__{key: nil} = cipher, _ad, plaintext) when is_binary(plaintext),
    do: {:ok, plaintext, cipher}

  def encrypt(%__MODULE__{nonce: @max_nonce}, _ad, _plaintext), do: {:error, :nonce_exhausted}

  def encrypt(%__MODULE__{key: key, nonce: nonce} = cipher, ad, plaintext)
      when is_binary(ad) and is_binary(plaintext) do
    {encrypted, tag} =
      :crypto.crypto_one_time_aead(
        :chacha20_poly1305,
        key,
        nonce_bytes(nonce),
        plaintext,
        ad,
        @tag_bytes,
        true
      )

    {:ok, encrypted <> tag, %{cipher | nonce: nonce + 1}}
  end

  @spec decrypt(t(), binary(), binary()) :: {:ok, binary(), t()} | {:error, term()}
  def decrypt(%__MODULE__{key: nil} = cipher, _ad, ciphertext) when is_binary(ciphertext),
    do: {:ok, ciphertext, cipher}

  def decrypt(%__MODULE__{nonce: @max_nonce}, _ad, _ciphertext), do: {:error, :nonce_exhausted}

  def decrypt(%__MODULE__{}, _ad, ciphertext) when byte_size(ciphertext) < @tag_bytes,
    do: {:error, :ciphertext_too_short}

  def decrypt(%__MODULE__{key: key, nonce: nonce} = cipher, ad, ciphertext)
      when is_binary(ad) and is_binary(ciphertext) do
    encrypted_size = byte_size(ciphertext) - @tag_bytes
    <<encrypted::binary-size(encrypted_size), tag::binary-size(@tag_bytes)>> = ciphertext

    case :crypto.crypto_one_time_aead(
           :chacha20_poly1305,
           key,
           nonce_bytes(nonce),
           encrypted,
           ad,
           tag,
           false
         ) do
      :error -> {:error, :authentication_failed}
      plaintext -> {:ok, plaintext, %{cipher | nonce: nonce + 1}}
    end
  end

  @spec rekey(t()) :: {:ok, t()} | {:error, term()}
  def rekey(%__MODULE__{key: nil}), do: {:error, :cipher_not_initialized}

  def rekey(%__MODULE__{key: key} = cipher) do
    nonce = nonce_bytes(@max_nonce)

    {material, _tag} =
      :crypto.crypto_one_time_aead(
        :chacha20_poly1305,
        key,
        nonce,
        :binary.copy(<<0>>, 32),
        <<>>,
        @tag_bytes,
        true
      )

    {:ok, %{cipher | key: material}}
  end

  defp nonce_bytes(nonce), do: <<0::unsigned-little-32, nonce::unsigned-little-64>>
end
