defmodule FermixCore.Providers.Anthropic.MessagesTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Providers.Anthropic.Messages

  describe "to_provider_tools/1" do
    test "returns [] for empty capability list" do
      assert Messages.to_provider_tools([]) == []
    end

    test "translates capabilities to Anthropic input_schema shape, no function wrapper" do
      capabilities = [
        Capability.new(%{
          name: "shell",
          description: "Run a shell command.",
          parameters: %{
            "type" => "object",
            "properties" => %{"command" => %{"type" => "string"}},
            "required" => ["command"]
          },
          kind: :builtin,
          policy_class: :exec,
          executor: {Mod, :run, []}
        }),
        Capability.new(%{
          name: "file_read",
          description: "Read a file.",
          parameters: %{"type" => "object", "properties" => %{}},
          kind: :builtin,
          policy_class: :read_only,
          executor: {Mod, :read, []}
        })
      ]

      assert Messages.to_provider_tools(capabilities) == [
               %{
                 name: "shell",
                 description: "Run a shell command.",
                 input_schema: %{
                   "type" => "object",
                   "properties" => %{"command" => %{"type" => "string"}},
                   "required" => ["command"]
                 }
               },
               %{
                 name: "file_read",
                 description: "Read a file.",
                 input_schema: %{"type" => "object", "properties" => %{}}
               }
             ]
    end
  end

  describe "parse_tool_calls/1" do
    test "extracts tool_use blocks with id, name, input" do
      body = %{
        "content" => [
          %{"type" => "text", "text" => "Let me look that up."},
          %{
            "type" => "tool_use",
            "id" => "toolu_01ABC",
            "name" => "shell",
            "input" => %{"command" => "ls -1"}
          },
          %{
            "type" => "tool_use",
            "id" => "toolu_02DEF",
            "name" => "file_read",
            "input" => %{"path" => "/tmp/x"}
          }
        ]
      }

      assert Messages.parse_tool_calls(body) == [
               %{
                 id: "toolu_01ABC",
                 call_id: "toolu_01ABC",
                 name: "shell",
                 arguments: %{"command" => "ls -1"}
               },
               %{
                 id: "toolu_02DEF",
                 call_id: "toolu_02DEF",
                 name: "file_read",
                 arguments: %{"path" => "/tmp/x"}
               }
             ]
    end

    test "returns [] when content has only text blocks" do
      assert Messages.parse_tool_calls(%{"content" => [%{"type" => "text", "text" => "hi"}]}) ==
               []
    end

    test "returns [] for malformed body" do
      assert Messages.parse_tool_calls(%{}) == []
      assert Messages.parse_tool_calls(nil) == []
    end
  end

  describe "parse_response/1" do
    test "joins text blocks, extracts tool calls, captures usage and stop_reason" do
      body = %{
        "model" => "claude-sonnet-4-6",
        "stop_reason" => "tool_use",
        "content" => [
          %{"type" => "text", "text" => "Calling tools."},
          %{
            "type" => "tool_use",
            "id" => "toolu_01",
            "name" => "shell",
            "input" => %{"command" => "uname"}
          }
        ],
        "usage" => %{"input_tokens" => 12, "output_tokens" => 7}
      }

      turn = Messages.parse_response(body)

      assert turn.content == "Calling tools."
      assert turn.model == "claude-sonnet-4-6"
      assert turn.usage == %{prompt_tokens: 12, completion_tokens: 7, total_tokens: 19}
      assert turn.provider_state.stop_reason == "tool_use"

      assert turn.tool_calls == [
               %{
                 id: "toolu_01",
                 call_id: "toolu_01",
                 name: "shell",
                 arguments: %{"command" => "uname"}
               }
             ]
    end
  end

  describe "chat/3 and continue/3" do
    test "both return :not_implemented cleanly" do
      assert {:error, :not_implemented} = Messages.chat([], [], [])
      assert {:error, :not_implemented} = Messages.continue(%{}, [], [])
    end
  end
end
