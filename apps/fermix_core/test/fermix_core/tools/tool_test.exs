defmodule FermixCore.Tools.ToolTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.Tool

  # A fake tool that implements the behaviour for testing
  defmodule FakeTool do
    @behaviour Tool

    @impl true
    def name, do: "fake_tool"

    @impl true
    def description, do: "A fake tool for testing"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "input" => %{"type" => "string", "description" => "Test input"}
        },
        "required" => ["input"]
      }
    end

    @impl true
    def execute(%{"input" => input}, _context) do
      {:ok, Tool.success("got: #{input}")}
    end
  end

  describe "format_for_llm/1" do
    test "returns OpenAI-compatible function calling format" do
      result = Tool.format_for_llm(FakeTool)

      assert result == %{
               type: "function",
               function: %{
                 name: "fake_tool",
                 description: "A fake tool for testing",
                 parameters: %{
                   "type" => "object",
                   "properties" => %{
                     "input" => %{"type" => "string", "description" => "Test input"}
                   },
                   "required" => ["input"]
                 }
               }
             }
    end
  end

  describe "success/1" do
    test "builds a success result map" do
      result = Tool.success("hello")

      assert result == %{success: true, output: "hello", error: nil}
    end
  end

  describe "error/1" do
    test "builds an error result map" do
      result = Tool.error("something broke")

      assert result == %{success: false, output: "", error: "something broke"}
    end
  end

  describe "behaviour callbacks" do
    test "FakeTool implements all required callbacks" do
      assert FakeTool.name() == "fake_tool"
      assert FakeTool.description() == "A fake tool for testing"
      assert is_map(FakeTool.parameters())
    end

    test "execute returns {:ok, tool_result()}" do
      context = %{agent_name: "test", conversation_key: :test}
      assert {:ok, result} = FakeTool.execute(%{"input" => "world"}, context)
      assert result.success == true
      assert result.output == "got: world"
      assert result.error == nil
    end
  end
end
