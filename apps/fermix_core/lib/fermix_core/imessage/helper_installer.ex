defmodule FermixCore.IMessage.HelperInstaller do
  @moduledoc """
  Installs and locates the **Fermix Messages** helper (M54 §1, §5.4), the
  signed app bundle that holds Full Disk Access and Automation for the iMessage
  channel:

      FERMIX_HOME/plugins/imessage_helper/<version>/macos-universal/Fermix Messages.app

  **fermix pins the checksums**, as it does for meetbot and fermix-stt: the
  helper is a Swift artifact with no library half to own the pin, so the
  release choreography ends in a PR against `@releases` here. A pin whose
  sha256 is still `"TBD"` refuses loud (`{:error, :pin_not_set}`) rather than
  downloading something unpinned.

  An install is a chain where every link must hold before the bundle is
  placed: the sha256 of the downloaded archive, `ditto` extraction into a
  staging directory, `codesign --verify --deep --strict`, and the signing Team
  ID. Only then is the bundle renamed into its versioned path, atomically, and
  registered with LaunchServices (`lsregister -f`) so TCC can resolve its
  bundle id. A failure at any link places nothing and leaves no partial file
  or staging directory behind.

  Resolution prefers a `dev_local` build (the helper-author loop):
  `<[fermix_core.plugins] dev_local>/imessage_helper/bin/macos-universal/Fermix Messages.app`.
  `binary_path/0` and `installed?/0` never download; they run on the readiness
  and spawn hot paths.
  """

  import Bitwise, only: [&&&: 2]

  alias FermixCore.IMessage
  alias FermixCore.Net.StreamDownload
  alias FermixCore.Setup.ConfigStore

  @plugin_name "imessage_helper"
  @target "macos-universal"
  @bundle "Fermix Messages.app"
  @executable "fermix-messages"
  @team_id "54A57TH9BJ"
  @unset_pin "TBD"

  @ditto "/usr/bin/ditto"
  @codesign "/usr/bin/codesign"
  @lsregister "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

  # version => %{target => %{url:, sha256:}}. The pin lands with the helper's
  # release choreography from the release's own `.sha256` sidecar; it is never
  # hand-written. A release whose sha256 is the unset marker is refused by
  # `install/1`. 0.1.1 is the helper's first notarized release
  # (tezra-io/fermix-messages at 6f9f137).
  @releases %{
    "0.1.1" => %{
      "macos-universal" => %{
        url:
          "https://github.com/tezra-io/fermix-messages/releases/download/v0.1.1/fermix-messages-0.1.1-macos-universal.zip",
        sha256: "fe667e30aa35e6bfba7da52a337ff74b45be8f1ca095f0fe6b22aba79dd8a308"
      }
    }
  }
  @pinned_version "0.1.1"

  @type release :: %{url: String.t(), sha256: String.t()}
  @type runner :: (String.t(), [String.t()] -> {String.t(), non_neg_integer()})
  @type install_error ::
          :pin_not_set
          | {:unsupported_platform, :imessage}
          | {:no_pinned_artifact, String.t(), String.t()}
          | {:checksum_mismatch, String.t(), String.t()}
          | {:helper_unverified, String.t() | :team_id_mismatch | :bundle_missing}
          | {:extract_failed, non_neg_integer(), String.t()}
          | {:lsregister_failed, non_neg_integer(), String.t()}
          | term()

  @doc "The stable identifier the setup surfaces and the install target key off."
  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc "The helper version this build pins."
  @spec pinned_version() :: String.t()
  def pinned_version, do: @pinned_version

  @doc "The pin table, version => target => url and sha256 (a release fact, never edited by hand)."
  @spec releases() :: %{String.t() => %{String.t() => %{url: String.t(), sha256: String.t()}}}
  def releases, do: @releases

  @doc "The Developer ID team every helper bundle must be signed by."
  @spec team_id() :: String.t()
  def team_id, do: @team_id

  @doc """
  Downloads, verifies and places the pinned helper, then registers it.

  Idempotent: a placed bundle that still verifies is the install, and only its
  registration runs again. `opts` are test seams only: `releases:`,
  `pinned_version:`, `req_options:` (passed to `StreamDownload`), `runner:` (the
  `ditto`/`codesign`/`lsregister` command runner) and `macos?:`.
  """
  @spec install(keyword()) :: {:ok, Path.t()} | {:error, install_error()}
  def install(opts \\ []) when is_list(opts) do
    releases = Keyword.get(opts, :releases, @releases)
    version = Keyword.get(opts, :pinned_version, @pinned_version)

    with :ok <- IMessage.check_platform([enabled: true], opts),
         {:ok, release} <- pinned_release(releases, version) do
      install_pinned(version, release, opts)
    end
  end

  @doc """
  The helper executable, **without downloading**: a `dev_local` build first,
  else the placed bundle for the pinned version.
  """
  @spec binary_path() :: {:ok, Path.t()} | {:error, :not_installed}
  def binary_path do
    case bundle_path() do
      {:ok, app} -> {:ok, executable_in(app)}
      {:error, :not_installed} -> {:error, :not_installed}
    end
  end

  @doc "The helper's app bundle, resolved as `binary_path/0` resolves it."
  @spec bundle_path() :: {:ok, Path.t()} | {:error, :not_installed}
  def bundle_path do
    candidates = [dev_local_bundle(), install_path(@pinned_version)]

    case Enum.find(candidates, &bundle_present?/1) do
      nil -> {:error, :not_installed}
      app -> {:ok, app}
    end
  end

  @doc "True when the helper executable is present and executable. No network."
  @spec installed?() :: boolean()
  def installed? do
    case binary_path() do
      {:ok, path} -> executable?(path)
      {:error, :not_installed} -> false
    end
  end

  @doc """
  `codesign --verify --deep --strict` on a bundle, then its signing Team ID.

  The same check the installer runs before placing a bundle, published so
  Doctor reports exactly what the install would have refused.
  """
  @spec verify_bundle(Path.t(), keyword()) ::
          :ok | {:error, {:helper_unverified, String.t() | :team_id_mismatch}}
  def verify_bundle(app, opts \\ []) when is_binary(app) and is_list(opts) do
    runner = Keyword.get(opts, :runner, &run/2)

    with :ok <- strict_verify(runner, app), do: team_matches(runner, app)
  end

  defp pinned_release(releases, version) do
    case releases |> Map.get(version, %{}) |> Map.get(@target) do
      %{sha256: @unset_pin} ->
        {:error, :pin_not_set}

      %{url: url, sha256: sha256} = release when is_binary(url) and is_binary(sha256) ->
        {:ok, release}

      _absent ->
        {:error, {:no_pinned_artifact, version, @target}}
    end
  end

  defp install_pinned(version, release, opts) do
    runner = Keyword.get(opts, :runner, &run/2)
    dest = install_path(version)

    with :ok <- placed_or_fetched(version, release, dest, runner, opts),
         :ok <- register(runner, dest) do
      {:ok, executable_in(dest)}
    end
  end

  # One path: a placed bundle that verifies is the install; one that does not is
  # discarded before the download rather than left where `installed?/0` would
  # answer for it.
  defp placed_or_fetched(version, release, dest, runner, opts) do
    if bundle_present?(dest) and verify_bundle(dest, runner: runner) == :ok do
      :ok
    else
      :ok = discard(dest)
      fetch_and_place(version, release, dest, runner, Keyword.get(opts, :req_options, []))
    end
  end

  defp fetch_and_place(version, release, dest, runner, req_options) do
    unique = System.unique_integer([:positive])
    version_dir = Path.join(helper_root(), version)
    partial = Path.join(version_dir, ".partial-#{unique}.zip")
    staging = Path.join(version_dir, ".staging-#{unique}")
    File.mkdir_p!(version_dir)

    try do
      with :ok <- StreamDownload.download(release.url, partial, req_options),
           :ok <- verify_checksum(partial, release.sha256),
           {:ok, staged} <- extract(runner, partial, staging),
           :ok <- verify_bundle(staged, runner: runner) do
        place(staged, dest)
      end
    after
      :ok = discard(partial)
      :ok = discard(staging)
    end
  end

  defp verify_checksum(path, sha256) do
    case StreamDownload.check_sha256(path, sha256) do
      :ok ->
        :ok

      {:error, {:sha256_mismatch, expected: expected, actual: actual}} ->
        {:error, {:checksum_mismatch, expected, actual}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract(runner, archive, staging) do
    File.mkdir_p!(staging)

    case runner.(@ditto, ["-x", "-k", archive, staging]) do
      {_output, 0} -> staged_bundle(Path.join(staging, @bundle))
      {output, code} -> {:error, {:extract_failed, code, String.trim(output)}}
    end
  end

  defp staged_bundle(app) do
    if bundle_present?(app), do: {:ok, app}, else: {:error, {:helper_unverified, :bundle_missing}}
  end

  defp strict_verify(runner, app) do
    case runner.(@codesign, ["--verify", "--deep", "--strict", app]) do
      {_output, 0} -> :ok
      {output, _code} -> {:error, {:helper_unverified, String.trim(output)}}
    end
  end

  # `codesign -dv` writes its description to stderr, which the runner folds into
  # its output. The Team ID line is the whole test: a bundle signed by anyone
  # else is not this helper, however valid its signature.
  defp team_matches(runner, app) do
    case runner.(@codesign, ["-dv", app]) do
      {output, 0} -> team_line(output)
      {output, _code} -> {:error, {:helper_unverified, String.trim(output)}}
    end
  end

  defp team_line(output) do
    if Regex.match?(~r/^TeamIdentifier=#{@team_id}$/m, output),
      do: :ok,
      else: {:error, {:helper_unverified, :team_id_mismatch}}
  end

  defp place(staged, dest) do
    File.mkdir_p!(Path.dirname(dest))
    File.rename(staged, dest)
  end

  defp register(runner, app) do
    case runner.(@lsregister, ["-f", app]) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:lsregister_failed, code, String.trim(output)}}
    end
  end

  # A partial download, a staging tree or a bundle that failed its checks is
  # worthless and must never be mistaken for an install; a missing path is the
  # same outcome, so only the removal matters.
  defp discard(path) do
    _ = File.rm_rf(path)
    :ok
  end

  defp run(command, args), do: System.cmd(command, args, stderr_to_stdout: true)

  defp install_path(version), do: Path.join([helper_root(), version, @target, @bundle])

  defp dev_local_bundle do
    case dev_local_root() do
      root when is_binary(root) and root != "" ->
        Path.join([root, @plugin_name, "bin", @target, @bundle])

      _unset ->
        nil
    end
  end

  defp dev_local_root do
    :fermix_core |> Application.get_env(:plugins, []) |> Keyword.get(:dev_local)
  end

  defp bundle_present?(nil), do: false
  defp bundle_present?(app), do: File.regular?(executable_in(app))

  defp executable_in(app), do: Path.join([app, "Contents", "MacOS", @executable])

  defp helper_root, do: Path.join(ConfigStore.workspace_paths().plugins, @plugin_name)

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> (mode &&& 0o111) != 0
      _other -> false
    end
  end
end
