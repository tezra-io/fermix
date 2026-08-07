defmodule FermixCore.Tools.EventRemove do
  @moduledoc """
  Soft-cancel a stored temporal event and its unsent reminders (MILESTONE_30 §7.1,
  §12.1).

  Cancellation is soft: the event row and its delivered reminder history stay
  queryable, and only pending reminders are cancelled. Like `event_update`, a
  reminder that is being sent right now blocks the cancel — a channel send
  cannot be recalled.

  Two shapes, one tool. The owner names an event, or says "cancel that" right
  after a reminder arrived — in which case the referent is resolved from the
  outbox exactly as `reminder_snooze` resolves "snooze that": the most recent
  reminder DELIVERED into this exact conversation within the last 24 hours, for
  this owner, and the event behind it is what gets cancelled. Nothing is ever
  guessed across conversations or owners; with no match the tool says so and the
  agent asks. The result carries the whole canonical event, so the reply names
  what ended — for a yearly event, every future occurrence with it.

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
  def name, do: "event_remove"

  @impl true
  @spec description() :: String.t()
  def description do
    "Cancel a stored event and its unsent reminders — by id, or with no id for " <>
      "\"cancel that\", which cancels the event behind the most recent reminder Fermix " <>
      "delivered in this conversation. Delivered reminder history is kept."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: [],
      properties: %{
        event_id: %{
          type: "string",
          description:
            "The stored event's id from event_list. Leave it out for \"cancel that\" or " <>
              "\"stop reminding me about this\": the event behind the last reminder " <>
              "delivered in this conversation within the past 24 hours. With nothing " <>
              "delivered here the tool says so and you ask the owner which event they mean."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "The owner asks to remove, cancel, or forget a stored event — including \"cancel " <>
      "that\" or \"stop reminding me about this\" right after a reminder arrived."
  end

  @impl true
  def examples do
    [
      %{args: %{"event_id" => "evt_abc"}, note: "cancel a named stored event"},
      %{args: %{}, note: "\"cancel that\" right after a reminder arrived"}
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "no_recent_reminder", description: "nothing was delivered here to cancel"},
      %{tag: "not_found", description: "no such event"},
      %{tag: "delivery_in_progress", description: "a reminder is being sent; retry shortly"},
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
      remove(args, context)
    else
      {:ok, Tool.error(Access.refusal(name()))}
    end
  end

  defp remove(args, context) do
    case Map.get(args, "event_id") do
      id when is_binary(id) and id != "" -> cancel(id, context)
      nil -> cancel_referent(context)
      other -> {:ok, Tool.error(invalid_event_id(other))}
    end
  end

  defp invalid_event_id(value) do
    Registry.describe_error({:invalid_param, "event_id=#{inspect(value)}"})
  end

  defp cancel(id, context) do
    case Registry.cancel_event(id, context) do
      {:ok, event} -> {:ok, Tool.success(Jason.encode!(view(event)))}
      {:error, reason} -> {:ok, Tool.error(Registry.describe_error(reason))}
    end
  end

  # The anchor is part of the acknowledgement: the owner said "that", and the
  # reply has to be able to say which reminder that was.
  defp cancel_referent(context) do
    case Registry.cancel_referent(context) do
      {:ok, %{event: event, source: source}} -> {:ok, Tool.success(anchored(event, source))}
      {:error, reason} -> {:ok, Tool.error(Registry.describe_error(reason))}
    end
  end

  defp anchored(event, source) do
    event
    |> view()
    |> Map.put("source_reminder_id", source.id)
    |> Jason.encode!()
  end

  defp view(event) do
    event
    |> Registry.event_view()
    |> Map.put("status", "cancelled")
  end
end
