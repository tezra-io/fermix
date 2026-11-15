defmodule FermixCore.Accessories.P256 do
  @moduledoc """
  ECDSA over P-256 with SHA-256, in the encodings the accessory link uses
  (`priv/accessory/PROTOCOL.md`, *Byte order and encodings*):

    * a public key is a SEC1 uncompressed point, 65 bytes (`04 ‖ X ‖ Y`);
    * a private key is the 32-byte big-endian scalar;
    * a signature is raw `r ‖ s`, 64 bytes, each half big-endian and
      zero-padded, as mbedTLS writes it without ASN.1;
    * an ID is the lowercase hex SHA-256 of a public key.

  `verify/3` never raises: a malformed key or signature is simply not a valid
  one. Every point is checked to lie on the curve before `:crypto` sees it, so
  a peer's bytes never reach OpenSSL's own refusal. Pure apart from the random
  source `generate/0` and `sign/2` draw on.
  """

  @p 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
  @b 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
  @n 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

  @type public_key :: <<_::520>>
  @type private_key :: <<_::256>>
  @type signature :: <<_::512>>

  @doc "A new key pair from the system's cryptographic random source."
  @spec generate() :: {public_key(), private_key()}
  def generate, do: :crypto.generate_key(:ecdh, :secp256r1)

  @doc "The public key of a private scalar, refusing one outside `[1, n − 1]`."
  @spec public_key(binary()) :: {:ok, public_key()} | {:error, :invalid_private_key}
  def public_key(private) when is_binary(private) do
    if valid_private_key?(private) do
      {public, ^private} = :crypto.generate_key(:ecdh, :secp256r1, private)
      {:ok, public}
    else
      {:error, :invalid_private_key}
    end
  end

  @doc "Whether these bytes are a 32-byte scalar in `[1, n − 1]`."
  @spec valid_private_key?(binary()) :: boolean()
  def valid_private_key?(<<scalar::256>>), do: scalar >= 1 and scalar < @n
  def valid_private_key?(_other), do: false

  @doc "Whether these bytes are an uncompressed point on P-256 (cofactor 1, so on the curve is enough)."
  @spec valid_public_key?(binary()) :: boolean()
  def valid_public_key?(<<4, x::256, y::256>>) when x < @p and y < @p do
    Integer.mod(y * y, @p) == Integer.mod(x * x * x - 3 * x + @b, @p)
  end

  def valid_public_key?(_other), do: false

  @doc "A public key's ID: the lowercase hex SHA-256 of its 65 bytes."
  @spec id(public_key()) :: String.t()
  def id(<<4, _point::binary-size(64)>> = public),
    do: :sha256 |> :crypto.hash(public) |> Base.encode16(case: :lower)

  @doc "Signs `message` (the signer hashes it with SHA-256), as raw `r ‖ s`."
  @spec sign(binary(), private_key()) :: signature()
  def sign(message, <<_::256>> = private) when is_binary(message) do
    der = :crypto.sign(:ecdsa, :sha256, message, [private, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    <<r::256, s::256>>
  end

  @doc """
  Whether `signature` is a valid raw `r ‖ s` signature of `message` by
  `public`. Any valid signature passes, `s` or `n − s`; `r` or `s` outside
  `[1, n − 1]`, a point off the curve or a wrong size do not.
  """
  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(message, <<r::256, s::256>>, public) when is_binary(message) do
    in_range?(r) and in_range?(s) and valid_public_key?(public) and
      :crypto.verify(:ecdsa, :sha256, message, der(r, s), [public, :secp256r1])
  end

  def verify(message, _signature, _public) when is_binary(message), do: false

  defp in_range?(value), do: value >= 1 and value < @n

  defp der(r, s), do: :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
end
