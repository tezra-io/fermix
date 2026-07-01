defmodule FermixCore.ComputerUse.SidecarInstaller do
  @moduledoc """
  Installs and locates the computer-use native sidecar binary via the `compux`
  library (`Compux.Binary`).

  compux owns the binary distribution: `install/0` downloads the per-target
  executable from the compux GitHub release and verifies it against the sha256
  baked into the compux dependency (`checksum-compux.exs`), caching it under
  `FERMIX_HOME/plugins/compux/` so it stays inside the user's fermix home. No
  fermix-plugins catalog tarball, no cosign — the sidecar is a plain library
  artifact now.

  **Trust model:** the sidecar injects synthetic input into the live desktop, so
  it is off by default and installed only on explicit enable. It is gated by the
  baked sha256 (integrity — it pins the exact bytes the shipped build was cut
  against) plus compux's own Developer-ID signing + notarization (macOS OS-trust).
  This is integrity, not independent signer provenance — a deliberate trade for
  making the library the single source of the binary.

  Resolution prefers a `dev_local` build (the plugin-author loop) so a locally
  built sidecar can be tested without a release.
  """

  import Bitwise, only: [&&&: 2]

  alias FermixCore.Setup.ConfigStore

  @command "compux"
  @plugin_name "computer_use_sidecar"

  @doc "The stable identifier the setup card keys off (unchanged for UX continuity)."
  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc """
  Download + cache the sidecar via `Compux.Binary` (sha256-verified against the
  baked checksum). No options — verification is baked in and non-overridable.
  """
  @spec install() :: {:ok, Path.t()} | {:error, term()}
  def install, do: Compux.Binary.path(cache_dir: cache_root())

  @doc """
  Resolve the installed sidecar path **without downloading** — a `dev_local` build
  first (the plugin-author loop), else the compux-cached binary. `install/0` is the
  sole path that fetches; resolving is side-effect-free, so it is safe on the spawn
  and readiness hot paths. Returns `{:error, :not_installed}` when neither exists,
  or a typed error on an unsupported host.
  """
  @spec binary_path() :: {:ok, Path.t()} | {:error, term()}
  def binary_path do
    case dev_local_build() do
      path when is_binary(path) -> {:ok, path}
      nil -> cached_path()
    end
  end

  @doc """
  True when the sidecar is present + executable, without downloading — this runs on
  the boot/readiness hot path, so a status read must never trigger a network fetch.
  """
  @spec installed?() :: boolean()
  def installed? do
    case binary_path() do
      {:ok, path} -> File.regular?(path) and executable?(path)
      {:error, _reason} -> false
    end
  end

  # The compux-cached binary, or a typed error — never a download.
  defp cached_path do
    case Compux.Binary.cached_path(cache_dir: cache_root()) do
      {:ok, path} -> {:ok, path}
      {:error, :not_cached} -> {:error, :not_installed}
      {:error, reason} -> {:error, reason}
    end
  end

  # A `dev_local` checkout of the sidecar, only when the binary actually exists:
  # `<[fermix_core.plugins] dev_local>/computer_use_sidecar/bin/<target>/compux`.
  defp dev_local_build do
    with root when is_binary(root) and root != "" <- dev_local_root(),
         {:ok, target} <- Compux.Binary.target() do
      candidate = Path.join([root, @plugin_name, "bin", target, @command])
      if File.regular?(candidate), do: candidate, else: nil
    else
      _ -> nil
    end
  end

  defp dev_local_root do
    :fermix_core |> Application.get_env(:plugins, []) |> Keyword.get(:dev_local)
  end

  # Cache the compux binary under FERMIX_HOME/plugins so it stays inside fermix home
  # (not the OS user-cache default). `workspace_paths/0` is a stable read.
  defp cache_root, do: Path.join(ConfigStore.workspace_paths().plugins, "compux")

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> (mode &&& 0o111) != 0
      {:error, _reason} -> false
    end
  end
end
