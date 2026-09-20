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

  alias Compux.Protocol

  # Actions that act on the machine the human is sitting at: they DISTURB them.
  # DERIVED, not listed (M42 slice 4 §4): every action the library offers that is
  # not read-only is disturbing, so an action added later — `press`, `set_value`,
  # whatever follows — joins the courtesy wait, the input seat and the action stamp
  # by construction rather than by someone remembering this list.
  #
  # Deliberately BROADER than `Compux.Protocol.read_only?/1` on one action:
  # `mouse_move` is read-only there (it mutates no app state) yet it visibly warps
  # the cursor, so the coexistence layer counts it. "Disturbing" and "mutating" are
  # two different properties; this is the split the V3 design calls for.
  @always_disturbing ~w(mouse_move)

  @disturbing Enum.uniq(
                Enum.reject(Protocol.actions(), &Protocol.read_only?/1) ++ @always_disturbing
              )

  # Max time the agent waits in-turn for the human to go idle before it steps aside.
  # An internal tuning bound, not an operator knob — config exposes only whether
  # courtesy is on (`courtesy`) and how much quiet counts as idle (`courtesy_idle_ms`).
  @defer_ms 3_000

  @doc "Whether an action disturbs a present human (moves the cursor or types)."
  @spec disturbing?(String.t()) :: boolean()
  def disturbing?(action) when is_binary(action), do: action in @disturbing

  @typedoc """
  How wide the contention question is for one action (M42 §5.3).

    * `:desktop` — the action takes the one cursor, the one keyboard or the one
      focused window, so ANY human activity is contention. Every foreground
      action, and every action at all while no window is bound.
    * `:target_process` — the action reaches a control inside ONE bound window by
      name: no pointer moves, no focus is seized, so the person typing in another
      application is not competing with it. Only activity in the target's own
      process is contention, which is what `front_is_target` answers.
  """
  @type scope :: :desktop | :target_process

  @doc """
  The contention scope for this action, given whether it is addressed at a
  control by name and what the session is bound to.

  Deliberately conservative on both axes: an accessibility action with no bound
  window still travels through the whole application, and a bound window does not
  narrow a click, a keystroke or a scroll — those take the machine however they
  are aimed.
  """
  @spec scope(boolean(), :window | :desktop | nil) :: scope()
  def scope(true = _ax_addressed?, :window), do: :target_process
  def scope(_ax_addressed?, _target_kind), do: :desktop

  @doc """
  Whether the agent should step aside, given the scope, whether the person is
  active at all, and whether the front application is the bound target.

  `front_is_target` is the helper's reading and may be absent: a probe that could
  not say leaves it `nil`, which is NOT contention. Courtesy fails open
  everywhere else (`Session`'s missing idle signal proceeds), and the whole point
  of a bound window is that work inside it does not stop because somebody is
  using a different application.
  """
  @spec contends?(scope(), boolean(), boolean() | nil) :: boolean()
  def contends?(:desktop, human_active?, _front_is_target), do: human_active?

  def contends?(:target_process, human_active?, front_is_target),
    do: human_active? and front_is_target == true

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
