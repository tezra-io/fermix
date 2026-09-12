defmodule FermixCore.Management.Text do
  @moduledoc """
  The one scrubber and the one byte-bounded truncator every management surface
  uses before operator text crosses the native boundary (M34 §2, §6).

  Two surfaces publish free text — Doctor check summaries and log entry
  messages — and both are exported again by `diagnostics.build`. When each had
  its own scrubber, a string was redacted at export and returned raw by
  `doctor.get`; when each had its own truncator, one counted bytes and the other
  graphemes, so a published byte bound was overshot fourfold on multi-byte text.
  One implementation removes both classes of drift.
  """

  alias FermixCore.Log.RedactingFormatter

  # Ordered. The shared log redactor runs first (vendor-shaped credentials),
  # then these: user paths, tokenized URLs, OAuth token fields, authorization
  # and API-key headers of any scheme, keyring service names, `key = value`
  # assignments, and `UPPER_ENV=value`.
  #
  # Each key/value pattern accepts the four separators a log line actually
  # writes: `key=value`, JSON `"key":"value"`, Elixir inspect `"key" => "value"`,
  # and the 2-tuple `{"key", "value"}` that `inspect/1` produces for a header
  # list. A pattern that only accepts `=` misses the provider-error body that
  # puts a refresh token in `fermix.log` today.
  @scrubbers [
    {~r{(/Users|/home)/[^/\s"']+}, "\\1/[REDACTED:user]"},
    {~r/([?&](?:t|token|access_token|refresh_token|code|api_key|key)=)[^&\s"']+/i,
     "\\1[REDACTED:token]"},
    {~r/\b(access_token|refresh_token|id_token)(?:"?\s*(?::|=>|=)\s*"?|"\s*,\s*")[^\s"',}\]\[]{8,}/i,
     "\\1=[REDACTED:token]"},
    {~r/\b(authorization|proxy-authorization|x-api-key|x-goog-api-key)(?:"?\s*(?::|=>|=)\s*"?|"\s*,\s*")(?:[A-Za-z][A-Za-z0-9-]*\s+)?[^\s"',}\]\[]{8,}/i,
     "\\1=[REDACTED:header]"},
    {~r/\bClaude Code-credentials-[A-Za-z0-9]+/, "[REDACTED:keyring]"},
    {~r/\b(api[_-]?key|secret|password|passphrase|token)(?:"?\s*(?::|=>|=)\s*"?|"\s*,\s*")[^\s"',}\]\[]{8,}/i,
     "\\1=[REDACTED:secret]"},
    {~r/\b[A-Z][A-Z0-9_]{5,}=[^\s"']{8,}/, "[REDACTED:env]"}
  ]

  @ellipsis "…"

  @doc "The ordered scrub patterns, published so a test can assert coverage per class."
  @spec scrubbers() :: [{Regex.t(), String.t()}]
  def scrubbers, do: @scrubbers

  @doc """
  Removes every secret class M34 §6 excludes from one operator-visible string.
  """
  @spec scrub(String.t()) :: String.t()
  def scrub(text) when is_binary(text) do
    Enum.reduce(@scrubbers, RedactingFormatter.redact(text), fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  @doc """
  Bounds `text` to `maximum` bytes, appending an ellipsis when it was cut.

  Bounded by construction: at most `maximum` graphemes are ever inspected, and
  the byte budget halts the fold before a multi-byte grapheme is split, so the
  result is always valid UTF-8 and always within the published byte bound.
  """
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(text, maximum) when is_binary(text) and is_integer(maximum) and maximum > 0 do
    if byte_size(text) <= maximum, do: text, else: cut(text, maximum)
  end

  defp cut(text, maximum) do
    budget = max(maximum - byte_size(@ellipsis), 0)

    kept =
      text
      |> String.slice(0, budget)
      |> String.graphemes()
      |> Enum.reduce_while({[], 0}, &take_within(&1, &2, budget))
      |> elem(0)
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    kept <> @ellipsis
  end

  defp take_within(grapheme, {kept, size}, budget) do
    next = size + byte_size(grapheme)
    if next > budget, do: {:halt, {kept, size}}, else: {:cont, {[grapheme | kept], next}}
  end
end
