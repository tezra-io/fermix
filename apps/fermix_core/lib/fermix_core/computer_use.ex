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
  alias FermixCore.ComputerUse.SidecarInstaller

  @spec enabled?() :: boolean()
  def enabled?, do: Config.enabled?()

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
end
