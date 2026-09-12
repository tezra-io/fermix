defmodule Fermix.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.10.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      dialyzer: [plt_add_apps: [:ex_unit, :mix]],
      listeners: [Phoenix.CodeReloader]
    ]
  end

  defp deps do
    [
      {:burrito, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end

  def cli do
    [preferred_envs: [quality: :test]]
  end

  defp aliases do
    [
      setup: ["deps.get", "cmd git config core.hooksPath .githooks"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "test"
      ]
    ]
  end

  defp releases do
    applications = release_applications()

    [
      fermix: [
        applications: applications,
        include_executables_for: [:unix],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            # DISCLAIM_TARGET reaches fermix_nif's Makefile through Burrito's
            # NIF recompile step so the macOS-only disclaim exec shim is
            # cross-compiled per target (an executable — it cannot use the
            # recompile step's CC, which bakes in `-shared`).
            macos_aarch64: [
              os: :darwin,
              cpu: :aarch64,
              nif_env: [{"DISCLAIM_TARGET", "aarch64-macos"}]
            ],
            macos_x86_64: [
              os: :darwin,
              cpu: :x86_64,
              nif_env: [{"DISCLAIM_TARGET", "x86_64-macos"}]
            ],
            linux_aarch64: [os: :linux, cpu: :aarch64],
            linux_x86_64: [os: :linux, cpu: :x86_64]
          ]
        ]
      ],
      fermix_app_engine: [
        applications: applications,
        include_executables_for: [:unix],
        steps: [
          &__MODULE__.validate_app_engine/1,
          &__MODULE__.build_app_engine_assets/1,
          :assemble,
          &__MODULE__.write_app_engine_manifest/1
        ]
      ]
    ]
  end

  @doc false
  @spec validate_app_engine(Mix.Release.t()) :: Mix.Release.t()
  def validate_app_engine(release) do
    case FermixCore.BuildInfo.validate_current_app_engine() do
      :ok ->
        release

      {:error, {:invalid_build_info, field}} ->
        Mix.raise(
          "cannot assemble fermix_app_engine: invalid immutable build field #{field}; " <>
            "recompile in a clean build path with the required FERMIX_BUILD_* inputs"
        )
    end
  end

  # The engine serves the setup UI's stylesheet and bundle from fermix_web's
  # priv/static; a release assembled without `assets.deploy` 404s both and the
  # app's embedded setup pane renders as raw unstyled HTML. Building here (not
  # in each caller's build script) means every `mix release fermix_app_engine`
  # ships working assets, including the first one from a clean worktree.
  @doc false
  @spec build_app_engine_assets(Mix.Release.t()) :: Mix.Release.t()
  def build_app_engine_assets(release) do
    Enum.each(["assets.setup", "assets.deploy"], &run_web_assets_task/1)
    release
  end

  defp run_web_assets_task(task) do
    opts = [
      cd: Path.join(__DIR__, "apps/fermix_web"),
      env: [{"MIX_ENV", "prod"}],
      into: IO.stream()
    ]

    case System.cmd("mix", [task], opts) do
      {_streamed, 0} ->
        :ok

      {_streamed, status} ->
        Mix.raise("cannot assemble fermix_app_engine: `mix #{task}` exited #{status}")
    end
  end

  @doc false
  @spec write_app_engine_manifest(Mix.Release.t()) :: Mix.Release.t()
  def write_app_engine_manifest(release) do
    case FermixCore.Release.AppEngineManifest.write(release.path) do
      {:ok, _manifest} ->
        release

      {:error, reason} ->
        Mix.raise("cannot write fermix_app_engine manifest: #{inspect(reason)}")
    end
  end

  defp release_applications do
    [
      fermix_core: :permanent,
      fermix_channels: :permanent,
      fermix_web: :permanent,
      fermix_nif: :temporary,
      mdns_lite: :load
    ]
  end
end
