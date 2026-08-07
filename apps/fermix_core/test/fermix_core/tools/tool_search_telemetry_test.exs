defmodule FermixCore.Tools.ToolSearchTelemetryTest do
  # Not async: the content gate is global application env, and these tests both
  # establish the default (capture off) and flip it. An async module could have
  # its value read by a concurrently running test.
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Tools.ToolSearch

  @event [:fermix, :tool_search, :query]
  # Every measurement this event carries. Written as the whole set, not as
  # per-key asserts: the miss rate is the soak metric the trace handler reads,
  # and a later change that gates one of these behind content capture — or adds
  # a fourth carrying text — has to come through this assertion.
  @measurement_keys [:catalog_size, :match_count, :top_score]
  @query "post to X"

  defmodule FakeMod do
    def execute(_args, _ctx), do: {:ok, :ok}
  end

  setup do
    name = :"toolsearch_tel_reg_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: name})

    handler = "toolsearch-tel-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      @event,
      fn _event, measurements, metadata, _config ->
        if self() == test_pid do
          send(test_pid, {:tool_search_query, measurements, metadata})
        end
      end,
      nil
    )

    # Establish both preconditions rather than inheriting them: another module
    # may have left content capture on, and "off by default" is exactly what is
    # asserted; deferral is default-on but an earlier test can leave the kill
    # switch flipped, which would empty the catalog and pass the gate assertions
    # for the wrong reason.
    prior_telemetry = Application.get_env(:fermix_core, :telemetry, [])
    prior_tools = Application.get_env(:fermix_core, :tools)
    set_capture_content(false)
    Application.put_env(:fermix_core, :tools, tool_search: [enabled: true])

    on_exit(fn ->
      :telemetry.detach(handler)
      Application.put_env(:fermix_core, :telemetry, prior_telemetry)
      restore_tools(prior_tools)
    end)

    %{registry: name}
  end

  defp restore_tools(nil), do: Application.delete_env(:fermix_core, :tools)
  defp restore_tools(value), do: Application.put_env(:fermix_core, :tools, value)

  defp set_capture_content(value) do
    Application.put_env(:fermix_core, :telemetry, capture_content: value)
  end

  defp register(registry, name, description) do
    cap =
      Capability.new(%{
        name: name,
        description: description,
        parameters: %{type: "object", properties: %{}},
        kind: :builtin,
        executor: {FakeMod, :execute, []},
        policy_class: :external_api,
        metadata: %{plugin_owned?: true, category: :plugin}
      })

    :ok = CapabilityRegistry.register(registry, cap)
  end

  defp seed_catalog(registry) do
    register(registry, "x_create_post", "Post to X. Optional reply_to_post_id replies to a post.")
    register(registry, "x_search_posts", "Search recent X posts (last 7 days).")
    register(registry, "notion_search", "Search Notion pages and data sources.")
  end

  defp search(registry, query) do
    {:ok, %{success: true}} =
      ToolSearch.execute(%{"query" => query}, %{
        capability_registry: registry,
        agent_name: "test"
      })

    assert_received {:tool_search_query, measurements, metadata}
    {measurements, metadata}
  end

  test "with content capture off, no metadata value carries the query text", %{
    registry: registry
  } do
    seed_catalog(registry)

    {_measurements, metadata} = search(registry, @query)

    refute Map.has_key?(metadata, :query)

    # Whole-surface: not "the :query key is gone" but "no value in this event
    # carries the user's words", so a differently-named copy fails too.
    for {key, value} <- metadata, is_binary(value) do
      refute String.contains?(value, @query),
             "metadata.#{key} leaks the raw query with content capture off"
    end

    assert metadata.agent == "test"
  end

  test "with content capture on, the query is attached", %{registry: registry} do
    seed_catalog(registry)
    set_capture_content(true)

    {_measurements, metadata} = search(registry, @query)

    assert metadata.query == @query
    assert metadata.agent == "test"
  end

  test "all three measurements are recorded on both sides of the content gate", %{
    registry: registry
  } do
    seed_catalog(registry)

    for capture <- [false, true] do
      set_capture_content(capture)
      {measurements, _metadata} = search(registry, @query)

      assert Enum.sort(Map.keys(measurements)) == @measurement_keys,
             "measurements changed with capture_content: #{capture}"

      assert measurements.catalog_size == 3
      assert measurements.match_count >= 1
      assert measurements.top_score > 0
    end
  end

  test "a miss still reports match_count 0 with capture off", %{registry: registry} do
    seed_catalog(registry)

    {measurements, metadata} = search(registry, "quantum chromodynamics")

    assert measurements.match_count == 0
    assert measurements.catalog_size == 3
    refute Map.has_key?(metadata, :query)
  end
end
