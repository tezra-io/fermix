defmodule FermixCore.Management.Cues.WatcherRow do
  @moduledoc """
  One watcher as the management socket publishes it (M60 app surface §3.4),
  read-only: watchers are made and changed in a consent turn in chat, so the
  row carries no actions.

  `state` is `paused` (switched off), `needs_update` (it breaks a rule a save
  now enforces, M60_CUE_INTAKE_AT_SCALE.md §3.1, so it gets nothing until a
  change in chat), `held` (its filter cannot reach its model) or `on`. Every
  `llm` watcher filters with the one Cues filter model. A watcher is its ids,
  switches, budgets and counts; `purpose`, `listen_for` and `instructions` are
  the owner's own words and travel on `cues.watchers.get` alone, and examples
  are counted, never shown. Decision reasons and filter hints never cross: a
  model wrote them from outside text.

  A watcher has a task, a follow-up or both (M60_WATCHER_CODING_RUNS.md §3.5):
  `task` is null for one with none, and `follow_up` is null for one with no
  follow-up, else its job, name, `mode` (`approve` or `auto`), whether an
  automatic one is `approved` (null for one that asks first), `state` (`ready`,
  or `held` while it cannot run: the owner's switch is off, or a tool or the
  channel it needs is not set up) and Fermix's sentence, which says what is
  missing and where to fix it while it is held. Read-only, like the rest.
  """

  alias FermixCore.Cues.Filter.Llm
  alias FermixCore.Cues.Overview

  @states ~w(on paused needs_update held)
  @follow_up_states ~w(ready held)

  @type facts :: %{window_s: pos_integer()}

  @doc "Every state a watcher row can carry."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "Every state a watcher's follow-up can carry."
  @spec follow_up_states() :: [String.t()]
  def follow_up_states, do: @follow_up_states

  @doc """
  What a watcher that needs an update (`Cues.Watchers.update_needed/2`) needs,
  in the owner's words: the row's sentence, and the setup page's.
  """
  @spec needs_update_sentence(:words | :filter) :: String.t()
  def needs_update_sentence(:words), do: "Needs words to listen for: update it in chat."

  def needs_update_sentence(:filter),
    do: "Passes everything, so it can't listen to a stream: give it a filter in chat."

  @doc "The row of one `Cues.Overview` watcher."
  @spec build(Overview.watcher(), facts()) :: map()
  def build(watcher, facts) when is_map(watcher) and is_map(facts) do
    state = state(watcher, facts)

    %{
      "id" => watcher.id,
      "name" => watcher.name,
      "enabled" => watcher.enabled?,
      "filter" => watcher.filter,
      "filter_model" => filter_model(watcher),
      "state" => state,
      "status_sentence" => sentence(state, watcher),
      "sources" => watcher.sources,
      "task" => task(watcher),
      "follow_up" => follow_up(watcher.follow_up),
      "task_notes" => watcher.task_notes?,
      "daily_cap" => watcher.daily_cap,
      "filter_budget" => watcher.filter_budget,
      "counts" => %{
        "offered" => watcher.offered,
        "waiting" => watcher.waiting,
        "passed" => watcher.passed,
        "dropped" => watcher.dropped,
        "acted" => watcher.acted,
        "failed" => watcher.failed
      },
      "instruction_count" => watcher.instruction_count,
      "created_at" => stamp(watcher.created_at)
    }
  end

  @doc """
  The row plus what `cues.watchers.get` adds from the stored watcher
  (`detail`, `CuesWatchersSql`'s `get_watcher`): its purpose, its words to
  listen for, its active instructions, and how many of its recent examples are
  marked each way.
  """
  @spec detail(map(), map()) :: map()
  def detail(row, stored) when is_map(row) and is_map(stored) do
    examples = Map.get(stored, :examples, [])

    Map.merge(row, %{
      "purpose" => Map.get(stored, :purpose),
      "listen_for" => Map.get(stored, :listen_for, []),
      "instructions" =>
        Enum.map(Map.get(stored, :instructions, []), fn instruction ->
          %{
            "number" => instruction.number,
            "text" => instruction.text,
            "added_at" => stamp(instruction.added_at)
          }
        end),
      "examples" => %{
        "pass" => Enum.count(examples, &(&1.label == "pass")),
        "drop" => Enum.count(examples, &(&1.label == "drop"))
      }
    })
  end

  defp state(%{enabled?: false}, _facts), do: "paused"
  defp state(%{needs_update: needed}, _facts) when not is_nil(needed), do: "needs_update"
  defp state(%{held?: true}, _facts), do: "held"
  defp state(_watcher, _facts), do: "on"

  defp sentence("paused", _watcher), do: "Paused."

  defp sentence("needs_update", watcher), do: needs_update_sentence(watcher.needs_update)

  defp sentence("held", %{waiting: 1}),
    do: "Held: it cannot reach its filter model. One item is waiting."

  defp sentence("held", watcher),
    do: "Held: it cannot reach its filter model. #{watcher.waiting} items are waiting."

  defp sentence("on", %{filter: "none", task_job_id: nil}),
    do: "Passes every item to its follow-up."

  defp sentence("on", %{filter: "none"}), do: "Passes every item to its task."
  defp sentence("on", _watcher), do: "Filtering normally."

  defp task(%{task_job_id: nil}), do: nil

  defp task(watcher),
    do: %{
      "job_id" => watcher.task_job_id,
      "name" => watcher.task_name,
      "paused" => watcher.task_paused?
    }

  defp follow_up(nil), do: nil

  defp follow_up(follow_up) do
    %{
      "job_id" => follow_up.job_id,
      "name" => follow_up.name,
      "mode" => follow_up.mode,
      "approved" => follow_up.approved?,
      "state" => if(follow_up.held, do: "held", else: "ready"),
      "status_sentence" => follow_up_sentence(follow_up)
    }
  end

  defp follow_up_sentence(%{held: held}) when is_binary(held), do: held

  defp follow_up_sentence(%{mode: "approve"}),
    do: "Asks first: you confirm each run on a short card."

  defp follow_up_sentence(%{approved?: true}),
    do: "Runs on its own on each passing item, within the daily cap."

  defp follow_up_sentence(_unapproved),
    do: "Asks first until you approve it to run on its own."

  # The one Cues filter model every `llm` watcher uses; null when that is the
  # main model, and for a watcher with no filter.
  defp filter_model(%{filter: "llm"}) do
    case Llm.configured() do
      %{model: nil} -> nil
      %{provider: provider, model: model} -> %{"provider" => provider, "model" => model}
    end
  end

  defp filter_model(_watcher), do: nil

  defp stamp(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp stamp(_absent), do: nil
end
