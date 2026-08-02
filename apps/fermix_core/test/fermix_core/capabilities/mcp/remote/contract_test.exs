defmodule FermixCore.Capabilities.MCP.Remote.ContractTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.MCP.Remote.Contract
  alias FermixCore.Plugins.CanonicalJson

  @schema %{
    "type" => "object",
    "properties" => %{
      "noteId" => %{"type" => "string"},
      "workspaceId" => %{"type" => "string"}
    },
    "required" => ["noteId", "workspaceId"]
  }

  @list_schema %{
    "type" => "object",
    "properties" => %{
      "limit" => %{"type" => "integer"},
      "workspaceId" => %{"type" => "string"}
    }
  }

  defp digest(name, input, output \\ nil, annotations \\ nil) do
    {:ok, value} = CanonicalJson.descriptor_digest(name, input, output, annotations)
    value
  end

  defp facts(name, input, overrides \\ %{}) do
    Map.merge(
      %{
        read_only: true,
        replay_safe: true,
        required_credential_scope: "read",
        descriptor_sha256: digest(name, input),
        collection_policy: nil,
        argument_guards: []
      },
      overrides
    )
  end

  defp spec(overrides \\ %{}) do
    Map.merge(
      %{
        source_id: {:plugin, "eden"},
        name: "eden",
        transport: :streamable_http,
        name_mode: :preserve,
        selected_profile: "retrieval",
        resource_scope: %{kind: :single_workspace, argument: "workspaceId", id: "ws_abc"},
        allowed_tools: %{"eden_get_note" => facts("eden_get_note", @schema)},
        budgets: %{"agent_turn_calls" => 20, "agent_turn_paginated_calls" => 5},
        result_contract: %{
          "kind" => "json_boolean",
          "success_field" => "ok",
          "status_field" => "status",
          "message_field" => "message"
        }
      },
      overrides
    )
  end

  defp compiled(overrides \\ %{}) do
    {:ok, contract} = Contract.compile(spec(overrides))
    contract
  end

  defp descriptor(name, input, extra \\ %{}) do
    Map.merge(%{name: name, description: "d", input_schema: input}, extra)
  end

  describe "compile/1" do
    test "compiles a signed remote spec into the immutable contract" do
      contract = compiled()

      assert contract.source_id == {:plugin, "eden"}
      assert contract.plugin == "eden"
      assert contract.name_mode == :preserve
      assert contract.selected_profile == "retrieval"
      assert contract.budgets == %{turn_calls: 20, turn_paginated_calls: 5}
      assert contract.result_contract.kind == :json_boolean
      assert contract.tools["eden_get_note"].credential_scope == :read
    end

    test "refuses a spec with no signed budgets rather than inventing ceilings" do
      assert {:error, {:invalid_remote_config, :budgets}} =
               Contract.compile(spec() |> Map.delete(:budgets))
    end

    test "refuses a spec with no signed result contract" do
      assert {:error, {:invalid_remote_config, :result_contract}} =
               Contract.compile(spec() |> Map.delete(:result_contract))
    end

    test "refuses an unusable resource scope" do
      assert {:error, {:invalid_remote_config, :resource_scope}} =
               Contract.compile(spec(%{resource_scope: %{kind: :single_workspace}}))
    end

    test "refuses a tool whose signed digest is not a sha256" do
      tools = %{"eden_get_note" => facts("eden_get_note", @schema, %{descriptor_sha256: "nope"})}

      assert {:error, {:invalid_remote_config, {:descriptor_sha256, "eden_get_note"}}} =
               Contract.compile(spec(%{allowed_tools: tools}))
    end
  end

  describe "select/2 — the raw-name filter" do
    test "discards an unexpected upstream tool by raw name" do
      contract = compiled()

      {:ok, selected} =
        Contract.select(contract, [
          descriptor("eden_get_note", @schema),
          descriptor("eden_delete_workspace", @schema)
        ])

      assert Enum.map(selected, & &1.name) == ["eden_get_note"]
    end

    test "filters BEFORE any schema is walked or hashed" do
      # A schema deep enough to fail the bounded walk. It never reaches the walk
      # because its name is not allowlisted.
      hostile = Enum.reduce(1..200, %{"type" => "object"}, fn _i, acc -> %{"p" => acc} end)

      {:ok, selected} =
        Contract.select(compiled(), [
          descriptor("eden_get_note", @schema),
          descriptor("eden_evil", hostile)
        ])

      assert Enum.map(selected, & &1.name) == ["eden_get_note"]
      assert {:ok, [_verified]} = Contract.verify(compiled(), selected)
    end

    test "a missing required tool fails the whole profile" do
      assert {:error, {:upstream_contract_mismatch, {:missing_tool, "eden_get_note"}}} =
               Contract.select(compiled(), [descriptor("eden_other", @schema)])
    end

    test "a duplicated upstream name fails the profile" do
      assert {:error, {:upstream_contract_mismatch, {:duplicate_tool, "eden_get_note"}}} =
               Contract.select(compiled(), [
                 descriptor("eden_get_note", @schema),
                 descriptor("eden_get_note", @schema)
               ])
    end

    test "a descriptor with no name is not allowlisted" do
      assert {:error, {:upstream_contract_mismatch, {:missing_tool, _}}} =
               Contract.select(compiled(), [%{description: "nameless"}])
    end
  end

  describe "verify/2 — all-or-none descriptor hashing" do
    test "verifies a matching descriptor and strips the resource-scope field" do
      {:ok, [tool]} = Contract.verify(compiled(), [descriptor("eden_get_note", @schema)])

      assert tool.final_name == "eden_get_note"
      refute Map.has_key?(tool.parameters["properties"], "workspaceId")
      assert tool.parameters["required"] == ["noteId"]
      assert tool.policy.read_only == true
    end

    test "one changed descriptor registers ZERO tools" do
      contract =
        compiled(%{
          allowed_tools: %{
            "eden_get_note" => facts("eden_get_note", @schema),
            "eden_search" => facts("eden_search", @list_schema)
          }
        })

      drifted = Map.put(@list_schema, "properties", %{"limit" => %{"type" => "string"}})

      assert {:error, {:upstream_contract_mismatch, {:descriptor_changed, "eden_search"}}} =
               Contract.verify(contract, [
                 descriptor("eden_get_note", @schema),
                 descriptor("eden_search", drifted)
               ])
    end

    test "an outputSchema the manifest signed as null is drift when the server adds one" do
      assert {:error, {:upstream_contract_mismatch, {:descriptor_changed, "eden_get_note"}}} =
               Contract.verify(compiled(), [
                 descriptor("eden_get_note", @schema, %{output_schema: %{"type" => "object"}})
               ])
    end

    test "a signed outputSchema and annotations verify when the server still sends them" do
      output = %{"type" => "object", "properties" => %{"ok" => %{"type" => "boolean"}}}
      annotations = %{"readOnlyHint" => true}

      contract =
        compiled(%{
          allowed_tools: %{
            "eden_get_note" =>
              facts("eden_get_note", @schema, %{
                descriptor_sha256: digest("eden_get_note", @schema, output, annotations)
              })
          }
        })

      assert {:ok, [tool]} =
               Contract.verify(contract, [
                 descriptor("eden_get_note", @schema, %{
                   output_schema: output,
                   annotations: annotations
                 })
               ])

      assert tool.name == "eden_get_note"
    end

    test "a pathological allowlisted schema is bounded, not parsed forever" do
      deep = Enum.reduce(1..64, %{"type" => "object"}, fn _i, acc -> %{"p" => acc} end)

      contract =
        compiled(%{
          allowed_tools: %{"eden_get_note" => facts("eden_get_note", deep)}
        })

      assert {:error, {:upstream_contract_mismatch, {:schema_too_deep, "eden_get_note"}}} =
               Contract.verify(contract, [descriptor("eden_get_note", deep)])
    end
  end

  describe "final_name/2" do
    test "preserve keeps the exact upstream name" do
      assert {:ok, "eden_get_note"} = Contract.final_name(compiled(), "eden_get_note")
    end

    test "preserve refuses a name outside the plugin namespace" do
      assert {:error, {:upstream_contract_mismatch, {:name_outside_namespace, "get_note"}}} =
               Contract.final_name(compiled(), "get_note")
    end

    test "preserve still enforces the 64-byte capability-name bound" do
      long = "eden_" <> String.duplicate("a", 70)

      assert {:error, {:capability_name_too_long, ^long}} =
               Contract.final_name(compiled(), long)
    end

    test "prefix mode namespaces a plugin's tool as <plugin>_<tool>" do
      contract = compiled(%{name_mode: :prefix})
      assert {:ok, "eden_get_note"} = Contract.final_name(contract, "get_note")
    end
  end

  describe "classify_result/2" do
    test "maps protocol isError to an error even when the body reads fine" do
      result = %{"isError" => true, "content" => [%{"type" => "text", "text" => ~s({"ok":true})}]}

      assert {:error, {:remote_tool_error, "unspecified"}} =
               Contract.classify_result(compiled(), result)
    end

    test "applies the signed result contract when isError is absent" do
      body = ~s({"ok":false,"status":"auth-expired","message":"nope"})
      result = %{"content" => [%{"type" => "text", "text" => body}]}

      assert {:error, {:remote_tool_error, "auth-expired"}} =
               Contract.classify_result(compiled(), result)
    end

    test "a status the peer controls never becomes an atom or a message" do
      body = ~s({"ok":false,"status":"#{String.duplicate("x", 100)}"})
      result = %{"content" => [%{"type" => "text", "text" => body}]}

      assert {:error, {:remote_tool_error, "unspecified"}} =
               Contract.classify_result(compiled(), result)
    end

    test "an ok body is a success" do
      result = %{"content" => [%{"type" => "text", "text" => ~s({"ok":true,"note":"hi"})}]}
      assert {:ok, ~s({"ok":true,"note":"hi"})} = Contract.classify_result(compiled(), result)
    end

    test "a non-JSON text body is a plain text success" do
      result = %{"content" => [%{"type" => "text", "text" => "# Note\nbody"}]}
      assert {:ok, "# Note\nbody"} = Contract.classify_result(compiled(), result)
    end

    test "rejects image, audio, resource, and blob content blocks in v1" do
      for type <- ~w(image audio resource) do
        result = %{"content" => [%{"type" => type, "data" => "AAAA"}]}

        assert {:error, {:invalid_remote_result, :unsupported_content}} =
                 Contract.classify_result(compiled(), result)
      end
    end

    test "a non-object result is invalid, not an empty success" do
      assert {:error, {:invalid_remote_result, :not_an_object}} =
               Contract.classify_result(compiled(), "just a string")
    end
  end
end
