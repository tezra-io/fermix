defmodule FermixCore.Tools.LeaveMeeting do
  @moduledoc """
  Wind the notetaker out of the meeting it is in (MILESTONE_21 C2 §14.1).

  Leaving is not an abort: `FermixCore.Meetings.leave/2` takes the notetaker out
  of the room, summarizes what was captured, and delivers the notes. So the
  acknowledgement says the notes are still coming, and `:not_active` — a
  meeting whose row exists but whose session is already gone — is reported as
  "already ended", never as a failure to leave.

  Attended-owner-only at advertisement and at execution, through the same
  `Temporal.Access` predicate the temporal event tools use.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Meetings
  alias FermixCore.Memory.Repo
  alias FermixCore.Temporal.Access
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @impl true
  @spec name() :: String.t()
  def name, do: "leave_meeting"

  @impl true
  @spec description() :: String.t()
  def description do
    "Take Fermix's notetaker out of a meeting it is currently in, by meeting id. " <>
      "Leaving also ends the capture: Fermix summarizes what it heard and sends the " <>
      "notes, so tell the owner the notes are on their way rather than that the " <>
      "meeting was abandoned. Use list_meetings first if the id is not already known."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["id"],
      properties: %{
        id: %{
          type: "string",
          description: "The meeting id, as returned by join_meeting or list_meetings."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "The owner asks the notetaker to leave a meeting, or to stop taking notes on one."
  end

  @impl true
  def examples do
    [%{args: %{"id" => "mtg_9Xq2LmTfa0Q"}, note: "leave the meeting the notetaker is in"}]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "not_found", description: "no meeting with that id"},
      %{tag: "not_active", description: "that meeting has already ended"},
      %{tag: "not_attended", description: "the turn is not an attended top-level owner turn"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :scheduling

  @doc "Attended-owner-only; the same predicate re-runs inside `execute/2`."
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context), do: Access.attended_operator_turn?(context)

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    result = gated(args, context)
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec(name(), context, success, duration, input: args, result: result)
    result
  end

  defp gated(args, context) do
    if Access.attended_operator_turn?(context) do
      requested(args, context)
    else
      {:ok, Tool.error(refusal())}
    end
  end

  defp requested(args, context) do
    case Map.get(args, "id") do
      id when is_binary(id) and id != "" -> leave(id, context)
      _missing -> {:ok, Tool.error("Missing required parameter: id")}
    end
  end

  defp leave(id, context) do
    case Meetings.leave(id, store_opts: [server: Map.get(context, :memory_repo, Repo)]) do
      :ok -> {:ok, Tool.success(Jason.encode!(view(id)))}
      {:error, reason} -> {:ok, Tool.error(describe_error(reason))}
    end
  end

  defp view(id) do
    %{
      "id" => id,
      "status" => "leaving",
      "note" =>
        "The notetaker is leaving. It summarizes what it captured and delivers the notes " <>
          "as a message once that finishes."
    }
  end

  defp describe_error(:not_found) do
    "No meeting with that id. Use list_meetings to see the recent ones."
  end

  defp describe_error(:not_active) do
    "That meeting has already ended, so there is nothing to leave. Its notes were " <>
      "delivered when it finished."
  end

  defp describe_error(reason), do: "Leaving that meeting failed: #{inspect(reason)}."

  defp refusal do
    "#{name()} is available only on an attended, top-level turn the owner is present " <>
      "for. Guest, scheduled, background, delegated, and coding-continuation runs cannot " <>
      "use the meeting notetaker."
  end
end
