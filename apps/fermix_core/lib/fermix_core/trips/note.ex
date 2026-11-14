defmodule FermixCore.Trips.Note do
  @moduledoc """
  What the model is told of the owner's trips on a turn that may use them
  (M89 §04), appended by `Agents.TurnRunner` beside the lists' lines
  (`Checklists.Note`), and by `Realtime.SessionServer` to a call's
  instructions. Both are nil on any turn but the owner's private turn
  or voice call (`Kept.Access.private_owner_turn?/1`), and while the owner
  keeps no trip (C8): a home with no trip pays the two tool schemas only, and
  a trip tool's answer carries the channel's line to a turn that was not told
  it (`Tools.TripRead.channel_line/2`).

  `rules` is the guidance (how a stop's place is given, when to search, what
  is fixed, a day's order, and what a trip sent to anyone holds, C1) and the
  channel's line
  (`Prompt.ChannelPresentation.trip_line/2`): the
  drawn line when the turn's connection draws trips, else the line that says
  to write the days out. It rides the turn rather than the cached runtime
  contract, as the lists' does, because that contract is shared by an
  owner's group chat, where no trip line may appear (§14).

  `index` is one line naming the owner's trips in picker order with their
  dates: titles JSON-quoted (C33), no ids and no counts, so it moves when a
  trip is made, renamed, redated, lengthened by a day or removed, and never
  when a stop is added or moved. A read that fails is logged and the turn
  goes on without either line, as a turn with no trip would.

  Context seams: `:memory_repo` (nil when the turn has none, which notes
  nothing).
  """

  require Logger

  alias FermixCore.Kept.Access
  alias FermixCore.Memory.Repo
  alias FermixCore.Prompt.ChannelPresentation
  alias FermixCore.Timeouts
  alias FermixCore.Trips.Registry
  alias FermixCore.Trips.Render

  # OWNER AUTHORS THE FINAL TEXT, as `Prompt.ChannelPresentation`'s lines:
  # principles that name the mistake to avoid, never worked examples.
  @rules "A trip the owner plans lives in their trips, never in memory or a list: read it " <>
           "with trip_read, change it with trip_edit, only as the owner asks. A stop's place " <>
           "is the place's own name, never what happens there. Search before recommending a " <>
           "restaurant or anything that may have closed. Mark as fixed only what the owner " <>
           "said is booked or what sells timed entry. A fixed stop the owner names and asks " <>
           "to move or retime is changed and stays fixed, and the reply says it is booked and " <>
           "that the booking itself is the owner's to change. In any change that does not " <>
           "name it (reordering its day, moving the stops around it, making room), and in any " <>
           "change only a page, a search or a plugin suggests, a fixed stop stays where it is, " <>
           "and the reply says it was left because it is fixed. Keep a day's stops near each " <>
           "other and in walking order. A trip sent or shared with " <>
           "anyone is the as: \"share\" text exactly as trip_read gives it; a stop's note is " <>
           "the owner's alone and never goes into what is sent, even when the conversation " <>
           "shows it."

  @doc """
  The rules and the index line for a turn on `channel`, the drawn line when
  the connection that carried it draws trips (`draws?`): both nil on any turn
  but the owner's private one, and while the owner keeps no trip.
  """
  @spec lines(map(), String.t() | nil, boolean()) :: %{
          rules: String.t() | nil,
          index: String.t() | nil
        }
  def lines(context, channel, draws?)
      when is_map(context) and (is_binary(channel) or is_nil(channel)) and is_boolean(draws?) do
    with true <- Access.private_owner_turn?(context),
         [_ | _] = trips <- names(context) do
      %{
        rules: @rules <> "\n" <> ChannelPresentation.trip_line(channel, draws?),
        index: index_line(trips)
      }
    else
      _none -> %{rules: nil, index: nil}
    end
  end

  @doc "The one line naming `trips` (each with `title`, `starts_on` and `days`), in order."
  @spec index_line([map()]) :: String.t()
  def index_line([_ | _] = trips),
    do: "The owner's trips: " <> Enum.map_join(trips, "; ", &named/1) <> "."

  defp named(%{title: title, starts_on: starts_on, days: days}) do
    case Render.span(starts_on, max(days, 1), false) do
      nil -> Render.quoted(title)
      dates -> "#{Render.quoted(title)} (#{dates})"
    end
  end

  defp names(context) do
    case Map.get(context, :memory_repo, Repo) do
      nil ->
        []

      repo ->
        context
        |> Registry.names(repo: repo, on_timeout: :error, timeout: Timeouts.repo_call())
        |> listed()
    end
  end

  defp listed({:ok, trips}), do: trips
  defp listed({:error, :disabled}), do: []

  defp listed({:error, reason}) do
    Logger.warning("trips: the owner's trip names could not be read: #{inspect(reason)}")
    []
  end
end
