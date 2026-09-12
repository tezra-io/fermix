defmodule FermixCore.Setup.EngineOwnerTest do
  @moduledoc """
  The advisory ownership marker from M34 native setup §15.2.

  The bundle-exists half is the case that matters: without it, deleting the app
  leaves a stale marker that refuses `fermix start` forever, and the standalone
  boot that would rewrite it can never happen, because that boot is the refused
  verb.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Setup.EngineOwner
  alias FermixTestSupport.SafeRm

  setup do
    dir = SafeRm.make_tmp_dir!("engine_owner")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    %{path: Path.join(dir, "engine-owner.json")}
  end

  test "an absent marker reads nil and claims nothing", %{path: path} do
    assert EngineOwner.read(path: path) == nil
    refute EngineOwner.app_managed_marker?(path: path)
  end

  test "an unreadable marker claims nothing", %{path: path} do
    File.write!(path, "{not json")

    assert EngineOwner.read(path: path) == nil
    refute EngineOwner.app_managed_marker?(path: path)
  end

  test "record writes the running engine's identity", %{path: path} do
    assert EngineOwner.record(path: path, app_bundle_path: "/Applications/Fermix.app") == :ok

    marker = EngineOwner.read(path: path)
    assert marker.distribution_identity == FermixCore.BuildInfo.distribution_identity()
    assert marker.app_bundle_path == "/Applications/Fermix.app"
    assert marker.written_at =~ "T"
  end

  test "an app marker whose bundle still exists claims the home", %{path: path} do
    write(path, "macos_app", "/Applications/Fermix.app")

    assert EngineOwner.app_managed_marker?(path: path, bundle_exists?: fn _dir -> true end)
  end

  # The trap this removes: with the app deleted the marker is stale and nothing
  # would ever clear it, because the boot that rewrites it is the refused verb.
  test "an app marker whose bundle is gone claims nothing", %{path: path} do
    write(path, "macos_app", "/Applications/Fermix.app")

    refute EngineOwner.app_managed_marker?(path: path, bundle_exists?: fn _dir -> false end)
  end

  test "a standalone marker never claims the home", %{path: path} do
    write(path, "standalone", "/Applications/Fermix.app")

    refute EngineOwner.app_managed_marker?(path: path, bundle_exists?: fn _dir -> true end)
  end

  test "an app marker with no recorded bundle claims nothing", %{path: path} do
    write(path, "macos_app", nil)

    refute EngineOwner.app_managed_marker?(path: path, bundle_exists?: fn _dir -> true end)
  end

  defp write(path, identity, bundle) do
    File.write!(
      path,
      Jason.encode!(%{
        "distribution_identity" => identity,
        "product_version" => "0.0.0",
        "build_id" => "b",
        "app_bundle_path" => bundle,
        "written_at" => "2026-09-04T00:00:00Z"
      })
    )
  end
end
