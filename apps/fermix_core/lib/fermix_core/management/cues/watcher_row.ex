defmodule FermixCore.Management.Cues.WatcherRow do
  @moduledoc """
  One watcher as the management socket publishes it (M60 app surface §3.4),
  read-only: watchers are made and changed in a consent turn in chat, so the
  row carries no actions.

  `state` is `paused` (switched off), `held` (its filter cannot reach its
  model) or `on`. An `llm` watcher with no model of its own filters with the
  default filter model, else the main model, so none waits for one. A watcher is its ids, switches, budgets and
  counts; `purpose` and `instructions` are the owner's own words and travel on
  `cues.watchers.get` alone, and examples are counted, never shown. Decision
  reasons and filter hints never cross: a model wrote them from outside text.
  """

  alias FermixCore.Cues.Overview

  @states ~w(on paused held)

  @type facts :: %{window_s: pos_integer()}

  @doc "Every state a watcher row can carry."
  @spec states() :: [String.t()]
  def states, do: @states

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
      "task" => %{
        "job_id" => watcher.task_job_id,
        "name" => watcher.task_name,
        "paused" => watcher.task_paused?
      },
      "task_notes" => watcher.task_notes?,
      "daily_cap" => watcher.daily_cap,
      "filter_budget" => watcher.filter_budget,
      "counts" => %{
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
  (`detail`, `CuesWatchersSql`'s `get_watcher`): its purpose, its active
  instructions, and how many of its recent examples are marked each way.
  """
  @spec detail(map(), map()) :: map()
  def detail(row, stored) when is_map(row) and is_map(stored) do
    examples = Map.get(stored, :examples, [])

    Map.merge(row, %{
      "purpose" => Map.get(stored, :purpose),
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

  defp state(%{held?: true}, _facts), do: "held"
  defp state(_watcher, _facts), do: "on"

  defp sentence("paused", _watcher), do: "Paused."

  defp sentence("held", %{waiting: 1}),
    do: "Held: it cannot reach its filter model. One item is waiting."

  defp sentence("held", watcher),
    do: "Held: it cannot reach its filter model. #{watcher.waiting} items are waiting."

  defp sentence("on", %{filter: "none"}), do: "Passes every item to its task."
  defp sentence("on", _watcher), do: "Filtering normally."

  defp filter_model(%{filter_model: model} = watcher) when is_binary(model) and model != "",
    do: %{"provider" => watcher.filter_provider, "model" => model}

  defp filter_model(_watcher), do: nil

  defp stamp(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp stamp(_absent), do: nil
end
