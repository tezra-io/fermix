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
  A date changes once a day; a clock time would bust the cache every turn.
  Agents that need the precise time run `date`.

  The date is reported in UTC because the runtime ships no IANA timezone
  database. The user's configured timezone (collected at setup, defaulting to
  `America/New_York`) is attached as a label so the agent can reason about
  their local date when it matters.
  """

  @spec note() :: String.t()
  def note do
    stamp = Calendar.strftime(DateTime.utc_now(), "%A, %Y-%m-%d")

    case configured_timezone() do
      tz when is_binary(tz) and tz != "" ->
        "Current date: #{stamp} (UTC). The user's timezone is #{tz} — " <>
          "their local date can differ from UTC near midnight."

      _ ->
        "Current date: #{stamp} (UTC)."
    end
  end

  defp configured_timezone do
    Application.get_env(:fermix_core, :personalization, [])
    |> Keyword.get(:timezone)
  end
end
