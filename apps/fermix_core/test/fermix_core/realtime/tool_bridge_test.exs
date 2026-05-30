defmodule FermixCore.Realtime.ToolBridgeTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Realtime.ToolBridge

  defmodule FakeTool do
    def execute(%{"text" => text}, context) do
      {:ok, %{success: true, output: "#{context.agent_name}:#{text}", error: nil}}
    end

    def execute(_args, _context), do: {:error, :bad_args}
  end

  test "converts capability snapshot to OpenAI function tools" do
    tools = ToolBridge.to_openai_tools([capability()])

    assert [
             %{
               type: "function",
               name: "echo",
               description: "Echo text.",
               parameters: %{"type" => "object"}
             }
           ] = tools
  end

  test "executes a known function call through the snapshot" do
    bridge = ToolBridge.new([capability()], %{agent_name: "realtime"})

    assert {:ok, output} =
             ToolBridge.execute_call(bridge, %{
               "call_id" => "call-1",
               "name" => "echo",
               "arguments" => Jason.encode!(%{"text" => "hello"})
             })

    assert output.call_id == "call-1"

    assert Jason.decode!(output.output) == %{
             "success" => true,
             "output" => "realtime:hello",
             "error" => nil
           }
  end

  test "returns loud tool errors for unknown tools and invalid JSON" do
    bridge = ToolBridge.new([capability()], %{agent_name: "realtime"})

    assert {:error, %{reason: {:unknown_tool, "missing"}}} =
             ToolBridge.execute_call(bridge, %{
               "call_id" => "call-1",
               "name" => "missing",
               "arguments" => "{}"
             })

    assert {:error, %{reason: :invalid_arguments_json}} =
             ToolBridge.execute_call(bridge, %{
               "call_id" => "call-2",
               "name" => "echo",
               "arguments" => "{"
             })
  end

  defp capability do
    Capability.new(%{
      name: "echo",
      description: "Echo text.",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {FakeTool, :execute, []},
      policy_class: :read_only
    })
  end
end
