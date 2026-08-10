defmodule FermixCore.Tools.SnippetSanitizerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.SnippetSanitizer

  test "strips provider markup and keeps the visible text" do
    assert SnippetSanitizer.sanitize("<strong>Quiet</strong> coffee") == "Quiet coffee"
  end

  test "a stripped tag separates the words it sat between" do
    assert SnippetSanitizer.sanitize("Quiet<br/>coffee") == "Quiet coffee"
  end

  test "decodes named, decimal, and hexadecimal entities" do
    assert SnippetSanitizer.sanitize("Ben &amp; Jerry&#39;s &mdash; open") ==
             "Ben & Jerry's — open"

    assert SnippetSanitizer.sanitize("caf&#xe9;") == "café"
    assert SnippetSanitizer.sanitize("a&nbsp;b") == "a b"
  end

  test "collapses runs of whitespace and trims the ends" do
    assert SnippetSanitizer.sanitize("  Quiet\n\tcoffee   shop  ") == "Quiet coffee shop"
  end

  test "an unknown entity is left exactly as written rather than dropped" do
    assert SnippetSanitizer.sanitize("100 &fakeentity; deg") == "100 &fakeentity; deg"
  end

  test "decoding runs once, so an escaped entity does not decode twice" do
    assert SnippetSanitizer.sanitize("&amp;lt;") == "&lt;"
  end

  test "encoded markup becomes visible text and is not stripped as a tag" do
    assert SnippetSanitizer.sanitize("&lt;strong&gt;bold&lt;/strong&gt;") ==
             "<strong>bold</strong>"
  end

  test "a bare less-than is preserved (only a closed tag is markup)" do
    assert SnippetSanitizer.sanitize("open 8 < 9 hours") == "open 8 < 9 hours"
  end

  test "a string with nothing to strip is returned unchanged" do
    assert SnippetSanitizer.sanitize("Blue Bottle Coffee") == "Blue Bottle Coffee"
  end

  test "markup-only input sanitizes to an empty string" do
    assert SnippetSanitizer.sanitize("<span></span>") == ""
  end

  test "a non-string raises — callers type-check provider payloads themselves" do
    assert_raise FunctionClauseError, fn -> SnippetSanitizer.sanitize(nil) end
    assert_raise FunctionClauseError, fn -> SnippetSanitizer.sanitize(42) end
  end
end
