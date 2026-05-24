defmodule Fermix.CLI.Service do
  @moduledoc """
  OS service installation for `fermix run`.

  Generates and installs a launchd `.plist` (macOS) or systemd
  `.service` unit (Linux) that executes `fermix run`. Two scopes
  per OS — user (default; per-user, no sudo) and system (`--system`;
  boot survival, sudo). On Linux user-scope, `loginctl enable-linger`
  is required for reboot survival; the installer runs it and aborts
  loud if it fails (no degraded "works while logged in" half-state).

  Pure dispatch: the launchd backend lives in `Service.Launchd`, the
  systemd backend in `Service.Systemd`, and the unit-file templates
  in `Service.Templates`. This module decides which backend to call
  based on the host OS, holds the install/uninstall/start/stop
  contracts, and computes the install target paths.
  """

  alias Burrito.Util.Args, as: BurritoArgs
  alias Fermix.CLI.Service.Launchd
  alias Fermix.CLI.Service.Systemd
  alias Fermix.CLI.Service.Templates

  @label "io.tezra.fermix"
  @linux_unit "fermix.service"

  @type scope :: :user | :system
  @type os :: :darwin | :linux

  @type unit_spec :: %{
          os: os(),
          scope: scope(),
          unit_path: Path.t(),
          fermix_path: Path.t(),
          fermix_home: Path.t(),
          log_path: Path.t(),
          label: String.t(),
          linux_unit: String.t()
        }

  @spec install(scope(), keyword()) :: :ok | {:error, term()}
  def install(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    with {:ok, spec} <- spec(scope, opts),
         :ok <- File.mkdir_p(Path.dirname(spec.unit_path)),
         :ok <- File.mkdir_p(Path.dirname(spec.log_path)),
         :ok <- write_unit(spec),
         :ok <- backend(spec).install(spec) do
      :ok
    end
  end

  @spec uninstall(scope(), keyword()) :: :ok | {:error, term()}
  def uninstall(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    with {:ok, spec} <- spec(scope, opts),
         :ok <- backend(spec).uninstall(spec),
         :ok <- remove_unit(spec) do
      :ok
    end
  end

  @spec start(scope(), keyword()) :: :ok | {:error, term()}
  def start(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    with {:ok, spec} <- spec(scope, opts), do: backend(spec).start(spec)
  end

  @spec stop(scope(), keyword()) :: :ok | {:error, term()}
  def stop(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    with {:ok, spec} <- spec(scope, opts), do: backend(spec).stop(spec)
  end

  @spec restart(scope(), keyword()) :: :ok | {:error, term()}
  def restart(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    with :ok <- stop(scope, opts), do: start(scope, opts)
  end

  @spec installed?(scope(), keyword()) :: boolean()
  def installed?(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    case spec(scope, opts) do
      {:ok, %{unit_path: path}} -> File.exists?(path)
      {:error, _} -> false
    end
  end

  @doc """
  True only when this process is the OS-supervised release daemon: a Burrito
  standalone release whose launchd/systemd unit is installed. False under
  `mix fermix.dev` and in tests, so callers that self-restart by exiting (and
  rely on the supervisor to relaunch) never strand a non-supervised process.
  """
  @spec supervised?(keyword()) :: boolean()
  def supervised?(opts \\ []) when is_list(opts) do
    Burrito.Util.running_standalone?() and
      (installed?(:user, opts) or installed?(:system, opts))
  end

  @spec spec(scope(), keyword()) :: {:ok, unit_spec()} | {:error, term()}
  def spec(scope, opts \\ []) when scope in [:user, :system] do
    case detect_os(opts) do
      :darwin -> {:ok, build_spec(:darwin, scope, opts)}
      :linux -> {:ok, build_spec(:linux, scope, opts)}
      other -> {:error, {:unsupported_os, other}}
    end
  end

  @doc """
  Render the unit-file body that would be written by `install/2` for
  the given scope. Used by tests and by `fermix doctor` to verify
  installed-vs-current parity.
  """
  @spec render_unit(scope(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def render_unit(scope, opts \\ []) when scope in [:user, :system] do
    with {:ok, spec} <- spec(scope, opts), do: {:ok, render(spec)}
  end

  defp build_spec(os, scope, opts) do
    %{
      os: os,
      scope: scope,
      unit_path: unit_path(os, scope, opts),
      fermix_path: fermix_path(opts),
      fermix_home: fermix_home(opts),
      log_path: log_path(opts),
      label: @label,
      linux_unit: @linux_unit
    }
  end

  defp unit_path(:darwin, :user, opts) do
    Keyword.get(opts, :unit_path) ||
      Path.join(System.user_home!(), "Library/LaunchAgents/#{@label}.plist")
  end

  defp unit_path(:darwin, :system, opts) do
    Keyword.get(opts, :unit_path) || "/Library/LaunchDaemons/#{@label}.plist"
  end

  defp unit_path(:linux, :user, opts) do
    Keyword.get(opts, :unit_path) ||
      Path.join(System.user_home!(), ".config/systemd/user/#{@linux_unit}")
  end

  defp unit_path(:linux, :system, opts) do
    Keyword.get(opts, :unit_path) || "/etc/systemd/system/#{@linux_unit}"
  end

  # When running inside the Burrito wrapper, `System.find_executable/1`
  # returns the *extracted* release launcher inside the Burrito cache,
  # which only understands the standard mix-release verbs (`start`,
  # `daemon`, `eval`) and rejects our `fermix run` subcommand. We need
  # the wrapper binary itself — the one launchd or systemd should
  # invoke — and Burrito exposes that via `__BURRITO_BIN_PATH`.
  defp fermix_path(opts) do
    Keyword.get(opts, :fermix_path) || burrito_bin_path() ||
      System.find_executable("fermix") ||
      raise ArgumentError, "fermix binary not on PATH; pass :fermix_path explicitly"
  end

  defp burrito_bin_path do
    case BurritoArgs.get_bin_path() do
      :not_in_burrito -> nil
      path when is_binary(path) -> path
    end
  end

  defp fermix_home(opts) do
    Keyword.get(opts, :fermix_home, default_fermix_home())
  end

  defp log_path(opts) do
    Keyword.get(opts, :log_path, Path.join(default_fermix_home(), "logs/fermix.log"))
  end

  defp default_fermix_home do
    System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
  end

  defp detect_os(opts) do
    Keyword.get(opts, :os) ||
      case :os.type() do
        {:unix, :darwin} -> :darwin
        {:unix, :linux} -> :linux
        other -> other
      end
  end

  defp backend(%{os: :darwin}), do: Launchd
  defp backend(%{os: :linux}), do: Systemd

  defp render(%{os: :darwin} = spec), do: Templates.render_darwin_plist(spec)
  defp render(%{os: :linux} = spec), do: Templates.render_linux_unit(spec)

  defp write_unit(spec), do: File.write(spec.unit_path, render(spec))

  defp remove_unit(%{unit_path: path}) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:remove_failed, reason}}
    end
  end
end
