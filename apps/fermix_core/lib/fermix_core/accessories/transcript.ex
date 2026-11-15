defmodule FermixCore.Accessories.Transcript do
  @moduledoc """
  The two byte strings the accessory link's signatures cover, and the
  enrollment compare code (`priv/accessory/PROTOCOL.md`, *The attach
  transcript*, *The enrollment transcript and the compare code*).

  Each starts with its own fixed 30-byte domain string, so a signature made
  for one can never serve as the other, nor as a TLS 1.3 handshake signature
  made with the same key in Phase B. Every field has a fixed width except the
  kind, which is length-prefixed and last. Pure.
  """

  @attach_domain "FERMIX-ACCESSORY-USB-ATTACH-v1"
  @enroll_domain "FERMIX-ACCESSORY-USB-ENROLL-v1"
  @kind ~r/\A[a-z][a-z0-9_]{0,15}\z/
  @u16 0..65_535
  @u32 0..4_294_967_295

  @type attach_fields :: %{
          host_id: String.t(),
          accessory_id: String.t(),
          host_nonce: <<_::256>>,
          accessory_nonce: <<_::256>>,
          wire: 0..65_535,
          host_caps: non_neg_integer(),
          accessory_caps: non_neg_integer(),
          gen: non_neg_integer(),
          kind: String.t()
        }

  @type enroll_fields :: %{
          host_pk: <<_::520>>,
          accessory_pk: <<_::520>>,
          host_nonce: <<_::256>>,
          accessory_nonce: <<_::256>>
        }

  @doc "The attach transcript both ends sign: 173 bytes plus the kind."
  @spec attach(attach_fields()) :: binary()
  def attach(
        %{host_nonce: <<_::256>> = host_nonce, accessory_nonce: <<_::256>> = accessory_nonce} = f
      )
      when f.wire in @u16 and f.host_caps in @u32 and f.accessory_caps in @u32 and f.gen in @u32 do
    <<@attach_domain::binary, digest!(f.host_id)::binary, digest!(f.accessory_id)::binary,
      host_nonce::binary, accessory_nonce::binary, f.wire::16-little, f.host_caps::32-little,
      f.accessory_caps::32-little, f.gen::32-little, byte_size(kind!(f.kind))::8, f.kind::binary>>
  end

  @doc "The enrollment transcript both ends sign and the compare code is read from: 224 bytes."
  @spec enroll(enroll_fields()) :: <<_::1792>>
  def enroll(%{
        host_pk: <<4, _host::binary-size(64)>> = host_pk,
        accessory_pk: <<4, _acc::binary-size(64)>> = accessory_pk,
        host_nonce: <<_::256>> = host_nonce,
        accessory_nonce: <<_::256>> = accessory_nonce
      }) do
    <<@enroll_domain::binary, host_pk::binary, accessory_pk::binary, host_nonce::binary,
      accessory_nonce::binary>>
  end

  @doc """
  The six-digit compare code of an enrollment transcript: the first four bytes
  of its SHA-256 as a big-endian u32, modulo 1,000,000, with leading zeros.
  """
  @spec compare_code(binary()) :: String.t()
  def compare_code(transcript) when is_binary(transcript) do
    <<first::32-big, _rest::binary>> = :crypto.hash(:sha256, transcript)
    first |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
  end

  defp kind!(kind) when is_binary(kind) do
    if Regex.match?(@kind, kind),
      do: kind,
      else: raise(ArgumentError, "invalid accessory kind: #{inspect(kind)}")
  end

  # An ID is the hex of a SHA-256: the transcript carries its 32 raw bytes.
  defp digest!(id) when is_binary(id) and byte_size(id) == 64,
    do: Base.decode16!(id, case: :lower)
end
