defmodule FermixCore.Plugins.RetiredTest do
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.Retired

  # Both files are tracked in this repo, so an unreadable one is a real failure
  # and not an environment the test should tiptoe around.
  @catalog Path.expand("../../../priv/plugins/index.json", __DIR__)
  @sync_script Path.expand("../../../../../scripts/release/sync_plugin_catalog.py", __DIR__)

  test "every retired name is a plain plugin name" do
    refute Enum.empty?(Retired.names())
    assert Enum.all?(Retired.names(), &is_binary/1)
    assert Retired.names() == Enum.uniq(Retired.names())
  end

  test "retired?/1 answers for a retired name and for a live one" do
    assert Retired.names() |> hd() |> Retired.retired?()
    refute Retired.retired?("github")
  end

  # The two lists answer different questions — the script decides what a NEW
  # install is offered, the module decides what an OLD one keeps running — and a
  # name in one but not the other puts an install in exactly the state the
  # module exists to end: offered by nobody, still started by its own config.
  test "the runtime list and the release script's RETIRED_PLUGINS are the same set" do
    source = File.read!(@sync_script)

    [_, inner] =
      Regex.run(~r/RETIRED_PLUGINS\s*=\s*frozenset\(\{([^}]*)\}\)/, source) ||
        flunk("RETIRED_PLUGINS is no longer a frozenset literal in #{@sync_script}")

    from_script =
      ~r/"([^"]+)"|'([^']+)'/
      |> Regex.scan(inner)
      |> Enum.map(fn match -> match |> Enum.drop(1) |> Enum.reject(&(&1 == "")) |> hd() end)
      |> MapSet.new()

    assert from_script == MapSet.new(Retired.names())
  end

  # Belt and braces from the engine's side: the catalog the binary ships must
  # not offer a plugin this build refuses to run.
  test "the baked catalog offers no retired plugin" do
    offered =
      @catalog
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("plugins")
      |> Enum.map(&Map.fetch!(&1, "name"))
      |> MapSet.new()

    assert MapSet.disjoint?(offered, MapSet.new(Retired.names()))
  end
end
