defmodule FermixCore.MCP.Inbound.ExposureTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Capability
  alias FermixCore.MCP.Inbound.Config
  alias FermixCore.MCP.Inbound.Exposure

  defmodule FakeExecutor do
    def execute(_args, _context), do: {:ok, :ok}
  end

  defp cap(name, opts \\ []) do
    Capability.new(%{
      name: name,
      description: "description for #{name}",
      parameters: %{type: "object", properties: %{}},
      kind: Keyword.get(opts, :kind, :builtin),
      executor: {FakeExecutor, :execute, []},
      policy_class: Keyword.get(opts, :policy_class, :read_only),
      hidden_from_agent?: Keyword.get(opts, :hidden_from_agent?, false)
    })
  end

  defp names(capabilities), do: Enum.map(capabilities, & &1.name)

  describe "expose_for_inbound/2" do
    test "disabled config returns nothing" do
      config = %Config{enabled?: false}

      assert Exposure.expose_for_inbound([cap("file_read")], config) == []
    end

    test "default gate exposes nothing without an explicit allowed_tools entry (F-07)" do
      capabilities = [
        cap("file_read", kind: :builtin, policy_class: :read_only),
        cap("file_write", kind: :builtin, policy_class: :read_write),
        cap("shell", kind: :builtin, policy_class: :exec),
        cap("local_skill", kind: :skill, policy_class: :exec),
        cap("mcp_github_issue_get", kind: :mcp, policy_class: :external_api)
      ]

      config = %Config{enabled?: true}

      assert Exposure.expose_for_inbound(capabilities, config) == []
    end

    test "default gate exposes only :read_only builtins explicitly listed (F-07)" do
      capabilities = [
        cap("file_read", kind: :builtin, policy_class: :read_only),
        cap("file_write", kind: :builtin, policy_class: :read_write),
        cap("shell", kind: :builtin, policy_class: :exec)
      ]

      config = %Config{enabled?: true, allowed_tools: ["file_read", "file_write", "shell"]}

      # Even with file_write and shell allowlisted, the default
      # policy_classes is [:read_only] — operator must opt in to
      # :read_write explicitly.
      assert capabilities |> Exposure.expose_for_inbound(config) |> names() == ["file_read"]
    end

    test "hidden_from_agent? capabilities are hidden unless explicitly exposed" do
      capabilities = [
        cap("safe", hidden_from_agent?: false),
        cap("hidden", hidden_from_agent?: true)
      ]

      config = %Config{enabled?: true, allowed_tools: ["safe", "hidden"]}

      assert capabilities |> Exposure.expose_for_inbound(config) |> names() == ["safe"]

      config = %Config{
        enabled?: true,
        allowed_tools: ["safe"],
        tool_overrides: %{"hidden" => %{exposed: true}}
      }

      assert capabilities |> Exposure.expose_for_inbound(config) |> names() == ["safe", "hidden"]
    end

    test "allowed and denied tools compose with the broad gate" do
      capabilities = [
        cap("a", policy_class: :read_only),
        cap("b", policy_class: :read_write),
        cap("c", policy_class: :read_only)
      ]

      config = %Config{
        enabled?: true,
        expose_policy_classes: [:read_only, :read_write],
        allowed_tools: ["a", "b"],
        denied_tools: ["b"]
      }

      assert capabilities |> Exposure.expose_for_inbound(config) |> names() == ["a"]
    end

    test "per-tool exposed override can force expose or force hide" do
      capabilities = [
        cap("shell", policy_class: :exec),
        cap("file_read", policy_class: :read_only)
      ]

      config = %Config{
        enabled?: true,
        tool_overrides: %{
          "shell" => %{exposed: true},
          "file_read" => %{exposed: false}
        }
      }

      assert capabilities |> Exposure.expose_for_inbound(config) |> names() == ["shell"]
    end
  end

  describe "to_mcp_tool_descriptor/2" do
    test "maps a capability to the MCP tool shape with description override" do
      capability = cap("file_read")

      descriptor =
        Exposure.to_mcp_tool_descriptor(capability, %{
          "file_read" => %{description_override: "Read one file."}
        })

      assert descriptor == %{
               "name" => "file_read",
               "description" => "Read one file.",
               "inputSchema" => %{type: "object", properties: %{}}
             }
    end
  end
end
