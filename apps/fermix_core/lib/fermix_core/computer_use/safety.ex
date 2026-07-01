defmodule FermixCore.ComputerUse.Safety do
  @moduledoc """
  Pure safety policy for computer-use (docs/design/COMPUTER_USE.md §14). The
  `Session` wires these decisions; keeping them pure makes the safety floor
  unit-testable.

  Two orthogonal, deterministic floors live here:

    * `gate/2` — the `access` posture: `:strict` refuses every mutating action
      (look only); `:standard`/`:open` auto-run them. `:standard`'s "confirm before
      something irreversible" is a PROMPT principle the agent applies itself (it
      sees the screen), NOT a per-action human gate — there is no blocking
      confirmation anywhere anymore.
    * `host_start_allowed?/1` — only an attended origin (interactive chat or the
      voice pet) may START a host session, independent of access.

  Host control of a real logged-in session remains risk *mitigation, not
  containment*: an on-screen prompt-injection can in principle talk a `:standard`
  agent out of asking (§14.4). Only `:strict` and the attended-origin gate are hard.
  """

  alias Compux.Protocol
  alias FermixCore.ComputerUse.Config

  # Origins that have a live, two-way owner surface able to confirm a consequential
  # action and to tear the session down: an interactive chat (`/stop` reaches it)
  # or the realtime voice pet (`interrupt`/`call_stop`). Scheduled/cron and any
  # owner-absent origin are unattended and fail closed.
  @attended_origins [:interactive, :voice]

  @doc """
  Gate decision for an action given the `access` posture (COMPUTER_USE.md §14):

    * `:auto`   — run it.
    * `:refuse` — deny it (a mutating action under `:strict`, which is look-only).

  This is the ONLY deterministic floor. Read-only actions (screenshot/mouse_move/
  wait) always auto-run. Under `:standard`/`:open` mutating actions also auto-run —
  `:standard`'s "confirm before something irreversible" is a PROMPT principle the
  agent applies with its own judgment (it sees the screen), not a per-action gate;
  `:open` never pauses. There is no `:confirm` outcome here by design.
  """
  @type gate_decision :: :auto | :refuse
  @spec gate(String.t(), Config.t()) :: gate_decision()
  def gate(action, %Config{access: access}) when is_binary(action) do
    cond do
      Protocol.read_only?(action) -> :auto
      access == :strict -> :refuse
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
end
