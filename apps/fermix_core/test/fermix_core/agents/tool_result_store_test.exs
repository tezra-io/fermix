defmodule FermixCore.Agents.ToolResultStoreTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.ToolResultStore

  setup do
    store = ToolResultStore.new()
    on_exit(fn -> :ok end)
    %{store: store}
  end

  defp put(store, call_id, output, opts \\ []) do
    :ok =
      ToolResultStore.put(store, %{
        call_id: call_id,
        step: Keyword.get(opts, :step, 1),
        tool_name: Keyword.get(opts, :tool_name, "shell"),
        output: output,
        external?: Keyword.get(opts, :external?, false)
      })
  end

  describe "put/2 and fetch/2" do
    test "stores a result and reads it back by call id with its size", %{store: store} do
      put(store, "c1", "alpha\nbeta", step: 3, tool_name: "web_fetch", external?: true)

      assert {:ok, entry} = ToolResultStore.fetch(store, "c1")
      assert entry.call_id == "c1"
      assert entry.step == 3
      assert entry.tool_name == "web_fetch"
      assert entry.bytes == byte_size("alpha\nbeta")
      assert entry.output == "alpha\nbeta"
      assert entry.external? == true
    end

    test "an unknown call id is :error", %{store: store} do
      assert ToolResultStore.fetch(store, "nope") == :error
    end

    test "external? is required", %{store: store} do
      assert_raise KeyError, fn ->
        ToolResultStore.put(store, %{call_id: "c1", step: 1, tool_name: "shell", output: "x"})
      end
    end
  end

  describe "entries/1" do
    test "lists results in the order they were recorded", %{store: store} do
      put(store, "b", "2", step: 2)
      put(store, "a", "1", step: 1)
      put(store, "c", "3", step: 2)

      assert Enum.map(ToolResultStore.entries(store), & &1.call_id) == ["b", "a", "c"]
    end
  end

  describe "index/1" do
    test "lists metadata without bodies, in recording order", %{store: store} do
      put(store, "b", "22", step: 2, tool_name: "web_fetch", external?: true)
      put(store, "a", "1", step: 1)

      assert ToolResultStore.index(store) == [
               %{call_id: "b", step: 2, tool_name: "web_fetch", bytes: 2, external?: true},
               %{call_id: "a", step: 1, tool_name: "shell", bytes: 1, external?: false}
             ]
    end
  end

  describe "delete/1" do
    test "drops the table", %{store: store} do
      put(store, "c1", "x")
      assert :ok = ToolResultStore.delete(store)
      assert :ets.info(store) == :undefined
    end
  end

  describe "search/3" do
    test "returns the numbered lines containing the phrase, case-insensitively", %{store: store} do
      put(store, "c1", "Total: 12\nnothing\nsubtotal: 4\nTOTAL again")
      {:ok, entry} = ToolResultStore.fetch(store, "c1")

      assert ToolResultStore.search(entry, "total", 10) == %{
               lines: [{1, "Total: 12"}, {3, "subtotal: 4"}, {4, "TOTAL again"}],
               truncated?: false
             }
    end

    test "caps the matches and reports the truncation", %{store: store} do
      put(store, "c1", Enum.map_join(1..5, "\n", &"row #{&1}"))
      {:ok, entry} = ToolResultStore.fetch(store, "c1")

      assert ToolResultStore.search(entry, "row", 2) == %{
               lines: [{1, "row 1"}, {2, "row 2"}],
               truncated?: true
             }
    end

    test "no match is an empty list", %{store: store} do
      put(store, "c1", "a\nb")
      {:ok, entry} = ToolResultStore.fetch(store, "c1")
      assert ToolResultStore.search(entry, "zzz", 5) == %{lines: [], truncated?: false}
    end
  end

  describe "slice/3" do
    test "returns the numbered line range", %{store: store} do
      put(store, "c1", "l1\nl2\nl3\nl4")
      {:ok, entry} = ToolResultStore.fetch(store, "c1")

      assert ToolResultStore.slice(entry, 2, 2) == [{2, "l2"}, {3, "l3"}]
      assert ToolResultStore.slice(entry, 4, 10) == [{4, "l4"}]
      assert ToolResultStore.slice(entry, 9, 1) == []
    end
  end

  describe "frame/2" do
    test "frames text as untrusted when the original result was external", %{store: store} do
      put(store, "c1", "page", tool_name: "web_fetch", external?: true)
      {:ok, entry} = ToolResultStore.fetch(store, "c1")

      framed = ToolResultStore.frame(entry, "digest text")
      assert framed =~ ~s(<untrusted_tool_result source="web_fetch">)
      assert framed =~ "digest text"
    end

    test "leaves text alone when the original result was internal", %{store: store} do
      put(store, "c1", "out", external?: false)
      {:ok, entry} = ToolResultStore.fetch(store, "c1")
      assert ToolResultStore.frame(entry, "digest text") == "digest text"
    end
  end
end
