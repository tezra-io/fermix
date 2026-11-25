defmodule FermixCore.Jobs.HealMessage do
  @moduledoc """
  The message a heal sends the owner (M106 §5.4, §5.8, §5.9), built by code
  from Fermix's own facts (`Memory.Repo.JobHealsSql`'s `{:message_facts, id}`):
  what failed and when, how often, and when the job runs next; for a
  provider, which one, its own words, and which jobs since when.

  Runs that ended ok without working (M106 §6, kind `tool_never_succeeded`)
  get code's own sentence for the kind: for a job, which tool never worked
  in its last runs though each ended without an error (and for its verdict,
  that it still does not); for a plugin, which plugin and tool, and which
  jobs since when. The tool's last words are quoted as its own.

  A diagnosed heal's message (stage S3) adds, after those facts, the heal
  run's note as Fermix's reading of the failure (newlines flattened, cut to a
  bound), then one line saying what Fermix did (it asked for the job to run
  again, raised its time limit, or paused it) or what it would change (each
  changed field with its new value quoted and cut to a bound, a long task's
  full text left to the job's record, and nothing said of how the owner says
  yes). A
  fix that did not hold gets one message of its own, the verdict: the job is
  still failing after what Fermix did, and how it failed this time.

  Pure: the facts in, the text out, every instant on the owner's clock
  (`FermixCore.Clock`, whose options `build/2` passes on). Words Fermix did not
  write (a job's name, the failure's sentence, the provider's words, a
  proposed value) are quoted as data and cut to a bound, with any double
  quote inside them turned to a single one so none can close the quote early.
  Nothing else of the facts reaches the text: no id, no tool output, and of
  what a model wrote only the note.
  """

  alias FermixCore.Clock
  alias FermixCore.Jobs.Degraded
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.Error, as: ProviderError

  @max_length 3_000
  @name_max 80
  @failure_text_max 300
  @words_max 200
  @note_max 500
  @value_max 160
  @degraded "tool_never_succeeded"

  @doc "The longest text `build/2` returns."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc "The message for a heal's facts."
  @spec build(map(), keyword()) :: String.t()
  def build(%{subject_kind: kind, conclusion: conclusion} = facts, clock_opts)
      when kind in ["job", "provider", "plugin"] and conclusion in ["first", "verdict"] and
             is_list(clock_opts) do
    facts
    |> lines(clock_opts)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.slice(0, @max_length)
  end

  defp lines(
         %{subject_kind: "job", conclusion: "verdict", failure_kind: @degraded, job: job} = facts,
         opts
       ) do
    [
      "Job #{quoted(job.name, @name_max)} is still not working after Fermix #{done(facts)}: " <>
        "on #{Clock.stated_instant(facts.failed_at, opts)} #{tool_phrase(facts)} " <>
        "failed on every call again, though the run ended without an error.",
      tool_words_line(facts),
      next_run(job, opts)
    ]
  end

  defp lines(%{subject_kind: "job", failure_kind: @degraded, job: job} = facts, opts) do
    [
      "Job #{quoted(job.name, @name_max)} ran without #{tool_phrase(facts)} working: " <>
        "every call to it failed in each of its last #{Degraded.runs()} runs, though each run " <>
        "ended without an error. The last ended on #{Clock.stated_instant(facts.failed_at, opts)}.",
      tool_words_line(facts),
      note_line(facts.note),
      move_line(facts.decision, facts.change),
      unless(facts.decision == "pause", do: next_run(job, opts))
    ]
  end

  defp lines(%{subject_kind: "job", conclusion: "verdict", job: job} = facts, opts) do
    [
      "Job #{quoted(job.name, @name_max)} is still failing after Fermix #{done(facts)}. " <>
        "It failed again on #{Clock.stated_instant(facts.failed_at, opts)}. " <>
        "The error: #{quoted(facts.failure_text, @failure_text_max)}",
      words_line(facts),
      next_run(job, opts)
    ]
  end

  defp lines(%{subject_kind: "job", job: job} = facts, opts) do
    [
      "Job #{quoted(job.name, @name_max)} failed on #{Clock.stated_instant(facts.failed_at, opts)}. " <>
        "The error: #{quoted(facts.failure_text, @failure_text_max)}",
      words_line(facts),
      how_often(facts.recent),
      note_line(facts.note),
      move_line(facts.decision, facts.change),
      unless(facts.decision == "pause", do: next_run(job, opts))
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

  # A plugin's tool that never worked, across the jobs that call it (§5.4).
  defp lines(%{subject_kind: "plugin"} = facts, opts) do
    [
      "Scheduled jobs cannot use the plugin #{quoted(facts.subject_id, @name_max)}: every call " <>
        "to #{tool_phrase(facts)} failed in each of #{Degraded.runs()} runs in a row, " <>
        "though each run ended without an error.",
      tool_words_line(facts),
      "#{runs_ended(facts.run_count)} this way since " <>
        "#{Clock.stated_instant(facts.opened_at, opts)}: #{jobs_list(facts.jobs, facts.job_count)}."
    ]
  end

  # The tool by its name, or, when its stored record could not be read, as
  # one of the job's tools.
  defp tool_phrase(%{tool: %{"name" => name}}), do: "its tool #{quoted(name, @name_max)}"
  defp tool_phrase(%{tool: nil}), do: "one of its tools"

  # The tool's own last words, someone else's: quoted as data.
  defp tool_words_line(%{failure_words: words}) when is_binary(words) and words != "",
    do: "The tool said: #{quoted(words, @words_max)}"

  defp tool_words_line(_facts), do: nil

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

  # The heal run's note, as Fermix's reading under its own facts.
  defp note_line(note) when is_binary(note) and note != "",
    do: "Fermix's reading: " <> cut(flat(note), @note_max)

  defp note_line(_none), do: nil

  # What Fermix did alone, or what it would change and has not.
  # Said before the run is asked for, so it says what holds whatever the
  # Scheduler answers: the run was asked for (`Jobs.HealRun` records what came
  # of it).
  defp move_line("rerun", _change), do: "Fermix has asked for it to run again now."

  defp move_line("raise_limit", %{"timeout_seconds" => %{"from" => from, "to" => to}}) do
    {from_words, to_words} = durations(from, to)
    "Fermix raised its time limit from #{from_words} to #{to_words}."
  end

  defp move_line("pause", _change), do: "Fermix paused it; it will not run until you resume it."

  defp move_line("propose", change) when is_map(change) do
    {changes, cut?} = proposal(change)
    full = if cut?, do: " (the full text is in the job's record)", else: ""
    "Fermix would #{changes}#{full}. Nothing has been changed yet."
  end

  defp move_line(_tell_or_none, _change), do: nil

  # What a fix that did not hold was.
  defp done(%{decision: "raise_limit", change: %{"timeout_seconds" => %{"to" => to}}}),
    do: "raised its time limit to #{duration(to)}"

  defp done(_rerun), do: "asked for it to run again"

  # "change its task to … and its schedule to …, and remove the model it is
  # pinned to": each field's phrase under its verb, and whether a value was cut.
  defp proposal(change) do
    phrases = change |> Enum.sort() |> fields() |> Enum.map(&field_phrase/1)
    cut? = Enum.any?(phrases, fn {_verb, _text, cut?} -> cut? end)

    verbs =
      ["change", "remove"]
      |> Enum.map(fn verb -> {verb, for({^verb, text, _cut?} <- phrases, do: text)} end)
      |> Enum.reject(fn {_verb, texts} -> texts == [] end)
      |> Enum.map(fn {verb, texts} -> verb <> " " <> join_phrases(texts) end)

    {Enum.join(verbs, ", and "), cut?}
  end

  # A pin's provider and model are one change; so are a delivery's mode and
  # target.
  defp fields(sorted) do
    map = Map.new(sorted)

    sorted
    |> Enum.reject(fn {field, _} -> field in ["model", "delivery_target"] end)
    |> Enum.map(fn
      {"provider", provider} -> {:pin, provider, Map.get(map, "model")}
      {"delivery_mode", mode} -> {:delivery, mode, Map.get(map, "delivery_target")}
      {field, value} -> {field, value}
    end)
    |> add_lone(map, "model", fn model -> {:pin, nil, model} end)
    |> add_lone(map, "delivery_target", fn target -> {:delivery, nil, target} end)
  end

  defp add_lone(fields, map, key, wrap) do
    partner = if key == "model", do: "provider", else: "delivery_mode"

    if Map.has_key?(map, key) and not Map.has_key?(map, partner),
      do: fields ++ [wrap.(Map.fetch!(map, key))],
      else: fields
  end

  defp field_phrase({"task", %{"to" => task}}) do
    {text, cut?} = quoted_cut(task, @value_max)
    {"change", "its task to #{text}", cut?}
  end

  defp field_phrase({"schedule", %{"to" => schedule}}),
    do: {"change", "its schedule to #{quoted(schedule, @value_max)}", false}

  defp field_phrase({"skill_name", %{"to" => skill}}),
    do: {"change", "the skill it uses to #{quoted(skill, @value_max)}", false}

  defp field_phrase({"timeout_seconds", %{"to" => seconds}}),
    do: {"change", "its time limit to #{duration(seconds)}", false}

  defp field_phrase({"clear_route_pin", _change}),
    do: {"remove", "the model it is pinned to", false}

  defp field_phrase({:pin, provider, model}) do
    pin = [to(provider), to(model)] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
    {"change", "the model it is pinned to to #{quoted(pin, @value_max)}", false}
  end

  defp field_phrase({:delivery, mode, target}) do
    where = delivery_words(to(mode), to(target))
    {"change", "where it delivers to #{quoted(where, @value_max)}", false}
  end

  defp to(%{"to" => value}), do: value
  defp to(nil), do: nil

  # A mode and the platform it reaches; never a chat's id.
  defp delivery_words(mode, %{"platform" => platform}) when is_binary(mode),
    do: "#{mode}, on #{platform}"

  defp delivery_words(mode, _target) when is_binary(mode), do: mode
  defp delivery_words(nil, %{"platform" => platform}), do: "on #{platform}"

  defp join_phrases([one]), do: one

  defp join_phrases(phrases),
    do: Enum.join(Enum.drop(phrases, -1), ", ") <> " and " <> List.last(phrases)

  # Both ends of a raise in one unit: minutes when both are whole minutes.
  defp durations(from, to) when rem(from, 60) == 0 and rem(to, 60) == 0,
    do: {"#{div(from, 60)}", "#{div(to, 60)} minutes"}

  defp durations(from, to), do: {"#{from}", "#{to} seconds"}

  defp duration(seconds) when rem(seconds, 3_600) == 0, do: plural(div(seconds, 3_600), "hour")
  defp duration(seconds) when rem(seconds, 60) == 0, do: plural(div(seconds, 60), "minute")
  defp duration(seconds), do: plural(seconds, "second")

  defp plural(1, unit), do: "1 #{unit}"
  defp plural(n, unit), do: "#{n} #{unit}s"

  defp next_run(%{enabled?: false}, _opts), do: "It is paused."
  defp next_run(%{state: "paused"}, _opts), do: "It is paused."
  defp next_run(%{state: "completed"}, _opts), do: "It will not run again."

  defp next_run(%{next_run_at: %DateTime{} = next}, opts),
    do: "It runs next on #{Clock.stated_instant(next, opts)}."

  defp next_run(_job, _opts), do: nil

  defp runs_failed(1), do: "1 run has failed"
  defp runs_failed(count), do: "#{count} runs have failed"

  defp runs_ended(1), do: "1 run has ended"
  defp runs_ended(count), do: "#{count} runs have ended"

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

  defp quoted(text, max) when is_binary(text), do: text |> quoted_cut(max) |> elem(0)

  defp quoted_cut(text, max) when is_binary(text) do
    flat = text |> String.replace("\"", "'") |> flat()
    {"\"" <> cut(flat, max) <> "\"", String.length(flat) > max}
  end

  defp flat(text), do: text |> String.split() |> Enum.join(" ")

  defp cut(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end
end
