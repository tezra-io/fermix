defmodule FermixCore.ComputerUse.Yield do
  @moduledoc """
  The courtesy step before a disturbing action (V3 R0, M42 §5.3): when courtesy
  is on, ask the helper how long the person has been idle, and step aside when
  they are at the machine. `Courtesy` holds the decisions; this module does their
  I/O, once, for each owner of a driver:

    * a `Session` driving this machine's own helper;
    * a computer whose server drives its screen (M97 §6.4,
      `Computers.Capabilities.Screen`), because the idle signal is on the
      computer. A session on the server whose driver is the computer's
      (`ComputerDriver`) runs with courtesy off, so the step runs on one side.

  `check/3` answers `{:proceed, courtesy}` (`:off`, `:unavailable`,
  `:proceeded`, `:deferred`), `{:refuse, :user_active}`, or `{:abort, reason}`
  when the helper stopped answering, which no input may follow.

  A missing idle signal (the probe is macOS-only, or a malformed reply) is not a
  failure: courtesy is a nicety, not a safety gate, so it fails OPEN and
  proceeds; the access posture and the attended-origin gate remain the hard
  floors.
  """

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Courtesy

  @typedoc """
  What the step reads besides the request: the courtesy config, the helper's
  reading (its `input_methods`), the kind of target the session is bound to, and
  when the agent last disturbed the seat (monotonic ms, or `:never`).
  """
  @type facts :: %{
          config: Config.t(),
          capabilities: map(),
          target_kind: :window | :desktop | nil,
          last_action_at: integer() | :never
        }

  @type outcome ::
          {:proceed, :off | :unavailable | :proceeded | :deferred}
          | {:refuse, :user_active}
          | {:abort, term()}

  @doc "The courtesy step for `request` (the moduledoc)."
  @spec check(map(), facts(), {module(), term()}) :: outcome()
  def check(request, %{config: %Config{} = config} = facts, {mod, _state} = driver)
      when is_map(request) and is_atom(mod) do
    if config.courtesy == :yield and Courtesy.disturbing?(request["action"]),
      do: arbitrate(request, facts, driver),
      else: {:proceed, :off}
  end

  # How wide the contention question is depends on what this action takes (M42
  # §5.3). A control pressed by name inside a bound window takes nothing the
  # person is holding, so only activity in THAT window's application is
  # contention; everything else takes the one cursor or the one keyboard, and any
  # activity at all is.
  defp arbitrate(request, facts, driver) do
    scope =
      Courtesy.scope(Courtesy.ax_addressed?(request, facts.capabilities), facts.target_kind)

    case idle_probe(driver) do
      {:ok, idle_ms, front_is_target} ->
        active? =
          Courtesy.human_active?(idle_ms, since_agent_ms(facts), facts.config.courtesy_idle_ms)

        if Courtesy.contends?(scope, active?, front_is_target),
          do: defer_to_human(facts, driver),
          else: {:proceed, :proceeded}

      {:error, reason} ->
        courtesy_error(reason)
    end
  end

  defp defer_to_human(facts, driver) do
    case wait_for_idle(facts, driver) do
      {:ok, true} -> {:proceed, :deferred}
      {:ok, false} -> {:refuse, :user_active}
      {:error, reason} -> courtesy_error(reason)
    end
  end

  # A sidecar TIMEOUT or EXIT is not a missing signal, it is a helper that stopped
  # answering. A reply now reaches the request that asked for it by id, so no late
  # frame can answer the action — but a helper that went quiet is not one to hand
  # real input to next, so these abort before any is sent.
  defp courtesy_error({:timeout, :cu_sidecar_action, _ms} = reason), do: {:abort, reason}
  defp courtesy_error({:sidecar_exited, _status} = reason), do: {:abort, reason}
  defp courtesy_error(:sidecar_unavailable = reason), do: {:abort, reason}
  defp courtesy_error(_reason), do: {:proceed, :unavailable}

  # `front_is_target` is the helper's reading of whether the application in front
  # is the bound one (M42 slice 5 §3.1). Absent is unknown, as everywhere else,
  # and unknown is not contention: a bound window exists so that work inside it
  # survives the person using something else.
  defp idle_probe({mod, state}) do
    case mod.execute(state, %{"action" => "idle_ms"}) do
      {:ok, %{"idle_ms" => ms} = reply} when is_integer(ms) and ms >= 0 ->
        {:ok, ms, front_is_target(reply["front_is_target"])}

      {:ok, _other} ->
        {:error, :malformed_idle_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp front_is_target(front) when is_boolean(front), do: front
  defp front_is_target(_absent), do: nil

  defp wait_for_idle(facts, {mod, state}) do
    request = %{
      "action" => "wait_for_idle",
      "idle_ms" => facts.config.courtesy_idle_ms,
      "timeout_ms" => Courtesy.defer_ms()
    }

    case mod.execute(state, request) do
      {:ok, %{"idle" => idle}} when is_boolean(idle) -> {:ok, idle}
      {:ok, _other} -> {:error, :malformed_idle_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp since_agent_ms(%{last_action_at: :never}), do: :never
  defp since_agent_ms(%{last_action_at: at}), do: System.monotonic_time(:millisecond) - at
end
