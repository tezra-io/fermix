defmodule FermixCore.Tools.ToolSearchTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Tools.ToolSearch

  defmodule FakeMod do
    def execute(_args, _ctx), do: {:ok, :ok}
  end

  setup do
    name = :"toolsearch_reg_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: name})
    %{registry: name}
  end

  defp register(registry, name, description, opts \\ []) do
    cap =
      Capability.new(%{
        name: name,
        description: description,
        parameters: Keyword.get(opts, :parameters, %{type: "object", properties: %{}}),
        kind: Keyword.get(opts, :kind, :builtin),
        executor: {FakeMod, :execute, []},
        policy_class: :external_api,
        metadata: Keyword.get(opts, :metadata, %{plugin_owned?: true, category: :plugin})
      })

    :ok = CapabilityRegistry.register(registry, cap)
  end

  defp seed_catalog(registry) do
    register(registry, "x_create_post", "Post to X. Optional reply_to_post_id replies to a post.")
    register(registry, "x_search_posts", "Search recent X posts (last 7 days).")
    register(registry, "notion_search", "Search Notion pages and data sources.")
    register(registry, "notion_create_page", "Create a Notion page under a parent.")
    register(registry, "gmail_send_message", "Send a Gmail message.")
    # A non-deferred builtin must never surface in results.
    register(registry, "shell", "Run a shell command.", metadata: %{category: :system})
  end

  defp search(registry, args) do
    {:ok, %{success: true, output: output}} =
      ToolSearch.execute(args, %{capability_registry: registry, agent_name: "test"})

    Jason.decode!(output)
  end

  test "ranks the relevant tool first and excludes non-deferred builtins", %{registry: registry} do
    seed_catalog(registry)

    result = search(registry, %{"query" => "post to X"})

    assert result["total_available"] == 5
    names = Enum.map(result["matches"], & &1["name"])
    assert hd(names) == "x_create_post"
    refute "shell" in names
  end

  test "matches across descriptions and parameter names", %{registry: registry} do
    seed_catalog(registry)

    result = search(registry, %{"query" => "notion pages"})
    names = Enum.map(result["matches"], & &1["name"])

    assert "notion_search" in names
    assert "notion_create_page" in names
  end

  test "zero-IDF fallback: a term present in every doc still finds name substrings", %{
    registry: registry
  } do
    register(registry, "github_get_me", "github profile via github api")
    register(registry, "github_list_repos", "github repos via github api")

    result = search(registry, %{"query" => "github"})
    names = Enum.map(result["matches"], & &1["name"])

    assert "github_get_me" in names
    assert "github_list_repos" in names
  end

  test "no matches returns an empty list (model retries with new terms)", %{registry: registry} do
    seed_catalog(registry)

    result = search(registry, %{"query" => "quantum chromodynamics"})
    assert result["matches"] == []
  end

  test "limit clamps to [1, 20] and defaults to 5", %{registry: registry} do
    for index <- 1..25 do
      register(registry, "fake_tool_#{index}", "manage fake widgets number #{index}")
    end

    assert search(registry, %{"query" => "fake widgets"})["matches"] |> length() == 5

    assert search(registry, %{"query" => "fake widgets", "limit" => 99})["matches"] |> length() ==
             20

    assert search(registry, %{"query" => "fake widgets", "limit" => -3})["matches"] |> length() ==
             1
  end

  test "reads the registry live — tools registered after boot are searchable", %{
    registry: registry
  } do
    assert search(registry, %{"query" => "post to X"})["matches"] == []

    register(registry, "x_create_post", "Post to X.")
    names = search(registry, %{"query" => "post to X"})["matches"] |> Enum.map(& &1["name"])

    assert names == ["x_create_post"]
  end

  test "emits [:fermix, :tool_search, :query] telemetry", %{registry: registry} do
    seed_catalog(registry)
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "toolsearch-test-#{inspect(ref)}",
      [:fermix, :tool_search, :query],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:tool_search_query, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("toolsearch-test-#{inspect(ref)}") end)

    search(registry, %{"query" => "post to X"})

    assert_received {:tool_search_query, measurements, metadata}
    assert measurements.match_count >= 1
    assert measurements.catalog_size == 5
    assert metadata.query == "post to X"
  end

  test "missing query is a tool error", %{registry: registry} do
    assert {:ok, %{success: false, error: error}} =
             ToolSearch.execute(%{}, %{capability_registry: registry})

    assert error =~ "query"
  end
end
