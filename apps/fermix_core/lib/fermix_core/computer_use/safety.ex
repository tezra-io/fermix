defmodule FermixCore.ComputerUse.Safety do
  @moduledoc """
  Pure safety policy for computer-use (docs/design/COMPUTER_USE.md §7). The
  `Session` wires these decisions; keeping them pure makes the safety floor
  unit-testable.

  None of these is sufficient alone — defense-in-depth — and host control of a
  real logged-in session remains risk *mitigation, not containment*. In
  particular the frontmost-app allowlist is a focus CHECK, not input routing, and
  is bypassable (§7.4); the load-bearing rule is that consequential actions are
  gated by a present human (§7.2/§7.3) and that only an attended origin may start
  a host session (§7.6).
  """

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Protocol

  # Origins that have a live, two-way owner surface able to confirm a consequential
  # action and to tear the session down: an interactive chat (`/stop` reaches it)
  # or the realtime voice pet (`interrupt`/`call_stop`). Scheduled/cron and any
  # owner-absent origin are unattended and fail closed.
  @attended_origins [:interactive, :voice]

  @doc """
  Gate decision for an action given config:

    * `:auto`    — run without confirmation (read-only actions always; or when an
      operator has explicitly disabled confirmation behind the §7.8 grant)
    * `:confirm` — require human-in-the-loop confirmation (a consequential action
      while `confirm_consequential?` is on — the default)

  Clicks/type/key/drag/scroll are consequential and gated by default: in a
  pixel-coordinate tool there is no semantic target, so the floor confirms every
  mutating action rather than guess (the Phase-2 AX-tree classifier relaxes this
  safely). Read-only actions (screenshot/mouse_move/wait) always auto-run.
  """
  @spec gate(String.t(), Config.t()) :: :auto | :confirm
  def gate(action, %Config{} = config) when is_binary(action) do
    cond do
      Protocol.read_only?(action) -> :auto
      config.confirm_consequential? -> :confirm
      true -> :auto
    end
  end

  @doc """
  True while the per-session action budget is not exhausted (§7.6). `count` is the
  number of actions already issued this session; on reaching `max_actions` the
  session halts and returns control to the human.
  """
  @spec within_action_budget?(non_neg_integer(), Config.t()) :: boolean()
  def within_action_budget?(count, %Config{max_actions: max})
      when is_integer(count) and count >= 0,
      do: count < max

  @doc """
  Whether an origin may START a host session (§7.6). Only attended owner origins
  qualify — an interactive chat or the voice pet, where a present human can
  confirm consequential actions and abort. Unattended origins (scheduled/cron,
  owner absent) fail closed: the safe path for unattended automation is the
  dedicated VM, not the real session.
  """
  @spec host_start_allowed?(atom()) :: boolean()
  def host_start_allowed?(origin) when is_atom(origin), do: origin in @attended_origins

  @doc """
  Frontmost-app allowlist CHECK for host mode (§7.4) — defense-in-depth, NOT a
  containment boundary (it races, and the agent can refocus a denied app with
  allowed keystrokes). An empty allowlist permits nothing (fail-closed).
  """
  @spec frontmost_app_allowed?(String.t(), Config.t()) :: boolean()
  def frontmost_app_allowed?(_app, %Config{allowed_apps: []}), do: false

  def frontmost_app_allowed?(app, %Config{allowed_apps: apps}) when is_binary(app),
    do: app in apps

  @doc """
  Domain allowlist for browser mode (§7.5) — an enforceable boundary there (the
  context cannot navigate off-allowlist), unlike the host-mode app check. An empty
  allowlist permits nothing (fail-closed).
  """
  @spec domain_allowed?(String.t(), Config.t()) :: boolean()
  def domain_allowed?(_host, %Config{allowed_domains: []}), do: false

  def domain_allowed?(host, %Config{allowed_domains: domains}) when is_binary(host),
    do: host in domains
end
