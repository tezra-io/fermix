defmodule FermixCore.Agents.BackgroundRun do
  @moduledoc """
  Neutral core runner for detached `/background` work. The gateway hands it a
  neutral request — no `reply_fn`, no channel context — and gets back a neutral
  result it can deliver. It has no dependency on `FermixChannels`.

  Backgrounded `/ultra` is **out of scope**: `work_scoped_message/3` builds the
  message with empty `metadata`, so a `run_profile: :ultra` tag never reaches
  `TurnRunner` here — a backgrounded run is always a normal turn. Threading the
  ultra mode through the detached path is a separate follow-up.

  It runs as a main-agent-equivalent coordinator: it checks out the turn-state
  snapshot from the one cache owner (`MainAgent.checkout_turn_state/2`, never a
  second cache) and runs a normal turn via `TurnRunner.run/3`, but under a
  **work-scoped** conversation key `{"background", work_id, :root}`. Because
  `TurnRunner` keys conversation history and conversation-scoped memory off the
  message's `ConversationKey`, this run neither reads nor writes the foreground
  conversation's history or conversation-scoped memory (§17.6). Owner-scoped
  long-term memory (the `memory_agent_id`/`memory_owner_id` from the cached
  turn-state) is intentionally shared.

  `subagent_depth` is absent (depth 0), so the coordinator can still call
  `subagents`. No channel reply context exists, so a mid-turn `send_attachment`
  fails loudly rather than silently dropping media; the final result is delivered
  by the gateway, not here.
  """

  alias FermixCore.Agents.MainAgent
  alias FermixCore.Agents.TurnRunner

  @type request :: %{
          required(:prompt) => String.t(),
          required(:work_id) => String.t(),
          required(:source_trust) => :operator | :guest,
          optional(:main_agent) => GenServer.server(),
          optional(:turn_runner) => module()
        }

  @spec run(request()) :: {:ok, String.t()} | {:error, term()}
  def run(%{prompt: prompt, work_id: work_id, source_trust: source_trust} = request)
      when is_binary(prompt) and is_binary(work_id) and source_trust in [:operator, :guest] do
    main_agent = Map.get(request, :main_agent, MainAgent)
    turn_runner = Map.get(request, :turn_runner, TurnRunner)
    msg = work_scoped_message(prompt, work_id, source_trust)

    with {:ok, turn_state, _cache_status} <- checkout(main_agent, msg),
         {:ok, response, _context_tokens} <- turn_runner.run(msg, turn_state, &deliver/1) do
      {:ok, response}
    end
  end

  # `ConversationKey.from/1` keys history + conversation-scoped memory by
  # {channel, chat_id, thread} = {"background", work_id, :root}, isolating this
  # run from any foreground conversation.
  defp work_scoped_message(prompt, work_id, source_trust) do
    %{
      content: prompt,
      sender: "background",
      channel: "background",
      chat_id: work_id,
      source_trust: source_trust,
      metadata: %{}
    }
  end

  defp checkout(main_agent, msg) do
    MainAgent.checkout_turn_state(main_agent, msg)
  catch
    :exit, reason -> {:error, {:checkout_unavailable, reason}}
  end

  # No channel here: fail media so `send_attachment` surfaces an error instead of
  # silently losing it. Text mid-turn parts are a no-op (the gateway delivers the
  # final result).
  defp deliver({:media, _part}), do: {:error, :no_background_channel}
  defp deliver(_part), do: :ok
end
