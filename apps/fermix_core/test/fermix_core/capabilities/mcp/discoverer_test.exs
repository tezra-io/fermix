defmodule FermixCore.Capabilities.MCP.Discoverer.HermesTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.MCP.Discoverer.Hermes, as: HermesDiscoverer

  describe "interpret_response/1" do
    test "unwraps a successful tools/list response and normalizes each tool" do
      response = %Hermes.MCP.Response{
        result: %{
          "tools" => [
            %{
              "name" => "click",
              "description" => "click on UI",
              "inputSchema" => %{"type" => "object", "properties" => %{}}
            },
            %{"name" => "see"}
          ]
        },
        id: "req_test",
        is_error: false
      }

      assert {:ok, tools} = HermesDiscoverer.interpret_response({:ok, response})
      assert length(tools) == 2

      [click, see] = tools
      assert click.name == "click"
      assert click.description == "click on UI"
      assert click.input_schema == %{"type" => "object", "properties" => %{}}

      assert see.name == "see"
      assert see.description == ""
      assert see.input_schema == %{type: "object", properties: %{}}
    end

    test "treats Hermes.MCP.Response with is_error: true as an error" do
      response = %Hermes.MCP.Response{
        result: %{"message" => "permission denied"},
        id: "req_err",
        is_error: true
      }

      assert {:error, {:tools_error, ^response}} =
               HermesDiscoverer.interpret_response({:ok, response})
    end

    test "returns :unexpected_tools_response when the result has no tools key" do
      response = %Hermes.MCP.Response{result: %{"prompts" => []}, id: "req_x", is_error: false}

      assert {:error, {:unexpected_tools_response, ^response}} =
               HermesDiscoverer.interpret_response({:ok, response})
    end

    test "propagates transport errors verbatim" do
      assert {:error, :timeout} = HermesDiscoverer.interpret_response({:error, :timeout})
    end
  end
end
