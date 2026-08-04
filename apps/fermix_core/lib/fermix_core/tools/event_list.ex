defmodule FermixCore.Tools.EventList do
  @moduledoc """
  List and search stored temporal events (MILESTONE_30 §12.1, §15.3).

  Each row carries the next occurrence, the stored reminder plan, the next due
  reminder, the last delivery state and error, and the snapshotted delivery
  platform — never channel credentials. Results default to 25 rows, cap at 100,
  accept at most a two-year date window per call, and page with an opaque cursor
  the model passes back verbatim. With no window and no status the list answers
  "what is coming up" and starts at today; history needs an explicit `from`/`to`
  or an explicit `status`.

  Attended-owner-only at both advertisement and execution through the one
  `Temporal.Access` predicate.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Temporal.Access
  alias FermixCore.Temporal.Registry
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @kinds ~w(birthday anniversary appointment deadline event follow_up explicit_reminder)
  @statuses ~w(active completed cancelled any)

  @impl true
  @spec name() :: String.t()
  def name, do: "event_list"

  @impl true
  @spec description() :: String.t()
  def description do
    "List or search the owner's stored events — what is coming up, when a birthday is, " <>
      "which reminders are planned, and whether any reminder failed to deliver. " <>
      "Defaults to active events from today onward; pass from/to or status to see history. " <>
      "Covers only events stored in Fermix — a connected calendar (e.g. Google Calendar) " <>
      "is a separate source with its own tools."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      properties: %{
        text: %{type: "string", description: "Match against title and description."},
        kind: %{type: "string", enum: @kinds, description: "Restrict to one event kind."},
        status: %{
          type: "string",
          enum: @statuses,
          description:
            "Defaults to active; \"any\" includes completed and cancelled events. Naming a " <>
              "status also drops the from-today floor, so past events become visible."
        },
        from: %{
          type: "string",
          description:
            "Earliest occurrence date, YYYY-MM-DD. Without it the list starts at today; " <>
              "pass a past date to include events that have already happened."
        },
        to: %{
          type: "string",
          description: "Latest occurrence date, YYYY-MM-DD. At most two years after from."
        },
        limit: %{type: "integer", description: "Rows per page; default 25, cap 100."},
        cursor: %{type: "string", description: "Opaque next-page cursor from a prior call."}
      }
    }
  end

  @impl true
  def when_to_use do
    ~s(Answer "what do I have coming up", "when is Sarah's birthday", or check whether ) <>
      "a reminder was delivered."
  end

  @impl true
  def examples do
    [
      %{args: %{}, note: "the owner's upcoming events"},
      %{args: %{"text" => "Sarah"}, note: "search stored events by text"}
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "date_window_too_wide", description: "the from/to window exceeds two years"},
      %{tag: "invalid_cursor", description: "the cursor did not come from a prior call"},
      %{
        tag: "not_attended",
        description:
          "the turn is neither an attended top-level owner turn nor an " <>
            "operator-created scheduled run"
      }
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :scheduling

  @doc """
  Attended owner turns plus operator-created scheduled runs (§12.1 read
  carve-out); the same predicate re-runs inside `execute/2`.
  """
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context), do: Access.operator_read_turn?(context)

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
    if Access.operator_read_turn?(context) do
      list(args, context)
    else
      {:ok, Tool.error(Access.read_refusal(name()))}
    end
  end

  defp list(args, context) do
    case Registry.list_events(filter(args), context) do
      {:ok, page} -> {:ok, Tool.success(Jason.encode!(view(page)))}
      {:error, reason} -> {:ok, Tool.error(Registry.describe_error(reason))}
    end
  end

  defp view(%{events: events, cursor: cursor}) do
    %{"events" => Enum.map(events, &Registry.event_view/1), "cursor" => cursor}
  end

  defp filter(args) do
    %{}
    |> copy(args, "text", :text)
    |> copy(args, "kind", :kind)
    |> copy(args, "from", :from)
    |> copy(args, "to", :to)
    |> copy(args, "limit", :limit)
    |> copy(args, "cursor", :cursor)
    |> put_status(args)
  end

  defp copy(filter, args, key, field) do
    case Map.fetch(args, key) do
      {:ok, value} -> Map.put(filter, field, value)
      :error -> filter
    end
  end

  defp put_status(filter, args) do
    case Map.get(args, "status") do
      nil -> filter
      "any" -> Map.put(filter, :status, :any)
      status -> Map.put(filter, :status, status)
    end
  end
end
