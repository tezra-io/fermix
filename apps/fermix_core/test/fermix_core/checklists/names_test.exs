defmodule FermixCore.Checklists.NamesTest do
  # MILESTONE_85 §04: no name the feature takes is in use. No built-in, no
  # plugin of the bundled catalog and no bundled skill takes checklist_read or
  # checklist_edit, and the plugin registry keeps the checklist prefix, so a
  # plugin named it, or starting with checklist_, is refused when it is
  # installed and when it is read, with the sentence, while none of today's
  # plugins is.
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Plugins.Registry

  @tools ["checklist_edit", "checklist_read"]
  @plugins_dir Application.app_dir(:fermix_core, "priv/plugins")
  @skills_dir Application.app_dir(:fermix_core, "priv/skills")
  @sentence "checklist is a name Fermix keeps for its own list tools. Rename the plugin to install it."

  defp manifest(name) do
    %{
      "schema_version" => 1,
      "name" => name,
      "display_name" => "Lists Plus",
      "description" => "A plugin that would shadow the list tools",
      "category" => "test",
      "version" => "1.0.0",
      "default_enabled" => false,
      "auth" => %{"type" => "none"},
      "tools" => [
        %{"name" => "#{name}_read", "description" => "Read things.", "read_only" => true}
      ],
      "skills" => [],
      "health_check" => %{"kind" => "local_readiness", "requires_auth" => false}
    }
  end

  test "the two names belong to the list tools alone among the built-ins" do
    names = Enum.map(BuiltinSeeder.builtin_tool_modules(), & &1.name())

    assert Enum.filter(names, &String.starts_with?(&1, "checklist")) |> Enum.sort() == @tools
    assert Enum.count(names, &(&1 in @tools)) == 2
  end

  test "no bundled catalog plugin takes the prefix, and every bundled manifest still decodes" do
    index = @plugins_dir |> Path.join("index.json") |> File.read!() |> Jason.decode!()
    catalog = @plugins_dir |> Path.join("catalog.json") |> File.read!() |> Jason.decode!()
    names = Enum.map(index["plugins"], & &1["name"]) ++ catalog["plugins"]

    assert names != []
    refute Enum.any?(names, &Registry.reserved_name?/1), inspect(names)

    for path <- Path.wildcard(Path.join(@plugins_dir, "*/plugin.json")) do
      manifest = path |> File.read!() |> Jason.decode!()
      assert {:ok, plugin} = Registry.decode_manifest(manifest, path), path
      refute Enum.any?(plugin.tools, &String.starts_with?(&1["name"], "checklist")), path
    end
  end

  test "no bundled skill is named for a list tool" do
    skills =
      @skills_dir
      |> Path.join("*/SKILL.md")
      |> Path.wildcard()
      |> Enum.map(fn path -> path |> Path.dirname() |> Path.basename() end)

    assert skills != []
    refute Enum.any?(skills, &(String.replace(&1, "-", "_") in @tools))
  end

  test "a plugin named checklist, or starting with checklist_, is refused; another name is not" do
    for name <- ["checklist", "checklist_pro", "checklist_read"] do
      assert {:error, {:reserved_name, ^name}} =
               Registry.decode_manifest(manifest(name), "/tmp/#{name}/plugin.json")
    end

    for name <- ["checklists", "my_checklist", "lists"] do
      assert {:ok, _plugin} = Registry.decode_manifest(manifest(name), "/tmp/#{name}/plugin.json")
    end

    assert Registry.reserved_name_sentence() == @sentence
  end
end
