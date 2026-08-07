defmodule FermixCore.Plugins.CanonicalJson do
  @moduledoc """
  RFC 8785 JSON Canonicalization Scheme (JCS), for signed plugin descriptors
  (M27 §7.6).

  This is a **cross-language wire contract**, not a formatting helper. A tool's
  `descriptor_sha256` is computed by `pluginlib.py` at publish time and
  recomputed here at load time; a single byte of disagreement refuses a plugin
  that validated fine when it was signed. The golden fixtures in
  `fermix-plugins/scripts/fixtures/jcs/` are the contract, and both sides run
  against them.

  Three places where the obvious Elixir implementation is wrong:

    * **Key order is by UTF-16 code unit, not code point.** RFC 8785 inherits
      JavaScript's ordering, so `U+1F600` (surrogate pair `D83D DE00`) sorts
      *before* `U+E000`. Sorting the UTF-8 binaries, or sorting by code point,
      puts them the other way round.
    * **Numbers use ECMAScript `Number::toString`.** `Float.to_string/1` gives
      `"1.0"` where JCS needs `"1"`, and `"1.0e21"` where JCS needs `"1e+21"`.
    * **Duplicate object keys are refused before canonicalization.** A decoder
      that keeps the last value would silently canonicalize a document the
      publisher never signed.

  Integers outside the IEEE-754 exactly-representable range are refused rather
  than rounded: a descriptor is a security boundary, and silently altering a
  number in it is worse than failing to load.
  """

  @max_safe_integer 9_007_199_254_740_991

  @doc """
  Canonicalize decoded JSON to its JCS text.

  Input must already be decoded *without* collapsing duplicate keys — use
  `decode/1`, which refuses them.
  """
  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(term) do
    {:ok, IO.iodata_to_binary(canonicalize(term))}
  catch
    {:canonical_json, reason} -> {:error, reason}
  end

  @doc """
  Decode JSON text, refusing duplicate object keys.

  `Jason.decode/2` keeps the last value for a repeated key, which would let a
  document canonicalize to something its publisher never signed.
  """
  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode(raw) when is_binary(raw) do
    case Jason.decode(raw, objects: :ordered_objects) do
      {:ok, decoded} -> reject_duplicates(decoded)
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
    end
  end

  @doc """
  SHA-256 over the canonical UTF-8 bytes, lowercase hex — the value a manifest
  declares as `descriptor_sha256`.
  """
  @spec digest(term()) :: {:ok, binary()} | {:error, term()}
  def digest(term) do
    with {:ok, canonical} <- encode(term) do
      {:ok, :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)}
    end
  end

  @doc """
  The signed security descriptor of one MCP tool: exact name, input schema,
  output schema or explicit `null`, and annotations or explicit `null`.

  The four keys are always present — an absent `outputSchema` and a `null` one
  must hash identically, or a server that starts omitting the field would look
  like drift.
  """
  @spec descriptor_digest(String.t(), map(), map() | nil, map() | nil) ::
          {:ok, binary()} | {:error, term()}
  def descriptor_digest(name, input_schema, output_schema, annotations)
      when is_binary(name) and is_map(input_schema) do
    digest(%{
      "name" => name,
      "inputSchema" => input_schema,
      "outputSchema" => output_schema,
      "annotations" => annotations
    })
  end

  # --- canonicalization ---------------------------------------------------

  defp canonicalize(nil), do: "null"
  defp canonicalize(true), do: "true"
  defp canonicalize(false), do: "false"
  defp canonicalize(value) when is_binary(value), do: [?", escape(value), ?"]
  defp canonicalize(value) when is_integer(value), do: integer_text(value)
  defp canonicalize(value) when is_float(value), do: float_text(value)

  defp canonicalize(value) when is_list(value) do
    [?[, value |> Enum.map(&canonicalize/1) |> Enum.intersperse(?,), ?]]
  end

  defp canonicalize(%Jason.OrderedObject{values: pairs}), do: object(pairs)
  defp canonicalize(value) when is_map(value), do: object(Map.to_list(value))

  defp canonicalize(value), do: throw({:canonical_json, {:unsupported_type, value}})

  defp object(pairs) do
    body =
      pairs
      |> Enum.sort_by(fn {key, _value} -> utf16_key(key) end, :asc)
      |> Enum.map(fn {key, value} -> [?", escape(key), ?", ?:, canonicalize(value)] end)
      |> Enum.intersperse(?,)

    [?{, body, ?}]
  end

  # Sorting the UTF-16 big-endian bytes IS sorting by UTF-16 code unit: the
  # encoding is order-preserving on code units, and comparing the resulting
  # binaries bytewise compares those units most-significant byte first.
  defp utf16_key(key) when is_binary(key) do
    case :unicode.characters_to_binary(key, :utf8, {:utf16, :big}) do
      encoded when is_binary(encoded) -> encoded
      _error -> throw({:canonical_json, {:invalid_key_encoding, key}})
    end
  end

  defp utf16_key(key), do: throw({:canonical_json, {:non_string_key, key}})

  # RFC 8785 escapes only `"`, `\`, and U+0000–U+001F. The short forms are
  # mandatory where they exist; every other control character is `\u00xx` in
  # LOWERCASE hex. DEL (U+007F) and all non-ASCII are emitted literally.
  defp escape(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.map(&escape_byte/1)
  end

  defp escape_byte(?"), do: "\\\""
  defp escape_byte(?\\), do: "\\\\"
  defp escape_byte(?\b), do: "\\b"
  defp escape_byte(?\t), do: "\\t"
  defp escape_byte(?\n), do: "\\n"
  defp escape_byte(?\f), do: "\\f"
  defp escape_byte(?\r), do: "\\r"

  defp escape_byte(byte) when byte < 0x20 do
    "\\u" <> (byte |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))
  end

  defp escape_byte(byte), do: byte

  defp integer_text(value) when value >= -@max_safe_integer and value <= @max_safe_integer,
    do: Integer.to_string(value)

  defp integer_text(value), do: throw({:canonical_json, {:integer_out_of_range, value}})

  # --- ECMAScript Number::toString ----------------------------------------

  # Matches -0.0 too (-0.0 == 0.0), which is what JCS wants: both render "0".
  defp float_text(value) when value == 0.0, do: "0"

  # No NaN/infinity guard, deliberately. Erlang has no infinite or NaN floats —
  # arithmetic that would produce one raises `badarith` — and JSON cannot
  # express either, so `Jason.decode/2` never yields one. A guard here would be
  # unreachable code masquerading as a safety check (credo flags the comparison
  # as always-false, correctly).
  defp float_text(value), do: format_float(value)

  defp format_float(value) do
    {digits, n} = shortest_digits(abs(value))
    sign = if value < 0, do: "-", else: ""
    sign <> render(digits, n, byte_size(digits))
  end

  # `Float.to_string/1` already produces the SHORTEST round-tripping decimal;
  # only its layout differs from ECMAScript. Reuse those digits and re-lay them
  # out rather than reimplementing shortest-representation search.
  defp shortest_digits(value) do
    {mantissa, exponent} = split_exponent(Float.to_string(value))
    {int_part, frac_part} = split_point(mantissa)

    raw = int_part <> frac_part
    point = String.length(int_part) + exponent

    {trimmed, dropped} = drop_leading_zeros(raw)
    {String.replace_trailing(trimmed, "0", "") |> zero_guard(), point - dropped}
  end

  defp split_exponent(text) do
    case String.split(text, "e") do
      [mantissa] -> {mantissa, 0}
      [mantissa, exponent] -> {mantissa, String.to_integer(exponent)}
    end
  end

  defp split_point(mantissa) do
    case mantissa |> String.trim_leading("-") |> String.split(".") do
      [int_part] -> {int_part, ""}
      [int_part, frac_part] -> {int_part, frac_part}
    end
  end

  defp drop_leading_zeros(raw) do
    trimmed = String.trim_leading(raw, "0")
    {trimmed, String.length(raw) - String.length(trimmed)}
  end

  defp zero_guard(""), do: "0"
  defp zero_guard(digits), do: digits

  # ECMA-262 Number::toString, cases 6-10, with `n` the decimal-point position
  # such that the value is `0.<digits> x 10^n`.
  defp render(digits, n, k) when k <= n and n <= 21,
    do: digits <> String.duplicate("0", n - k)

  defp render(digits, n, k) when 0 < n and n <= 21 and n < k do
    String.slice(digits, 0, n) <> "." <> String.slice(digits, n, k - n)
  end

  defp render(digits, n, _k) when -6 < n and n <= 0,
    do: "0." <> String.duplicate("0", -n) <> digits

  defp render(digits, n, 1), do: digits <> exponent_text(n - 1)

  defp render(digits, n, _k) do
    String.slice(digits, 0, 1) <> "." <> String.slice(digits, 1..-1//1) <> exponent_text(n - 1)
  end

  defp exponent_text(exponent) when exponent >= 0, do: "e+" <> Integer.to_string(exponent)
  defp exponent_text(exponent), do: "e-" <> Integer.to_string(-exponent)

  # --- duplicate-key refusal ----------------------------------------------

  defp reject_duplicates(term) do
    {:ok, walk(term)}
  catch
    {:canonical_json, reason} -> {:error, reason}
  end

  defp walk(%Jason.OrderedObject{values: pairs} = object) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(Enum.uniq(keys)) == length(keys) do
      Enum.each(pairs, fn {_key, value} -> walk(value) end)
      object
    else
      throw({:canonical_json, :duplicate_object_key})
    end
  end

  defp walk(term) when is_list(term) do
    Enum.each(term, &walk/1)
    term
  end

  defp walk(term), do: term
end
