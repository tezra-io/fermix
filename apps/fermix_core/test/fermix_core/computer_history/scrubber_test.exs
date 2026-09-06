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
end
