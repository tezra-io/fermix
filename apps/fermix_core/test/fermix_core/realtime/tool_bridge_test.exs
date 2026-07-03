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

  defmodule ScreenTool do
    # Mirrors a computer-use screenshot result: model-visible text + image parts.
    def execute(_args, _context) do
      {:ok,
       %{
         success: true,
         output: "screenshot 1366x384. Cursor at (10,20).",
         error: nil,
         images: [%{type: :image, mime_type: "image/png", data: <<137, 80, 78, 71>>}]
       }}
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

  test "a gui_control result: images are split out and the text is framed untrusted" do
    bridge = ToolBridge.new([gui_capability()], %{agent_name: "realtime"})

    assert {:ok, output} =
             ToolBridge.execute_call(bridge, %{
               "call_id" => "call-1",
               "name" => "computer_use",
               "arguments" => "{}"
             })

    # Image parts ride the dedicated field as raw parts, never the text output —
    # so their bytes are not scrubbed to garbage or bloated onto the wire.
    assert output.images == [%{type: :image, mime_type: "image/png", data: <<137, 80, 78, 71>>}]
    refute output.output =~ "image/png"
    refute String.contains?(output.output, <<137, 80, 78, 71>>)

    # Screen text is attacker-controllable → wrapped in the untrusted frame.
    assert output.output =~ ~s(<untrusted_tool_result source="computer_use">)
    assert output.output =~ "screenshot 1366x384"
  end

  test "a read-only result is not framed and carries no images" do
    bridge = ToolBridge.new([capability()], %{agent_name: "realtime"})

    assert {:ok, output} =
             ToolBridge.execute_call(bridge, %{
               "call_id" => "c",
               "name" => "echo",
               "arguments" => Jason.encode!(%{"text" => "hi"})
             })

    assert output.images == []
    refute output.output =~ "untrusted_tool_result"
    assert Jason.decode!(output.output)["output"] == "realtime:hi"
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

  defp gui_capability do
    Capability.new(%{
      name: "computer_use",
      description: "Drive the desktop.",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {ScreenTool, :execute, []},
      policy_class: :gui_control
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
