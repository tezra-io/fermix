defmodule FermixCore.ComputerUse.Courtesy do
  @moduledoc """
  Coexistence policy (docs/design/COMPUTER_USE_V3_COEXISTENCE.md, R0): keep the agent
  from fighting a present human for the one shared cursor. The agent yields the seat
  when the human is actively using the machine, and picks up when they go idle.

  Pure DECISIONS live here; the I/O (the `idle_ms` probe and `wait_for_idle`
  micro-defer) lives in `Session`, and the OS mechanism lives in compux — the same
  mechanism-in-library / policy-in-Fermix split as the rest of computer-use.

  This is a courtesy, NOT a safety floor. Where the idle signal is unavailable (the
  compux probe is macOS-only), the Session fails OPEN — it proceeds rather than
  blocking every action — because the hard floors are elsewhere (`Safety.gate/2`'s
  `:strict` posture and the attended-origin gate). Losing the courtesy signal must
  never brick computer-use, only drop it back to the pre-coexistence behavior.
  """

  # Actions that move the cursor or type: they DISTURB a present human. Note this is
  # deliberately BROADER than `Compux.Protocol.read_only?/1` — `mouse_move` is
  # read-only there (it mutates no app state) yet it visibly warps the cursor, so the
  # coexistence layer counts it as disturbing. "Disturbing" and "mutating" are two
  # different properties; this is the split the V3 design calls for.
  @disturbing ~w(left_click right_click double_click mouse_move left_click_drag scroll type key paste)

  # Max time the agent waits in-turn for the human to go idle before it steps aside.
  # An internal tuning bound, not an operator knob — config exposes only whether
  # courtesy is on (`courtesy`) and how much quiet counts as idle (`courtesy_idle_ms`).
  @defer_ms 3_000

  @doc "Whether an action disturbs a present human (moves the cursor or types)."
  @spec disturbing?(String.t()) :: boolean()
  def disturbing?(action) when is_binary(action), do: action in @disturbing

  @doc """
  Is a human actively using the machine right now, given the idle probe?

    * `idle_ms` — ms since the OS last saw ANY input (INCLUDING the agent's own
      synthetic events; the compux probe cannot separate them).
    * `since_agent_ms` — ms since the agent's own last disturbing action, or
      `:never` if it hasn't acted this session.
    * `idle_threshold_ms` — quiet for at least this long counts as idle.

  We attribute recent input to the human ONLY when the agent has itself been quiet
  for at least the threshold — otherwise the agent's own just-issued click would look
  like human activity and it would pause itself into a stall. If the agent acted more
  recently than the threshold we can't cleanly attribute the input, so we report "not
  active" and let it proceed; the next natural gap (a model round-trip) re-checks.
  """
  @spec human_active?(non_neg_integer(), non_neg_integer() | :never, pos_integer()) :: boolean()
  def human_active?(idle_ms, since_agent_ms, idle_threshold_ms)
      when is_integer(idle_ms) and idle_ms >= 0 and is_integer(idle_threshold_ms) and
             idle_threshold_ms > 0 do
    agent_quiet_enough?(since_agent_ms, idle_threshold_ms) and idle_ms < idle_threshold_ms
  end

  defp agent_quiet_enough?(:never, _threshold), do: true

  defp agent_quiet_enough?(since_agent_ms, threshold)
       when is_integer(since_agent_ms) and since_agent_ms >= 0,
       do: since_agent_ms >= threshold

  @doc "Max in-turn wait (ms) for the human to go idle before the agent steps aside."
  @spec defer_ms() :: pos_integer()
  def defer_ms, do: @defer_ms
end
