defmodule FermixCore.ComputerUse do
  @moduledoc """
  Top-level entry points for the computer-use subsystem (GUI control of a desktop
  or browser — docs/design/COMPUTER_USE.md).

  `ready?/0` is the single gate that decides whether the session supervisor boots
  and whether the `computer_use` tool is registered for the model: the feature must
  be enabled, the OS-driver sidecar binary must be installed (via the signed plugin
  catalog — see `SidecarInstaller`), and OS permissions must be granted. It is false
  by default (the feature is off), so nothing boots and the tool is never advertised
  until an operator turns it on AND the sidecar is installed — wiring the subsystem
  in activates nothing on its own.
  """

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.SidecarInstaller

  @spec enabled?() :: boolean()
  def enabled?, do: Config.enabled?()

  @doc """
  Whether computer-use can actually run: enabled, the sidecar binary installed
  (existing + executable, resolved through the plugin store), and OS permissions
  granted. Drives the supervisor and tool registration.
  """
  @spec ready?() :: boolean()
  def ready? do
    config = Config.current()
    config.enabled? and SidecarInstaller.installed?() and permissions_ok?(config)
  end

  # Phase-1e TODO: a real readiness probe — macOS TCC (Screen Recording +
  # Accessibility, both user-approval-only and silently-failing without) and the
  # Linux/X11 dependency check. Until that lands the gate still holds, because
  # `enabled?` is false by default and the sidecar binary is absent.
  defp permissions_ok?(%Config{}), do: true
end
