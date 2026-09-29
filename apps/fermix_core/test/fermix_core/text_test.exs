defmodule FermixCore.TextTest do
  use ExUnit.Case, async: true

  alias FermixCore.Text

  describe "truncate_utf8/2" do
    test "returns text within the bound unchanged" do
      assert Text.truncate_utf8("héllo", 10) == "héllo"
      assert Text.truncate_utf8("héllo", 6) == "héllo"
    end

    test "cuts on a codepoint boundary and drops the partial codepoint" do
      # "é" is two bytes; a cut inside it drops it rather than leaving a stray byte
      assert Text.truncate_utf8("héllo", 2) == "h"
      assert Text.truncate_utf8("héllo", 3) == "hé"
      assert Text.truncate_utf8(String.duplicate("é", 5), 5) == "éé"
    end

    test "a zero bound is the empty string" do
      assert Text.truncate_utf8("abc", 0) == ""
    end
  end
end
