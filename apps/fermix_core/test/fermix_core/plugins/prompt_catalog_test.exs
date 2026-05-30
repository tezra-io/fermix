defmodule FermixCore.Plugins.PromptCatalogTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Plugins.PromptCatalog

  defp plugin_cap(name, plugin) do
    Capability.new(%{
      name: name,
      description: "x",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {__MODULE__, :unused, []},
      policy_class: :external_api,
      metadata: %{plugin_owned?: true, plugin: plugin}
    })
  end

  defp builtin_cap(name) do
    Capability.new(%{
      name: name,
      description: "x",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {__MODULE__, :unused, []},
      policy_class: :read_only,
      metadata: %{}
    })
  end

  test "entries/2 derives tools from plugin-owned capabilities only" do
    caps = [
      plugin_cap("google_calendar_search_events", "google_calendar"),
      builtin_cap("file_read")
    ]

    assert [entry] = PromptCatalog.entries(caps, ["google-calendar"])
    assert entry.name == "google_calendar"
    assert entry.tools == ["google_calendar_search_events"]
    assert entry.skills == ["google-calendar"]
  end

  test "entries/2 lists only skills that are actually loaded" do
    caps = [plugin_cap("google_calendar_search_events", "google_calendar")]

    assert [entry] = PromptCatalog.entries(caps, [])
    assert entry.skills == []
  end

  test "entries/2 is empty when no capability is plugin-owned" do
    assert PromptCatalog.entries([builtin_cap("file_read")], ["google-calendar"]) == []
  end
end
