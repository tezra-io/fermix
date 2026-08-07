defmodule FermixCore.Capabilities.MCP.Discoverer.AnubisTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.MCP.Discoverer.Anubis, as: AnubisDiscoverer

  describe "interpret_response/1" do
    test "unwraps a successful tools/list response and normalizes each tool" do
      response = %Anubis.MCP.Response{
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

      assert {:ok, tools} = AnubisDiscoverer.interpret_response({:ok, response})
      assert length(tools) == 2

      [click, see] = tools
      assert click.name == "click"
      assert click.description == "click on UI"
      assert click.input_schema == %{"type" => "object", "properties" => %{}}

      assert see.name == "see"
      assert see.description == ""
      # String-keyed, matching the wire: the signed descriptor is canonicalized
      # over the JSON shape, so an atom-keyed default would hash differently
      # from the same schema that arrived over the socket.
      assert see.input_schema == %{"type" => "object", "properties" => %{}}
    end

    test "treats Anubis.MCP.Response with is_error: true as an error" do
      response = %Anubis.MCP.Response{
        result: %{"message" => "permission denied"},
        id: "req_err",
        is_error: true
      }

      assert {:error, {:tools_error, ^response}} =
               AnubisDiscoverer.interpret_response({:ok, response})
    end

    test "returns :unexpected_tools_response when the result has no tools key" do
      response = %Anubis.MCP.Response{result: %{"prompts" => []}, id: "req_x", is_error: false}

      assert {:error, {:unexpected_tools_response, ^response}} =
               AnubisDiscoverer.interpret_response({:ok, response})
    end

    test "propagates transport errors verbatim" do
      assert {:error, :timeout} = AnubisDiscoverer.interpret_response({:error, :timeout})
    end
  end

  describe "signed-descriptor fidelity (M27 §7.6)" do
    # THE BUG THIS PINS: the signed descriptor is the canonicalization of
    # name + inputSchema + outputSchema + annotations. `normalize/1` used to
    # carry only name/description/inputSchema, so `Contract` hashed every
    # remote tool with `annotations: nil` while the publisher had signed the
    # real ones — every descriptor read as drifted and NOTHING registered.
    # Eden returns annotations on all 78 of its tools, so this was total.
    test "carries outputSchema and annotations through" do
      response = %Anubis.MCP.Response{
        result: %{
          "tools" => [
            %{
              "name" => "eden_list_workspaces",
              "description" => "List workspaces.",
              "inputSchema" => %{"type" => "object", "properties" => %{}},
              "outputSchema" => %{"type" => "object"},
              "annotations" => %{"readOnlyHint" => true, "idempotentHint" => true}
            }
          ]
        },
        is_error: false
      }

      assert {:ok, [tool]} =
               AnubisDiscoverer.interpret_response({:ok, response})

      assert tool.output_schema == %{"type" => "object"}
      assert tool.annotations == %{"readOnlyHint" => true, "idempotentHint" => true}
    end

    # A server that simply omits the fields must hash identically to one that
    # sends explicit nulls, or an omission would read as drift.
    test "an omitted outputSchema/annotations normalizes to nil, not a default" do
      response = %Anubis.MCP.Response{
        result: %{
          "tools" => [
            %{"name" => "t", "description" => "d", "inputSchema" => %{"type" => "object"}}
          ]
        },
        is_error: false
      }

      assert {:ok, [tool]} =
               AnubisDiscoverer.interpret_response({:ok, response})

      assert tool.output_schema == nil
      assert tool.annotations == nil
    end
  end

  describe "one canonical normalizer (M27 §7.6)" do
    # THE ROOT CAUSE THIS PINS: descriptor normalization used to be duplicated —
    # `Discoverer.Anubis` for stdio, `Remote.Owner` for remote — and BOTH copies
    # dropped outputSchema and annotations. The signed hash covers all four
    # fields, so every remote tool hashed to something the publisher never
    # signed and the whole plugin read as drifted. Eden sends annotations on all
    # 78 of its tools, so nothing registered at all. There is now one function;
    # this pins its contract.
    alias FermixCore.Capabilities.MCP.Discoverer
    alias FermixCore.Plugins.CanonicalJson

    @wire %{
      "name" => "eden_list_workspaces",
      "description" => "List workspaces.",
      "inputSchema" => %{"type" => "object", "properties" => %{}},
      "annotations" => %{"readOnlyHint" => true, "idempotentHint" => true}
    }

    test "carries every field the signature covers" do
      d = Discoverer.normalize(@wire)

      assert d.name == "eden_list_workspaces"
      assert d.input_schema == %{"type" => "object", "properties" => %{}}
      assert d.annotations == %{"readOnlyHint" => true, "idempotentHint" => true}
      assert d.output_schema == nil
    end

    # The invariant that matters: a normalized descriptor must hash to exactly
    # what the publisher computed from the raw wire fields. If normalization
    # ever drops or reshapes one of the four, this fails.
    test "normalizing does not change the signed digest" do
      d = Discoverer.normalize(@wire)

      {:ok, from_normalized} =
        CanonicalJson.descriptor_digest(d.name, d.input_schema, d.output_schema, d.annotations)

      {:ok, from_wire} =
        CanonicalJson.descriptor_digest(
          @wire["name"],
          @wire["inputSchema"],
          @wire["outputSchema"],
          @wire["annotations"]
        )

      assert from_normalized == from_wire
    end

    test "an omitted field is nil, so omission hashes like an explicit null" do
      omitted = Discoverer.normalize(Map.drop(@wire, ["annotations"]))
      explicit = Discoverer.normalize(Map.put(@wire, "annotations", nil))

      assert omitted.annotations == nil
      assert explicit.annotations == nil
    end
  end
end
