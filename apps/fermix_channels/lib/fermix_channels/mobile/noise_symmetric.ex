defmodule FermixChannels.Mobile.Noise.Symmetric do
  @moduledoc false

  alias FermixChannels.Mobile.Noise.Cipher

  @hash_bytes 32

  @enforce_keys [:chaining_key, :handshake_hash, :cipher]
  defstruct [:chaining_key, :handshake_hash, :cipher]

  @type t :: %__MODULE__{
          chaining_key: binary(),
          handshake_hash: binary(),
          cipher: Cipher.t()
        }

  @spec initialize(binary(), binary(), binary()) :: t()
  def initialize(protocol_name, prologue, responder_static)
      when is_binary(protocol_name) and is_binary(prologue) and
             byte_size(responder_static) == 32 do
    hash = protocol_hash(protocol_name)

    %__MODULE__{chaining_key: hash, handshake_hash: hash, cipher: Cipher.empty()}
    |> mix_hash(prologue)
    |> mix_hash(responder_static)
  end

  @spec mix_hash(t(), binary()) :: t()
  def mix_hash(%__MODULE__{} = state, data) when is_binary(data) do
    %{state | handshake_hash: hash(state.handshake_hash <> data)}
  end

  @spec mix_key(t(), binary()) :: t()
  def mix_key(%__MODULE__{} = state, input_key_material) when is_binary(input_key_material) do
    [chaining_key, cipher_key] = hkdf(state.chaining_key, input_key_material, 2)
    %{state | chaining_key: chaining_key, cipher: Cipher.initialize(cipher_key)}
  end

  @spec mix_key_and_hash(t(), binary()) :: t()
  def mix_key_and_hash(%__MODULE__{} = state, input_key_material)
      when is_binary(input_key_material) do
    [chaining_key, temp_hash, cipher_key] =
      hkdf(state.chaining_key, input_key_material, 3)

    state
    |> Map.put(:chaining_key, chaining_key)
    |> mix_hash(temp_hash)
    |> Map.put(:cipher, Cipher.initialize(cipher_key))
  end

  @spec encrypt_and_hash(t(), binary()) :: {:ok, binary(), t()} | {:error, term()}
  def encrypt_and_hash(%__MODULE__{} = state, plaintext) when is_binary(plaintext) do
    with {:ok, ciphertext, cipher} <-
           Cipher.encrypt(state.cipher, state.handshake_hash, plaintext) do
      next = %{state | cipher: cipher} |> mix_hash(ciphertext)
      {:ok, ciphertext, next}
    end
  end

  @spec decrypt_and_hash(t(), binary()) :: {:ok, binary(), t()} | {:error, term()}
  def decrypt_and_hash(%__MODULE__{} = state, ciphertext) when is_binary(ciphertext) do
    with {:ok, plaintext, cipher} <-
           Cipher.decrypt(state.cipher, state.handshake_hash, ciphertext) do
      next = %{state | cipher: cipher} |> mix_hash(ciphertext)
      {:ok, plaintext, next}
    end
  end

  @spec split(t()) :: {Cipher.t(), Cipher.t()}
  def split(%__MODULE__{} = state) do
    [first, second] = hkdf(state.chaining_key, <<>>, 2)
    {Cipher.initialize(first), Cipher.initialize(second)}
  end

  defp protocol_hash(name) when byte_size(name) <= @hash_bytes,
    do: name <> :binary.copy(<<0>>, @hash_bytes - byte_size(name))

  defp protocol_hash(name), do: hash(name)

  defp hkdf(chaining_key, input_key_material, outputs) when outputs in [2, 3] do
    temp_key = hmac(chaining_key, input_key_material)
    first = hmac(temp_key, <<1>>)
    second = hmac(temp_key, first <> <<2>>)

    if outputs == 2 do
      [first, second]
    else
      [first, second, hmac(temp_key, second <> <<3>>)]
    end
  end

  defp hash(data), do: :crypto.hash(:sha256, data)
  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
