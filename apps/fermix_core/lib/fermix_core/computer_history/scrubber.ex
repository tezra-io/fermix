defmodule FermixCore.ComputerHistory.Scrubber do
  @moduledoc """
  Ingest-time secret scrubber (MILESTONE_32 §13.1). Runs before every spool
  write on **every** free-form string column — `text`, `url`, `window_title`,
  `page_title`, `field_label` — because titles and labels routinely carry 2FA
  codes, tokens, and sensitive document names, so scrubbing only `text`/`url`
  would leave them exposed.

  It reuses the **single maintained secret-pattern corpus** — the same list the
  log `RedactingFormatter` maintains (`RedactingFormatter.redact/1`) — rather
  than hand-rolling a second regex pile that rots out of step (the
  adversarial-audit lesson). On top of that maintained corpus it layers the
  ingest-specific heuristics §13.1 calls for: JWTs, `password=`/`token=`/`key=`
  URL query-param values (value stripped, host+path kept), high-entropy
  base64/hex runs above a length floor, and OTP digit runs near a
  "code"/"verification" keyword.

  It borrows the `redact_values` **shape** (single choke point, a redaction
  marker, a minimum-length floor) but **not** its mechanism — it is never fed
  the operator's real secrets as literals (a process holding every secret to
  scrub them would be a better target than the spool). Coverage is honestly
  incomplete (S5): low-entropy secrets, secrets split across events,
  keyword-less OTPs, and anything novel pass through. The scrubber reduces the
  secret-capture risk (T13); it cannot close it.
  """

  alias FermixCore.Log.RedactingFormatter

  @marker "«redacted»"

  # JWT: three base64url segments, the first two starting `eyJ` (the `{"` of a
  # JSON header/payload).
  @jwt ~r/\beyJ[A-Za-z0-9_-]{6,}\.eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}/

  # Sensitive URL query-param VALUES — keep the key and the rest of the URL.
  @url_param ~r/([?&](?:password|passwd|pwd|token|access_token|refresh_token|api[_-]?key|key|secret|client_secret|code)=)[^&#\s]+/i

  # OTP: a 4-8 digit run within a short window after a code-ish keyword.
  @otp ~r/((?:code|verification|verify|otp|passcode|one[- ]?time)\D{0,15})(\d{4,8})\b/i

  # High-entropy candidates: long hex (hashes/tokens) and long base64url runs.
  # The base64 branch is validated post-match (must mix classes) to spare prose.
  @hex_run ~r/\b[0-9a-fA-F]{40,}\b/
  @b64_run ~r/\b[A-Za-z0-9_\/+-]{44,}\b/

  @doc "Scrub secrets from one free-form value. `nil` passes through."
  @spec scrub(String.t() | nil) :: String.t() | nil
  def scrub(nil), do: nil

  def scrub(value) when is_binary(value) do
    value
    |> RedactingFormatter.redact()
    |> replace(@jwt, @marker)
    |> replace_url_params()
    |> replace(@otp, "\\1#{@marker}")
    |> replace(@hex_run, @marker)
    |> replace_high_entropy_b64()
  end

  @doc "The redaction marker, exposed for tests."
  @spec marker() :: String.t()
  def marker, do: @marker

  # Regex.replace with a plain replacement string.
  defp replace(text, pattern, replacement), do: Regex.replace(pattern, text, replacement)

  # `?key=SECRET` -> `?key=«redacted»`, preserving the captured key= prefix.
  defp replace_url_params(text), do: Regex.replace(@url_param, text, &url_param_replacement/2)

  defp url_param_replacement(_whole, key_prefix), do: key_prefix <> @marker

  # Redact a long base64url run only when it mixes character classes (contains
  # both a letter and a digit), so a long lowercase prose word is spared.
  defp replace_high_entropy_b64(text) do
    Regex.replace(@b64_run, text, fn match ->
      if mixed_classes?(match), do: @marker, else: match
    end)
  end

  defp mixed_classes?(run) do
    String.match?(run, ~r/[A-Za-z]/) and String.match?(run, ~r/[0-9]/)
  end
end
