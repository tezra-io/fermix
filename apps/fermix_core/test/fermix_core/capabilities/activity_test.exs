defmodule FermixCore.Capabilities.ActivityTest do
  @moduledoc """
  What the Mac's chat shows while a tool runs (companion protocol 6): a
  sentence for every built-in the seeder can register, in a person's words,
  never the tool's name, and one rule for every other capability.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Activity
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.MCP.Capability, as: McpCapability
  alias FermixCore.Capabilities.Registry
  alias FermixCore.Companion.Protocol
  alias FermixCore.Management.Copy

  # Proper nouns a sentence names that the copy gate cannot know.
  @names ["Codex"]

  defmodule Executor do
    @moduledoc false
    def execute(_args, _context), do: {:ok, :ok}
  end

  setup do
    registry = :"activity_caps_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: registry})
    %{registry: registry}
  end

  test "every built-in the seeder can register says its own step" do
    seeded = Enum.map(BuiltinSeeder.builtin_tool_modules(), & &1.name())
    missing = seeded -- Map.keys(Activity.builtin_sentences())

    assert missing == [], "built-ins with no activity sentence: #{inspect(missing)}"
  end

  test "every sentence is short, clean copy, and never the tool's name" do
    for {tool, sentence} <- Activity.builtin_sentences() do
      assert sentence != ""
      assert byte_size(sentence) <= Protocol.max_activity_bytes(), "#{tool}: too long"
      refute String.ends_with?(sentence, "."), "#{tool}: #{inspect(sentence)} ends with a period"
      assert Copy.violations(sentence, :prose, @names) == [], "#{tool}: #{inspect(sentence)}"
      refute names_tool?(sentence, tool), "#{tool}: #{inspect(sentence)} names the tool"
    end
  end

  test "the name check itself catches a sentence that names its tool" do
    assert names_tool?("Running web_search", "web_search")
    assert names_tool?("Running the web search", "web_search")
    assert names_tool?("Using the browser", "browser")
    refute names_tool?("Adding a reaction", "react")
  end

  test "a built-in says its own sentence through the registry", %{registry: registry} do
    :ok = Registry.register(registry, capability("web_search", :builtin))

    assert Activity.sentence(registry, "web_search") == "Searching the web"
  end

  test "a tool of an MCP server the owner added says Using and the server's name", %{
    registry: registry
  } do
    capability =
      McpCapability.from_tool_descriptor("Notion", %{name: "search"}, final_name: "notion_search")

    :ok = Registry.register(registry, capability)

    assert Activity.sentence(registry, "notion_search") == "Using Notion"
  end

  test "a plugin's tool says Using and the plugin's display name, cut on a character", %{
    registry: registry
  } do
    long = String.duplicate("é", 80)

    :ok =
      Registry.register(
        registry,
        capability("acme_lookup", :builtin, %{plugin_owned?: true, plugin_display_name: long})
      )

    sentence = Activity.sentence(registry, "acme_lookup")

    assert String.starts_with?(sentence, "Using é")
    assert String.valid?(sentence)
    assert byte_size(sentence) <= Protocol.max_activity_bytes()
  end

  test "a skill and a name no capability has say the plain sentence", %{registry: registry} do
    :ok = Registry.register(registry, capability("weekly_review", :skill))

    assert Activity.sentence(registry, "weekly_review") == Activity.plain()
    assert Activity.sentence(registry, "no_such_tool") == Activity.plain()
    assert Activity.plain() == "Working on it"
  end

  # A sentence names its tool when one of its words is the tool's name, or,
  # for a name made of several words, when it spells those words out.
  defp names_tool?(sentence, tool) do
    lower = String.downcase(sentence)
    words = String.split(lower, ~r/[^\p{L}\p{N}_]+/u, trim: true)

    tool in words or
      (String.contains?(tool, "_") and String.contains?(lower, String.replace(tool, "_", " ")))
  end

  defp capability(name, kind, metadata \\ %{}) do
    Capability.new(%{
      name: name,
      description: "test #{name}",
      parameters: %{type: "object"},
      kind: kind,
      executor: {Executor, :execute, []},
      policy_class: :read_only,
      metadata: metadata
    })
  end
end
