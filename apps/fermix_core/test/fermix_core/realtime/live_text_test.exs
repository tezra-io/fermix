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

  # A spoken request's tail is the ask itself, so the front gives way, behind a
  # marker that says something was cut (M56 §4.1).
  describe "tail/2" do
    test "leaves text inside the bound alone" do
      assert LiveText.tail("user: book the room", 4_096) == "user: book the room"
    end

    test "keeps the end, cut from the front behind a marker, inside the bound" do
      text = String.duplicate("a", 5_000) <> "user: use that link"
      cut = LiveText.tail(text, 4_096)

      assert byte_size(cut) == 4_096
      assert String.starts_with?(cut, LiveText.cut_marker())
      assert String.ends_with?(cut, "user: use that link")
    end

    test "never starts in the middle of a multibyte character" do
      # Two-byte characters after one ASCII byte: the cut point falls mid-character.
      text = "a" <> String.duplicate("é", 3_000)
      cut = LiveText.tail(text, 4_096)

      assert String.valid?(cut)
      assert byte_size(cut) <= 4_096
      assert String.starts_with?(cut, LiveText.cut_marker() <> "é")
      assert String.ends_with?(cut, "éé")
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

  # M56 §4.5: a hand-off's reply is said in a line and, when there is more than
  # can be said, shown whole in the chat.
  describe "split/2" do
    @delimiter LiveText.shown_delimiter()

    test "a short plain reply is spoken only" do
      assert LiveText.split("  The room is booked for 10am.  ", 1_500) ==
               {"The room is booked for 10am.", nil}
    end

    test "the line before the delimiter is spoken and what follows it is shown" do
      reply =
        "I found the form.\n#{@delimiter}\nIt is at https://x.test/form.\n\nIt asks for:\n- a name"

      assert LiveText.split(reply, 1_500) ==
               {"I found the form.", "It is at https://x.test/form.\n\nIt asks for:\n- a name"}
    end

    test "the delimiter counts with spaces around it and a carriage return" do
      reply = "Done.\r\n   #{@delimiter}  \r\n| a | b |"

      assert LiveText.split(reply, 1_500) == {"Done.", "| a | b |"}
    end

    test "the spoken part is returned whole, past the bound or with a link: the caller cuts it" do
      long = String.duplicate("word ", 400) <> "https://x.test"

      assert {spoken, "the rest"} = LiveText.split(long <> "\n#{@delimiter}\nthe rest", 1_500)
      assert spoken == String.trim(long)
    end

    test "nothing after the delimiter shows nothing" do
      assert LiveText.split("All set.\n#{@delimiter}\n  \n", 1_500) == {"All set.", nil}
    end

    test "only the first delimiter parts the reply; a later one is shown as written" do
      reply = "Two parts.\n#{@delimiter}\nfirst\n#{@delimiter}\nsecond"

      assert LiveText.split(reply, 1_500) == {"Two parts.", "first\n#{@delimiter}\nsecond"}
    end

    test "a delimiter with nothing before it parts what follows it instead" do
      assert LiveText.split("#{@delimiter}\nThe room is booked.", 1_500) ==
               {"The room is booked.", nil}

      assert LiveText.split("\n#{@delimiter}\nSee https://x.test/a", 1_500) ==
               {"See https://x.test/a", "See https://x.test/a"}

      assert LiveText.split("#{@delimiter}\nOpen it.\n#{@delimiter}\n| a |  b |", 1_500) ==
               {"Open it.", "| a |  b |"}
    end

    test "the delimiter inside a line is text, not a delimiter" do
      reply = "It says #{@delimiter} in the middle."

      assert LiveText.split(reply, 1_500) == {reply, nil}
    end

    test "with no delimiter a link is shown whole" do
      reply = "The form is at https://x.test/form."

      assert LiveText.split(reply, 1_500) == {reply, reply}
    end

    test "with no delimiter a code fence is shown whole" do
      reply = "Run this:\n```\nmix test\n```"

      assert LiveText.split(reply, 1_500) == {reply, reply}
    end

    test "with no delimiter a table row is shown whole" do
      reply = "Here they are.\n| day | room |\n| Mon | 4B |"

      assert LiveText.split(reply, 1_500) == {reply, reply}
    end

    test "with no delimiter a reply past the bound is shown whole, counted in bytes" do
      over = String.duplicate("é", 751)
      fits = String.duplicate("é", 750)

      assert LiveText.split(over, 1_500) == {over, over}
      assert LiveText.split(fits, 1_500) == {fits, nil}
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
