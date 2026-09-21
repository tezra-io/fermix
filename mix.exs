defmodule Fermix.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.10.5",
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
      ],
      # The Linux distribution package's engine (M38 §1.3, §2.2). Its own
      # release name gives the packaged payload its own extraction namespace
      # (`fermix_linux_package_erts-…`) and its own override variable
      # (`FERMIX_LINUX_PACKAGE_INSTALL_DIR`, which the vendor unit sets), so a
      # standalone install and a packaged one at the same version never touch
      # each other's extracted tree. The two extra steps move the musl loader
      # off `/tmp` and onto the root-owned address the package materialises.
      fermix_linux_package: [
        applications: applications,
        include_executables_for: [:unix],
        version: packaged_release_version(),
        steps: [&__MODULE__.validate_linux_package/1, :assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_aarch64: [os: :linux, cpu: :aarch64],
            linux_x86_64: [os: :linux, cpu: :x86_64]
          ],
          extra_steps: [
            fetch: [post: [FermixCore.Release.PackagedMuslRuntime]],
            patch: [post: [FermixCore.Release.PackagedInterpreter]]
          ]
        ]
      ]
    ]
  end

  # The version the packaged Linux release is assembled under, which is NOT the
  # version anyone sees. Burrito extracts its payload into a directory named
  # `<release>_erts-<erts>_<app_version>` (deps/burrito/src/wrapper.zig:160-166)
  # and reuses it whenever a metadata file is present, so two builds sharing a
  # product version shared an extraction and the second one installed never
  # unpacked: the owner kept running the first engine across restarts. Appending
  # the build identity here is what makes that directory differ per payload.
  #
  # It is deliberately semver BUILD METADATA (after `+`). Build metadata is
  # ignored when comparing precedence, so `0.10.5+dev.abc` is neither newer nor
  # older than `0.10.5` and no upgrade check can read it as a new version. The
  # product version stays `0.10.5` everywhere a person or a protocol sees it:
  # `fermix --version`, engine.json's product_version and the deb and rpm
  # versions all come from elsewhere, never from this string.
  #
  # Setting it in the release rather than in the environment is the whole point.
  # Burrito prints two lines to STDOUT on every invocation when its
  # `*_INSTALL_DIR` variable is set (logger.zig sends `info` to stdout, with no
  # quiet switch and no way for Elixir to intercept it, since the zig wrapper
  # runs before the BEAM), which put a two-line preamble in front of every
  # `--json` command. Naming the default directory costs nothing on stdout.
  defp packaged_release_version do
    case System.get_env("FERMIX_BUILD_ID") do
      nil -> "0.10.5"
      "" -> "0.10.5"
      build_id -> "0.10.5+" <> semver_metadata(build_id)
    end
  end

  # Semver build metadata is dot-separated alphanumerics and hyphens, so every
  # other character folds to a hyphen. The build id's own alphabet is already
  # nearly this (`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`); in practice only `:`
  # is rewritten.
  defp semver_metadata(build_id) do
    String.replace(build_id, ~r/[^0-9A-Za-z.-]/, "-")
  end

  @doc false
  @spec validate_linux_package(Mix.Release.t()) :: Mix.Release.t()
  def validate_linux_package(release) do
    case FermixCore.BuildInfo.validate_linux_package(FermixCore.BuildInfo.identity()) do
      :ok ->
        release

      {:error, {:invalid_build_info, field}} ->
        Mix.raise(
          "cannot assemble fermix_linux_package: invalid immutable build field #{field}; " <>
            "recompile with FERMIX_BUILD_DISTRIBUTION=linux_package and the required " <>
            "FERMIX_BUILD_* inputs"
        )
    end
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
