defmodule FermixCore.Introspection.WireTest do
  use ExUnit.Case, async: true

  alias FermixCore.Introspection.Wire

  test "raises on non-JSON terms instead of stringifying them" do
    assert_raise ArgumentError, ~r/non-JSON term: {:ok, "value"}/, fn ->
      Wire.json_safe({:ok, "value"})
    end
  end

  test "keeps booleans and nil JSON-native while stringifying other atoms" do
    assert Wire.json_safe(%{ok: true, off: false, missing: nil, kind: :done}) ==
             %{"ok" => true, "off" => false, "missing" => nil, "kind" => "done"}
  end
end
