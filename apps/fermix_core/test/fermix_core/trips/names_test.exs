defmodule FermixCore.Trips.NamesTest do
  # M89 §04: no name the feature takes is in use, as the lists' names test
  # has it. No built-in, no plugin of the bundled catalog and no bundled skill
  # takes trip_read or trip_edit, and the plugin registry keeps the trip
  # prefix, so a plugin named it, or starting with trip_, is refused when it
  # is installed and when it is read, with its own sentence, while none of
  # today's plugins is.
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Plugins.Registry

  @tools ["trip_edit", "trip_read"]
  @plugins_dir Application.app_dir(:fermix_core, "priv/plugins")
  @skills_dir Application.app_dir(:fermix_core, "priv/skills")
  @sentence "trip is a name Fermix keeps for its own trip tools. Rename the plugin to install it."
  @list_sentence "checklist is a name Fermix keeps for its own list tools. Rename the plugin to " <>
                   "install it."

  defp manifest(name) do
    %{
      "schema_version" => 1,
      "name" => name,
      "display_name" => "Trips Plus",
      "description" => "A plugin that would shadow the trip tools",
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

  test "the two names belong to the trip tools alone among the built-ins" do
    names = Enum.map(BuiltinSeeder.builtin_tool_modules(), & &1.name())

    assert Enum.filter(names, &String.starts_with?(&1, "trip_")) |> Enum.sort() == @tools
    assert Enum.count(names, &(&1 in @tools)) == 2
  end

  test "no bundled catalog plugin takes the prefix, and no bundled tool its names" do
    index = @plugins_dir |> Path.join("index.json") |> File.read!() |> Jason.decode!()
    catalog = @plugins_dir |> Path.join("catalog.json") |> File.read!() |> Jason.decode!()
    names = Enum.map(index["plugins"], & &1["name"]) ++ catalog["plugins"]

    assert names != []
    refute Enum.any?(names, &(&1 == "trip" or String.starts_with?(&1, "trip_"))), inspect(names)

    for path <- Path.wildcard(Path.join(@plugins_dir, "*/plugin.json")) do
      manifest = path |> File.read!() |> Jason.decode!()
      assert {:ok, plugin} = Registry.decode_manifest(manifest, path), path
      refute Enum.any?(plugin.tools, &(&1["name"] in @tools)), path
    end
  end

  test "no bundled skill is named for a trip tool" do
    skills =
      @skills_dir
      |> Path.join("*/SKILL.md")
      |> Path.wildcard()
      |> Enum.map(fn path -> path |> Path.dirname() |> Path.basename() end)

    assert skills != []
    refute Enum.any?(skills, &(String.replace(&1, "-", "_") in @tools))
  end

  test "a plugin named trip, or starting with trip_, is refused with its sentence; another is not" do
    for name <- ["trip", "trip_planner", "trip_read"] do
      assert {:error, {:reserved_name, ^name}} =
               Registry.decode_manifest(manifest(name), "/tmp/#{name}/plugin.json")

      assert Registry.reserved_name_sentence(name) == @sentence
    end

    for name <- ["trips", "my_trip", "tripadvisor"] do
      assert {:ok, _plugin} = Registry.decode_manifest(manifest(name), "/tmp/#{name}/plugin.json")
    end

    assert Registry.reserved_name_sentence("checklist_pro") == @list_sentence
  end
end
