defmodule FermixCore.Tools.RecallActivity do
  @moduledoc """
  Owner-only query over the on-device computer-history activity memories
  (MILESTONE_32 §11.2, §24.4). Answers "what am I working on?" from the current
  work threads, "what did I do yesterday?" from the dated session notes, and
  "which pages about X?" by topic — all from derived summaries, **never** the raw
  event spool (§9.4). Gated by the single `ComputerHistory.Gate`: advertised and executed
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

  @windows ~w(current today yesterday this_morning this_afternoon this_week recent)

  @impl true
  def name, do: "recall_activity"

  @impl true
  def description,
    do:
      "Recall what the owner is working on or was doing on their computer (apps, pages, " <>
        "documents) from on-device activity memory: a time window, the current threads of " <>
        "work, or a topic. Owner-only; returns summaries, never raw keystrokes. Results are " <>
        "dated, newest first, and bounded; when older entries were omitted the answer says " <>
        "so, and a narrower window or topic returns them."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        window: %{
          type: "string",
          enum: @windows,
          description:
            ~s|Time window to recall, in the owner's timezone. Defaults to "today". | <>
              ~s|"recent" is the last few hours; "current" is what the owner is working | <>
              ~s|on now (the active threads of work, dated by when each was last touched) | <>
              ~s|rather than a window of time.|
        },
        about: %{
          type: "string",
          description:
            "Optional topic to search activity for — a word or two, matched against the " <>
              "summaries, page titles and URLs of both threads and sittings. When given, " <>
              "window is ignored and results come from every date on record."
        }
      }
    }
  end

  @impl true
  def when_to_use,
    do:
      "When the owner asks what they were working on, what they are working on now, which " <>
        "app/page/document they had open, where something about a topic was, or to summarize " <>
        "their recent computer activity for a standup or recap."

  @impl true
  def category, do: :memory

  @doc """
  Advertised only when the Gate permits the tool this turn (owner, attended,
  permitted chain). Reads the turn's frozen snapshot from
  `context.computer_history_gate` when present, so advertisement, the section,
  and the taint stamp share one per-turn decision.
  """
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context),
    do: Gate.allow?(turn_snapshot(context), {:tool_advertise, context})

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), Map.delete(context, :tool_trace), fn -> run(args, context) end)
  end

  # The Gate is re-checked here — advertisement is never the only barrier
  # (§14.1). Same frozen turn snapshot as advertisement: a mid-turn enable can
  # never open the tool inside a turn that started denied, and a mid-turn
  # disable keeps the stamp consistent with what actually flowed.
  defp run(args, context) do
    if Gate.allow?(turn_snapshot(context), {:tool_execute, context}) do
      recall(args, Map.get(context, :memory_repo, Repo))
    else
      {:ok, Tool.error("Computer history is not available on this turn.")}
    end
  end

  # A topic answers from every date on record, so it replaces the window rather
  # than narrowing it — one read per call, never both.
  defp recall(args, repo) do
    args
    |> Map.get("about")
    |> read(args, repo)
    |> reply()
  end

  defp read(about, _args, repo) when is_binary(about) and about != "",
    do: Recall.search(about, repo: repo)

  defp read(_about, args, repo),
    do: Recall.query(Map.get(args, "window", "today"), repo: repo)

  defp reply({:ok, text}), do: {:ok, Tool.success(text)}

  # A topic with no searchable word is the caller's mistake, not a store failure:
  # say what to do instead of showing an error atom.
  defp reply({:error, :empty_query}),
    do: {:ok, Tool.error("Give a word or two to search activity for.")}

  defp reply({:error, reason}),
    do: {:ok, Tool.error("Could not read activity memory: #{inspect(reason)}")}

  defp turn_snapshot(context),
    do: Map.get(context, :computer_history_gate) || Gate.snapshot(context)
end
