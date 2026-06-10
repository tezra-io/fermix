defmodule FermixCore.Plugins.Dist.IndexTest do
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.Dist.Index

  setup do
    tmp = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-index-test")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(tmp) end)

    %{seed: Path.join(tmp, "seed.json")}
  end

  defp index_json(generated_at, plugins) do
    Jason.encode!(%{schema_version: 1, generated_at: generated_at, plugins: plugins})
  end

  defp sample_plugin do
    %{
      name: "github",
      display_name: "GitHub",
      category: "developer",
      description: "GitHub from Fermix",
      auth_type: "api_key",
      rails: ["http"],
      latest: "1.2.0",
      yanked: ["1.1.0"],
      versions: [
        %{
          version: "1.2.0",
          published_at: "2026-06-07T00:00:00Z",
          min_core_version: "0.4.0",
          plugin_api: 2,
          artifacts: [
            %{
              target: "any",
              url: "https://example.com/github-1.2.0.tar.gz",
              sha256: "abc",
              sig_url: "https://example.com/github-1.2.0.tar.gz.sig",
              cert_url: "https://example.com/github-1.2.0.tar.gz.pem"
            }
          ]
        }
      ]
    }
  end

  describe "parse/1" do
    test "accepts a well-formed index and normalizes plugins" do
      {:ok, decoded} = Jason.decode(index_json("2026-06-07T00:00:00Z", [sample_plugin()]))
      assert {:ok, index} = Index.parse(decoded)
      assert index.schema_version == 1
      assert [plugin] = index.plugins
      assert plugin.name == "github"
      assert plugin.rails == ["http"]
      assert [version] = plugin.versions
      assert version.plugin_api == 2
      assert [artifact] = version.artifacts
      assert artifact.target == "any"
    end

    test "rejects an unknown schema_version (no silent degrade)" do
      assert {:error, {:unsupported_index_schema, 999}} =
               Index.parse(%{"schema_version" => 999, "generated_at" => "x", "plugins" => []})
    end

    test "rejects a shape mismatch" do
      assert {:error, :index_schema_mismatch} = Index.parse(%{"plugins" => []})
      assert {:error, :index_schema_mismatch} = Index.parse("not a map")
    end

    test "rejects a malformed plugin entry" do
      bad = %{"schema_version" => 1, "generated_at" => "x", "plugins" => [%{"no_name" => true}]}
      assert {:error, {:invalid_plugin_entry, _}} = Index.parse(bad)
    end
  end

  describe "load/1 (seed-only read)" do
    test "reads the bundled seed", ctx do
      File.write!(ctx.seed, index_json("2026-01-01T00:00:00Z", [sample_plugin()]))

      assert {:ok, index} = Index.load(seed_path: ctx.seed)
      assert [%{name: "github"}] = index.plugins
    end

    test "errors when the seed is missing", ctx do
      assert {:error, :enoent} = Index.load(seed_path: ctx.seed)
    end

    test "errors when the seed is corrupt", ctx do
      File.write!(ctx.seed, "{ not valid json")
      assert {:error, {:index_invalid_json, _}} = Index.load(seed_path: ctx.seed)
    end
  end

  describe "find/2 and yanked?/3" do
    test "find returns the plugin; yanked? reflects the per-plugin yanked list" do
      {:ok, decoded} = Jason.decode(index_json("2026-06-07T00:00:00Z", [sample_plugin()]))
      {:ok, index} = Index.parse(decoded)

      assert %{name: "github"} = Index.find(index, "github")
      assert Index.find(index, "missing") == nil
      assert Index.yanked?(index, "github", "1.1.0")
      refute Index.yanked?(index, "github", "1.2.0")
      refute Index.yanked?(index, "missing", "1.0.0")
    end
  end
end
