defmodule Fermix.CLI.LauncherPath do
  @moduledoc """
  The absolute path of the `fermix` launcher another program should invoke.

  One resolver, because there is one answer and several places that need it: a
  launchd plist, a systemd unit, and the native-messaging host manifest a
  browser starts the bridge pump from. Getting it wrong is silent — the file is
  written, and the failure appears the next time something else launches it.

  Inside the Burrito wrapper `System.find_executable/1` answers with the
  *extracted* release launcher under the Burrito cache, which understands only
  the standard mix-release verbs (`start`, `daemon`, `eval`) and rejects
  `fermix run` or `fermix browser-bridge`. The wrapper binary is the one to
  name, and Burrito exposes it as `__BURRITO_BIN_PATH`.
  """

  alias Burrito.Util.Args, as: BurritoArgs

  @doc """
  Resolve the launcher, or raise when there is none to name.

  `:fermix_path` overrides it — the seam every caller and every test uses.
  """
  @spec resolve(keyword()) :: String.t()
  def resolve(opts \\ []) when is_list(opts) do
    resolved =
      Keyword.get(opts, :fermix_path) || burrito_bin_path() ||
        System.find_executable("fermix") ||
        raise(ArgumentError, "fermix binary not on PATH; pass :fermix_path explicitly")

    stable_path(resolved)
  end

  # A Homebrew install resolves to a versioned Cellar path
  # (e.g. /opt/homebrew/Cellar/fermix/0.1.0/bin/fermix). Pin to the stable
  # `<prefix>/bin/<name>` symlink so `brew upgrade` does not strand whoever
  # wrote the path down; non-Cellar paths pass through unchanged.
  defp stable_path(path) do
    case Regex.run(~r{^(.*)/Cellar/[^/]+/[^/]+/bin/([^/]+)$}, path) do
      [_full, prefix, name] ->
        symlink = Path.join([prefix, "bin", name])
        if File.exists?(symlink), do: symlink, else: path

      _no_match ->
        path
    end
  end

  defp burrito_bin_path do
    case BurritoArgs.get_bin_path() do
      :not_in_burrito -> nil
      path when is_binary(path) -> path
    end
  end
end
