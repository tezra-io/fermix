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
  URL query-param values (value stripped, host+path kept), payment-card numbers
  (Luhn-checked), IBANs (ISO 13616 registry + ISO 7064 mod-97), OTP digit runs
  near a "code"/"verification" keyword, and high-entropy base64/hex runs above a
  length floor.

  The two checksummed patterns exist because browser capture brings the web's
  plain-text secrets into the spool: a card number and an IBAN are typed in the
  clear into ordinary fields, and neither has a prefix or an entropy signature to
  recognize. Their arithmetic check is what keeps them from eating an order number,
  a phone number or a product code — a digit run that fails Luhn, or an
  IBAN-shaped run whose country code and length are not in the registry (or that
  fails mod-97), is left exactly as observed. **The IBAN registry is the gate**: a
  span is matched only at a registered country code's exact registered length, so
  the pattern can neither run one character long nor swallow the word after a
  printed IBAN.

  **Order inside the chain matters**: cards and IBANs run BEFORE the OTP rule. A
  `Card verification: <PAN>` label otherwise let the OTP rule eat the first four
  digits of the PAN, and the rest of the number then survived as fragments the card
  pattern no longer recognized.

  URL query parameters are still scrubbed even though a stored `url` column no
  longer has a query string: typed text and titles routinely carry a full URL with
  its token.

  It borrows the `redact_values` **shape** (single choke point, a redaction
  marker, a minimum-length floor) but **not** its mechanism — it is never fed
  the operator's real secrets as literals (a process holding every secret to
  scrub them would be a better target than the spool). Coverage is honestly
  incomplete (S5): low-entropy secrets, secrets split across events,
  keyword-less OTPs, a card number butted straight against another digit run (the
  scanned window then fails Luhn and is left alone), and anything novel pass
  through. The scrubber reduces the secret-capture risk (T13); it cannot close it.
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

  # Payment card: 13-19 digits, optionally one space or dash between groups.
  # Redacted only when the digits pass Luhn (see `luhn_valid?/1`).
  @card ~r/\b(?:\d[ -]?){12,18}\d\b/

  # The ISO 13616 registry: every registered country code and its exact IBAN
  # length. The registry IS the gate — a code it does not list is not an IBAN no
  # matter what its checksum says, and an exact length is what keeps a matched span
  # from running one character long or swallowing the next word.
  @iban_lengths %{
    "AD" => 24,
    "AE" => 23,
    "AL" => 28,
    "AT" => 20,
    "AZ" => 28,
    "BA" => 20,
    "BE" => 16,
    "BG" => 22,
    "BH" => 22,
    "BR" => 29,
    "BY" => 28,
    "CH" => 21,
    "CR" => 22,
    "CY" => 28,
    "CZ" => 24,
    "DE" => 22,
    "DK" => 18,
    "DO" => 28,
    "EE" => 20,
    "EG" => 29,
    "ES" => 24,
    "FI" => 18,
    "FO" => 18,
    "FR" => 27,
    "GB" => 22,
    "GE" => 22,
    "GI" => 23,
    "GL" => 18,
    "GR" => 27,
    "GT" => 28,
    "HR" => 21,
    "HU" => 28,
    "IE" => 22,
    "IL" => 23,
    "IQ" => 23,
    "IS" => 26,
    "IT" => 27,
    "JO" => 30,
    "KW" => 30,
    "KZ" => 20,
    "LB" => 28,
    "LC" => 32,
    "LI" => 21,
    "LT" => 20,
    "LU" => 20,
    "LV" => 21,
    "LY" => 25,
    "MC" => 27,
    "MD" => 24,
    "ME" => 22,
    "MK" => 19,
    "MR" => 27,
    "MT" => 31,
    "MU" => 30,
    "NL" => 18,
    "NO" => 15,
    "PK" => 24,
    "PL" => 28,
    "PS" => 29,
    "PT" => 25,
    "QA" => 29,
    "RO" => 24,
    "RS" => 22,
    "RU" => 33,
    "SA" => 24,
    "SC" => 31,
    "SD" => 18,
    "SE" => 24,
    "SI" => 19,
    "SK" => 24,
    "SM" => 27,
    "ST" => 25,
    "SV" => 28,
    "TL" => 23,
    "TN" => 24,
    "TR" => 26,
    "UA" => 29,
    "VA" => 22,
    "VG" => 24,
    "XK" => 20
  }

  # Built from the registry at compile time: a registered country code, its two
  # check digits, then EXACTLY the remaining registered number of alphanumerics,
  # with single spaces allowed between printed groups, word-bounded at both ends.
  # Codes are grouped BY LENGTH — one bounded repeat per distinct length, not per
  # country — because PCRE expands a bounded repeat inline and eighty of them
  # overflow its pattern-size limit outright.
  @iban_source "\\b(?:" <>
                 (@iban_lengths
                  |> Enum.group_by(fn {_code, length} -> length end, fn {code, _len} -> code end)
                  |> Enum.sort()
                  |> Enum.map_join("|", fn {length, codes} ->
                    "(?:" <>
                      Enum.join(Enum.sort(codes), "|") <>
                      ")(?: ?\\d){2}(?: ?[A-Z0-9]){#{length - 4}}"
                  end)) <> ")\\b"

  @iban Regex.compile!(@iban_source)

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
    |> replace_cards()
    |> replace_ibans()
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

  # --- Luhn-checked card numbers ------------------------------------------

  defp replace_cards(text) do
    Regex.replace(@card, text, fn match ->
      if match |> digits() |> luhn_valid?(), do: @marker, else: match
    end)
  end

  @doc """
  The Luhn (mod-10) check every payment card carries, on a digits-only string.
  False for anything outside 13-19 digits — a shorter or longer run is not a card
  no matter what the checksum says.
  """
  @spec luhn_valid?(String.t()) :: boolean()
  def luhn_valid?(digits) when is_binary(digits) do
    length = String.length(digits)

    length >= 13 and length <= 19 and rem(luhn_sum(digits), 10) == 0
  end

  # Doubling every second digit from the right, subtracting 9 when the double
  # exceeds 9 — the standard formulation, done on the reversed charlist so the
  # position parity is the index.
  defp luhn_sum(digits) do
    digits
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce(0, fn {char, index}, sum -> sum + luhn_digit(char - ?0, index) end)
  end

  defp luhn_digit(digit, index) when rem(index, 2) == 0, do: digit
  defp luhn_digit(digit, _odd_index) when digit >= 5, do: digit * 2 - 9
  defp luhn_digit(digit, _odd_index), do: digit * 2

  defp digits(value), do: String.replace(value, ~r/[^0-9]/, "")

  # --- registry-matched, mod-97-checked IBANs ------------------------------

  # The pattern already bounds the span exactly (registered country code +
  # registered length, word-bounded), so a match is either the whole IBAN or
  # nothing: the checksum is the only remaining question.
  defp replace_ibans(text) do
    Regex.replace(@iban, text, fn match ->
      if match |> String.replace(" ", "") |> iban_valid?(), do: @marker, else: match
    end)
  end

  @doc """
  Whether a space-free candidate is an IBAN: its country code must be in the
  ISO 13616 registry at exactly this length, and it must pass the ISO 7064
  mod-97-10 check (move the first four characters to the end, map letters to their
  two-digit values, require a remainder of 1). A registered length is not a
  formality — it is what stops an arbitrary uppercase run from being scored at all.
  """
  @spec iban_valid?(String.t()) :: boolean()
  def iban_valid?(candidate) when is_binary(candidate) do
    registered_length?(candidate) and mod97(rearrange(candidate)) == 1
  end

  defp registered_length?(candidate) do
    Map.get(@iban_lengths, String.slice(candidate, 0, 2)) == String.length(candidate)
  end

  defp rearrange(candidate) do
    {head, tail} = String.split_at(candidate, 4)
    tail <> head
  end

  # Folded digit by digit so the integer never grows past two digits plus the
  # remainder — a 34-character IBAN is a 40-digit number otherwise.
  defp mod97(rearranged) do
    rearranged
    |> String.to_charlist()
    |> Enum.reduce(0, fn char, acc -> rem(acc * char_scale(char) + char_value(char), 97) end)
  end

  defp char_scale(char) when char in ?0..?9, do: 10
  defp char_scale(_letter), do: 100

  defp char_value(char) when char in ?0..?9, do: char - ?0
  defp char_value(char), do: char - ?A + 10

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
