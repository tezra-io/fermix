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
    # bundle, assemble, then write the manifest the app verifies against.
    assert [validator, assets_builder, :assemble, manifest_writer] = app_engine[:steps]
    assert Function.info(validator, :module) == {:module, Fermix.MixProject}
    assert Function.info(validator, :name) == {:name, :validate_app_engine}
    assert Function.info(assets_builder, :module) == {:module, Fermix.MixProject}
    assert Function.info(assets_builder, :name) == {:name, :build_app_engine_assets}
    assert Function.info(manifest_writer, :module) == {:module, Fermix.MixProject}
    assert Function.info(manifest_writer, :name) == {:name, :write_app_engine_manifest}

    assert Enum.any?(standalone[:steps], fn
             step when is_function(step, 1) -> Function.info(step, :module) == {:module, Burrito}
             _step -> false
           end)
  end
end
