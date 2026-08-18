defmodule FermixCore.Tools.ListMeetings do
  @moduledoc """
  List the meetings the notetaker has been asked to attend (MILESTONE_21 C2 §14.1).

  `scope: "active"` answers "is the notetaker in a meeting right now"; the
  default `"recent"` answers "what has it been to", newest first. Each row is
  the stored meeting record — its platform, its status, when it started and
  ended, where its artifacts live, and the error that ended it if one did — so
  a meeting that failed says so instead of quietly not appearing.

  Attended-owner-only at advertisement and at execution, through the same
  `Temporal.Access` predicate the temporal event tools use: the rows are the
  owner's own meetings.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Meetings
  alias FermixCore.Memory.Repo
  alias FermixCore.Temporal.Access
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @scopes ~w(active recent)

  @impl true
  @spec name() :: String.t()
  def name, do: "list_meetings"

  @impl true
  @spec description() :: String.t()
  def description do
    "List the meetings Fermix's notetaker has been asked to attend, newest first — " <>
      "their ids, platforms, titles, statuses, and when they ran. Pass scope \"active\" " <>
      "to see only the meeting it is in right now. Use it to find the id leave_meeting " <>
      "needs, or to answer what happened to a meeting's notes."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      properties: %{
        scope: %{
          type: "string",
          enum: @scopes,
          description:
            "\"recent\" (default) lists past and present meetings newest first; " <>
              "\"active\" lists only a meeting running right now."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "Answer whether the notetaker is in a meeting, or find a meeting's id or outcome."
  end

  @impl true
  def examples do
    [
      %{args: %{}, note: "the recent meetings, newest first"},
      %{args: %{"scope" => "active"}, note: "only a meeting running right now"}
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "invalid_scope", description: "scope is not active or recent"},
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
    case scope(args) do
      {:ok, scope} -> list(scope, context)
      {:error, message} -> {:ok, Tool.error(message)}
    end
  end

  defp list(scope, context) do
    opts = [scope: scope, store_opts: [server: Map.get(context, :memory_repo, Repo)]]

    case Meetings.list(opts) do
      {:ok, meetings} -> {:ok, Tool.success(Jason.encode!(%{"meetings" => meetings}))}
      {:error, reason} -> {:ok, Tool.error("Listing meetings failed: #{inspect(reason)}.")}
    end
  end

  # The scope reaches a Repo query, so it is matched against the two known
  # values rather than converted from whatever string arrived.
  defp scope(args) do
    case Map.get(args, "scope") do
      nil ->
        {:ok, :recent}

      "recent" ->
        {:ok, :recent}

      "active" ->
        {:ok, :active}

      other ->
        {:error, "Invalid scope #{inspect(other)}; use one of: #{Enum.join(@scopes, ", ")}."}
    end
  end

  defp refusal do
    "#{name()} is available only on an attended, top-level turn the owner is present " <>
      "for. Guest, scheduled, background, delegated, and coding-continuation runs cannot " <>
      "use the meeting notetaker."
  end
end
