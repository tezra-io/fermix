defmodule FermixCore.OpenLoops.DueNote do
  @moduledoc """
  Rung 1 of a due open loop (MILESTONE_78 §04 stage 3, §07, §18 "rung 1
  window"): the system note an owner's private turn carries while a loop is
  due, appended by `Agents.TurnRunner` the way the current date and recent
  activity are.

  `note/1` is nil unless the feature is enabled, the turn is an attended owner
  turn (`OpenLoops.Access.attended?/1`), the chat is not a shared room
  (`Prompt.ChannelPresentation.group_chat?/1`), and a loop is inside its touch
  window (`Repo.due_open_loops_for_note/4` with
  `OpenLoops.Defaults.rung1_window_ms/0`). Otherwise it is one paragraph per due
  loop, in the §07 wording: the day the owner said it and the date it matters
  by, both absolute with the weekday in the loop's zone, the owner's words
  quoted as stored, and the loop's id on its own line so `open_loop_update` can
  name it.

  The note is context, not the turn: a read that fails is logged and the turn
  goes on without it, as a turn with no due loop would.

  Context seams: `:memory_repo` (nil when the turn has none, which notes
  nothing) and `:now_fn` (the clock).
  """

  require Logger

  alias FermixCore.Memory.Repo
  alias FermixCore.OpenLoops.Access
  alias FermixCore.OpenLoops.Config
  alias FermixCore.OpenLoops.Defaults
  alias FermixCore.OpenLoops.Registry
  alias FermixCore.Prompt.ChannelPresentation
  alias FermixCore.Timeouts

  @doc "The due note for this turn, or nil when no loop is due or the turn gets none."
  @spec note(map()) :: String.t() | nil
  def note(context) when is_map(context) do
    if noted_turn?(context), do: due_note(context)
  end

  defp noted_turn?(context) do
    Config.enabled?() and Access.attended?(context) and
      not ChannelPresentation.group_chat?(Map.get(context, :chat_type))
  end

  defp due_note(context) do
    case Map.get(context, :memory_repo, Repo) do
      nil -> nil
      repo -> context |> read(repo) |> render()
    end
  end

  defp read(context, repo) do
    owner_id = Map.get(context, :memory_owner_id, "default")
    agent_id = Map.get(context, :memory_agent_id, "main")

    opts =
      repo
      |> Repo.periodic_opts(Timeouts.repo_call())
      |> Keyword.put(:window_ms, Defaults.rung1_window_ms())

    Repo.due_open_loops_for_note(owner_id, agent_id, now(context), opts)
  end

  defp now(%{now_fn: now_fn}) when is_function(now_fn, 0), do: now_fn.()
  defp now(_context), do: DateTime.utc_now()

  defp render({:ok, []}), do: nil
  defp render({:ok, loops}), do: Enum.map_join(loops, "\n\n", &paragraph/1)
  defp render({:error, :disabled}), do: nil

  defp render({:error, reason}) do
    Logger.warning("open_loops: the due loops could not be read: #{inspect(reason)}")
    nil
  end

  # §07's due note, read off the stored row through the model's own view of a
  # loop, so the dates say exactly what `open_loop_list` would.
  defp paragraph(loop) do
    view = Registry.view(loop)

    "Open loop due. On #{view["said_on"]} the owner said: \"#{view["intention"]}\". " <>
      "It matters by #{view["matters_by"]}. Raise it under the open-loop rules only if this " <>
      "exchange reaches a natural stopping point and the owner is not under pressure; " <>
      "otherwise leave it for Fermix to raise on its own.\n" <>
      "open_loop_id: #{view["open_loop_id"]}"
  end
end
