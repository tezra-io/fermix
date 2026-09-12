defmodule FermixCore.ComputerUse do
  @moduledoc """
  Top-level entry points for the computer-use subsystem (GUI control of the host
  desktop — docs/design/COMPUTER_USE_V2.md).

  `ready?/0` is the single gate that decides whether the session supervisor boots
  and whether the `computer_use` tool is registered for the model: the feature must
  be enabled AND the OS-driver sidecar binary installed (downloaded via the `compux`
  library — see `SidecarInstaller`). It is false by default (the feature is off), so
  nothing boots and the tool is never advertised until an operator turns it on AND
  the sidecar is installed — wiring the subsystem in activates nothing on its own.

  OS-permission state is deliberately NOT part of this gate (see `ready?/0`).
  """

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Grant
  alias FermixCore.ComputerUse.PortDriver
  alias FermixCore.ComputerUse.SessionManager
  alias FermixCore.ComputerUse.SidecarInstaller

  require Logger

  # Boot-time bound on the one-shot sidecar ensure below: a slow or offline
  # download is killed after this so it never blocks the daemon's boot, and
  # computer-use stays off (fail-closed) until the next boot.
  @sidecar_boot_ensure_timeout_ms 30_000

  @spec enabled?() :: boolean()
  def enabled?, do: Config.enabled?()

  @doc """
  Ensure the compux OS-driver sidecar matching the COMPILED-IN version is
  installed, so a daemon that just upgraded (new compux ref -> new sidecar
  version) downloads the matching sidecar at boot instead of silently losing the
  features that need it until the operator re-runs setup. The one binary is
  shared by computer-use AND computer-history, so `:wanted?` decides whether the
  sidecar is needed at all (default: computer-use enabled); the boot caller ORs
  in computer-history so either feature triggers the download.

  Returns `:ok` immediately with NO network when the sidecar is not wanted or is
  already installed, so the common boot path is untouched. Otherwise it downloads
  once, BOUNDED by `:timeout_ms` and FAIL-SOFT: a slow, failed, or crashing
  download is logged and leaves the dependent features off (the existing
  fail-closed state, retried on the next boot or via the setup card) — it never
  blocks or crashes boot. `:installer` (default `SidecarInstaller`) is injectable
  for tests.
  """
  @spec ensure_sidecar_installed(keyword()) :: :ok
  def ensure_sidecar_installed(opts \\ []) when is_list(opts) do
    installer = Keyword.get(opts, :installer, SidecarInstaller)
    timeout = Keyword.get(opts, :timeout_ms, @sidecar_boot_ensure_timeout_ms)
    wanted? = Keyword.get_lazy(opts, :wanted?, fn -> Config.current().enabled? end)

    cond do
      not wanted? -> :ok
      installer.installed?() -> :ok
      true -> download_sidecar(installer, timeout)
    end
  end

  defp download_sidecar(installer, timeout) do
    task = Task.async(fn -> safe_install(installer) end)

    (Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill))
    |> log_ensure_result()

    :ok
  end

  # The task body must never raise: `Task.async` links to the boot process, so an
  # install exception here would otherwise crash the daemon's startup.
  defp safe_install(installer) do
    installer.install()
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp log_ensure_result({:ok, {:ok, path}}),
    do: Logger.info("compux sidecar ensured at boot (#{path})")

  defp log_ensure_result({:ok, {:error, reason}}),
    do:
      Logger.warning(
        "compux sidecar ensure failed at boot (#{inspect(reason)}); " <>
          "features needing it stay off until the next boot or re-enable"
      )

  defp log_ensure_result({:exit, reason}),
    do:
      Logger.warning(
        "compux sidecar ensure crashed at boot (#{inspect(reason)}); features needing it stay off"
      )

  defp log_ensure_result(nil),
    do: Logger.warning("compux sidecar ensure timed out at boot; features needing it stay off")

  # Catch-all so an unexpected install return can never raise a FunctionClauseError
  # in the boot process — the never-crash-boot guarantee holds even off-contract.
  defp log_ensure_result(other),
    do:
      Logger.warning(
        "compux sidecar ensure returned an unexpected result at boot " <>
          "(#{inspect(other)}); features needing it stay off"
      )

  @doc """
  Pause the computer-use session for a conversation `context` (the `/pause` command):
  the human is reclaiming the machine. The session, its sidecar, and the task stay
  ALIVE and resumable — this only flips the session's guard so it refuses actions
  until `resume/1` (contrast the interactive `/stop`, which tears the session down).
  Returns `:paused` if a session was running, `:no_session` otherwise. A safe no-op
  when computer-use isn't running.
  """
  @spec pause(map()) :: :paused | :no_session
  def pause(context) when is_map(context), do: SessionManager.pause(context)

  @doc "Resume a paused computer-use session (`/resume`). `:resumed` or `:no_session`."
  @spec resume(map()) :: :resumed | :no_session
  def resume(context) when is_map(context), do: SessionManager.resume(context)

  @doc """
  Actively PROMPT for the macOS Screen Recording + Accessibility grants and report the
  resulting state. Registers the sidecar bundle with LaunchServices, then raises the OS
  dialogs (see `Grant`). Called from the setup card / `fermix doctor` at enable time so
  permissions register up front rather than on the model's first screenshot. A no-op
  prompt off macOS. Returns `{:error, reason}` if the sidecar is unavailable.
  """
  @spec request_permissions() :: {:ok, Grant.result()} | {:error, term()}
  def request_permissions, do: Grant.request()

  @doc """
  Whether computer-use can actually run: enabled and the sidecar binary installed
  (existing + executable, resolved through the plugin store). Drives the supervisor
  and tool registration.

  OS-permission state is deliberately NOT part of this gate. It is surfaced as an
  operator-facing diagnostic instead (`ComputerUse.Probe`, shown in `fermix doctor`
  and the setup card) for two reasons: probing requires spawning the sidecar — too
  heavy for this hot path — and a read-only `screenshot` works without the
  Accessibility grant, so a missing grant must INFORM the operator, not silently
  hide the tool. See docs/design/COMPUTER_USE_V2.md, Phase A.
  """
  @spec ready?() :: boolean()
  def ready? do
    Config.current().enabled? and SidecarInstaller.installed?()
  end

  @doc """
  The production OS-driver spec — `{PortDriver, binary_path: path}` — resolved
  from the installed sidecar, or `{:error, {:sidecar_unavailable, reason}}`.

  One resolver for every driver owner: the per-conversation `SessionManager` and
  the realtime `ScreenFeed`'s dedicated capture port both start their OWN driver
  instance (separate Ports, one purpose each) but must resolve the SAME installed
  binary the same way, including the fail-closed shape when it is missing.
  """
  @spec driver_spec() :: {:ok, {module(), keyword()}} | {:error, term()}
  def driver_spec do
    case SidecarInstaller.binary_path() do
      {:ok, path} -> {:ok, {PortDriver, [binary_path: path]}}
      {:error, reason} -> {:error, {:sidecar_unavailable, reason}}
    end
  end
end
