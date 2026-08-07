defmodule FermixCore.Plugins.RegistryApi3Test do
  @moduledoc """
  The plugin-api-3 manifest grammar (M27 §7.1, §7.2, §7.5, §7.6, §7.7, §8.1, §9.2).

  Fixtures are built inline and their `descriptor_sha256` values are computed
  with the same `CanonicalJson.descriptor_digest/4` the validator uses, so every
  valid fixture is self-consistent by construction and a test that mutates a
  schema without re-signing is *supposed* to fail the hash rule.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Plugins.CanonicalJson
  alias FermixCore.Plugins.Registry

  @path "/tmp/eden/plugin.json"

  describe "a valid plugin-api-3 remote manifest" do
    test "decodes with the remote contract on the struct" do
      assert {:ok, plugin} = Registry.decode_manifest(remote_manifest(), @path)

      assert plugin.plugin_api == 3
      assert plugin.runtime["kind"] == "remote_mcp"
      assert plugin.runtime["tool_name_mode"] == "preserve"
      assert plugin.setup_tools == ["eden_list_workspaces"]
      assert plugin.budgets == %{"agent_turn_calls" => 20, "agent_turn_paginated_calls" => 5}
      assert plugin.result_contract["kind"] == "json_boolean"
      assert plugin.resource_scope["argument"] == "workspaceId"
      assert Enum.map(plugin.tool_profiles, & &1["name"]) == ["retrieval", "capture"]

      assert plugin.auth.validation == %{
               prefix: "eden_pat_",
               min_bytes: 16,
               max_bytes: 512,
               charset: "visible_ascii",
               forbid_whitespace: true
             }
    end

    test "replay_safe is independent of read_only" do
      # A read-only tool that is NOT replay-safe, and a mutating tool that IS:
      # neither combination may be inferred from the other (§7.6).
      manifest =
        put_tool(remote_manifest(), "eden_search", fn tool ->
          Map.merge(tool, %{"read_only" => true, "replay_safe" => false})
        end)

      assert {:ok, _plugin} = Registry.decode_manifest(manifest, @path)

      manifest =
        put_tool(remote_manifest(), "eden_connect_items", fn tool ->
          Map.merge(tool, %{"read_only" => false, "replay_safe" => true})
        end)

      assert {:ok, _plugin} = Registry.decode_manifest(manifest, @path)
    end

    test "prefix is also a legal remote tool_name_mode" do
      manifest = put_runtime(remote_manifest(), "tool_name_mode", "prefix")
      assert {:ok, plugin} = Registry.decode_manifest(manifest, @path)
      assert plugin.runtime["tool_name_mode"] == "prefix"
    end

    test "every remote contract block is required" do
      # A remote plugin with no signed profile, budget, or result contract has
      # no enforcement boundary at all, so absence is refused rather than
      # defaulted (§7.6, §8.1).
      expected = %{
        "tool_profiles" => {:invalid_tool_profiles, []},
        # An absent `setup_tools` decodes to `[]`, so the refusal lands on the
        # resource scope whose discovery tool is now unreachable.
        "setup_tools" => {:invalid_resource_scope, "discovery_tool", "eden_list_workspaces"},
        "resource_scope" => {:invalid_resource_scope, "resource_scope", nil},
        "budgets" => {:invalid_budgets, "budgets", nil},
        "result_contract" => {:invalid_result_contract, "contract", nil}
      }

      for {field, reason} <- expected do
        manifest = Map.delete(remote_manifest(), field)
        assert {:error, ^reason} = Registry.decode_manifest(manifest, @path)
      end
    end

    test "plugin_api 3 requires schema_version 2" do
      manifest = Map.put(remote_manifest(), "schema_version", 1)

      assert {:error, {:invalid_plugin_api_3_schema_version, 1}} =
               Registry.decode_manifest(manifest, @path)
    end
  end

  describe "plugin-api-2 refuses every plugin-api-3-only field" do
    test "root blocks" do
      for field <- ~w(tool_profiles setup_tools resource_scope budgets result_contract) do
        manifest = Map.put(api2_manifest(), field, Map.get(remote_manifest(), field))

        assert {:error, {:requires_plugin_api_3, [^field]}} =
                 Registry.decode_manifest(manifest, @path)
      end
    end

    test "auth.validation" do
      manifest = put_in(api2_manifest(), ["auth", "validation"], auth_validation())

      assert {:error, {:requires_plugin_api_3, ["auth.validation"]}} =
               Registry.decode_manifest(manifest, @path)
    end

    test "runtime.kind remote_mcp" do
      manifest = Map.put(api2_manifest(), "runtime", remote_runtime())

      assert {:error, {:requires_plugin_api_3, ["runtime.kind=remote_mcp"]}} =
               Registry.decode_manifest(manifest, @path)

      # …and the version gate still speaks first when an mcp-rail tool would
      # otherwise route the block into the stdio runtime validator.
      with_mcp_tool =
        Map.put(manifest, "tools", [
          %{"name" => "eden_read", "description" => "Read.", "rail" => "mcp"}
        ])

      assert {:error, {:requires_plugin_api_3, ["runtime.kind=remote_mcp"]}} =
               Registry.decode_manifest(with_mcp_tool, @path)
    end

    test "runtime.tool_name_mode" do
      runtime = %{"kind" => "node", "command" => "server.mjs", "tool_name_mode" => "prefix"}
      manifest = Map.put(api2_manifest(), "runtime", runtime)

      assert {:error, {:requires_plugin_api_3, ["runtime.tool_name_mode"]}} =
               Registry.decode_manifest(manifest, @path)
    end

    test "per-tool contract fields" do
      fields = ~w(
        argument_guards collection_policy descriptor_sha256 output_schema
        replay_safe required_credential_scope upstream_annotations
      )

      for field <- fields do
        tool = Map.put(api2_tool(), field, Map.get(search_tool(), field))
        manifest = Map.put(api2_manifest(), "tools", [tool])

        assert {:error, {:requires_plugin_api_3, [^field]}} =
                 Registry.decode_manifest(manifest, @path)
      end
    end

    test "an api-2 manifest with none of them still decodes" do
      assert {:ok, plugin} = Registry.decode_manifest(api2_manifest(), @path)
      assert plugin.plugin_api == 2
      assert plugin.tool_profiles == []
      assert plugin.setup_tools == []
      assert plugin.resource_scope == nil
      assert plugin.budgets == nil
      assert plugin.result_contract == nil
      assert plugin.auth.validation == nil
    end

    test "policy_class is a shipped api-2 tool field, not part of the api-3 gate" do
      # The bundled Google plugins already declare it, so gating on it would
      # refuse every manifest in the catalog.
      tool = put(api2_tool(), "policy_class", "external_api")
      manifest = Map.put(api2_manifest(), "tools", [tool])
      assert {:ok, _plugin} = Registry.decode_manifest(manifest, @path)
    end

    test "a non-integer plugin_api is refused rather than read as api 2" do
      manifest = Map.put(api2_manifest(), "plugin_api", "3")
      assert {:error, {:invalid_plugin_api, "3"}} = Registry.decode_manifest(manifest, @path)
    end
  end

  describe "remote_mcp runtime" do
    test "is mutually exclusive with every local-process field" do
      locals = %{
        "command" => "server.mjs",
        "args" => ["--stdio"],
        "env" => %{"A" => "b"},
        "pass_env" => ["PATH"],
        "cwd" => "/tmp",
        "vendored" => true,
        "min_version" => "20"
      }

      for {field, value} <- locals do
        manifest = put_runtime(remote_manifest(), field, value)

        assert {:error, {:remote_runtime_conflict, [^field]}} =
                 Registry.decode_manifest(manifest, @path)
      end
    end

    test "rejects an unknown runtime field" do
      manifest = put_runtime(remote_manifest(), "headers", %{"X" => "y"})
      assert {:error, {:unknown_fields, ["headers"]}} = Registry.decode_manifest(manifest, @path)
    end

    test "requires transport streamable_http" do
      manifest = put_runtime(remote_manifest(), "transport", "sse")

      assert {:error, {:invalid_remote_runtime, "transport", "sse"}} =
               Registry.decode_manifest(manifest, @path)
    end

    test "requires protocol_version 2025-06-18" do
      manifest = put_runtime(remote_manifest(), "protocol_version", "2025-03-26")

      assert {:error, {:invalid_remote_runtime, "protocol_version", "2025-03-26"}} =
               Registry.decode_manifest(manifest, @path)
    end

    test "requires a known tool_name_mode" do
      manifest = put_runtime(remote_manifest(), "tool_name_mode", "hash")

      assert {:error, {:invalid_remote_runtime, "tool_name_mode", "hash"}} =
               Registry.decode_manifest(manifest, @path)

      manifest = update_runtime(remote_manifest(), &Map.delete(&1, "tool_name_mode"))

      assert {:error, {:invalid_remote_runtime, "tool_name_mode", nil}} =
               Registry.decode_manifest(manifest, @path)
    end

    test "validates base_url and mcp_path through Remote.Endpoint" do
      bad = [
        {"base_url", "http://mcp.eden.so"},
        {"base_url", "https://user:pw@mcp.eden.so"},
        {"base_url", "https://mcp.eden.so/mcp"},
        {"base_url", "https://mcp.eden.so?x=1"},
        {"base_url", "https://{host}.eden.so"},
        {"base_url", "https://93.184.216.34"},
        {"mcp_path", "mcp"},
        {"mcp_path", "/mcp?x=1"},
        {"mcp_path", "/../mcp"},
        {"mcp_path", "/a%2Fb"}
      ]

      for {field, value} <- bad do
        manifest = put_runtime(remote_manifest(), field, value)
        assert {:error, {tag, _detail}} = Registry.decode_manifest(manifest, @path)
        assert tag in [:invalid_base_url, :invalid_mcp_path]
      end
    end

    test "preserve mode requires every declared tool to be plugin-namespaced" do
      # `<plugin>_` namespacing is what makes preserve mode safe: the upstream
      # name is already the final capability name (§7.7).
      manifest =
        remote_manifest()
        |> Map.put("name", "notes")
        |> put_in(["resource_scope", "discovery_tool"], "eden_list_workspaces")

      assert {:error, {:unpreservable_tool_name, "eden_list_workspaces"}} =
               Registry.decode_manifest(manifest, @path)
    end

    test "a local api-3 runtime may declare only prefix" do
      manifest = local_api3_manifest(%{"tool_name_mode" => "preserve"})

      assert {:error, {:invalid_tool_name_mode, "preserve"}} =
               Registry.decode_manifest(manifest, @path)

      assert {:ok, _plugin} =
               Registry.decode_manifest(
                 local_api3_manifest(%{"tool_name_mode" => "prefix"}),
                 @path
               )
    end

    test "a local api-3 runtime may not carry the remote-only blocks" do
      manifest = Map.put(local_api3_manifest(%{}), "budgets", budgets())

      assert {:error, {:remote_only_fields, ["budgets"]}} =
               Registry.decode_manifest(manifest, @path)
    end
  end

  describe "remote auth grammar" do
    test "must be api_key with authorization/bearer, matched case-insensitively" do
      manifest = put_in(remote_manifest(), ["auth", "header"], "X-Api-Key")

      assert {:error, {:invalid_remote_auth, :header_must_be_authorization}} =
               Registry.decode_manifest(manifest, @path)

      manifest = put_in(remote_manifest(), ["auth", "scheme"], "Bot")

      assert {:error, {:invalid_remote_auth, :scheme_must_be_bearer}} =
               Registry.decode_manifest(manifest, @path)

      lowercased =
        remote_manifest()
        |> put_in(["auth", "header"], "authorization")
        |> put_in(["auth", "scheme"], "Bearer")

      assert {:ok, _plugin} = Registry.decode_manifest(lowercased, @path)
    end

    test "must not be an oauth2 or keyless plugin" do
      manifest = Map.put(remote_manifest(), "auth", %{"type" => "none"})

      assert {:error, {:invalid_remote_auth, {:type, :none}}} =
               Registry.decode_manifest(manifest, @path)
    end
  end

  describe "auth.validation" do
    test "is a bounded declarative block" do
      bad = [
        {%{"regex" => "^eden_"}, {:unknown_fields, ["regex"]}},
        {put(auth_validation(), "prefix", ""), {:invalid_auth_validation, "prefix", ""}},
        {put(auth_validation(), "min_bytes", 0), {:invalid_auth_validation, "min_bytes", 0}},
        {put(auth_validation(), "max_bytes", "512"),
         {:invalid_auth_validation, "max_bytes", "512"}},
        {put(auth_validation(), "charset", "utf8"),
         {:invalid_auth_validation, "charset", "utf8"}},
        {put(auth_validation(), "forbid_whitespace", "yes"),
         {:invalid_auth_validation, "forbid_whitespace", "yes"}}
      ]

      for {block, expected} <- bad do
        manifest = put_in(remote_manifest(), ["auth", "validation"], block)
        assert {:error, ^expected} = Registry.decode_manifest(manifest, @path)
      end
    end

    test "refuses min_bytes above max_bytes" do
      block = auth_validation() |> put("min_bytes", 600) |> put("max_bytes", 512)
      manifest = put_in(remote_manifest(), ["auth", "validation"], block)

      assert {:error, {:invalid_auth_validation, "min_bytes", 600}} =
               Registry.decode_manifest(manifest, @path)
    end
  end

  describe "tool_profiles" do
    test "requires at least one profile" do
      manifest = Map.put(remote_manifest(), "tool_profiles", [])
      assert {:error, {:invalid_tool_profiles, []}} = Registry.decode_manifest(manifest, @path)
    end

    test "requires exactly one default" do
      none = Enum.map(profiles(), &put(&1, "default", false))
      manifest = Map.put(remote_manifest(), "tool_profiles", none)
      assert {:error, {:invalid_default_profile, 0}} = Registry.decode_manifest(manifest, @path)

      both = Enum.map(profiles(), &put(&1, "default", true))
      manifest = Map.put(remote_manifest(), "tool_profiles", both)
      assert {:error, {:invalid_default_profile, 2}} = Registry.decode_manifest(manifest, @path)
    end

    test "validates each field" do
      bad = [
        {put(retrieval(), "name", "Retrieval"), {:invalid_tool_profile_name, "Retrieval"}},
        {put(retrieval(), "display_name", ""),
         {:invalid_tool_profile, "retrieval", {:invalid_field, "display_name", ""}}},
        {put(retrieval(), "default", "yes"),
         {:invalid_tool_profile, "retrieval", {:invalid_field, "default", "yes"}}},
        {put(retrieval(), "required_credential_scope", "admin"),
         {:invalid_tool_profile, "retrieval",
          {:invalid_field, "required_credential_scope", "admin"}}},
        {put(retrieval(), "scope_visibility", "some"),
         {:invalid_tool_profile, "retrieval", {:invalid_field, "scope_visibility", "some"}}},
        {put(retrieval(), "tools", []),
         {:invalid_tool_profile, "retrieval", {:invalid_field, "tools", []}}},
        {put(retrieval(), "extra", true),
         {:invalid_tool_profile, "retrieval", {:unknown_fields, ["extra"]}}}
      ]

      for {profile, expected} <- bad do
        manifest = Map.put(remote_manifest(), "tool_profiles", [profile])
        assert {:error, ^expected} = Registry.decode_manifest(manifest, @path)
      end
    end

    test "rejects duplicate profile names" do
      manifest = Map.put(remote_manifest(), "tool_profiles", [retrieval(), retrieval()])

      assert {:error, {:duplicate_tool_profile, "retrieval"}} =
               Registry.decode_manifest(manifest, @path)
    end

    test "every profile tool must be declared" do
      profile = put(retrieval(), "tools", ["eden_missing"])
      manifest = Map.put(remote_manifest(), "tool_profiles", [profile])

      assert {:error, {:undeclared_profile_tool, "eden_missing"}} =
               Registry.decode_manifest(manifest, @path)
    end

    test "a setup tool may not appear in a profile" do
      profile = put(retrieval(), "tools", ["eden_search", "eden_list_workspaces"])
      manifest = Map.put(remote_manifest(), "tool_profiles", [profile])

      assert {:error, {:setup_tool_in_profile, "retrieval", "eden_list_workspaces"}} =
               Registry.decode_manifest(manifest, @path)
    end
  end

  describe "setup_tools" do
    test "must name declared tools" do
      manifest = Map.put(remote_manifest(), "setup_tools", ["eden_nope"])

      assert {:error, {:undeclared_setup_tool, "eden_nope"}} =
               Registry.decode_manifest(manifest, @path)
    end

    test "must be a list of unique non-empty names" do
      for value <- [%{}, ["a", "a"], [""], [1]] do
        manifest = Map.put(remote_manifest(), "setup_tools", value)

        assert {:error, {:invalid_setup_tools, ^value}} =
                 Registry.decode_manifest(manifest, @path)
      end
    end
  end

  describe "resource_scope" do
    test "validates kind, fields, and the discovery tool" do
      bad = [
        {put(resource_scope(), "kind", "many"), {:invalid_resource_scope, "kind", "many"}},
        {put(resource_scope(), "id_field", ""), {:invalid_resource_scope, "id_field", ""}},
        {put(resource_scope(), "label_field", nil),
         {:invalid_resource_scope, "label_field", nil}},
        {put(resource_scope(), "argument", ""), {:invalid_resource_scope, "argument", ""}},
        {put(resource_scope(), "discovery_tool", "eden_search"),
         {:invalid_resource_scope, "discovery_tool", "eden_search"}},
        {put(resource_scope(), "extra", 1), {:unknown_fields, ["extra"]}}
      ]

      for {scope, expected} <- bad do
        manifest = Map.put(remote_manifest(), "resource_scope", scope)
        assert {:error, ^expected} = Registry.decode_manifest(manifest, @path)
      end
    end

    test "the argument must be a declared parameter of every profile tool" do
      manifest =
        put_tool(remote_manifest(), "eden_search", fn tool ->
          update_in(tool, ["parameters", "properties"], &Map.delete(&1, "workspaceId"))
        end)

      assert {:error, {:missing_scope_argument, "eden_search", "workspaceId"}} =
               Registry.decode_manifest(manifest, @path)
    end
  end

  describe "budgets" do
    test "bounds the per-turn call counts" do
      bad = [
        {put(budgets(), "agent_turn_calls", 0), {:invalid_budgets, "agent_turn_calls", 0}},
        {put(budgets(), "agent_turn_calls", 101), {:invalid_budgets, "agent_turn_calls", 101}},
        {put(budgets(), "agent_turn_paginated_calls", 0),
         {:invalid_budgets, "agent_turn_paginated_calls", 0}},
        {put(budgets(), "agent_turn_paginated_calls", 101),
         {:invalid_budgets, "agent_turn_paginated_calls", 101}},
        {put(budgets(), "agent_turn_calls", 4),
         {:invalid_budgets, "agent_turn_paginated_calls", 5}},
        {put(budgets(), "burst", 3), {:unknown_fields, ["burst"]}}
      ]

      for {block, expected} <- bad do
        manifest = Map.put(remote_manifest(), "budgets", block)
        assert {:error, ^expected} = Registry.decode_manifest(manifest, @path)
      end
    end
  end

  describe "result_contract" do
    test "validates kind and field names" do
      bad = [
        {put(result_contract(), "kind", "text"), {:invalid_result_contract, "kind", "text"}},
        {put(result_contract(), "success_field", ""),
         {:invalid_result_contract, "success_field", ""}},
        {put(result_contract(), "status_field", nil),
         {:invalid_result_contract, "status_field", nil}},
        {put(result_contract(), "message_field", 1),
         {:invalid_result_contract, "message_field", 1}},
        {put(result_contract(), "extra", 1), {:unknown_fields, ["extra"]}}
      ]

      for {block, expected} <- bad do
        manifest = Map.put(remote_manifest(), "result_contract", block)
        assert {:error, ^expected} = Registry.decode_manifest(manifest, @path)
      end
    end
  end

  describe "the signed per-tool contract" do
    test "validates every policy field" do
      bad = [
        {put(search_tool(), "policy_class", "local"), {:invalid_field, "policy_class", "local"}},
        {put(search_tool(), "rail", "http"), {:invalid_field, "rail", "http"}},
        {put(search_tool(), "read_only", "yes"), {:invalid_field, "read_only", "yes"}},
        {put(search_tool(), "replay_safe", nil), {:invalid_field, "replay_safe", nil}},
        {put(search_tool(), "required_credential_scope", "admin"),
         {:invalid_field, "required_credential_scope", "admin"}}
      ]

      for {tool, expected} <- bad do
        manifest = replace_tool(remote_manifest(), tool)

        assert {:error, {:invalid_remote_tool, "eden_search", ^expected}} =
                 Registry.decode_manifest(manifest, @path)
      end
    end

    test "requires object schemas" do
      manifest = replace_tool(remote_manifest(), put(search_tool(), "parameters", []))

      assert {:error, {:invalid_remote_tool, "eden_search", {:invalid_field, "parameters", []}}} =
               Registry.decode_manifest(manifest, @path)

      manifest =
        replace_tool(remote_manifest(), put(search_tool(), "output_schema", %{"type" => "array"}))

      assert {:error, {:invalid_remote_tool, "eden_search", {:invalid_field, "output_schema", _}}} =
               Registry.decode_manifest(manifest, @path)

      manifest = replace_tool(remote_manifest(), put(search_tool(), "upstream_annotations", []))

      assert {:error,
              {:invalid_remote_tool, "eden_search", {:invalid_field, "upstream_annotations", []}}} =
               Registry.decode_manifest(manifest, @path)
    end

    test "rejects unknown and missing tool fields" do
      manifest = replace_tool(remote_manifest(), put(search_tool(), "request", %{}))

      assert {:error, {:invalid_remote_tool, "eden_search", {:unknown_fields, ["request"]}}} =
               Registry.decode_manifest(manifest, @path)

      manifest = replace_tool(remote_manifest(), Map.delete(search_tool(), "collection_policy"))

      assert {:error,
              {:invalid_remote_tool, "eden_search", {:missing_fields, ["collection_policy"]}}} =
               Registry.decode_manifest(manifest, @path)
    end

    test "requires a 64-lowercase-hex descriptor_sha256" do
      for value <- ["", "ZZ", String.upcase(String.duplicate("a", 64)), 1] do
        manifest = replace_tool(remote_manifest(), put(search_tool(), "descriptor_sha256", value))

        assert {:error,
                {:invalid_remote_tool, "eden_search",
                 {:invalid_field, "descriptor_sha256", ^value}}} =
                 Registry.decode_manifest(manifest, @path)
      end
    end

    test "refuses a descriptor hash that does not match its own schemas" do
      # Edit the signed schema WITHOUT re-signing: the manifest now declares a
      # hash of a descriptor it does not contain (§7.6 rule 6).
      tool =
        update_in(search_tool(), ["parameters", "properties"], fn properties ->
          Map.put(properties, "cursor", %{"type" => "string"})
        end)

      manifest = replace_tool(remote_manifest(), tool)

      assert {:error,
              {:invalid_remote_tool, "eden_search",
               {:descriptor_sha256_mismatch, _declared, _computed}}} =
               Registry.decode_manifest(manifest, @path)
    end
  end

  describe "collection_policy" do
    test "validates the declarative pagination block" do
      bad = [
        {put(collection_policy(), "paginated", false),
         {:invalid_collection_policy, "paginated", false}},
        {put(collection_policy(), "default_limit", 0),
         {:invalid_collection_policy, "default_limit", 0}},
        {put(collection_policy(), "default_limit", 101),
         {:invalid_collection_policy, "default_limit", 101}},
        {put(collection_policy(), "max_returned_items", 0),
         {:invalid_collection_policy, "max_returned_items", 0}},
        {put(collection_policy(), "max_returned_items", 101),
         {:invalid_collection_policy, "max_returned_items", 101}},
        {put(collection_policy(), "cursor", "/next"), {:unknown_fields, ["cursor"]}}
      ]

      for {policy, expected} <- bad do
        manifest =
          replace_tool(remote_manifest(), sign(put(search_tool(), "collection_policy", policy)))

        assert {:error, {:invalid_remote_tool, "eden_search", ^expected}} =
                 Registry.decode_manifest(manifest, @path)
      end
    end

    test "pointers are RFC 6901, wildcard-free, and must resolve compatibly" do
      bad = [
        {"request_limit_pointer", "limit", {:invalid_pointer, "limit"}},
        {"request_limit_pointer", "/*", {:wildcard_pointer, "/*"}},
        {"request_limit_pointer", "/nope", {:pointer_unresolved, "nope"}},
        {"request_limit_pointer", "/query", {:incompatible_type, "string"}},
        {"request_limit_pointer", "/a~2b", {:invalid_pointer, "/a~2b"}},
        {"result_items_pointer", "/nope", {:pointer_unresolved, "nope"}}
      ]

      for {key, pointer, detail} <- bad do
        policy = put(collection_policy(), key, pointer)

        manifest =
          replace_tool(remote_manifest(), sign(put(search_tool(), "collection_policy", policy)))

        assert {:error,
                {:invalid_remote_tool, "eden_search", {:invalid_collection_policy, ^key, ^detail}}} =
                 Registry.decode_manifest(manifest, @path)
      end
    end

    test "a null collection_policy is valid" do
      manifest =
        replace_tool(remote_manifest(), sign(put(search_tool(), "collection_policy", nil)))

      assert {:ok, _plugin} = Registry.decode_manifest(manifest, @path)
    end
  end

  describe "argument_guards" do
    test "the manifest picks the field and maximum, never the guard" do
      bad = [
        {put(url_guard(), "kind", "regex"), {:invalid_argument_guard, "kind", "regex"}},
        {put(url_guard(), "kind", "allow_all"), {:invalid_argument_guard, "kind", "allow_all"}},
        {put(url_guard(), "max_items", 0), {:invalid_argument_guard, "max_items", 0}},
        {put(url_guard(), "max_items", 101), {:invalid_argument_guard, "max_items", 101}},
        {put(url_guard(), "pointer", "/workspaceId"),
         {:invalid_argument_guard, "pointer", {:incompatible_type, "string"}}},
        {put(url_guard(), "pointer", "/*"),
         {:invalid_argument_guard, "pointer", {:wildcard_pointer, "/*"}}},
        {put(url_guard(), "allow_private", true), {:unknown_fields, ["allow_private"]}}
      ]

      for {guard, expected} <- bad do
        tool = sign(put(connect_tool(), "argument_guards", [guard]))
        manifest = replace_tool(remote_manifest(), tool)

        assert {:error, {:invalid_remote_tool, "eden_connect_items", ^expected}} =
                 Registry.decode_manifest(manifest, @path)
      end
    end

    test "accepts the second fixed core guard kind" do
      guard = put(url_guard(), "kind", "bounded_visible_ascii_array")
      tool = sign(put(connect_tool(), "argument_guards", [guard]))
      manifest = replace_tool(remote_manifest(), tool)
      assert {:ok, _plugin} = Registry.decode_manifest(manifest, @path)
    end
  end

  # --- fixtures -----------------------------------------------------------

  defp remote_manifest do
    %{
      "schema_version" => 2,
      "plugin_api" => 3,
      "min_core_version" => "0.8.0",
      "name" => "eden",
      "display_name" => "Eden",
      "description" => "Search, read, capture, and connect knowledge in an Eden workspace.",
      "category" => "productivity",
      "version" => "1.0.0",
      "default_enabled" => false,
      "auth" => %{
        "type" => "api_key",
        "key_name" => "EDEN_PERSONAL_ACCESS_TOKEN",
        "header" => "Authorization",
        "scheme" => "Bearer",
        "prompt" => "Paste an Eden personal access token",
        "help_url" => "https://eden.so/help/eden-mcp/installing-with-cli/",
        "validation" => auth_validation()
      },
      "runtime" => remote_runtime(),
      "tool_profiles" => profiles(),
      "setup_tools" => ["eden_list_workspaces"],
      "resource_scope" => resource_scope(),
      "budgets" => budgets(),
      "result_contract" => result_contract(),
      "tools" => [workspaces_tool(), search_tool(), connect_tool()],
      "skills" => []
    }
  end

  defp remote_runtime do
    %{
      "kind" => "remote_mcp",
      "transport" => "streamable_http",
      "protocol_version" => "2025-06-18",
      "base_url" => "https://mcp.eden.so",
      "mcp_path" => "/mcp",
      "tool_name_mode" => "preserve"
    }
  end

  defp auth_validation do
    %{
      "prefix" => "eden_pat_",
      "min_bytes" => 16,
      "max_bytes" => 512,
      "charset" => "visible_ascii",
      "forbid_whitespace" => true
    }
  end

  defp profiles, do: [retrieval(), capture()]

  defp retrieval do
    %{
      "name" => "retrieval",
      "display_name" => "Retrieval only",
      "default" => true,
      "required_credential_scope" => "read",
      "scope_visibility" => "none",
      "tools" => ["eden_search"]
    }
  end

  defp capture do
    %{
      "name" => "capture",
      "display_name" => "Retrieval and capture",
      "default" => false,
      "required_credential_scope" => "write",
      "scope_visibility" => "none",
      "tools" => ["eden_search", "eden_connect_items"]
    }
  end

  defp resource_scope do
    %{
      "kind" => "single_workspace",
      "discovery_tool" => "eden_list_workspaces",
      "id_field" => "id",
      "label_field" => "name",
      "argument" => "workspaceId"
    }
  end

  defp budgets, do: %{"agent_turn_calls" => 20, "agent_turn_paginated_calls" => 5}

  defp result_contract do
    %{
      "kind" => "json_boolean",
      "success_field" => "ok",
      "status_field" => "status",
      "message_field" => "message"
    }
  end

  defp collection_policy do
    %{
      "paginated" => true,
      "request_limit_pointer" => "/limit",
      "default_limit" => 50,
      "result_items_pointer" => "/items",
      "max_returned_items" => 50
    }
  end

  defp url_guard,
    do: %{"pointer" => "/urls", "kind" => "public_http_url_array", "max_items" => 20}

  defp workspaces_tool do
    sign(%{
      "name" => "eden_list_workspaces",
      "description" => "List Eden workspaces available to the connected token.",
      "policy_class" => "external_api",
      "read_only" => true,
      "replay_safe" => false,
      "required_credential_scope" => "read",
      "rail" => "mcp",
      "collection_policy" => nil,
      "argument_guards" => [],
      "parameters" => %{"type" => "object", "properties" => %{}},
      "output_schema" => nil,
      "upstream_annotations" => nil
    })
  end

  defp search_tool do
    sign(%{
      "name" => "eden_search",
      "description" => "Search an Eden workspace.",
      "policy_class" => "external_api",
      "read_only" => true,
      "replay_safe" => true,
      "required_credential_scope" => "read",
      "rail" => "mcp",
      "collection_policy" => collection_policy(),
      "argument_guards" => [],
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "workspaceId" => %{"type" => "string"},
          "query" => %{"type" => "string"},
          "limit" => %{"type" => "integer"}
        },
        "required" => ["workspaceId", "query"]
      },
      "output_schema" => %{
        "type" => "object",
        "properties" => %{"items" => %{"type" => "array"}}
      },
      "upstream_annotations" => nil
    })
  end

  defp connect_tool do
    sign(%{
      "name" => "eden_connect_items",
      "description" => "Connect web sources to an Eden note.",
      "policy_class" => "external_api",
      "read_only" => false,
      "replay_safe" => false,
      "required_credential_scope" => "write",
      "rail" => "mcp",
      "collection_policy" => nil,
      "argument_guards" => [url_guard()],
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "workspaceId" => %{"type" => "string"},
          "urls" => %{"type" => "array", "items" => %{"type" => "string"}}
        }
      },
      "output_schema" => nil,
      "upstream_annotations" => %{"readOnlyHint" => false}
    })
  end

  # Recompute `descriptor_sha256` from the tool's own schemas, exactly as the
  # validator does. Every fixture mutation that touches a signed schema must be
  # re-signed, or the self-consistency rule is (correctly) what fails.
  defp sign(tool) do
    {:ok, digest} =
      CanonicalJson.descriptor_digest(
        Map.fetch!(tool, "name"),
        Map.fetch!(tool, "parameters"),
        Map.get(tool, "output_schema"),
        Map.get(tool, "upstream_annotations")
      )

    Map.put(tool, "descriptor_sha256", digest)
  end

  defp api2_manifest do
    %{
      "schema_version" => 2,
      "plugin_api" => 2,
      "min_core_version" => "0.4.0",
      "name" => "eden",
      "display_name" => "Eden",
      "description" => "An api-2 plugin.",
      "category" => "productivity",
      "version" => "1.0.0",
      "default_enabled" => false,
      "auth" => %{"type" => "api_key", "key_name" => "EDEN_TOKEN", "prompt" => "Token"},
      "tools" => [api2_tool()],
      "skills" => []
    }
  end

  defp api2_tool do
    %{
      "name" => "eden_search",
      "description" => "Search an Eden workspace.",
      "read_only" => true,
      "rail" => "http",
      "parameters" => %{"type" => "object", "properties" => %{"query" => %{"type" => "string"}}},
      "request" => %{
        "method" => "GET",
        "url" => "https://api.eden.so/v1/search",
        "query" => %{"q" => "{query}"}
      }
    }
  end

  defp local_api3_manifest(runtime_extra) do
    runtime = Map.merge(%{"kind" => "node", "command" => "server.mjs"}, runtime_extra)

    %{
      "schema_version" => 2,
      "plugin_api" => 3,
      "min_core_version" => "0.8.0",
      "name" => "eden",
      "display_name" => "Eden",
      "description" => "A local api-3 plugin.",
      "category" => "productivity",
      "version" => "1.0.0",
      "default_enabled" => false,
      "auth" => %{"type" => "none"},
      "runtime" => runtime,
      "tools" => [%{"name" => "eden_read", "description" => "Read.", "rail" => "mcp"}],
      "skills" => []
    }
  end

  # --- fixture helpers ----------------------------------------------------

  defp put(map, key, value), do: Map.put(map, key, value)

  defp put_runtime(manifest, key, value), do: update_runtime(manifest, &Map.put(&1, key, value))

  defp update_runtime(manifest, fun), do: Map.update!(manifest, "runtime", fun)

  defp replace_tool(manifest, %{"name" => name} = tool) do
    Map.update!(manifest, "tools", fn tools -> Enum.map(tools, &swap_tool(&1, name, tool)) end)
  end

  defp swap_tool(%{"name" => name}, name, tool), do: tool
  defp swap_tool(existing, _name, _tool), do: existing

  defp put_tool(manifest, name, fun) do
    Map.update!(manifest, "tools", fn tools -> Enum.map(tools, &edit_tool(&1, name, fun)) end)
  end

  defp edit_tool(%{"name" => name} = tool, name, fun), do: sign(fun.(tool))
  defp edit_tool(tool, _name, _fun), do: tool

  describe "schema_version unknown-major refusal (M8 §5.2)" do
    test "accepts the two known majors" do
      for version <- [1, 2] do
        manifest = %{
          "schema_version" => version,
          "name" => "demo",
          "display_name" => "Demo",
          "description" => "d",
          "category" => "productivity",
          "version" => "1.0.0",
          "auth" => %{"type" => "none"}
        }

        assert {:ok, _plugin} = Registry.decode_manifest(manifest, "/tmp/demo/plugin.json")
      end
    end

    # Every schema_version branch in the decoder is written `v < 2`, so before
    # this gate a `3` silently inherited v2 semantics — validated by rules it
    # was never written against.
    test "refuses an unknown major instead of treating it as the newest known" do
      manifest = %{
        "schema_version" => 3,
        "name" => "demo",
        "display_name" => "Demo",
        "description" => "d",
        "category" => "productivity",
        "version" => "1.0.0",
        "auth" => %{"type" => "none"}
      }

      assert {:error, {:unsupported_schema_version, 3}} =
               Registry.decode_manifest(manifest, "/tmp/demo/plugin.json")
    end

    test "refuses a non-integer schema_version" do
      manifest = %{
        "schema_version" => "2",
        "name" => "demo",
        "display_name" => "Demo",
        "description" => "d",
        "category" => "productivity",
        "version" => "1.0.0",
        "auth" => %{"type" => "none"}
      }

      assert {:error, {:unsupported_schema_version, "2"}} =
               Registry.decode_manifest(manifest, "/tmp/demo/plugin.json")
    end
  end
end
