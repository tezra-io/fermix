defmodule FermixCore.Tools.RecallActivity do
  @moduledoc """
  Owner-only query over the on-device computer-history activity memories
  (MILESTONE_32 §11.2). Answers "what was I working on this morning?", "what did
  I do yesterday?" from derived summaries — **never** the raw event spool
  (§9.4). Gated by the single `ComputerHistory.Gate`: advertised and executed
  only on an attended operator turn whose whole route chain is local-or-granted,
  so activity never rides an ungranted-remote wire. Advertisement is a readiness
  signal, never the only barrier — `execute/2` re-checks the Gate (the
  place_search discipline).

  Naming avoids the `memory_recall` / "history" (message-history) collision
  (§13.4): the model-facing tool is `recall_activity`.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.ComputerHistory.Gate
  alias FermixCore.ComputerHistory.Recall
  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.Support

  @windows ~w(today yesterday this_morning this_afternoon this_week recent)

  @impl true
  def name, do: "recall_activity"

  @impl true
  def description,
    do:
      "Recall what the owner was doing on their computer (apps, pages, documents) from " <>
        "on-device activity memory. Owner-only; returns summaries, never raw keystrokes."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        window: %{
          type: "string",
          enum: @windows,
          description:
            "Time window to recall, in the owner's timezone. Defaults to \"today\". " <>
              "\"recent\" is the last few hours."
        }
      }
    }
  end

  @impl true
  def when_to_use,
    do:
      "When the owner asks what they were working on, which app/page/document they had open, " <>
        "or to summarize their recent computer activity for a standup or recap."

  @impl true
  def category, do: :memory

  @doc "Advertised only when the Gate permits the tool this turn (owner, attended, permitted chain)."
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context),
    do: Gate.allow?(Gate.snapshot(context), {:tool_advertise, context})

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), Map.delete(context, :tool_trace), fn -> run(args, context) end)
  end

  # The Gate is re-checked here — advertisement is never the only barrier (§14.1).
  defp run(args, context) do
    if Gate.allow?(Gate.snapshot(context), {:tool_execute, context}) do
      window = Map.get(args, "window", "today")
      repo = Map.get(context, :memory_repo, Repo)

      case Recall.query(window, repo: repo) do
        {:ok, text} ->
          {:ok, Tool.success(text)}

        {:error, reason} ->
          {:ok, Tool.error("Could not read activity memory: #{inspect(reason)}")}
      end
    else
      {:ok, Tool.error("Computer history is not available on this turn.")}
    end
  end
end
