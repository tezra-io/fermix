defmodule FermixCore.ReleaseProfileTest do
  use ExUnit.Case, async: true

  test "defines a distinct plain app-engine release" do
    releases = Fermix.MixProject.project() |> Keyword.fetch!(:releases)
    standalone = Keyword.fetch!(releases, :fermix)
    app_engine = Keyword.fetch!(releases, :fermix_app_engine)

    assert app_engine[:applications] == standalone[:applications]
    assert app_engine[:include_executables_for] == [:unix]
    refute Keyword.has_key?(app_engine, :burrito)

    # Validate, build the web assets the setup door serves from inside the
    # bundle, assemble, place the pinned fermix-iroh helper (so the inventory
    # lists it and checks its architecture), then write the manifest the app
    # verifies against.
    assert [validator, assets_builder, :assemble, helper_placer, manifest_writer] =
             app_engine[:steps]

    assert Function.info(validator, :module) == {:module, Fermix.MixProject}
    assert Function.info(validator, :name) == {:name, :validate_app_engine}
    assert Function.info(assets_builder, :module) == {:module, Fermix.MixProject}
    assert Function.info(assets_builder, :name) == {:name, :build_app_engine_assets}
    assert Function.info(helper_placer, :module) == {:module, Fermix.MixProject}
    assert Function.info(helper_placer, :name) == {:name, :place_app_engine_iroh_helper}
    assert Function.info(manifest_writer, :module) == {:module, Fermix.MixProject}
    assert Function.info(manifest_writer, :name) == {:name, :write_app_engine_manifest}

    assert Enum.any?(standalone[:steps], fn
             step when is_function(step, 1) -> Function.info(step, :module) == {:module, Burrito}
             _step -> false
           end)
  end

  # Every Burrito target names beam-machine's native runtime before anything is
  # fetched (its newest is older than the build machine's OTP), and puts that
  # runtime's native libraries where the release loads them first thing after
  # the patch phase. M62 stage 5: each then places its pinned fermix-iroh helper
  # in its own work_dir. The Linux package places it before the interpreter
  # rewrite, which then scans a tree that already holds it.
  test "every Burrito release names its native runtime and places its libraries and helper" do
    releases = Fermix.MixProject.project() |> Keyword.fetch!(:releases)

    standalone = releases |> Keyword.fetch!(:fermix) |> Keyword.fetch!(:burrito)

    assert standalone[:extra_steps] == [
             fetch: [pre: [FermixCore.Release.NativeRuntime]],
             patch: [
               post: [FermixCore.Release.NativeLibraries, FermixCore.Release.IrohHelper]
             ]
           ]

    package = releases |> Keyword.fetch!(:fermix_linux_package) |> Keyword.fetch!(:burrito)

    assert package[:extra_steps] == [
             fetch: [
               pre: [FermixCore.Release.NativeRuntime],
               post: [FermixCore.Release.PackagedMuslRuntime]
             ],
             patch: [
               post: [
                 FermixCore.Release.NativeLibraries,
                 FermixCore.Release.IrohHelper,
                 FermixCore.Release.PackagedInterpreter
               ]
             ]
           ]
  end
end
