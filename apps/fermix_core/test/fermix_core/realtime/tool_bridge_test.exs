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

  defmodule InvalidUtf8Tool do
    # 0xF3 is a UTF-8 lead byte with no continuation bytes — invalid on its own,
    # the same shape a Latin-1 file read or raw command output can produce.
    def execute(_args, _context) do
      {:ok, %{success: true, output: <<"risk: ", 0xF3, " exposure">>, error: nil}}
    end
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

  test "scrubs invalid UTF-8 from tool output so the wire frame stays encodable" do
    bridge = ToolBridge.new([invalid_utf8_capability()], %{agent_name: "realtime"})

    # Without scrubbing, Jason.encode! raises here on the 0xF3 byte and crashes
    # the realtime session — the same failure class as the agent-loop path.
    assert {:ok, output} =
             ToolBridge.execute_call(bridge, %{
               "call_id" => "call-1",
               "name" => "invalid_utf8",
               "arguments" => "{}"
             })

    assert String.valid?(output.output)
    decoded = Jason.decode!(output.output)
    assert decoded["success"] == true
    # Surrounding content preserved; only the bad byte is replaced.
    assert decoded["output"] =~ "risk:"
    assert decoded["output"] =~ "exposure"
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

  defp invalid_utf8_capability do
    Capability.new(%{
      name: "invalid_utf8",
      description: "Returns output carrying a byte that is not valid UTF-8.",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {InvalidUtf8Tool, :execute, []},
      policy_class: :read_only
    })
  end
end
