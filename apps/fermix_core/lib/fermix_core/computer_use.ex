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
end
