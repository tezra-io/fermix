defmodule FermixCore.Nostr.Key do
  @moduledoc """
  Nostr key codec: the bech32 (BIP-173) `nsec`/`npub` forms and secp256k1
  x-only public-key derivation.

  Deliberately not a Nostr client — no relay transport, no signing, no event
  model (`MILESTONE_29_ACP_AGENT_SURFACE.md` §17.2, §17.7). Its only job is to
  *name* an identity: decode a presented secret, derive the public key that keys
  its record, and render the npub that is the only form ever printed.

  It is also the single npub/hex normalizer for the repo. Two stores that
  disagree about what an npub means is precisely the failure a second
  implementation would buy, so there is one.

  Every entry point returns `{:ok, …} | {:error, reason}`: garbage arriving from
  a client must be a value the caller can name in a log, never an exception.
  """

  import Bitwise

  @charset ~c"qpzry9x8gf2tvdw0s3jn54khce6mua7l"
  @generator {0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3}

  # secp256k1 group order. A scalar outside 1..n-1 has no curve point, and
  # handing one to :crypto raises — checked here so it stays a value.
  @curve_order 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

  # BIP-173 caps an encoded string at 90 characters; nsec/npub are 63.
  @max_encoded 90
  @checksum_length 6

  @type secret :: <<_::256>>

  @type bech32_reason ::
          :mixed_case
          | :missing_separator
          | :empty_hrp
          | :too_long
          | :too_short
          | :invalid_character
          | :bad_checksum
          | :bad_padding
          | {:hrp, String.t()}
          | {:length, non_neg_integer()}

  @type reason ::
          {:invalid_secret, :not_hex | :out_of_range | {:length, non_neg_integer()}}
          | {:invalid_nsec, bech32_reason()}
          | {:invalid_public_key, :not_hex | {:length, non_neg_integer()}}

  @doc """
  Decode a presented signing secret — bech32 `nsec` or 64-character hex — to its
  32 raw bytes.

  The two forms are told apart by shape, not by trying one and falling back to
  the other: a bech32 string always carries HRP letters outside the hex
  alphabet, so "every character is a hex digit" separates them with no overlap
  and keeps both error families precise (a truncated hex secret reports its
  length; an `npub` pasted in place of an `nsec` reports the HRP it actually
  carries). An all-uppercase bech32 string is valid per BIP-173; a mixed-case
  one is not, and is refused rather than normalized.
  """
  @spec decode_secret(String.t()) :: {:ok, secret()} | {:error, reason()}
  def decode_secret(value) when is_binary(value) do
    case hex_form?(value) do
      true -> decode_hex_secret(value)
      false -> decode_nsec(value)
    end
  end

  @doc """
  Derive the x-only secp256k1 public key of a 32-byte secret, as lowercase hex.

  "x-only" is the 32 bytes after the uncompressed point's leading format byte —
  the identity's canonical name everywhere in Nostr.
  """
  @spec public_hex(binary()) :: {:ok, String.t()} | {:error, reason()}
  def public_hex(<<secret::binary-size(32)>>) do
    scalar = :binary.decode_unsigned(secret)

    case scalar > 0 and scalar < @curve_order do
      true -> {:ok, derive_public_hex(secret)}
      false -> {:error, {:invalid_secret, :out_of_range}}
    end
  end

  def public_hex(secret) when is_binary(secret),
    do: {:error, {:invalid_secret, {:length, byte_size(secret)}}}

  @doc """
  Render a hex public key as its bech32 `npub` display form — the only form an
  operator surface ever prints.
  """
  @spec npub(String.t()) :: {:ok, String.t()} | {:error, reason()}
  def npub(public_key_hex) when is_binary(public_key_hex) do
    case Base.decode16(public_key_hex, case: :mixed) do
      {:ok, <<raw::binary-size(32)>>} -> {:ok, encode("npub", raw)}
      {:ok, other} -> {:error, {:invalid_public_key, {:length, byte_size(other)}}}
      :error -> {:error, {:invalid_public_key, :not_hex}}
    end
  end

  defp hex_form?(value), do: value |> :binary.bin_to_list() |> Enum.all?(&hex_digit?/1)

  defp hex_digit?(char), do: char in ?0..?9 or char in ?a..?f or char in ?A..?F

  defp decode_hex_secret(value) do
    case Base.decode16(value, case: :mixed) do
      {:ok, <<raw::binary-size(32)>>} -> {:ok, raw}
      {:ok, other} -> {:error, {:invalid_secret, {:length, byte_size(other)}}}
      :error -> {:error, {:invalid_secret, :not_hex}}
    end
  end

  defp decode_nsec(value) do
    with {:ok, "nsec", values} <- decode(value),
         {:ok, <<raw::binary-size(32)>>} <- payload(values) do
      {:ok, raw}
    else
      {:ok, hrp, _values} -> {:error, {:invalid_nsec, {:hrp, hrp}}}
      {:ok, other} -> {:error, {:invalid_nsec, {:length, byte_size(other)}}}
      {:error, reason} -> {:error, {:invalid_nsec, reason}}
    end
  end

  defp derive_public_hex(secret) do
    {<<4, x::binary-size(32), _y::binary-size(32)>>, _private} =
      :crypto.generate_key(:ecdh, :secp256k1, secret)

    Base.encode16(x, case: :lower)
  end

  # --- bech32 (BIP-173) ---

  @spec decode(String.t()) :: {:ok, String.t(), [0..31]} | {:error, bech32_reason()}
  defp decode(value) do
    with :ok <- check_encoded_length(value),
         {:ok, normalized} <- normalize_case(value),
         {:ok, hrp, data} <- split_at_separator(normalized),
         {:ok, values} <- charset_values(data),
         :ok <- verify_checksum(hrp, values) do
      {:ok, hrp, Enum.drop(values, -@checksum_length)}
    end
  end

  @spec encode(String.t(), binary()) :: String.t()
  defp encode(hrp, payload) do
    {:ok, values} = convert_bits(:binary.bin_to_list(payload), 8, 5, true)
    chars = Enum.map(values ++ checksum(hrp, values), &Enum.at(@charset, &1))
    hrp <> "1" <> List.to_string(chars)
  end

  defp payload(values) do
    case convert_bits(values, 5, 8, false) do
      {:ok, bytes} -> {:ok, :binary.list_to_bin(bytes)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_encoded_length(value) when byte_size(value) > @max_encoded, do: {:error, :too_long}
  defp check_encoded_length(_value), do: :ok

  defp normalize_case(value) do
    lower = String.downcase(value)

    cond do
      value == lower -> {:ok, lower}
      value == String.upcase(value) -> {:ok, lower}
      true -> {:error, :mixed_case}
    end
  end

  # The separator is the LAST "1", so an HRP may legitimately contain one.
  defp split_at_separator(value) do
    case :binary.matches(value, "1") do
      [] -> {:error, :missing_separator}
      matches -> split_at(value, matches |> List.last() |> elem(0))
    end
  end

  defp split_at(_value, 0), do: {:error, :empty_hrp}

  defp split_at(value, index) do
    {:ok, binary_part(value, 0, index),
     binary_part(value, index + 1, byte_size(value) - index - 1)}
  end

  defp charset_values(data) do
    values = data |> :binary.bin_to_list() |> Enum.map(&charset_index/1)

    cond do
      Enum.any?(values, &is_nil/1) -> {:error, :invalid_character}
      length(values) < @checksum_length -> {:error, :too_short}
      true -> {:ok, values}
    end
  end

  defp charset_index(char), do: Enum.find_index(@charset, &(&1 == char))

  defp verify_checksum(hrp, values) do
    case polymod(hrp_expand(hrp) ++ values) do
      1 -> :ok
      _other -> {:error, :bad_checksum}
    end
  end

  defp checksum(hrp, values) do
    residue = bxor(polymod(hrp_expand(hrp) ++ values ++ [0, 0, 0, 0, 0, 0]), 1)
    Enum.map(0..5, &band(bsr(residue, 5 * (5 - &1)), 31))
  end

  defp hrp_expand(hrp) do
    chars = :binary.bin_to_list(hrp)
    Enum.map(chars, &bsr(&1, 5)) ++ [0] ++ Enum.map(chars, &band(&1, 31))
  end

  defp polymod(values), do: Enum.reduce(values, 1, &polymod_step/2)

  defp polymod_step(value, checksum) do
    top = bsr(checksum, 25)
    base = bxor(bsl(band(checksum, 0x01FFFFFF), 5), value)
    Enum.reduce(0..4, base, &apply_generator(&2, top, &1))
  end

  defp apply_generator(acc, top, index) do
    case band(bsr(top, index), 1) do
      1 -> bxor(acc, elem(@generator, index))
      0 -> acc
    end
  end

  # Regroup `values` from `from`-bit to `to`-bit units. Terminates because each
  # drain step reduces the pending bit count by `to`.
  defp convert_bits(values, from, to, pad?) do
    {acc, bits, out} = Enum.reduce(values, {0, 0, []}, &convert_step(&1, &2, from, to))
    finish_bits(acc, bits, out, from, to, pad?)
  end

  defp convert_step(value, {acc, bits, out}, from, to) do
    drain_bits(bor(bsl(acc, from), value), bits + from, out, to)
  end

  defp drain_bits(acc, bits, out, to) when bits >= to do
    remaining = bits - to
    chunk = band(bsr(acc, remaining), bsl(1, to) - 1)
    drain_bits(band(acc, bsl(1, remaining) - 1), remaining, [chunk | out], to)
  end

  defp drain_bits(acc, bits, out, _to), do: {acc, bits, out}

  defp finish_bits(acc, bits, out, _from, to, true) when bits > 0,
    do: {:ok, Enum.reverse([band(bsl(acc, to - bits), bsl(1, to) - 1) | out])}

  defp finish_bits(_acc, _bits, out, _from, _to, true), do: {:ok, Enum.reverse(out)}

  defp finish_bits(_acc, bits, _out, from, _to, false) when bits >= from,
    do: {:error, :bad_padding}

  defp finish_bits(acc, bits, out, _from, to, false) do
    case band(bsl(acc, to - bits), bsl(1, to) - 1) do
      0 -> {:ok, Enum.reverse(out)}
      _other -> {:error, :bad_padding}
    end
  end
end
