defmodule FermixCore.Plugins.Http.ExtractTest do
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.Http.Extract

  test "nil spec returns the body unchanged" do
    assert Extract.apply(nil, %{"a" => 1}) == %{"a" => 1}
  end

  test "fields-only picks keys from a top-level-array response (GitHub style)" do
    body = [
      %{"id" => 1, "title" => "x", "extra" => "drop"},
      %{"id" => 2, "title" => "y", "extra" => "drop"}
    ]

    assert Extract.apply(%{"fields" => ["id", "title"]}, body) ==
             [%{"id" => 1, "title" => "x"}, %{"id" => 2, "title" => "y"}]
  end

  test "bare [*] path traverses a top-level array" do
    body = [%{"id" => 1, "extra" => "drop"}, %{"id" => 2, "extra" => "drop"}]

    assert Extract.apply(%{"path" => "[*]", "fields" => ["id"]}, body) ==
             [%{"id" => 1}, %{"id" => 2}]
  end

  test "dot-path navigates into nested objects" do
    body = %{"data" => %{"user" => %{"name" => "ada"}}}
    assert Extract.apply(%{"path" => "data.user"}, body) == %{"name" => "ada"}
  end

  test "[*] traverses a list and picks fields from each (Notion style)" do
    body = %{"results" => [%{"id" => "a", "size" => 1}, %{"id" => "b", "size" => 2}]}

    assert Extract.apply(%{"path" => "results[*]", "fields" => ["id"]}, body) ==
             [%{"id" => "a"}, %{"id" => "b"}]
  end

  test "nested [*] then key" do
    body = %{"groups" => [%{"items" => %{"id" => 1}}, %{"items" => %{"id" => 2}}]}

    assert Extract.apply(%{"path" => "groups[*].items", "fields" => ["id"]}, body) ==
             [%{"id" => 1}, %{"id" => 2}]
  end

  test "a missing path key yields nil, not a crash" do
    assert Extract.apply(%{"path" => "nope.missing"}, %{"a" => 1}) == nil
  end

  test "empty path returns the whole body, fields applied" do
    assert Extract.apply(%{"path" => "", "fields" => ["a"]}, %{"a" => 1, "b" => 2}) == %{"a" => 1}
  end
end
