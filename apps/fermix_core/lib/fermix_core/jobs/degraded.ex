defmodule FermixCore.Jobs.Degraded do
  @moduledoc """
  Whether a scheduled job's ok run ended without working (M106 §6), decided
  by code at the run's settle from the tool tallies of the run and of the
  job's runs before it. Pure, as `Jobs.Retry.decide/1` is: the settle reads
  the tallies in its transaction and opens the heal
  (`Memory.Repo.JobHealsSql`).

  A tally is a whole-run fact the runner stores beside the timeline: each
  tool the run called, with how many of its calls succeeded (`ok`), failed
  (`error`) or were still running when the run ended (`unfinished`), its
  plugin when it is a plugin's, and its last error's own words. It reads no
  words: only whether a call succeeded.

  A tool trips the rule when, in each of the job's last `runs/0` runs (the
  one settling and the ones settled before it), it was called, none of its
  calls succeeded, and at least one finished and failed. An unfinished call
  is no success, and alone it is no failure. A run with no tally (settled
  before tallies were kept, or by the Scheduler after its runner died), a
  run that did not call the tool, and a job with fewer runs each break the
  streak. When several tools trip it, one is chosen: a plugin's tool first,
  then the most failed calls over the runs, then the name.

  `readable_tally/1` is the one place that decides whether a stored tally is
  one this engine can read. One it cannot (text that is not JSON, not a list,
  an entry of another shape, as a damaged row or a later engine sharing the
  home could leave) proves nothing and reads as no tally, so the store never
  raises on one. `worked?/2` is what an ok run proves of a heal about one
  tool: that the tool succeeded in it.
  """

  # The runs in a row a tool must never have worked in: an internal constant,
  # never a setting.
  @runs 3

  @typedoc "One tool's calls in one run, as the run's facts store it (string keys)."
  @type entry :: %{required(String.t()) => term()}

  @typedoc "A run's tally, or nil for a run that has none."
  @type tally :: [entry()] | nil

  @typedoc """
  The tool that tripped the rule: its name, its plugin in the newest run (nil
  for a tool of no plugin), its failed calls in each run newest first, and
  the last error's words of the newest run (nil when it gave none).
  """
  @type tool :: %{
          name: String.t(),
          plugin: String.t() | nil,
          failed_calls: [pos_integer()],
          last_error: String.t() | nil
        }

  @doc """
  A stored tally as this engine reads it: `{:ok, tally}` for JSON text (or
  a decoded list) of well-formed entries, `{:ok, nil}` for none, and
  `:unreadable` for anything else. An entry is well-formed with a text
  `name`, non-negative integer `ok` and `error` counts, and, when present, a
  non-negative integer `unfinished`, a text `plugin` and a text `last_error`;
  a key another engine added is read past. Pure: the store logs an
  unreadable one and reads it as none.
  """
  @spec readable_tally(String.t() | list() | nil) :: {:ok, [entry()] | nil} | :unreadable
  def readable_tally(nil), do: {:ok, nil}

  def readable_tally(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_list(decoded) -> readable_tally(decoded)
      _not_a_list -> :unreadable
    end
  end

  def readable_tally(tally) when is_list(tally),
    do: if(Enum.all?(tally, &entry?/1), do: {:ok, tally}, else: :unreadable)

  def readable_tally(_other), do: :unreadable

  @doc "Whether `name` succeeded at least once in a run with this tally."
  @spec worked?([entry()] | nil, String.t()) :: boolean()
  def worked?(nil, name) when is_binary(name), do: false

  def worked?(tally, name) when is_list(tally) and is_binary(name),
    do: Enum.any?(tally, &(&1["name"] == name and &1["ok"] > 0))

  @doc "How many runs in a row a tool must never have worked in."
  @spec runs() :: pos_integer()
  def runs, do: @runs

  @doc """
  The tool that never worked in any of the runs' tallies, newest run first,
  or `:none`. Anything but exactly `runs/0` tallies is `:none`.
  """
  @spec decide([tally()]) :: :none | {:tool, tool()}
  def decide(tallies) when is_list(tallies) do
    never_worked = Enum.map(tallies, &never_worked/1)

    if length(tallies) == @runs and Enum.all?(never_worked, &is_map/1),
      do: never_worked |> candidates() |> pick(),
      else: :none
  end

  # The run's tools with no success and at least one failed call, by name;
  # nil for a run with no tally.
  defp never_worked(nil), do: nil

  defp never_worked(tally) when is_list(tally) do
    for %{"name" => name, "ok" => ok, "error" => error} = entry <- Enum.map(tally, &checked/1),
        ok == 0 and error > 0,
        into: %{},
        do: {name, entry}
  end

  defp entry?(%{"name" => name, "ok" => ok, "error" => error} = entry)
       when is_binary(name) and is_integer(ok) and ok >= 0 and is_integer(error) and error >= 0 do
    known?(entry, "unfinished", &(is_integer(&1) and &1 >= 0)) and
      known?(entry, "plugin", &is_binary/1) and known?(entry, "last_error", &is_binary/1)
  end

  defp entry?(_other), do: false

  defp known?(entry, key, check) do
    case Map.get(entry, key) do
      nil -> true
      value -> check.(value)
    end
  end

  defp checked(%{"name" => name, "ok" => ok, "error" => error} = entry)
       when is_binary(name) and is_integer(ok) and ok >= 0 and is_integer(error) and error >= 0,
       do: entry

  defp candidates([newest | _older] = runs) do
    for {name, entry} <- newest, Enum.all?(runs, &Map.has_key?(&1, name)) do
      %{
        name: name,
        plugin: Map.get(entry, "plugin"),
        failed_calls: Enum.map(runs, &get_in(&1, [name, "error"])),
        last_error: Map.get(entry, "last_error")
      }
    end
  end

  defp pick([]), do: :none

  defp pick(candidates) do
    {:tool, Enum.min_by(candidates, &{is_nil(&1.plugin), -Enum.sum(&1.failed_calls), &1.name})}
  end
end
