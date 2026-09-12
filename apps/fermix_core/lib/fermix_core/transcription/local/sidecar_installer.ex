defmodule FermixCore.Transcription.Local.SidecarInstaller do
  @moduledoc """
  Installs and locates the `fermix-stt` sidecar binary under
  `FERMIX_HOME/plugins/stt/bin/<target>/fermix-stt`.

  **fermix pins the checksums.** Unlike the compux sidecar — whose Elixir
  library half carries its own `checksum-compux.exs` — fermix-stt is a plain
  Rust artifact with no library to own the pin, so the release choreography ends
  in a PR against `@releases` here. Until the first `tezra-io/fermix-stt`
  release exists that table is empty and `install/1` refuses loud rather than
  downloading something unpinned.

  Resolution prefers a `dev_local` build (the sidecar-author loop) so a locally
  built binary can be driven without a release. `binary_path/0` and
  `installed?/0` never download — they run on the readiness and spawn hot paths.
  `install/1` is called only from the setup surface, never from a session or
  from boot.
  """

  import Bitwise, only: [&&&: 2]

  alias FermixCore.Net.StreamDownload
  alias FermixCore.Setup.ConfigStore

  @command "fermix-stt"
  @plugin_name "stt_sidecar"

  # target => %{url: String.t(), sha256: String.t()}. Pinned per released
  # target (v0.1.0 ships macos-aarch64; other targets land as CI builds them).
  # A pin is never hand-written — it lands with the release choreography, which
  # downloads the artifact and hashes it. An unpinned target refuses via
  # `@no_release_pinned_message`.
  @releases %{
    "macos-aarch64" => %{
      url:
        "https://github.com/tezra-io/fermix-stt/releases/download/v0.1.0/fermix-stt-macos-aarch64",
      sha256: "55e115c3c4fab23dd9758ec57299b9ace0f6bfd5215eb1755c6f496d1bae3b95"
    }
  }

  @no_release_pinned_message "fermix-stt has no pinned release yet. Build it locally and point " <>
                               "[fermix_core.plugins] dev_local at a checkout containing " <>
                               "stt_sidecar/bin/<target>/fermix-stt."

  @typedoc "A pinned artifact for one host target."
  @type release :: %{url: String.t(), sha256: String.t()}

  @doc "The stable identifier the setup card keys off."
  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc "Operator-facing copy for an install refusal, rendered verbatim by doctor and setup."
  @spec error_message(:no_release_pinned) :: String.t()
  def error_message(:no_release_pinned), do: @no_release_pinned_message

  @doc """
  Whether this build pins a release artifact for the host target — what the
  doctor asks before telling an operator to install anything, so "not installed"
  and "not installable yet" stay different answers.
  """
  @spec release_pinned?() :: boolean()
  def release_pinned? do
    case target() do
      {:ok, target} -> Map.has_key?(@releases, target)
      {:error, _reason} -> false
    end
  end

  @doc "The release-artifact target string for this host."
  @spec target() :: {:ok, String.t()} | {:error, {:unsupported_target, String.t()}}
  def target do
    with {:ok, os} <- host_os(),
         {:ok, arch} <- host_arch() do
      {:ok, os <> "-" <> arch}
    end
  end

  @doc """
  Resolves the sidecar path **without downloading** — a `dev_local` build first,
  else the installed binary for this host.
  """
  @spec binary_path() :: {:ok, Path.t()} | {:error, :not_installed}
  def binary_path do
    case dev_local_build() do
      path when is_binary(path) -> {:ok, path}
      nil -> installed_path()
    end
  end

  @doc "True when the sidecar is present and executable, without downloading."
  @spec installed?() :: boolean()
  def installed? do
    case binary_path() do
      {:ok, path} -> File.regular?(path) and executable?(path)
      {:error, :not_installed} -> false
    end
  end

  @doc """
  Downloads the pinned sidecar for this host, verifies its sha256, and installs
  it executable and atomically.

  `opts` is a dependency-injection seam for tests only — `releases:` and
  `req_options:` (passed through to `StreamDownload`). The shipped call is
  `install/0`, which uses the baked pins.
  """
  @spec install(keyword()) ::
          {:ok, Path.t()}
          | {:error, :no_release_pinned | {:unsupported_target, String.t()} | term()}
  def install(opts \\ []) when is_list(opts) do
    releases = Keyword.get(opts, :releases, @releases)

    with {:ok, target} <- target(),
         {:ok, release} <- pinned_release(releases, target) do
      download(target, release, Keyword.get(opts, :req_options, []))
    end
  end

  defp pinned_release(releases, target) do
    case Map.get(releases, target) do
      %{url: url, sha256: sha256} when is_binary(url) and is_binary(sha256) ->
        {:ok, %{url: url, sha256: sha256}}

      _absent ->
        {:error, :no_release_pinned}
    end
  end

  defp download(target, release, req_options) do
    dest = install_path(target)
    partial = dest <> ".partial"
    File.mkdir_p!(Path.dirname(dest))

    with :ok <- StreamDownload.download(release.url, partial, req_options),
         :ok <- verify(partial, release.sha256),
         :ok <- File.rename(partial, dest),
         :ok <- File.chmod(dest, 0o755) do
      {:ok, dest}
    else
      {:error, reason} ->
        discard(partial)
        {:error, reason}
    end
  end

  defp verify(path, sha256) do
    case StreamDownload.check_sha256(path, sha256) do
      :ok ->
        :ok

      {:error, {:sha256_mismatch, expected: expected, actual: actual}} ->
        {:error, {:checksum_mismatch, expected, actual}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A partial download is worthless and must never be mistaken for an install;
  # a missing file here is the same outcome, so only the removal matters.
  defp discard(path) do
    _ = File.rm(path)
    :ok
  end

  defp install_path(target), do: Path.join([stt_root(), "bin", target, @command])

  defp installed_path do
    with {:ok, target} <- target(),
         path = install_path(target),
         true <- File.regular?(path) do
      {:ok, path}
    else
      _absent -> {:error, :not_installed}
    end
  end

  # `<[fermix_core.plugins] dev_local>/stt_sidecar/bin/<target>/fermix-stt`.
  defp dev_local_build do
    with root when is_binary(root) and root != "" <- dev_local_root(),
         {:ok, target} <- target() do
      candidate = Path.join([root, @plugin_name, "bin", target, @command])
      if File.regular?(candidate), do: candidate, else: nil
    else
      _other -> nil
    end
  end

  defp dev_local_root do
    :fermix_core |> Application.get_env(:plugins, []) |> Keyword.get(:dev_local)
  end

  defp stt_root, do: Path.join(ConfigStore.workspace_paths().plugins, "stt")

  defp host_os do
    case :os.type() do
      {:unix, :darwin} -> {:ok, "macos"}
      {:unix, :linux} -> {:ok, "linux"}
      other -> {:error, {:unsupported_target, inspect(other)}}
    end
  end

  defp host_arch do
    case :erlang.system_info(:system_architecture) |> List.to_string() do
      "aarch64" <> _rest -> {:ok, "aarch64"}
      "arm64" <> _rest -> {:ok, "aarch64"}
      "x86_64" <> _rest -> {:ok, "x86_64"}
      "amd64" <> _rest -> {:ok, "x86_64"}
      other -> {:error, {:unsupported_target, other}}
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> (mode &&& 0o111) != 0
      {:error, _reason} -> false
    end
  end
end
