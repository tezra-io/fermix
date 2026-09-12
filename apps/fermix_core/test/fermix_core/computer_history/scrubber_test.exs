defmodule FermixCore.ComputerHistory.ScrubberTest do
  @moduledoc "MILESTONE_32 §13.1 — ingest-time secret scrubber (inv. 14)."
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Scrubber

  defp scrubbed?(input, secret) do
    out = Scrubber.scrub(input)

    refute String.contains?(out, secret),
           "expected #{inspect(secret)} to be scrubbed from #{inspect(out)}"

    out
  end

  describe "the maintained vendor corpus (via RedactingFormatter)" do
    test "known key prefixes are removed" do
      scrubbed?("key is sk-abcdefghijklmnop1234567890", "sk-abcdefghijklmnop1234567890")

      scrubbed?(
        "token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345",
        "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
      )

      scrubbed?("aws AKIAIOSFODNN7EXAMPLE here", "AKIAIOSFODNN7EXAMPLE")
      scrubbed?("slack xoxb-1234567890-abcdefghijkl", "xoxb-1234567890-abcdefghijkl")

      scrubbed?(
        "google AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456",
        "AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456"
      )
    end
  end

  describe "ingest-specific heuristics (§13.1)" do
    test "a JWT is redacted" do
      jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcDEF123456"
      scrubbed?("bearer #{jwt}", jwt)
    end

    test "sensitive URL query-param values are stripped, host and path kept" do
      out =
        scrubbed?("https://example.com/login?token=SUPERSECRETVALUE&next=/x", "SUPERSECRETVALUE")

      assert String.contains?(out, "example.com/login")
      assert String.contains?(out, "token=")
      assert String.contains?(out, "next=/x")
    end

    test "an OTP digit run near a code keyword is redacted, keyword kept" do
      out = scrubbed?("Your verification code is 483920 now", "483920")
      assert String.contains?(out, "code")
    end

    test "a long hex run is redacted" do
      hex = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef1234"
      scrubbed?("hash #{hex}", hex)
    end

    test "a long mixed base64 run is redacted" do
      b64 = "aGVsbG8xMjM0NTY3ODkwYWJjZGVmMTIzNDU2Nzg5MGFiY2RlZg99"
      scrubbed?("blob #{b64}", b64)
    end
  end

  # Browser capture brings the web's plain-text secrets into the spool: a card
  # number and an IBAN are typed in the clear, with no prefix and no entropy
  # signature. Their arithmetic check is the whole false-positive defense, so both
  # halves are asserted — the valid one redacted, the look-alike untouched.
  describe "payment-card numbers (Luhn-checked)" do
    test "a valid card is redacted in spaced, dashed and compact form" do
      for form <- ["4111 1111 1111 1111", "4111-1111-1111-1111", "4111111111111111"] do
        scrubbed?("paying with #{form} today", form)
      end
    end

    test "Mastercard and Amex lengths are covered too" do
      scrubbed?("mc 5555555555554444 ok", "5555555555554444")
      scrubbed?("amex 3782 822463 10005 ok", "3782 822463 10005")
    end

    test "a Luhn-invalid digit run is left exactly as observed" do
      invalid = "paying with 4111 1111 1111 1112 today"
      assert Scrubber.scrub(invalid) == invalid
    end

    test "a phone number and an order number are left alone" do
      for text <- ["call 555-123-4567 now", "order 1234567890 shipped"] do
        assert Scrubber.scrub(text) == text
      end
    end

    test "luhn_valid?/1 rejects a correct checksum outside card length" do
      # "18" passes mod-10 but is not a card; length is part of the predicate.
      refute Scrubber.luhn_valid?("18")
      assert Scrubber.luhn_valid?("4111111111111111")
    end

    # F6: the OTP rule used to run first, so a "verification" label next to a PAN
    # ate its first four digits and the rest survived as fragments the card pattern
    # could no longer recognize. Cards and IBANs scrub before the OTP rule.
    test "a card labelled with a code keyword is redacted whole, not in fragments" do
      out = scrubbed?("Card verification: 4111 1111 1111 1111 exp 12/27", "4111")

      refute String.contains?(out, "1111")
      assert String.contains?(out, "exp 12/27")
    end
  end

  describe "IBANs (ISO 7064 mod-97-checked)" do
    test "a valid IBAN is redacted compact and in printed groups" do
      scrubbed?("pay to GB82WEST12345698765432 please", "GB82WEST12345698765432")
      scrubbed?("pay to GB82 WEST 1234 5698 7654 32 please", "GB82 WEST 1234 5698 7654 32")
    end

    test "a wrong check digit is left exactly as observed" do
      invalid = "pay to GB00WEST12345698765432 please"
      assert Scrubber.scrub(invalid) == invalid
    end

    test "an uppercase word run is not an IBAN" do
      words = "CONTACT SUPPORT ABOUT THIS ORDER"
      assert Scrubber.scrub(words) == words
    end

    # F7: the span is bounded by the registry (a registered country code at exactly
    # its registered length, word-bounded), so a following word is outside the match
    # by construction rather than by a post-hoc shrink.
    test "a following uppercase word is outside the match" do
      out = scrubbed?("GB82 WEST 1234 5698 7654 32 NOTES", "GB82 WEST 1234 5698 7654 32")
      assert String.contains?(out, "NOTES")

      out = scrubbed?("GB82WEST12345698765432 IBAN", "GB82WEST12345698765432")
      assert String.contains?(out, "IBAN")
    end

    # An unregistered country code is not an IBAN whatever its arithmetic says —
    # this run is the shape an ordinary uppercase identifier takes.
    test "an unregistered country code never matches" do
      text = "ZB11 CAY4 SGPW V5GX 0WWZ FXNX"
      assert Scrubber.scrub(text) == text
    end

    test "a registered code at the wrong length is untouched" do
      # GB is registered at 22; one short and one long are both not IBANs.
      for text <- ["ref GB82WEST1234569876543 x", "ref GB82WEST123456987654321 x"] do
        assert Scrubber.scrub(text) == text
      end
    end

    test "iban_valid?/1 keys on the registered length for the country code" do
      refute Scrubber.iban_valid?("GB82WEST1234")
      refute Scrubber.iban_valid?("ZB11CAY4SGPWV5GX0WWZFXNX")
      assert Scrubber.iban_valid?("GB82WEST12345698765432")
    end
  end

  describe "false-positive safety" do
    test "ordinary prose is left intact" do
      prose = "The quick brown fox jumps over the lazy dog near the office."
      assert Scrubber.scrub(prose) == prose
    end

    test "a long lowercase word without digits is not treated as high-entropy" do
      word = "supercalifragilisticexpialidociousandthensomewords"
      assert Scrubber.scrub(word) == word
    end

    test "nil passes through" do
      assert Scrubber.scrub(nil) == nil
    end
  end

  describe "the url column keeps its path but not its secrets (scrub_url, M32.1)" do
    test "a path with a year and numeric segments is kept whole" do
      url = "https://www.formula1.com/en/results/2026/races/1234/spain/race-result"
      assert Scrubber.scrub_url(url) == url
    end

    test "a hyphenated article slug with a year is kept whole" do
      url =
        "https://www.formula1.com/en/latest/article/" <>
          "2026-spanish-grand-prix-qualifying-report-and-highlights-as-norris"

      assert Scrubber.scrub_url(url) == url
    end

    test "an underscore-delimited wiki path with a year is kept whole" do
      url = "https://en.wikipedia.org/wiki/2026_FIFA_World_Cup_qualification_UEFA_Group_A"
      assert Scrubber.scrub_url(url) == url
    end

    test "a named secret in a path is still redacted" do
      jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N"
      scrubbed?("https://app.example.com/sso/#{jwt}", jwt)

      key = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
      scrubbed?("https://example.com/callback/#{key}", key)
    end

    test "an opaque run in a path is left whole — url recall over run-scrubbing a stripped address" do
      token = "aGVsbG8xMjM0NTY3ODkwYWJjZGVmMTIzNDU2Nzg5MGFiY2RlZg99"
      url = "https://example.com/reset/#{token}"
      # The query is already stripped at normalisation; the opaque-run heuristics do
      # not run on a url, so a bare path token is kept rather than eating the path.
      assert Scrubber.scrub_url(url) == url
    end
  end

  describe "the natural-language columns keep both opaque-run detectors (scrub, M32.1)" do
    test "a base64url token with - and _ is still redacted in free-form text" do
      token = "aB3dEf9GhJkLmN0p-aB3dEf9GhJkLmN0p_aB3dEf9GhJkLmN0p"
      scrubbed?("my new session #{token} paste", token)
    end

    test "a bare opaque path token pasted as typed text is still redacted" do
      token = "aGVsbG8xMjM0NTY3ODkwYWJjZGVmMTIzNDU2Nzg5MGFiY2RlZg99"
      scrubbed?("https://example.com/reset/#{token}", token)
    end
  end
end
