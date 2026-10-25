defmodule FermixCore.Cues.JsonPathTest do
  use ExUnit.Case, async: true

  alias FermixCore.Cues.JsonPath

  @document %{
    "data" => %{
      "items" => [
        %{"id" => "a-1", "seq" => 41, "tags" => ["ops", "db"], "blank" => "  "},
        %{"id" => " b-2 ", "price" => 12.5, "flag" => true}
      ]
    }
  }

  describe "valid?/1" do
    test "takes the document itself and dot paths of at most 16 well-formed segments" do
      assert JsonPath.valid?(".")
      assert JsonPath.valid?("id")
      assert JsonPath.valid?("data.items.0.id")
      assert JsonPath.valid?(Enum.join(List.duplicate("k", 16), "."))
      assert JsonPath.valid?("$type")
    end

    test "refuses empty segments, whitespace, a 17th segment and anything not text" do
      for path <- ["", "data..id", ".id", "id.", "my id", Enum.join(List.duplicate("k", 17), ".")] do
        refute JsonPath.valid?(path), inspect(path)
      end

      refute JsonPath.valid?(String.duplicate("k", 129))
      refute JsonPath.valid?(nil)
      refute JsonPath.valid?(:id)
    end
  end

  describe "lookup/2" do
    test "walks object keys and list indexes, \".\" being the document" do
      assert JsonPath.lookup(@document, ".") == {:ok, @document}
      assert {:ok, [_first, _second]} = JsonPath.lookup(@document, "data.items")
      assert JsonPath.lookup(@document, "data.items.1.price") == {:ok, 12.5}
      assert JsonPath.lookup(@document, "data.items.0.tags.1") == {:ok, "db"}
      assert JsonPath.lookup([%{"id" => 7}], "0.id") == {:ok, 7}
    end

    test "a missing key, an index out of range or a step into a scalar is :error" do
      assert JsonPath.lookup(@document, "data.missing") == :error
      assert JsonPath.lookup(@document, "data.items.2") == :error
      assert JsonPath.lookup(@document, "data.items.-1") == :error
      assert JsonPath.lookup(@document, "data.items.first") == :error
      assert JsonPath.lookup(@document, "data.items.0.id.deeper") == :error
    end
  end

  describe "time/2 and fields/3" do
    test "a time is RFC 3339 text at the path; anything else is nil" do
      entry = %{"at" => " 2026-10-12T13:59:00Z ", "bad" => "Monday", "n" => 5}

      assert JsonPath.time(entry, "at") == ~U[2026-10-12 13:59:00Z]
      assert JsonPath.time(entry, "bad") == nil
      assert JsonPath.time(entry, "n") == nil
      assert JsonPath.time(entry, nil) == nil
    end

    test "an entry's item fields by its paths, with the caller's default type" do
      entry = %{"id" => 7, "rev" => "r2", "kind" => "alert", "about" => ["KTRL"], "at" => "x"}
      paths = %{id_path: "id", revision_path: "rev", type_path: "kind", subject_path: "about.0"}

      assert JsonPath.fields(entry, paths, "stream.item") == %{
               item_id: "7",
               revision: "r2",
               type: "alert",
               subject: "KTRL",
               occurred_at: nil,
               datacontenttype: "application/json",
               data: entry,
               title: nil
             }

      bare = JsonPath.fields(%{"id" => "a"}, %{id_path: "id"}, "feed.item")
      assert %{revision: "1", type: "feed.item", subject: nil, occurred_at: nil} = bare
      assert JsonPath.fields(%{}, %{id_path: "id"}, "stream.item").item_id == nil
    end

    test "an id over 512 bytes is replaced by its digest" do
      long = String.duplicate("k", 513)
      assert "sha256:" <> digest = JsonPath.fields(%{"id" => long}, %{id_path: "id"}, "t").item_id
      assert byte_size(digest) == 64
    end
  end

  describe "scalar/2" do
    test "text trimmed, an integer as its digits, nil for blank, other values and no path" do
      assert JsonPath.scalar(@document, "data.items.0.id") == "a-1"
      assert JsonPath.scalar(@document, "data.items.1.id") == "b-2"
      assert JsonPath.scalar(@document, "data.items.0.seq") == "41"
      assert JsonPath.scalar(@document, "data.items.0.blank") == nil
      assert JsonPath.scalar(@document, "data.items.1.price") == nil
      assert JsonPath.scalar(@document, "data.items.1.flag") == nil
      assert JsonPath.scalar(@document, "data.items.0.tags") == nil
      assert JsonPath.scalar(@document, "data.nothing") == nil
      assert JsonPath.scalar(@document, nil) == nil
    end
  end
end
