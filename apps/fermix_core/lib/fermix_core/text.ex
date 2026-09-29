defmodule FermixCore.Text do
  @moduledoc """
  Byte-bounded text cuts that never split a UTF-8 codepoint.
  """

  @doc """
  The longest prefix of `text` that is at most `max_bytes` long and ends on a
  codepoint boundary. A partial trailing codepoint is dropped, never replaced.
  """
  @spec truncate_utf8(String.t(), non_neg_integer()) :: String.t()
  def truncate_utf8(text, max_bytes)
      when is_binary(text) and is_integer(max_bytes) and max_bytes >= 0 do
    if byte_size(text) <= max_bytes, do: text, else: valid_prefix(binary_part(text, 0, max_bytes))
  end

  # A codepoint is at most four bytes, so at most three trailing bytes are
  # ever dropped.
  defp valid_prefix(""), do: ""

  defp valid_prefix(binary) do
    if String.valid?(binary),
      do: binary,
      else: valid_prefix(binary_part(binary, 0, byte_size(binary) - 1))
  end
end
