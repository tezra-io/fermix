defmodule FermixCore.Tools.EventUpdate do
  @moduledoc """
  Edit a stored temporal event (MILESTONE_30 §7.3, §12.1).

  A patch merges over the stored event, its time is re-resolved through the
  event's timezone, and the bounded plan is re-materialized under a new revision
  inside one Repo transaction: pending reminders from older revisions are
  cancelled while delivered and failed history stays immutable.
  `rebind_delivery_to_default: true` snapshots the CURRENT configured default
  target and regenerates unsent rows (§11.1).

  A reminder for this event that is being sent right now blocks the edit: a
  channel send cannot be recalled, so the tool asks the owner to try again
  rather than pretending it revoked an external side effect.

  Attended-owner-only at both advertisement and execution through the one
  `Temporal.Access` predicate.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Temporal.Access
  alias FermixCore.Temporal.Registry
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @kinds ~w(birthday anniversary appointment deadline event follow_up explicit_reminder)

  @patch_keys [
    {"title", :title},
    {"description", :description},
    {"kind", :kind},
    {"when", :when},
    {"timezone", :timezone},
    {"leap_day_policy", :leap_day_policy},
    {"reminders", :reminders},
    {"no_reminders", :no_reminders},
    {"followup", :followup},
    {"rebind_delivery_to_default", :rebind_delivery_to_default},
    {"owner_direction", :owner_direction}
  ]

  @impl true
  @spec name() :: String.t()
  def name, do: "event_update"

  @impl true
  @spec description() :: String.t()
  def description do
    "Change a stored event: its title, date or time, recurrence, or reminder plan, or " <>
      "rebind it to the current default delivery channel. Fields left out keep their " <>
      "stored values. Changing the date overwrites the stored one, and a name that " <>
      "matches while the date does not may belong to a different person or occasion, so " <>
      "a date change requires owner_direction: the owner's own words directing it. If " <>
      "there is nothing to quote, ask the owner instead of writing. " <>
      "Confirm back the date this edit left stored, absolutely and with its weekday, as " <>
      "the result's stated_as gives it: a relative phrase alone hands the ambiguity back " <>
      "to the owner instead of resolving it."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["event_id"],
      properties: %{
        event_id: %{type: "string", description: "The stored event's id from event_list."},
        title: %{type: "string", description: "New title."},
        description: %{type: "string", description: "New description."},
        kind: %{type: "string", enum: @kinds, description: "New event kind."},
        when: %{
          type: "object",
          description:
            "New time, in the same tagged forms event_store accepts (date, datetime, " <>
              "relative, annual)."
        },
        timezone: %{type: "string", description: "New IANA zone for the event."},
        leap_day_policy: %{type: "string", enum: ["feb_28", "mar_1"]},
        reminders: %{
          type: "array",
          items: %{type: "object"},
          description: "A replacement reminder plan; it replaces the stored one entirely."
        },
        no_reminders: %{type: "boolean", description: "Drop every reminder for this event."},
        followup: %{
          type: "boolean",
          description:
            "Set this for an occasion the owner would plausibly want help acting on — a " <>
              "message to send, something to prepare or decide — and clear it for a " <>
              "logistics ping that needs only the fact."
        },
        rebind_delivery_to_default: %{
          type: "boolean",
          description:
            "Re-snapshot the current configured default delivery target and regenerate " <>
              "unsent reminders on it. Only on the owner's explicit request."
        },
        owner_direction: %{
          type: "string",
          description:
            "Required to change the date: the owner's words that explicitly directed this " <>
              "date change, excerpted near-verbatim as just the directing clause. The " <>
              "owner stating their own new date, or asking to move a named event, counts. " <>
              "When the owner merely restated a date under a stored name, there is nothing " <>
              "here to quote — leave it absent and ask them which event they mean."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "Move an appointment, change a reminder plan, correct a stored date, or move an " <>
      "event's reminders to the current default channel."
  end

  @impl true
  def examples do
    [
      %{
        args: %{"event_id" => "evt_abc", "title" => "Dentist — rescheduled"},
        note: "retitle a stored event; a date change additionally needs owner_direction"
      },
      %{
        args: %{"event_id" => "evt_abc", "rebind_delivery_to_default" => true},
        note: "move its reminders to the current default channel"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_parameters", description: "event_id is absent"},
      %{tag: "not_found", description: "no such event"},
      %{
        tag: "overwrite_unconfirmed",
        description:
          "changing the stored date needs owner_direction quoting the owner; ask them first"
      },
      %{
        tag: "owner_direction_too_long",
        description: "owner_direction must be the directing clause, not the whole message"
      },
      %{tag: "delivery_in_progress", description: "a reminder is being sent; retry shortly"},
      %{tag: "ambiguous_local_time", description: "a DST gap or fold needs a clarification"},
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
      update(args, context)
    else
      {:ok, Tool.error(Access.refusal(name()))}
    end
  end

  defp update(args, context) do
    case Map.get(args, "event_id") do
      id when is_binary(id) and id != "" -> apply_patch(id, args, context)
      _absent -> {:ok, Tool.error(Registry.describe_error({:missing_param, "event_id"}))}
    end
  end

  defp apply_patch(id, args, context) do
    case Registry.update_event(id, patch(args), context) do
      {:ok, updated} -> {:ok, Tool.success(Jason.encode!(view(updated)))}
      {:error, reason} -> {:ok, Tool.error(Registry.describe_error(reason))}
    end
  end

  defp patch(args) do
    Enum.reduce(@patch_keys, %{}, fn {key, field}, acc ->
      case Map.fetch(args, key) do
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end

  # `previous` holds the prior value of exactly the user-facing fields this edit
  # changed, so the reply can state was-and-now from stored values instead of
  # from what the model remembers of the conversation. `stated_as` is the "now"
  # half stated absolutely, so a moved date is confirmed as the day it landed on
  # rather than as the relative phrase that moved it.
  defp view(%{event: event, reminders: reminders, previous: previous} = updated) do
    event
    |> Registry.event_view()
    |> Map.merge(%{
      "status" => "updated",
      "stated_as" => updated.stated_as,
      "previous" => previous,
      "planned_reminders" => Enum.map(reminders, &Registry.reminder_view/1)
    })
  end
end
