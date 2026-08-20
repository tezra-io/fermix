defmodule FermixCore.Meetings.SidecarInstaller do
  @moduledoc """
  Installs and locates the `fermix-meetbot` sidecar binary, and owns the
  on-disk layout of everything meetbot keeps under
  `FERMIX_HOME/plugins/meetbot/`:

      bin/<tag>/fermix-meetbot   the downloaded, sha256-verified executable
      profile/                   the Chromium profile holding the bot's signed-in state
      signed_in                  a marker that the interactive sign-in succeeded

  **fermix pins the checksums.** Unlike the compux sidecar — whose Elixir
  library half carries its own `checksum-compux.exs` — meetbot is a Node
  artifact with no library to own the pin, so the release choreography ends in
  a PR against `@releases` here (tag → notarized artifacts → checksum PR →
  pin). `v0.2.0` is pinned for `macos-aarch64`; a target with no pin refuses
  loud rather than downloading something unpinned.

  Resolution prefers a `dev_local` build (the sidecar-author loop) so a locally
  built binary can be driven without a release. `binary_path/0` and
  `installed?/0` never download — they run on the readiness and spawn hot
  paths. `install/1` is called only from the setup card, never from a Session
  or from boot.
  """

  import Bitwise, only: [&&&: 2]

  alias FermixCore.Net.StreamDownload
  alias FermixCore.Setup.ConfigStore

  @command "fermix-meetbot"
  @plugin_name "meetbot_sidecar"
  @repo "tezra-io/fermix-meetbot"

  # tag => %{target => sha256}. Pinned to the released tag per target (v0.2.0
  # ships macos-aarch64; other targets land as CI builds them). A pin is never
  # hand-written — it lands with the release choreography. An unpinned target
  # refuses via `@no_pinned_release_message`.
  @releases %{
    "v0.2.0" => %{
      "macos-aarch64" => "f51f9e6ee147435d8960a54cca08d8f3d87025e56c3bb877526d4e86cb16e561"
    }
  }
  @pinned_tag "v0.2.0"

  # A sibling of `bin/` and `profile/` recording that an interactive sign-in
  # succeeded. It lives OUTSIDE the profile because the daemon never reads
  # inside the profile — it only ever asks "did a sign-in finish", not "what is
  # in the browser store".
  @signed_in_marker "signed_in"

  @no_pinned_release_message "No meetbot sidecar release is pinned in this fermix build yet. " <>
                               "For development, set [fermix_core.plugins] dev_local to a " <>
                               "fermix-meetbot checkout with a built binary at " <>
                               "meetbot_sidecar/bin/<target>/fermix-meetbot."

  @doc "The stable identifier the setup card keys off."
  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc "The release tag this fermix build pins, or `nil` when none is pinned yet."
  @spec pinned_tag() :: String.t() | nil
  def pinned_tag, do: @pinned_tag

  @doc "Operator-facing copy for an install refusal, rendered verbatim by the setup card."
  @spec error_message(:no_pinned_release) :: String.t()
  def error_message(:no_pinned_release), do: @no_pinned_release_message

  @doc """
  Downloads the pinned sidecar for this host, verifies its sha256, and installs
  it atomically.

  `opts` is a dependency-injection seam for tests only — `releases:`,
  `pinned_tag:`, and `req_options:` (passed through to `StreamDownload`). The
  shipped call is `install/0`, which uses the baked pins.
  """
  @spec install(keyword()) ::
          {:ok, Path.t()}
          | {:error, :no_pinned_release | {:unsupported_target, String.t()} | term()}
  def install(opts \\ []) when is_list(opts) do
    releases = Keyword.get(opts, :releases, @releases)

    case Keyword.get(opts, :pinned_tag, pinned_tag()) do
      nil -> {:error, :no_pinned_release}
      tag -> install_pinned(tag, releases, opts)
    end
  end

  @doc """
  Resolves the sidecar path **without downloading** — a `dev_local` build
  first, else the cached install for the pinned tag.
  """
  @spec binary_path() :: {:ok, Path.t()} | {:error, :not_installed}
  def binary_path do
    case dev_local_build() do
      path when is_binary(path) -> {:ok, path}
      nil -> cached_path(pinned_tag())
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

  @doc "The release-artifact target string for this host."
  @spec target() :: {:ok, String.t()} | {:error, {:unsupported_target, String.t()}}
  def target do
    with {:ok, os} <- host_os(),
         {:ok, arch} <- host_arch() do
      {:ok, os <> "-" <> arch}
    end
  end

  @doc """
  The Chromium profile directory holding the bot account's signed-in state.

  The daemon never reads inside it — it only passes the path to the sidecar,
  which is the sole owner of the browser. Credentials never cross the wire.
  """
  @spec profile_dir() :: Path.t()
  def profile_dir, do: Path.join(meetbot_root(), "profile")

  @doc """
  Records that the bot's Google account was signed in. Called by
  `FermixCore.Meetings.SignIn` after the interactive flow reports success.
  """
  @spec mark_signed_in() :: :ok
  def mark_signed_in do
    marker = signed_in_marker_path()
    File.mkdir_p!(Path.dirname(marker))
    File.write!(marker, DateTime.to_iso8601(DateTime.utc_now()))
  end

  @doc """
  True when a sign-in has completed and the profile it wrote still exists.

  Both halves matter: the marker without a profile (someone deleted the browser
  store) is not signed in, and a profile without the marker is a bare install
  that never signed in. Never reads inside the profile.
  """
  @spec signed_in?() :: boolean()
  def signed_in? do
    File.regular?(signed_in_marker_path()) and profile_present?()
  end

  defp profile_present? do
    case File.ls(profile_dir()) do
      {:ok, [_ | _]} -> true
      _empty_or_error -> false
    end
  end

  defp signed_in_marker_path, do: Path.join(meetbot_root(), @signed_in_marker)

  defp install_pinned(tag, releases, opts) do
    with {:ok, target} <- target(),
         {:ok, sha256} <- expected_sha256(releases, tag, target) do
      download(tag, target, sha256, Keyword.get(opts, :req_options, []))
    end
  end

  defp expected_sha256(releases, tag, target) do
    case releases |> Map.get(tag, %{}) |> Map.get(target) do
      sha256 when is_binary(sha256) -> {:ok, sha256}
      nil -> {:error, {:no_pinned_artifact, tag, target}}
    end
  end

  defp download(tag, target, sha256, req_options) do
    dest = install_path(tag)
    partial = dest <> ".partial"
    File.mkdir_p!(Path.dirname(dest))

    with :ok <- StreamDownload.download(release_url(tag, target), partial, req_options),
         :ok <- verify(partial, sha256),
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

  defp release_url(tag, target),
    do: "https://github.com/#{@repo}/releases/download/#{tag}/#{@command}-#{target}"

  defp install_path(tag), do: Path.join([meetbot_root(), "bin", tag, @command])

  defp cached_path(tag) do
    path = install_path(tag)
    if File.regular?(path), do: {:ok, path}, else: {:error, :not_installed}
  end

  # `<[fermix_core.plugins] dev_local>/meetbot_sidecar/bin/<target>/fermix-meetbot`.
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

  defp meetbot_root, do: Path.join(ConfigStore.workspace_paths().plugins, "meetbot")

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
