defmodule FermixCore.Tools.ReminderSnooze do
  @moduledoc """
  Defer one reminder to a later time (MILESTONE_30 §20).

  Two shapes, one tool. The owner names a reminder ("push the dentist reminder
  to tomorrow morning"), or says "snooze that" right after one arrived — in
  which case the source is resolved from the outbox: the most recent reminder
  DELIVERED into this exact conversation within the last 24 hours, for this
  owner. Nothing is ever guessed across conversations or owners; with no match
  the tool asks which event.

  A snooze creates ONE bounded ad-hoc reminder linked to its source. Repeating
  the same deferral returns the same row rather than a second reminder, a second
  snooze of the same source replaces the first, and a delivered source stays
  delivered — sent history is never rewritten. A time at or after the event
  itself needs the owner's explicit confirmation, because a reminder that lands
  after the thing it warns about is a different promise.

  Attended-owner-only at both advertisement and execution through the one
  `Temporal.Access` predicate.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Temporal.Access
  alias FermixCore.Temporal.Registry
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @impl true
  @spec name() :: String.t()
  def name, do: "reminder_snooze"

  @impl true
  @spec description() :: String.t()
  def description do
    "Push a reminder to a later time — \"snooze that for two hours\", or defer a " <>
      "specific stored reminder by id. Without an id the tool resolves the reminder " <>
      "Fermix most recently delivered in this conversation. It never moves the event " <>
      "itself; use event_update for that."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["snooze"],
      properties: %{
        reminder_id: %{
          type: "string",
          description:
            "The reminder to defer, from event_list. Leave it out for \"snooze that\", " <>
              "which resolves the last reminder delivered in this conversation."
        },
        snooze: %{
          type: "object",
          description:
            ~s(One tagged form: {"type":"duration","amount":2,"unit":"minutes"|"hours"|"days"} ) <>
              ~s(relative to now, or {"type":"datetime","date":"YYYY-MM-DD","time":"HH:MM:SS"} ) <>
              ~s(with an optional "utc_offset" when the local time is ambiguous.)
        },
        confirm_past_boundary: %{
          type: "boolean",
          description:
            "Only after the owner confirms a reminder that would arrive at or after the " <>
              "event itself. Never set this on your own."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "The owner wants a reminder again later: \"snooze that for two hours\", \"remind me " <>
      "about this again tomorrow at 9\", or a named reminder pushed back."
  end

  @impl true
  def examples do
    [
      %{
        args: %{"snooze" => %{"type" => "duration", "amount" => 2, "unit" => "hours"}},
        note: "\"snooze that for two hours\" right after a reminder arrived"
      },
      %{
        args: %{
          "reminder_id" => "rem_abc",
          "snooze" => %{"type" => "datetime", "date" => "2026-08-17", "time" => "09:00:00"}
        },
        note: "defer a named reminder to a specific local time"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_parameters", description: "snooze is absent or not a tagged form"},
      %{tag: "no_recent_reminder", description: "nothing was delivered here to snooze"},
      %{tag: "snooze_in_past", description: "the requested time is not in the future"},
      %{
        tag: "past_boundary_unconfirmed",
        description: "the time is at or after the event; confirm with the owner first"
      },
      %{tag: "source_delivering", description: "that reminder is being sent; retry shortly"},
      %{tag: "not_attended", description: "the turn is not an attended top-level owner turn"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :scheduling

  @doc "Attended-owner-only (§12.1); the same predicate re-runs inside `execute/2`."
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
      defer(args, context)
    else
      {:ok, Tool.error(Access.refusal(name()))}
    end
  end

  defp defer(args, context) do
    case Registry.snooze_reminder(params(args), context) do
      {:ok, result} -> {:ok, Tool.success(Jason.encode!(Registry.snooze_view(result)))}
      {:error, reason} -> {:ok, Tool.error(Registry.describe_error(reason))}
    end
  end

  defp params(args) do
    %{
      reminder_id: Map.get(args, "reminder_id"),
      snooze: Map.get(args, "snooze"),
      confirm_past_boundary: Map.get(args, "confirm_past_boundary")
    }
  end
end
