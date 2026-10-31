defmodule FermixCore.Checklists.Note do
  @moduledoc """
  What the model is told about the owner's lists on every turn that may use
  them (MILESTONE_85 §05), appended by `Agents.TurnRunner` the way the current
  date is. Both are nil on any turn but the owner's private turn or voice call
  (`Checklists.Access.private_owner_turn?/1`), so a guest, a group chat or a
  shared session is told nothing of the lists.

  `rules/3` is the routing line, the one that says a list never lives in
  memory, and the channel line (`Prompt.ChannelPresentation.checklist_line/2`):
  the card's line when the turn's connection draws lists, else the line that
  says to write one. It rides the turn rather
  than the cached runtime contract because that contract is one per trust
  profile and an owner's group chat shares it, where no list line may appear
  (§11).

  `index/1` is one line naming the owner's lists, by folder in picker order,
  the lists in no folder last: names only, JSON-quoted, with no ids (a title
  names one list) and no counts, so it changes when a list is made, renamed,
  moved or removed, and never on a tick, and the prompt cache is left alone.
  It is nil when the owner has no list. A read that fails is logged and the
  turn goes on without it, as a turn with no lists would.

  Context seams: `:memory_repo` (nil when the turn has none, which notes
  nothing).
  """

  require Logger

  alias FermixCore.Checklists.Access
  alias FermixCore.Checklists.Registry
  alias FermixCore.Checklists.Render
  alias FermixCore.Memory.Repo
  alias FermixCore.Prompt.ChannelPresentation
  alias FermixCore.Timeouts

  @rules "A list the owner keeps, a backlog, a shopping list, anything they tick off, lives " <>
           "in a list and never in memory: read it with checklist_read, change it with " <>
           "checklist_edit, only as the owner asks. File each item in the list it belongs to, " <>
           "and when one could belong to more than one, ask before adding it. Make a new list " <>
           "only when the owner names a new one, in the folder that holds lists like it."

  @doc """
  The routing line and the channel line for `channel`, the card's when the
  connection that carried the turn draws lists (`draws?`), or nil on any turn
  but the owner's private one.
  """
  @spec rules(map(), String.t() | nil, boolean()) :: String.t() | nil
  def rules(context, channel, draws?) when is_map(context) and is_boolean(draws?) do
    if Access.private_owner_turn?(context),
      do: @rules <> "\n" <> ChannelPresentation.checklist_line(channel, draws?)
  end

  @doc "The one line naming the owner's lists, or nil."
  @spec index(map()) :: String.t() | nil
  def index(context) when is_map(context) do
    if Access.private_owner_turn?(context), do: context |> names() |> line()
  end

  defp names(context) do
    case Map.get(context, :memory_repo, Repo) do
      nil ->
        {:ok, []}

      repo ->
        Registry.names(context, repo: repo, on_timeout: :error, timeout: Timeouts.repo_call())
    end
  end

  defp line({:ok, []}), do: nil

  defp line({:ok, lists}),
    do: "The owner's lists: " <> Enum.map_join(Render.grouped(lists), "; ", &group/1) <> "."

  defp line({:error, :disabled}), do: nil

  defp line({:error, reason}) do
    Logger.warning("checklists: the owner's list names could not be read: #{inspect(reason)}")
    nil
  end

  defp group({nil, lists}), do: titles(lists)
  defp group({folder, lists}), do: "in #{Render.quoted(folder)}, " <> titles(lists)

  defp titles(lists), do: Enum.map_join(lists, ", ", &Render.quoted(&1.title))
end
