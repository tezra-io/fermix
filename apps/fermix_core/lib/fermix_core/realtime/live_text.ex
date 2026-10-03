defmodule FermixCore.Realtime.LiveText do
  @moduledoc """
  Bounded text for a Live call.

  Three different readers take text out of a Live session and all three have a
  hard limit: a `session.thinking.append` and a `session.commentary.append` are
  capped at 500 tokens by the API, and the wire's `task.summary` is capped at
  240 characters by the local protocol. A tool that returns 40 KB would
  otherwise be refused by the provider, truncated by the companion, or read
  aloud for a minute.

  Cutting is done here rather than at each call site because HOW a cut is made
  matters: commentary is SPOKEN, so it ends at a sentence boundary when it can —
  a sentence that stops halfway sounds like a failure even when the task
  succeeded. Everything is cut on a valid UTF-8 boundary, never mid-codepoint.

  `reason/1` is the fourth reader: the vendor's own words for a failure, on
  their way to a trace field and a companion frame.
  """

  @ellipsis "…"

  # What stands in front of a request cut from the front: the reader learns
  # that speech came before, and that it was cut rather than never said.
  @cut_marker "(earlier speech cut for length)\n"

  @doc "Collapse whitespace to single spaces and cut to `max_bytes`."
  @spec one_line(String.t(), pos_integer()) :: String.t()
  def one_line(text, max_bytes)
      when is_binary(text) and is_integer(max_bytes) and max_bytes > 0 do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate_bytes(max_bytes)
  end

  @doc """
  Cut to `max_bytes` at the last sentence end that fits, or at the byte bound
  when the text holds no sentence end at all.
  """
  @spec sentence(String.t(), pos_integer()) :: String.t()
  def sentence(text, max_bytes)
      when is_binary(text) and is_integer(max_bytes) and max_bytes > 0 do
    trimmed = String.trim(text)

    if byte_size(trimmed) <= max_bytes do
      trimmed
    else
      cut_at_sentence(truncate_bytes(trimmed, max_bytes))
    end
  end

  @doc """
  Keep the END of `text` within `max_bytes`, cut from the front on a UTF-8
  boundary behind `cut_marker/0`, which counts toward the bound.

  For a speaker-labelled request (M56 §4.1): the end of the exchange is the
  ask itself, so it is the beginning that gives way.
  """
  @spec tail(String.t(), pos_integer()) :: String.t()
  def tail(text, max_bytes)
      when is_binary(text) and is_integer(max_bytes) and max_bytes > byte_size(@cut_marker) do
    if byte_size(text) <= max_bytes do
      text
    else
      keep = max_bytes - byte_size(@cut_marker)
      @cut_marker <> drop_partial_codepoint(binary_part(text, byte_size(text) - keep, keep))
    end
  end

  @doc "The marker `tail/2` puts in front of a cut request."
  @spec cut_marker() :: String.t()
  def cut_marker, do: @cut_marker

  @doc """
  One line of at most `max_chars` CHARACTERS, ellipsised when cut.

  Characters, not bytes: this is the wire's own bound on `task.summary`, and the
  companion counts what it renders.
  """
  @spec summary(String.t() | nil, pos_integer()) :: String.t() | nil
  def summary(nil, _max_chars), do: nil

  def summary(text, max_chars)
      when is_binary(text) and is_integer(max_chars) and max_chars > 1 do
    line = one_line(text, max_chars * 4)

    if String.length(line) <= max_chars do
      line
    else
      String.slice(line, 0, max_chars - 1) <> @ellipsis
    end
  end

  @doc """
  One string for a failure reason, whatever shape it arrived in.

  The vendor's own sentence is the only diagnosis a reader gets, so it has to
  survive the trip to the trace and to the companion's `error.detail` — and a
  reason arrives as whatever the transport chose: an atom, a binary, an
  exception struct, a decoded error map. Rendering is TOTAL, with no term it
  refuses, because the alternative is raising inside the error path itself: a
  `to_string/1` on a `%WebSockex.RequestError{}` took a whole Live session down
  and the companion's connection closed with no frame at all.
  """
  @spec reason(term()) :: String.t()
  def reason(value) when is_atom(value), do: Atom.to_string(value)
  def reason(value) when is_binary(value), do: value

  # A refused handshake: the status and the server's reason phrase together ARE
  # the sentence ("401 Unauthorized"). `WebSockex.RequestError`'s own `message/1`
  # buries them in prose with the phrase inspected, so this comes first.
  def reason(%{code: code, message: message}) when is_integer(code) and is_binary(message),
    do: "#{code} #{message}"

  def reason(%{code: code}) when is_binary(code), do: code
  def reason(%{"code" => code}) when is_binary(code), do: code
  def reason(%{message: message}) when is_binary(message), do: message
  def reason(%{"message" => message}) when is_binary(message), do: message
  def reason(%{reason: nested}), do: reason(nested)
  def reason(%{"reason" => nested}), do: reason(nested)
  def reason(value) when is_exception(value), do: Exception.message(value)
  def reason(value), do: inspect(value)

  defp cut_at_sentence(cut) do
    case Regex.run(~r/^(.*[.!?])\s/su, cut, capture: :all_but_first) do
      [sentence] -> sentence
      nil -> cut
    end
  end

  # A cut from the front can land inside a character: its continuation bytes
  # (10xxxxxx) are dropped, at most three of them in valid UTF-8.
  defp drop_partial_codepoint(<<byte, rest::binary>>) when byte in 0x80..0xBF,
    do: drop_partial_codepoint(rest)

  defp drop_partial_codepoint(text), do: text

  defp truncate_bytes(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp truncate_bytes(text, max_bytes) do
    text
    |> binary_part(0, max_bytes)
    |> String.chunk(:valid)
    |> List.first("")
  end
end
