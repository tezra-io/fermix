defmodule FermixCore.Cues.Filter.Answer do
  @moduledoc """
  Reads a filter model's reply (M60 §8.2): the first JSON object in the text,
  `{"decision": "pass" | "drop", "reason": "…", "hint": "…"}`.

  Prose or a code fence around the object is tolerated; the object itself is
  never repaired and a decision is never guessed. The decision word is read
  without case or surrounding space. A reason longer than 200 characters and a
  hint longer than 500 are cut, not refused; an empty reason, a decision other
  than pass or drop, a repeated key or a hint that is not text is an invalid
  answer, which the caller treats as a content failure for that cue (§8.3).

  An invalid answer's detail is Fermix's own sentence and never quotes the
  reply: the reply was written under the influence of an outside item.
  """

  alias FermixCore.Plugins.CanonicalJson

  @max_reason_chars 200
  @max_hint_chars 500
  # The reply is capped at 150 tokens upstream; these bound a provider that
  # ignores the cap, so the scan stays linear in a small constant.
  @max_scan_bytes 16_384
  @max_candidates 32

  @type result ::
          {:pass, String.t(), String.t() | nil}
          | {:drop, String.t()}
          | {:error, :invalid_answer, String.t()}

  @doc "Parses one reply into a decision, or an invalid answer with Fermix's detail."
  @spec parse(String.t()) :: result()
  def parse(text) when is_binary(text) do
    with {:ok, object} <- first_object(text),
         {:ok, decision} <- decision(object),
         {:ok, reason} <- reason(object),
         {:ok, hint} <- hint(object) do
      build(decision, reason, hint)
    end
  end

  defp build(:pass, reason, hint), do: {:pass, reason, hint}
  defp build(:drop, reason, _hint), do: {:drop, reason}

  # --- the first object ---------------------------------------------------------

  defp first_object(text) do
    scanned = binary_part(text, 0, min(byte_size(text), @max_scan_bytes))

    scanned
    |> :binary.matches("{")
    |> Enum.take(@max_candidates)
    |> Enum.reduce_while(invalid("The reply holds no JSON object."), fn {start, 1}, none ->
      case candidate(scanned, start) do
        :skip -> {:cont, none}
        result -> {:halt, result}
      end
    end)
  end

  defp candidate(scanned, start) do
    <<_before::binary-size(start), rest::binary>> = scanned

    with {:ok, length} <- object_length(rest),
         {:ok, decoded} <- decode(binary_part(rest, 0, length)) do
      as_object(decoded)
    end
  end

  defp decode(raw) do
    case CanonicalJson.decode(raw) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, :duplicate_object_key} -> invalid("The reply's JSON object repeats a key.")
      {:error, _not_json} -> :skip
    end
  end

  defp as_object(%Jason.OrderedObject{values: pairs}), do: {:ok, Map.new(pairs)}
  defp as_object(_other), do: :skip

  # The byte length of the balanced object at the start of `text`, honouring
  # strings and escapes. JSON's structural characters are ASCII, so a byte scan
  # is safe on UTF-8 text.
  defp object_length(text), do: scan(text, 0, 0, :code)

  defp scan(<<>>, _length, _depth, _mode), do: :skip

  defp scan(<<_c, rest::binary>>, length, depth, :escape),
    do: scan(rest, length + 1, depth, :string)

  defp scan(<<?\\, rest::binary>>, length, depth, :string),
    do: scan(rest, length + 1, depth, :escape)

  defp scan(<<?", rest::binary>>, length, depth, :string),
    do: scan(rest, length + 1, depth, :code)

  defp scan(<<_c, rest::binary>>, length, depth, :string),
    do: scan(rest, length + 1, depth, :string)

  defp scan(<<?", rest::binary>>, length, depth, :code),
    do: scan(rest, length + 1, depth, :string)

  defp scan(<<?{, rest::binary>>, length, depth, :code),
    do: scan(rest, length + 1, depth + 1, :code)

  defp scan(<<?}, _rest::binary>>, length, 1, :code), do: {:ok, length + 1}

  defp scan(<<?}, rest::binary>>, length, depth, :code),
    do: scan(rest, length + 1, depth - 1, :code)

  defp scan(<<_c, rest::binary>>, length, depth, :code), do: scan(rest, length + 1, depth, :code)

  # --- the fields -----------------------------------------------------------------

  defp decision(object) do
    case object |> Map.get("decision") |> normalized_word() do
      "pass" -> {:ok, :pass}
      "drop" -> {:ok, :drop}
      _other -> invalid("The decision must be pass or drop.")
    end
  end

  defp normalized_word(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalized_word(_value), do: nil

  defp reason(object) do
    case Map.get(object, "reason") do
      text when is_binary(text) -> nonempty_reason(String.trim(text))
      _missing -> invalid("The reason is empty.")
    end
  end

  defp nonempty_reason(""), do: invalid("The reason is empty.")
  defp nonempty_reason(text), do: {:ok, String.slice(text, 0, @max_reason_chars)}

  defp hint(object) do
    case Map.get(object, "hint") do
      nil -> {:ok, nil}
      text when is_binary(text) -> {:ok, optional_hint(String.trim(text))}
      _other -> invalid("The hint must be text.")
    end
  end

  defp optional_hint(""), do: nil
  defp optional_hint(text), do: String.slice(text, 0, @max_hint_chars)

  defp invalid(detail), do: {:error, :invalid_answer, detail}
end
