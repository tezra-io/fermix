defmodule FermixCore.Realtime.LiveTextTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.LiveText

  describe "one_line/2" do
    test "collapses whitespace and leaves text inside the bound alone" do
      assert LiveText.one_line("  reading\n  the   file\t ", 100) == "reading the file"
    end

    test "cuts to the byte bound" do
      assert LiveText.one_line(String.duplicate("a", 50), 10) == String.duplicate("a", 10)
    end

    test "never cuts a multibyte character in half" do
      cut = LiveText.one_line(String.duplicate("é", 20), 9)

      assert String.valid?(cut)
      assert cut == String.duplicate("é", 4)
    end
  end

  describe "sentence/2" do
    test "returns text that already fits, trimmed" do
      assert LiveText.sentence("  The room is booked.  ", 100) == "The room is booked."
    end

    test "cuts at the last sentence end inside the bound" do
      text = "The room is booked. The projector is reserved. There is one more thing to say."

      assert LiveText.sentence(text, 50) == "The room is booked. The projector is reserved."
    end

    test "falls back to the byte bound when there is no sentence end" do
      text = String.duplicate("word ", 40)

      cut = LiveText.sentence(text, 20)
      assert byte_size(cut) <= 20
      assert String.valid?(cut)
    end
  end

  describe "summary/2" do
    test "passes nil through" do
      assert LiveText.summary(nil, 240) == nil
    end

    test "bounds by characters and marks the cut" do
      summary = LiveText.summary(String.duplicate("é", 400), 240)

      assert String.length(summary) == 240
      assert String.ends_with?(summary, "…")
    end

    test "leaves a short summary alone on one line" do
      assert LiveText.summary("booked\nfor 10am", 240) == "booked for 10am"
    end
  end
end
