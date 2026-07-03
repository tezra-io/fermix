defmodule FermixCore.Tools.Watch do
  @moduledoc """
  Start a live, attended WATCH: a supervised loop that observes the user's screen
  (via computer_use) or a page the agent is driving (via browser) and delivers an
  update to this conversation whenever something relevant to the task changes,
  until stopped with `stop_watch`. Read-only by default — it reports, it does not
  mutate.

  Refused for an unattended origin (a background/scheduled turn) — that is a
  `schedule_job`, not a watch.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry
  alias FermixCore.Watch.SessionManager

  @impl true
  def name, do: "watch"

  @impl true
  def description do
    "Start a live, attended watch loop that keeps observing OVER TIME and reports as " <>
      "things change — NOT a one-off look. It watches what's on the user's screen " <>
      "(via computer_use) or a page you are driving (via browser) and delivers an " <>
      "update to THIS conversation whenever something relevant to the task changes, " <>
      "until stopped with stop_watch. For a SINGLE look or action right now, call " <>
      "computer_use or browser directly, not watch. Read-only — it reports, it does " <>
      "not click or type."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["task"],
      properties: %{
        task: %{
          type: "string",
          description:
            "What to watch and what to report/do when it changes, e.g. " <>
              "\"tell me when the build in my terminal finishes\"."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "For CONTINUOUS, in-the-moment monitoring while the user is present — observe " <>
      "the user's live screen or a browser session you're driving and report/react " <>
      "as it changes, without the user pinging you each time (e.g. \"watch my screen " <>
      "and tell me when the download finishes\", \"reply when my opponent moves\"). " <>
      "A single look right now is computer_use or browser directly, NOT watch; " <>
      "later/recurring/background checks are schedule_job, NOT watch. Use this ONLY " <>
      "for attended, live, over-time watching. Read-only — it reports, it doesn't act."
  end

  @impl true
  def examples do
    [
      %{
        args: %{"task" => "tell me when the progress bar on my screen reaches 100%"},
        note: "attended screen watch"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_task", description: "no task describing what to watch"},
      %{tag: "no_conversation", description: "no conversation to report back to"},
      %{tag: "unattended", description: "refused from a background/scheduled turn"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :gui

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    result = do_execute(args, context)
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec(name(), context, success, duration, input: args, result: result)
    result
  end

  defp do_execute(args, context) do
    task = args |> Map.get("task", "") |> to_string() |> String.trim()

    cond do
      task == "" ->
        {:ok, Tool.error("watch requires a 'task' describing what to watch")}

      not Map.has_key?(context, :conversation_key) ->
        {:ok, Tool.error("watch needs a conversation to report back to")}

      true ->
        start_watch(task, context)
    end
  end

  defp start_watch(task, context) do
    case SessionManager.ensure(context, task: task) do
      {:ok, _pid} ->
        {:ok,
         Tool.success(
           "Watching: #{task}. I'll message you here when something relevant changes; " <>
             "say \"stop watching\" to end it."
         )}

      {:error, {:watch_refused, origin}} ->
        {:ok,
         Tool.error(
           "watch needs an attended session (interactive or voice); it can't run " <>
             "unattended (#{origin}). For a background/scheduled check, use schedule_job."
         )}

      {:error, reason} ->
        {:ok, Tool.error("could not start watch: #{inspect(reason)}")}
    end
  end
end
