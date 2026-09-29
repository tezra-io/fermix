defmodule FermixCore.Tools.ToolResultRecallTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.ToolResultStore
  alias FermixCore.Tools.ToolResultRecall

  setup do
    store = ToolResultStore.new()

    :ok =
      ToolResultStore.put(store, %{
        call_id: "call_17",
        step: 2,
        tool_name: "web_fetch",
        output: Enum.map_join(1..500, "\n", &"row #{&1}: value #{&1 * 3}"),
        external?: true
      })

    :ok =
      ToolResultStore.put(store, %{
        call_id: "call_2",
        step: 1,
        tool_name: "shell",
        output: "ok\nTotal: 42\ndone",
        external?: false
      })

    context = %{agent_name: "test_agent", conversation_key: :test, tool_result_store: store}
    %{store: store, context: context}
  end

  test "name, category and schema", _ctx do
    assert ToolResultRecall.name() == "tool_result_recall"
    assert ToolResultRecall.category() == :system
    assert ToolResultRecall.parameters().required == ["call_id"]
  end

  describe "advertise?/1" do
    test "is offered only to a run that carries a store", %{context: context} do
      assert ToolResultRecall.advertise?(context)
      refute ToolResultRecall.advertise?(%{agent_name: "x", conversation_key: :y})
    end
  end

  describe "execute/2 with a query" do
    test "returns the numbered matching lines, framed like the original", %{context: context} do
      assert {:ok, %{success: true, output: output}} =
               ToolResultRecall.execute(%{"call_id" => "call_17", "query" => "VALUE 30"}, context)

      assert output =~ ~s(<untrusted_tool_result source="web_fetch">)
      assert output =~ "10: row 10: value 30"
      assert output =~ "100: row 100: value 300"
      refute output =~ "row 11:"
    end

    test "an internal result is returned unframed", %{context: context} do
      assert {:ok, %{success: true, output: output}} =
               ToolResultRecall.execute(%{"call_id" => "call_2", "query" => "total"}, context)

      refute output =~ "untrusted_tool_result"
      assert output =~ "2: Total: 42"
    end

    test "says so when nothing matches", %{context: context} do
      assert {:ok, %{success: true, output: output}} =
               ToolResultRecall.execute(%{"call_id" => "call_2", "query" => "zzz"}, context)

      assert output =~ "No line of shell result call_2 contains \"zzz\""
    end

    test "caps the matches and says how to narrow", %{context: context} do
      assert {:ok, %{success: true, output: output}} =
               ToolResultRecall.execute(%{"call_id" => "call_17", "query" => "row"}, context)

      assert output =~ "first 200 matches; narrow the query"
      assert output =~ "200: row 200"
      refute output =~ "201: row 201"
    end
  end

  describe "execute/2 with a range" do
    test "reads the default range from line 1", %{context: context} do
      assert {:ok, %{success: true, output: output}} =
               ToolResultRecall.execute(%{"call_id" => "call_17"}, context)

      assert output =~ "Lines 1-200 of 500 from web_fetch result call_17"
      assert output =~ "1: row 1: value 3"
      assert output =~ "200: row 200"
      refute output =~ "201: row 201"
    end

    test "reads an explicit range and clamps the limit", %{context: context} do
      assert {:ok, %{success: true, output: output}} =
               ToolResultRecall.execute(
                 %{"call_id" => "call_17", "offset" => 480, "limit" => 9_999},
                 context
               )

      assert output =~ "Lines 480-500 of 500"
      assert output =~ "500: row 500"
    end

    test "rejects a non-positive offset", %{context: context} do
      assert {:ok, %{success: false, error: error}} =
               ToolResultRecall.execute(%{"call_id" => "call_17", "offset" => 0}, context)

      assert error =~ "offset must be a positive integer"
    end

    test "bounds the output bytes with a marker", %{context: context} do
      store = context.tool_result_store

      :ok =
        ToolResultStore.put(store, %{
          call_id: "big",
          step: 1,
          tool_name: "shell",
          output: Enum.map_join(1..300, "\n", fn _ -> String.duplicate("x", 100) end),
          external?: false
        })

      assert {:ok, %{success: true, output: output}} =
               ToolResultRecall.execute(%{"call_id" => "big", "limit" => 400}, context)

      assert byte_size(output) < 16_200
      assert output =~ "[capped at 16000 bytes"
    end
  end

  describe "execute/2 errors" do
    test "a run without a store", _ctx do
      assert {:ok, %{success: false, error: error}} =
               ToolResultRecall.execute(%{"call_id" => "call_17"}, %{
                 agent_name: "a",
                 conversation_key: :k
               })

      assert error =~ "keeps no tool results"
    end

    test "an unknown call id", %{context: context} do
      assert {:ok, %{success: false, error: error}} =
               ToolResultRecall.execute(%{"call_id" => "nope"}, context)

      assert error =~ "No tool result of this run has call_id nope"
    end

    test "a missing call id", %{context: context} do
      assert {:ok, %{success: false, error: "Missing required parameter: call_id"}} =
               ToolResultRecall.execute(%{}, context)
    end
  end
end
