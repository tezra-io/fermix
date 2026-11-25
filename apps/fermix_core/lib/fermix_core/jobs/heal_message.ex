defmodule FermixCore.Jobs.HealMessage do
  @moduledoc """
  The message a heal sends the owner (M106 §5.4, §5.8, §5.9), built by code
  from Fermix's own facts (`Memory.Repo.JobHealsSql`'s `{:message_facts, id}`):
  what failed and when, how often, and when the job runs next; for a
  provider, which one, its own words, and which jobs since when.

  What failed is Fermix's own sentence for the failure's kind
  (`Jobs.Failure.sentence/2`, the heal's `failure_text`), stated after the
  job's name and never quoted. Only words someone else wrote are quoted, and
  introduced as theirs: the provider's ("OpenAI said:"), a tool's ("The tool
  said:"), and the text of a failure Fermix has no sentence for ("The error
  said:"). For that kind (`other`) the stated sentence is always code's, and a
  stored `failure_text` that is not it (an older engine's raw text, a seeded
  heal's) is quoted as the error's own words, never stated as Fermix's.

  Runs that ended ok without working (M106 §6, kind `tool_never_succeeded`)
  get code's own sentence for the kind: for a job, which tool never worked
  in its last runs though each ended without an error (and for its verdict,
  that it still does not); for a plugin, which plugin and tool, and the jobs
  it affects by name, with no count or "since", which would start at the run
  that opened the heal. The tool's last words are quoted as its own.

  A diagnosed heal's message (stage S3) adds, after those facts, the heal
  run's note as Fermix's reading of the failure (newlines flattened, cut to a
  bound), then one line saying what Fermix did (it asked for the job to run
  again, raised its time limit, or paused it). A fix that did not hold gets
  one message of its own, the verdict: the job is still failing after what
  Fermix did, and how it failed this time; after a change the owner
  approved, that the change did not fix it.

  A proposal (stage S4, decision D5) is stated short: what failed, in code's
  sentence; the note; then one line per changed field (`change_lines/2`) with
  its new value only, a task as its changed part (the common start and end
  trimmed to whole words: what replaces what, never both whole texts); then
  one closing line saying Fermix has not made the change. It says nothing on
  how to answer: the proposal's card, which the owner answers, is the next
  stage. How often and when the job runs next are left out. A value is shown
  whole or not at all: one past the bound, or a task change of spacing or
  quote marks only (which a quoted line cannot show), says so and that Fermix
  can show it in full, as `list_jobs` holds the exact change.

  Pure: the facts in, the text out, every instant on the owner's clock
  (`FermixCore.Clock`, whose options `build/2` passes on). Words Fermix did not
  write (a job's name, the provider's or a tool's words, an error's own text,
  a proposed value) are quoted as data and cut to a bound, with any double
  quote inside them turned to a single one so none can close the quote early.
  Nothing else of the facts reaches the text: no id, no tool output, and of
  what a model wrote only the note.
  """

  alias FermixCore.Clock
  alias FermixCore.Jobs.Degraded
  alias FermixCore.Jobs.Failure
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.Error, as: ProviderError

  @max_length 3_000
  @name_max 80
  @failure_text_max 300
  @words_max 200
  @note_max 500
  @value_max 160
  @degraded "tool_never_succeeded"

  @note_left_out "Fermix's reading: sent to the owner with this message; it is not kept in " <>
                   "this history."
  @proposal_lead "Fermix would change:"
  @proposal_closing "Fermix has not made this change."
  @longer_task "a longer rewrite than fits here."
  @longer_value "a longer value than fits here."
  @spacing_only "a change of spacing or quote marks only."
  @shown_in_full %{
    proposed: "Fermix can show it in full.",
    applied: "The job's settings show it in full."
  }

  @doc """
  A job's name as every message shows it inside its quotes: a double quote
  turned single, whitespace flattened, cut to the bound. What the owner reads
  of a job's name, and what Fermix's account of an answer names
  (`Jobs.HealAnswer`).
  """
  @spec shown_name(String.t()) :: String.t()
  def shown_name(name) when is_binary(name), do: cut(shown(name), @name_max)

  @doc """
  The copy of a heal's message that is written to the conversation's history
  (§5.8, §9): `text` as sent, every line of it Fermix's own (the facts, the
  change's lines, the closing line) kept as it is, and the heal run's note,
  the one line a model wrote after reading outside content, left out and
  said to be left out. The owner has the note in the message sent; the main
  agent reads it only through `get_job_run`, which counts as an outside
  source for its turn. History is no outside source and compaction would
  carry a frame's words on without the frame, so the note is never kept
  there. A message with no note line is its own copy.
  """
  @spec history_copy(String.t(), String.t() | nil) :: String.t()
  def history_copy(text, note) when is_binary(text) do
    case note_line(note) do
      nil -> text
      line -> String.replace(text, line, @note_left_out, global: false)
    end
  end

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
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.slice(0, @max_length)
  end

  # The verdict after a change the owner approved (§5.9, D5).
  defp lines(
         %{
           subject_kind: "job",
           conclusion: "verdict",
           decision: "propose",
           failure_kind: @degraded,
           job: job
         } = facts,
         opts
       ) do
    [
      "The change you approved did not fix job #{quoted(job.name, @name_max)}: on " <>
        "#{Clock.stated_instant(facts.failed_at, opts)} #{tool_phrase(facts)} failed on " <>
        "every call again, though the run ended without an error.",
      tool_words_line(facts),
      next_run(job, opts)
    ]
  end

  defp lines(
         %{subject_kind: "job", conclusion: "verdict", decision: "propose", job: job} = facts,
         opts
       ) do
    [
      "The change you approved did not fix job #{quoted(job.name, @name_max)}: it failed " <>
        "again on #{Clock.stated_instant(facts.failed_at, opts)}. " <> stated(facts),
      words_line(facts),
      next_run(job, opts)
    ]
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
      unless(facts.decision in ["pause", "propose"], do: next_run(job, opts))
    ]
  end

  defp lines(%{subject_kind: "job", conclusion: "verdict", job: job} = facts, opts) do
    [
      "Job #{quoted(job.name, @name_max)} is still failing after Fermix #{done(facts)}. " <>
        "It failed again on #{Clock.stated_instant(facts.failed_at, opts)}. " <> stated(facts),
      words_line(facts),
      next_run(job, opts)
    ]
  end

  defp lines(%{subject_kind: "job", job: job} = facts, opts) do
    [
      "Job #{quoted(job.name, @name_max)} failed on #{Clock.stated_instant(facts.failed_at, opts)}. " <>
        stated(facts),
      words_line(facts),
      unless(facts.decision == "propose", do: how_often(facts.recent)),
      note_line(facts.note),
      move_line(facts.decision, facts.change),
      unless(facts.decision in ["pause", "propose"], do: next_run(job, opts))
    ]
  end

  defp lines(%{subject_kind: "provider"} = facts, opts) do
    [
      "Scheduled jobs are failing on #{provider_label(facts.subject_id)}. " <> stated(facts),
      words_line(facts),
      "#{runs_failed(facts.run_count)} this way since " <>
        "#{Clock.stated_instant(facts.opened_at, opts)}: #{jobs_list(facts.jobs, facts.job_count)}."
    ]
  end

  # A plugin's tool that never worked, across the jobs that call it (§5.4).
  # The jobs are named; no count or "since" is stated, since the heal holds
  # only the runs from the one that opened it, not the days before.
  defp lines(%{subject_kind: "plugin"} = facts, _opts) do
    [
      "Scheduled jobs cannot use the plugin #{quoted(facts.subject_id, @name_max)}: every call " <>
        "to #{tool_phrase(facts)} failed in each of #{Degraded.runs()} runs in a row, " <>
        "though each run ended without an error.",
      tool_words_line(facts),
      "It affects these jobs: #{jobs_named(facts.jobs, facts.job_count)}."
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

  # Fermix's own sentence for the failure, stated as Fermix's. For a failure
  # Fermix has no sentence for, that sentence is code's, whatever the heal
  # stored: a stored text there is the failure's own (an older engine's or a
  # seeded heal's), so it is quoted (`words_line/1`), never stated.
  defp stated(%{failure_kind: "other"}), do: Failure.sentence(:other)
  defp stated(%{failure_text: text}), do: text |> flat() |> cut(@failure_text_max)

  # Words someone else wrote, quoted as data and introduced as theirs: the
  # provider's own, or the text of a failure Fermix has no sentence for.
  defp words_line(%{failure_kind: "other"} = facts) do
    case other_words(facts) do
      nil -> nil
      words -> "The error said: #{quoted(words, @words_max)}"
    end
  end

  defp words_line(%{failure_words: words} = facts) when is_binary(words) and words != "",
    do: "#{whose_words(facts)} said: #{quoted(words, @words_max)}"

  defp words_line(_facts), do: nil

  defp other_words(%{failure_words: words}) when is_binary(words) and words != "", do: words

  defp other_words(%{failure_text: text}) when is_binary(text) and text != "" do
    if text == Failure.sentence(:other), do: nil, else: text
  end

  defp other_words(_facts), do: nil

  defp whose_words(%{subject_kind: "provider", subject_id: provider}),
    do: provider_label(provider)

  defp whose_words(_facts), do: "The provider"

  defp how_often(%{same: same, of: of}) when same > 1,
    do: "#{same} of its last #{of} runs ended this way."

  defp how_often(_recent), do: nil

  # The heal run's note, as Fermix's reading under its own facts.
  defp note_line(note) when is_binary(note) and note != "",
    do: "Fermix's reading: " <> shown_note(note)

  defp note_line(_none), do: nil

  defp shown_note(note), do: note |> flat() |> cut(@note_max)

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

  # The proposal (D5): one line per changed field, then that it is not made.
  defp move_line("propose", change) when is_map(change) do
    [@proposal_lead, Enum.map(change_lines(change, :proposed), &("- " <> &1)), @proposal_closing]
  end

  defp move_line(_tell_or_none, _change), do: nil

  # What a fix that did not hold was.
  defp done(%{decision: "raise_limit", change: %{"timeout_seconds" => %{"to" => to}}}),
    do: "raised its time limit to #{duration(to)}"

  defp done(_rerun), do: "asked for it to run again"

  @doc """
  Each changed field of a heal's proposal as one line, built by code from the
  stored change (M106 §5.8, D5): its label and its new value only, in a fixed
  order (task, schedule, skill, time limit, model, delivery); a pin's
  provider and model, and a delivery's mode and target, are one line each.
  A task is shown as its changed part: the common start and end trimmed to
  whole words, then the words added, the words removed, what replaces what,
  or the new text alone when nothing is in common, never both whole texts.
  Every value is quoted data (a double quote turned single, whitespace
  flattened) and shown whole or not at all: past the bound, or a task change
  of spacing or quote marks only, the line says so and where it can be read
  in full (`tail`: `:proposed` for the proposal, `:applied` for the account
  of a change the owner's answer made). No id or chat is ever shown.
  """
  @spec change_lines(map(), :proposed | :applied) :: [String.t()]
  def change_lines(change, tail) when is_map(change) and is_map_key(@shown_in_full, tail) do
    [
      task: Map.get(change, "task"),
      schedule: Map.get(change, "schedule"),
      skill: Map.get(change, "skill_name"),
      timeout: Map.get(change, "timeout_seconds"),
      model: pin_change(change),
      delivery: delivery_change(change)
    ]
    |> Enum.reject(fn {_field, value} -> is_nil(value) end)
    |> Enum.map(&field_line(&1, Map.fetch!(@shown_in_full, tail)))
  end

  defp pin_change(%{"clear_route_pin" => _cleared}), do: :cleared

  defp pin_change(change) do
    case Enum.reject([to(change["provider"]), to(change["model"])], &is_nil/1) do
      [] -> nil
      pin -> Enum.map_join(pin, " ", &text/1)
    end
  end

  defp delivery_change(change) do
    if Map.has_key?(change, "delivery_mode") or Map.has_key?(change, "delivery_target"),
      do: delivery_words(to(change["delivery_mode"]), to(change["delivery_target"])),
      else: nil
  end

  defp field_line({:task, %{"to" => new} = task}, in_full),
    do: task_line(text(Map.get(task, "from") || ""), text(new), in_full)

  defp field_line({:schedule, %{"to" => value}}, in_full),
    do: value_line("Schedule", value, in_full)

  defp field_line({:skill, %{"to" => value}}, in_full), do: value_line("Skill", value, in_full)

  defp field_line({:timeout, %{"to" => seconds}}, _in_full) when is_integer(seconds),
    do: "Time limit: #{duration(seconds)}"

  defp field_line({:timeout, %{"to" => value}}, in_full),
    do: value_line("Time limit", value, in_full)

  defp field_line({:model, :cleared}, _in_full), do: "Model: none pinned (the default route)"
  defp field_line({:model, pin}, in_full), do: value_line("Model", pin, in_full)
  defp field_line({:delivery, words}, in_full), do: value_line("Delivery", words, in_full)

  defp value_line(label, value, in_full),
    do: parts_line(label, [text(value)], &hd/1, @longer_value, in_full)

  # What replaces what in a task, by the part that changed (`task_part/2`).
  defp task_line(from, new, in_full) do
    {old_part, new_part, whole?} = task_part(from, new)

    cond do
      shown(old_part) == shown(new_part) ->
        "Task: #{@spacing_only} #{in_full}"

      whole? ->
        parts_line("Task", [new_part], &hd/1, @longer_task, in_full)

      shown(old_part) == "" ->
        parts_line("Task", [new_part], &"adds #{hd(&1)}", @longer_task, in_full)

      shown(new_part) == "" ->
        parts_line("Task", [old_part], &"removes #{hd(&1)}", @longer_task, in_full)

      true ->
        parts_line("Task", [old_part, new_part], &replaced/1, @longer_task, in_full)
    end
  end

  defp replaced([old, new]), do: "#{old} becomes #{new}"

  # A line whose every part is shown whole and quoted, or none of them.
  defp parts_line(label, parts, render, longer, in_full) do
    if Enum.all?(parts, &(String.length(shown(&1)) <= @value_max)),
      do: "#{label}: " <> render.(Enum.map(parts, &("\"" <> shown(&1) <> "\""))),
      else: "#{label}: #{longer} #{in_full}"
  end

  # The part of `from` and `to` that differs, its ends moved out to whole
  # words (a boundary is the text's start or end, or beside whitespace), each
  # part trimmed, and whether the two had no word in common at all.
  defp task_part(from, to) do
    a = String.graphemes(from)
    b = String.graphemes(to)
    {ta, tb} = {List.to_tuple(a), List.to_tuple(b)}
    {la, lb} = {tuple_size(ta), tuple_size(tb)}

    p = snap(prefix_length(ta, tb, 0, min(la, lb)), &(boundary?(ta, &1) and boundary?(tb, &1)))
    max_s = min(la, lb) - p
    raw_s = suffix_length(ta, tb, 0, max_s)
    s = snap(raw_s, &(boundary?(ta, la - &1) and boundary?(tb, lb - &1)))

    common = Enum.join(Enum.take(a, p)) <> Enum.join(Enum.drop(a, la - s))
    old_part = a |> Enum.slice(p, la - p - s) |> Enum.join() |> String.trim()
    new_part = b |> Enum.slice(p, lb - p - s) |> Enum.join() |> String.trim()
    {old_part, new_part, String.trim(common) == ""}
  end

  defp prefix_length(ta, tb, i, max) when i < max do
    if elem(ta, i) == elem(tb, i), do: prefix_length(ta, tb, i + 1, max), else: i
  end

  defp prefix_length(_ta, _tb, i, _max), do: i

  defp suffix_length(ta, tb, k, max) when k < max do
    if elem(ta, tuple_size(ta) - 1 - k) == elem(tb, tuple_size(tb) - 1 - k),
      do: suffix_length(ta, tb, k + 1, max),
      else: k
  end

  defp suffix_length(_ta, _tb, k, _max), do: k

  # Back off to the nearest length that ends on a boundary; bounded by `n`.
  defp snap(0, _boundary?), do: 0
  defp snap(n, boundary?), do: if(boundary?.(n), do: n, else: snap(n - 1, boundary?))

  defp boundary?(t, i) when i == 0 or i == tuple_size(t), do: true
  defp boundary?(t, i), do: blank?(elem(t, i - 1)) or blank?(elem(t, i))

  defp blank?(grapheme), do: String.trim(grapheme) == ""

  defp to(%{"to" => value}), do: value
  defp to(_absent), do: nil

  # A mode and the platform it reaches; never a chat's id.
  defp delivery_words(mode, %{"platform" => platform}) when is_binary(mode),
    do: "#{mode}, on #{platform}"

  defp delivery_words(mode, _target) when is_binary(mode), do: mode
  defp delivery_words(nil, %{"platform" => platform}), do: "on #{platform}"
  defp delivery_words(nil, _target), do: "no destination"

  # A stored value as text: the stored shape is someone else's to keep, so a
  # value of another type is shown as data rather than raising here.
  defp text(value) when is_binary(value), do: value
  defp text(value), do: inspect(value)

  # A value as the message shows it inside its quotes.
  defp shown(text), do: text |> String.replace("\"", "'") |> flat()

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

  defp jobs_named(jobs, job_count) do
    named = Enum.map_join(jobs, ", ", &quoted(&1.name, @name_max))

    case job_count - length(jobs) do
      more when more > 0 -> "#{named}, and #{more} more"
      _none -> named
    end
  end

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

  defp quoted(text, max) when is_binary(text), do: "\"" <> cut(shown(text), max) <> "\""

  defp flat(text), do: text |> String.split() |> Enum.join(" ")

  defp cut(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end
end
