defmodule FermixCore.Plugins.RegistryProvenanceTest do
  @moduledoc """
  The `remote_mcp` provenance gate as the Registry actually runs it.

  NOT async: `DistVerifierStub` is a named ETS table, so two modules allow-listing
  concurrently would see each other's entries — the shared-global-state failure
  mode this repo keeps relearning.
  """
  use ExUnit.Case, async: false

  alias FermixCore.Plugins.CanonicalJson
  alias FermixCore.Plugins.Dist.Store, as: DistStore
  alias FermixCore.Plugins.Registry
  alias FermixTestSupport.DistFixtures
  alias FermixTestSupport.DistVerifierStub
  alias FermixTestSupport.SafeRm

  describe "remote_mcp provenance gate (M27 §9.3, §10.2)" do
    @remote_runtime %{
      "kind" => "remote_mcp",
      "transport" => "streamable_http",
      "protocol_version" => "2025-06-18",
      "base_url" => "https://mcp.example.com",
      "mcp_path" => "/mcp",
      "tool_name_mode" => "prefix"
    }

    setup do
      root = SafeRm.make_tmp_dir!("registry-gate")
      store = Path.join(root, "plugins")
      fixtures = Path.join(root, "fixtures")
      File.mkdir_p!(fixtures)
      DistStore.ensure!(store)
      DistVerifierStub.init()

      on_exit(fn ->
        DistVerifierStub.cleanup()
        SafeRm.rm_rf!(root)
      end)

      %{root: root, store: store, fixtures: fixtures}
    end

    # A remote manifest binds a live credential to an endpoint, so an unsigned
    # copy in a dev_local checkout must never load — that is the whole point of
    # the gate, and it was the one production caller the design left unwired.
    test "a dev_local remote manifest is refused, and does not take the registry down",
         %{root: root} do
      checkout = Path.join(root, "dev")
      write_dev_local(checkout, "remotedemo", @remote_runtime)
      write_dev_local(checkout, "localdemo", nil)

      assert {:ok, plugins} =
               Registry.list(installed_root: Path.join(root, "empty"), dev_local: checkout)

      names = Enum.map(plugins, & &1.name)
      refute "remotedemo" in names, "an unsigned remote manifest must not load"
      assert "localdemo" in names, "one refused plugin must not cost the author the others"
    end

    test "an installed remote plugin loads only when its signature verifies",
         %{store: store, fixtures: fixtures} do
      :ok =
        DistFixtures.install_remote_plugin(
          store,
          fixtures,
          "remotedemo",
          "1.0.0",
          remote_manifest()
        )

      # DistVerifierStub denies by default: nothing allow-listed yet.
      assert {:error, {:verification_failed, :plugin, _reason}} =
               Registry.list(installed_root: store, dev_local: nil)

      :ok = DistVerifierStub.allow("remotedemo", "1.0.0")
      assert {:ok, plugins} = Registry.list(installed_root: store, dev_local: nil)
      assert Enum.any?(plugins, &(&1.name == "remotedemo"))
    end

    # The on-disk manifest decides only "is this remote"; what gets DECODED is
    # the signed copy, so editing the installed file cannot redirect the
    # credential to another origin.
    test "the decoded manifest comes from the signed bytes, not the installed file",
         %{store: store, fixtures: fixtures} do
      :ok =
        DistFixtures.install_remote_plugin(
          store,
          fixtures,
          "remotedemo",
          "1.0.0",
          remote_manifest()
        )

      :ok = DistVerifierStub.allow("remotedemo", "1.0.0")

      installed = Path.join(DistStore.current_link(store, "remotedemo"), "plugin.json")

      tampered =
        put_in(
          Jason.decode!(File.read!(installed)),
          ["runtime", "base_url"],
          "https://evil.example.com"
        )

      File.write!(installed, Jason.encode!(tampered))

      # The tree digest no longer matches the signed archive: refuse outright
      # rather than load either copy.
      assert {:error, {:active_tree_mismatch, _expected, _got}} =
               Registry.list(installed_root: store, dev_local: nil)
    end
  end

  defp write_dev_local(checkout, name, runtime) do
    dir = Path.join(checkout, name)
    File.mkdir_p!(dir)

    manifest =
      %{
        "schema_version" => 2,
        "name" => name,
        "display_name" => name,
        "description" => "#{name} fixture",
        "category" => "developer",
        "version" => "1.0.0",
        "plugin_api" => if(runtime, do: 3, else: 2),
        "auth" => %{"type" => "none"},
        "tools" => []
      }

    manifest = if runtime, do: Map.put(manifest, "runtime", runtime), else: manifest
    File.write!(Path.join(dir, "plugin.json"), Jason.encode!(manifest))
  end

  # A minimal but VALID plugin-api-3 remote manifest: the gate runs before
  # decoding, so an invalid one would mask a gate result behind a decode error.
  defp remote_manifest do
    %{
      "plugin_api" => 3,
      "min_core_version" => "0.1.0",
      "auth" => %{
        "type" => "api_key",
        "key_name" => "REMOTEDEMO_TOKEN",
        "header" => "Authorization",
        "scheme" => "Bearer",
        "prompt" => "Paste a token"
      },
      "runtime" => @remote_runtime,
      "tool_profiles" => [
        %{
          "name" => "retrieval",
          "display_name" => "Retrieval only",
          "default" => true,
          "required_credential_scope" => "read",
          "scope_visibility" => "none",
          "tools" => ["remotedemo_search"]
        }
      ],
      "setup_tools" => ["remotedemo_list_workspaces"],
      "resource_scope" => %{
        "kind" => "single_workspace",
        "discovery_tool" => "remotedemo_list_workspaces",
        "id_field" => "id",
        "label_field" => "name",
        "argument" => "workspaceId"
      },
      "budgets" => %{"agent_turn_calls" => 20, "agent_turn_paginated_calls" => 5},
      "result_contract" => %{
        "kind" => "json_boolean",
        "success_field" => "ok",
        "status_field" => "status",
        "message_field" => "message"
      },
      "tools" => [sign_tool("remotedemo_search"), sign_tool("remotedemo_list_workspaces", %{})]
    }
  end

  defp sign_tool(name, params \\ %{"workspaceId" => %{"type" => "string"}}) do
    tool = %{
      "name" => name,
      "description" => "Search.",
      "policy_class" => "external_api",
      "read_only" => true,
      "replay_safe" => true,
      "required_credential_scope" => "read",
      "rail" => "mcp",
      "collection_policy" => nil,
      "argument_guards" => [],
      "parameters" => %{"type" => "object", "properties" => params},
      "output_schema" => nil,
      "upstream_annotations" => nil
    }

    {:ok, digest} =
      CanonicalJson.descriptor_digest(name, tool["parameters"], nil, nil)

    Map.put(tool, "descriptor_sha256", digest)
  end
end
