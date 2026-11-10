defmodule FermixCore.Home.ReadableTest do
  # M97 §3.4: the one rule for whether this engine reads a home another
  # engine wrote, by engine version until D16 is decided.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Readable

  test "a home this engine or an older one wrote is readable" do
    for theirs <- ["4.12.3", "4.12.0", "4.11.9", "3.0.0", "4.12.3-rc.1"] do
      assert Readable.readable?(%{engine_version: theirs}, "4.12.3") == :ok, theirs
    end
  end

  test "a home a newer engine wrote is refused by name" do
    for theirs <- ["4.12.4", "4.13.0", "5.0.0"] do
      assert Readable.readable?(%{engine_version: theirs}, "4.12.3") ==
               {:error, {:newer_engine, theirs, "4.12.3"}}
    end
  end

  test "a version that does not parse, or none, is refused the same way" do
    for theirs <- ["latest", "4.12", nil] do
      assert Readable.readable?(%{engine_version: theirs}, "4.12.3") ==
               {:error, {:newer_engine, theirs, "4.12.3"}}
    end
  end

  test "a manifest with more fields reads by its engine version alone" do
    manifest = %{format: 1, engine_version: "0.9.0", primary_epoch: 3, files: []}
    assert Readable.readable?(manifest, "0.10.0") == :ok
  end
end
