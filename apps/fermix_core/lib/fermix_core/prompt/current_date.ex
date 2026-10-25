defmodule FermixCore.Prompt.CurrentDate do
  @moduledoc """
  Builds the per-turn "current date" system note.

  The composed system prompt and the generated runtime section are cached per
  profile in `FermixCore.Agents.RuntimeContext` (rebuilt only on reload), so the
  current date cannot live there — it would freeze until the cache is
  invalidated. `FermixCore.Agents.TurnRunner` injects this note fresh on every
  turn (and `FermixCore.Jobs.Runner` on every scheduled run), which is why it
  lives in its own module rather than in the cached sections.

  Date-only on purpose: the note sits ahead of conversation history in every
  request, so any change to it invalidates the provider's prompt-cache prefix.
  A date changes once a day; a clock time would bust the cache every turn. A run
  that reasons about time left carries `FermixCore.Clock.now_line/2` in its own
  message instead.

  The date is the owner's local date, from `FermixCore.Clock`, the same clock
  every other date and time a model is shown is stated on, so "today" and the
  day something was said can never disagree. With no usable zone the note states
  the UTC date and says why.
  """

  alias FermixCore.Clock

  @spec note(DateTime.t()) :: String.t()
  def note(%DateTime{} = now \\ DateTime.utc_now()) do
    day = Clock.stated_day(now)

    case Clock.display_zone() do
      {:ok, zone} ->
        "Current date: #{day}, in the owner's time zone (#{zone}, #{Clock.utc_offset(now)}). " <>
          "Every date and time Fermix shows you is in this zone unless it names another."

      {:utc, :timezone_not_configured} ->
        "Current date: #{day} (UTC). No time zone is configured, so every date and time " <>
          "Fermix shows you is in UTC; ask the owner for their time zone before stating a " <>
          "local time."

      {:utc, {:invalid_timezone, zone}} ->
        "Current date: #{day} (UTC). The configured time zone #{inspect(zone)} is not one " <>
          "Fermix knows, so every date and time Fermix shows you is in UTC."
    end
  end
end
