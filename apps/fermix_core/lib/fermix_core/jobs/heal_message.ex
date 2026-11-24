defmodule FermixCore.Jobs.HealMessage do
  @moduledoc """
  The one message a heal sends the owner (M106 §5.4), built by code from
  Fermix's own facts (`Memory.Repo.JobHealsSql`'s `{:message_facts, id}`):
  what failed and when, how often, and when the job runs next; for a
  provider, which one, its own words, and which jobs since when.

  Pure: the facts in, the text out, every instant on the owner's clock
  (`FermixCore.Clock`, whose options `build/2` passes on). Words Fermix did not
  write (a job's name, the failure's sentence, the provider's words) are
  quoted as data and cut to a bound, with any double quote inside them turned
  to a single one so none can close the quote early. Nothing else of the
  facts reaches the text: no id, no tool output, nothing a run's model wrote.
  """

  alias FermixCore.Clock
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.Error, as: ProviderError

  @max_length 1_200
  @name_max 80
  @failure_text_max 300
  @words_max 200

  @doc "The longest text `build/2` returns."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc "The message for a heal's facts."
  @spec build(map(), keyword()) :: String.t()
  def build(%{subject_kind: kind} = facts, clock_opts)
      when kind in ["job", "provider"] and is_list(clock_opts) do
    facts
    |> lines(clock_opts)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.slice(0, @max_length)
  end

  defp lines(%{subject_kind: "job", job: job} = facts, opts) do
    [
      "Job #{quoted(job.name, @name_max)} failed on #{Clock.stated_instant(facts.failed_at, opts)}. " <>
        "The error: #{quoted(facts.failure_text, @failure_text_max)}",
      words_line(facts),
      how_often(facts.recent),
      next_run(job, opts)
    ]
  end

  defp lines(%{subject_kind: "provider"} = facts, opts) do
    [
      "Scheduled jobs are failing on #{provider_label(facts.subject_id)}. " <>
        "The error: #{quoted(facts.failure_text, @failure_text_max)}",
      words_line(facts),
      "#{runs_failed(facts.run_count)} this way since " <>
        "#{Clock.stated_instant(facts.opened_at, opts)}: #{jobs_list(facts.jobs, facts.job_count)}."
    ]
  end

  # The provider's own words, when the failure's sentence does not already
  # quote them.
  defp words_line(%{failure_words: words, failure_text: text})
       when is_binary(words) and words != "" do
    unless String.contains?(text, words), do: "It said: #{quoted(words, @words_max)}"
  end

  defp words_line(_facts), do: nil

  defp how_often(%{same: same, of: of}) when same > 1,
    do: "#{same} of its last #{of} runs ended this way."

  defp how_often(_recent), do: nil

  defp next_run(%{enabled?: false}, _opts), do: "It is paused."
  defp next_run(%{state: "paused"}, _opts), do: "It is paused."
  defp next_run(%{state: "completed"}, _opts), do: "It will not run again."

  defp next_run(%{next_run_at: %DateTime{} = next}, opts),
    do: "It runs next on #{Clock.stated_instant(next, opts)}."

  defp next_run(_job, _opts), do: nil

  defp runs_failed(1), do: "1 run has failed"
  defp runs_failed(count), do: "#{count} runs have failed"

  defp jobs_list(jobs, job_count) do
    named = Enum.map_join(jobs, ", ", &"#{quoted(&1.name, @name_max)} (#{&1.runs})")

    case job_count - length(jobs) do
      more when more > 0 -> "#{named}, and #{more} more"
      _none -> named
    end
  end

  # A provider the engine knows is named as every reply names it; any other
  # id is shown as it is stored.
  defp provider_label(id) do
    case Enum.find(Descriptor.ids(), &(Atom.to_string(&1) == id)) do
      nil -> ProviderError.provider_label(id)
      provider -> ProviderError.provider_label(provider)
    end
  end

  defp quoted(text, max) when is_binary(text) do
    flat = text |> String.replace("\"", "'") |> String.split() |> Enum.join(" ")
    cut = if String.length(flat) > max, do: String.slice(flat, 0, max - 1) <> "…", else: flat
    "\"" <> cut <> "\""
  end
end
