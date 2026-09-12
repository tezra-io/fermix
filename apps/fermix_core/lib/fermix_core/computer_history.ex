defmodule FermixCore.ComputerHistory do
  @moduledoc """
  On-device computer-history rail (MILESTONE_32): an opt-in, off-by-default,
  macOS-only recorder of an interaction-event stream, summarized on-device
  into durable activity memories the owner can recall.

  This module is the thin facade over the subsystem's operative state. Every
  flow decision ("may activity reach *this* sink") goes through
  `FermixCore.ComputerHistory.Gate`, never a scattered `enabled?()` check —
  the Gate is the single resolver (§9). This facade answers only the two
  coarse questions the supervisor and the Gate snapshot need: is the feature
  enabled, and is this a macOS host where it can run at all.

  The capture layer *is* macOS (Accessibility TCC, NSWorkspace, AXObserver);
  it does not port. On any non-macOS host the feature is unavailable —
  `operative?/0` is false, nothing is advertised, and the config section is
  inert (§4.2, Decision 12).
  """

  alias FermixCore.ComputerHistory.Config
  alias FermixCore.ComputerHistory.Controller

  require Logger

  @doc "Whether the operator has enabled computer history in config."
  @spec enabled?() :: boolean()
  def enabled?, do: Config.enabled?()

  @doc """
  Whether this host is macOS. Production reads `:os.type/0`; tests inject the
  platform through `Gate.snapshot/2`'s `:macos?` opt rather than mutating this,
  so the suite stays hermetic on Linux CI (Code Rule 5, pass deps explicitly).
  """
  @spec macos?() :: boolean()
  def macos?, do: :os.type() == {:unix, :darwin}

  @doc """
  Whether the feature is operative: enabled *and* on a macOS host. This is the
  master switch every Gate consumer sink is gated on; retention and purge run
  independently of it (§6.3), so they do not consult this.
  """
  @spec operative?() :: boolean()
  def operative?, do: macos?() and enabled?()

  @doc """
  Raise the macOS Accessibility grant capture needs, via the shared compux driver
  (`ComputerUse.request_permissions/0` — same binary, same TCC identity). Capture
  uses only the Accessibility grant; the shared prompt also raises Screen Recording,
  which capture ignores (an Accessibility-only action is a v1.1 refinement, §22.3).
  A no-op off macOS. Called from the Computer-History setup card at enable time so
  the prompt appears up front rather than on the first observe.
  """
  @spec request_permissions() :: {:ok, map()} | {:error, term()}
  def request_permissions do
    if macos?(), do: FermixCore.ComputerUse.request_permissions(), else: {:ok, %{}}
  end

  @doc """
  Reconcile the runtime capture children to the current config, live (an
  enable/disable act on a running daemon). Delegates to the `Controller`, which
  re-reads `operative?/0` and starts or stops the `Capturer` + summarizer. A safe
  no-op when the controller is not running — off macOS the supervisor is absent,
  and a config-only surface (e.g. the setup CLI) has no daemon tree — so the
  caller never needs to know whether a daemon is up.
  """
  @spec reconcile_runtime() :: :ok
  def reconcile_runtime do
    Controller.reconcile()
  catch
    :exit, _reason ->
      Logger.debug("computer_history reconcile_runtime: no controller running (no-op)")
      :ok
  end
end
