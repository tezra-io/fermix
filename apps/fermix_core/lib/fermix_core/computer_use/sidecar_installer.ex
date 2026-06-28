defmodule FermixCore.ComputerUse.SidecarInstaller do
  @moduledoc """
  Installs and locates the computer-use native sidecar binary through Fermix's
  existing signed plugin-distribution pipeline (docs/design/COMPUTER_USE.md §1f).

  The sidecar ships as a catalog/index entry (`computer_use_sidecar`) carrying one
  signed per-target binary artifact and NO agent tools. `install/0` runs it through
  `Dist.Installer.run_install` — resolve → sha256 → cosign → extract → atomic
  activate — so a binary that injects synthetic input into the live desktop is
  installed only after mandatory signature verification.

  `install/0` deliberately takes **no options**: it must never let a caller thread
  a `:verifier`/`:fetcher` seam into a production install (a per-call verifier
  override would be a desktop-takeover vector). Tests that need a fake artifact
  call `Dist.Installer.run_install/2` directly with their own seams — never through
  this wrapper.

  The pipeline extracts into the plugin store, not `FERMIX_HOME/bin`, so this module
  is also the single source of truth for the binary's path: it resolves live through
  the store's `current` symlink (an upgrade's atomic version-swap is picked up with
  no copy), and never fabricates a sentinel path.
  """

  import Bitwise, only: [&&&: 2]

  alias Fermix.CLI.Upgrade.Manifest
  alias FermixCore.Plugins.Dist.Installer
  alias FermixCore.Plugins.Dist.Store
  alias FermixCore.Setup.ConfigStore

  @plugin_name "computer_use_sidecar"
  @command "fermix-computer-use"

  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc """
  Install the signed sidecar through the catalog pipeline. No options — cosign +
  sha256 verification are mandatory and non-overridable on this path.
  """
  @spec install() :: {:ok, term()} | {:error, term()}
  def install, do: Installer.run_install(@plugin_name)

  @doc """
  Absolute path the runtime/`PortDriver` should spawn. Resolution order:

    1. A `dev_local` build, if present — `<[fermix_core.plugins] dev_local>/computer_use_sidecar/bin/<target>/fermix-computer-use`.
       This is the plugin-author loop: `cargo build` the sidecar (native/computer-use-sidecar/)
       into a dev_local checkout and test without a signed release.
    2. Otherwise the installed catalog binary, resolved live through the store's
       `current` symlink (so an upgrade's atomic version-swap is picked up).

  The path is well-defined whenever the host target is supported (existence is
  checked separately by `installed?/0` and by `PortDriver.start/1`, so neither a
  missing dev build nor a missing install fabricates a runnable path); `{:error, _}`
  only when the host arch/OS is unsupported.
  """
  @spec binary_path() :: {:ok, Path.t()} | {:error, term()}
  def binary_path do
    with {:ok, target} <- host_target() do
      rel = Path.join(["bin", target, @command])
      {:ok, dev_local_build(rel) || Path.join(Store.current_link(root(), @plugin_name), rel)}
    end
  end

  @doc "True when the installed sidecar binary exists and is executable for this host."
  @spec installed?() :: boolean()
  def installed? do
    case binary_path() do
      {:ok, path} -> File.regular?(path) and executable?(path)
      {:error, _reason} -> false
    end
  end

  # Reuse the exact "<os>-<arch>" target string the installer resolves artifacts
  # by (installer.ex host_target/0), so the install target and the lookup target
  # are one convention.
  defp host_target do
    case Manifest.target_for_host() do
      {:ok, {os, arch}} -> {:ok, "#{os}-#{arch}"}
      {:error, reason} -> {:error, {:host_unsupported, reason}}
    end
  end

  # A dev_local checkout of the sidecar, only when the binary actually exists there
  # (so the installed path stays the production default). Reuses the existing
  # `[fermix_core.plugins] dev_local` key — the same dev folder plugin authors use.
  defp dev_local_build(rel) do
    case dev_local_root() do
      root when is_binary(root) and root != "" ->
        candidate = Path.join([root, @plugin_name, rel])
        if File.regular?(candidate), do: candidate, else: nil

      _ ->
        nil
    end
  end

  defp dev_local_root do
    :fermix_core |> Application.get_env(:plugins, []) |> Keyword.get(:dev_local)
  end

  # Same root `Dist.Installer.run_install/1` defaults to (resolve_root/1), so the
  # install location and the lookup location always agree. `workspace_paths/0` is
  # a stable read; we never write config_store.
  defp root, do: ConfigStore.workspace_paths().plugins

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> (mode &&& 0o111) != 0
      {:error, _reason} -> false
    end
  end
end
