defmodule FermixCore.Watch.Runtime do
  @moduledoc """
  Builds the two production EFFECTS a `Watch.Session` runs — `decide` (one bounded
  model observation over the watched target) and `deliver` (surface a report to
  the origin conversation) — from a starting turn's context.

  This is the integration EDGE, kept thin and separate from the session's loop:

    * `decide` reuses `AgentLoop.run/1` (a bounded single decision with a scoped
      tool set — NOT `TurnRunner`, whose history/compaction/memory side effects
      have no place in a per-cycle watch). Routes + registry are snapshotted ONCE
      via `MainAgent.checkout_turn_state/2`, then reused every cycle.
    * `deliver` reuses `Jobs.Delivery.deliver_with_timeout/3` with a job-shaped map
      (`delivery_mode: "origin"` + the origin session id) — the same detached
      "post back to the conversation that started me" path scheduled jobs use.

  Channel origin only: a voice/Realtime origin delivers to a process-local pid
  that dies with the session (not persistable), so a watch is not offered there.

  The model loop + real channel delivery are exercised live (a daemon gate); the
  session's loop/lifecycle around these effects is unit-tested with fakes.
  """

  alias FermixCore.AgentLoop
  alias FermixCore.Agents.MainAgent
  alias FermixCore.ComputerUse
  alias FermixCore.Jobs.Delivery

  require Logger

  # One frame → one decision (+ an optional follow-up look) then a terminal reply.
  @cycle_max_iterations 4
  @scoped_tools ["computer_use", "browser"]

  @doc """
  Build `{:ok, decide, deliver}` for a watch on `task` started from `context`, or
  `{:error, reason}` if the turn-state snapshot can't be checked out.
  """
  @spec build(map(), String.t()) ::
          {:ok, (map() -> term()), (String.t() -> :ok)} | {:error, term()}
  def build(context, task) when is_map(context) and is_binary(task) do
    with {:ok, turn_state, _cache} <- checkout(context),
         {:ok, routes} <- routes(turn_state) do
      {:ok, decide_fn(context, turn_state, routes), deliver_fn(context)}
    end
  end

  # --- decide ---------------------------------------------------------------

  defp decide_fn(context, turn_state, routes) do
    origin = Map.get(context, :computer_use_origin, :interactive)
    # Only offer — and tell the model about — the observation tools actually
    # available. Without computer-use it can watch a browser page it drives but
    # NOT the host screen, so make that explicit: the model bails fast with a
    # clear message instead of failing screenshot after screenshot.
    cu_available = ComputerUse.ready?()
    tools = if cu_available, do: @scoped_tools, else: ["browser"]

    fn %{task: task, cycle: cycle} ->
      loop_opts = [
        messages: [%{role: "user", content: watch_prompt(task, cu_available)}],
        context: cycle_context(context, origin, cycle),
        capability_registry: turn_state.capability_registry,
        trust: :operator,
        allowed_tools: tools,
        max_iterations: @cycle_max_iterations,
        routes: routes
      ]

      case AgentLoop.run(loop_opts) do
        {:ok, %{response: text}} -> interpret(text)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp cycle_context(context, origin, cycle) do
    %{
      agent_name: "watch",
      conversation_key: Map.fetch!(context, :conversation_key),
      session_id: "watch_cycle_#{cycle}",
      # Attended origin so computer-use may start a host session from the loop.
      computer_use_origin: origin
    }
  end

  # A watch is read-only by default: the model observes and reports; it never
  # mutates the screen autonomously (a "watch and act" flow stays turn-driven).
  defp watch_prompt(task, cu_available) do
    """
    You are running a background WATCH for the user. Watch task: "#{task}".

    #{tools_line(cu_available)} To wait for a change, block on that tool's own wait \
    (computer_use `wait_for_change`, or the browser's `wait`), then read the new state.

    Decide whether anything relevant to the task has happened. If yes, describe it \
    in one or two sentences addressed to the user (this text is delivered to them). \
    If nothing relevant has changed, reply with EXACTLY: no change

    If you CANNOT do this watch with the tools you have — e.g. the task is about the \
    user's host screen but you only have the browser — do not keep retrying; reply \
    with EXACTLY: CANNOT_WATCH: <one short reason for the user>

    This is a READ-ONLY watch — do not click, type, or take any mutating action. \
    Then stop.
    """
  end

  defp tools_line(true),
    do:
      "Look at what you are watching RIGHT NOW: use computer_use to see the user's " <>
        "host screen, or browser for a page you are driving."

  defp tools_line(false),
    do:
      "You have the browser tool only (for a page you are driving) — computer_use is " <>
        "DISABLED, so you CANNOT see the user's host screen."

  # `CANNOT_WATCH:` → stop the watch now with the reason; empty/"no change" →
  # nothing to deliver this cycle; anything else → a report to deliver.
  defp interpret(text) when is_binary(text) do
    trimmed = String.trim(text)
    down = String.downcase(trimmed)

    cond do
      String.starts_with?(down, "cannot_watch:") ->
        {:stop_watch, reason_after_colon(trimmed)}

      down == "" or String.starts_with?(down, "no change") or
          String.starts_with?(down, "nothing ") ->
        :quiet

      true ->
        {:report, trimmed}
    end
  end

  defp reason_after_colon(text) do
    case String.split(text, ":", parts: 2) do
      [_, reason] -> String.trim(reason)
      _ -> text
    end
  end

  # --- deliver --------------------------------------------------------------

  defp deliver_fn(context) do
    job = %{
      delivery_mode: "origin",
      created_by_session_id: origin_session_id(context),
      silent_marker: nil
    }

    opts = [channels: delivery_channels()]
    label = inspect(Map.get(context, :conversation_key))

    fn text when is_binary(text) ->
      # Never swallow a delivery failure — `Jobs.Delivery` returns (and does not
      # log) `{:error, _}` on timeout/crash/unsupported-platform, and the post-wake
      # Finch pool-checkout timeout is a real live case. Log it with context.
      case Delivery.deliver_with_timeout(job, text, opts) do
        {:error, reason} ->
          Logger.warning("watch delivery failed for #{label}: #{inspect(reason)}")
          :ok

        _delivered ->
          :ok
      end
    end
  end

  # {channel, chat_id, thread_scope} → "channel:chat_id:scope" (mirrors
  # `Tools.ScheduleJob.origin_session_id/1`, the shape `Jobs.Delivery` splits).
  defp origin_session_id(%{conversation_key: {channel, chat_id, thread_scope}}) do
    Enum.map_join([channel, chat_id, thread_scope], ":", &part/1)
  end

  defp part(:root), do: "root"
  defp part(value), do: to_string(value)

  defp delivery_channels do
    :fermix_core
    |> Application.get_env(:jobs, [])
    |> Keyword.get(:delivery_channels, %{})
  end

  # --- turn-state snapshot --------------------------------------------------

  defp checkout(context) do
    MainAgent.checkout_turn_state(MainAgent, checkout_message(context))
  catch
    :exit, reason -> {:error, {:checkout_unavailable, reason}}
  end

  # Shaped as `MainAgent.channel_message()` — `:reply_fn` is a required key even
  # though the checkout path only reads channel/chat_id (via `ConversationKey`); a
  # no-op reply_fn satisfies the contract without a channel.
  defp checkout_message(%{conversation_key: {channel, chat_id, _scope}}) do
    %{
      content: "watch",
      sender: "watch",
      channel: to_string(channel),
      chat_id: to_string(chat_id),
      reply_fn: fn _ -> :ok end
    }
  end

  defp routes(turn_state) do
    case Map.get(turn_state, :ordered_routes) do
      [_ | _] = routes -> {:ok, routes}
      _ -> {:error, :no_routes}
    end
  end
end
