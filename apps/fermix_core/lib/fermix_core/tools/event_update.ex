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
    {"rebind_delivery_to_default", :rebind_delivery_to_default}
  ]

  @impl true
  @spec name() :: String.t()
  def name, do: "event_update"

  @impl true
  @spec description() :: String.t()
  def description do
    "Change a stored event: its title, date or time, recurrence, or reminder plan, or " <>
      "rebind it to the current default delivery channel. Fields left out keep their " <>
      "stored values."
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
        rebind_delivery_to_default: %{
          type: "boolean",
          description:
            "Re-snapshot the current configured default delivery target and regenerate " <>
              "unsent reminders on it. Only on the owner's explicit request."
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
        args: %{
          "event_id" => "evt_abc",
          "when" => %{"type" => "datetime", "date" => "2026-08-16", "time" => "16:00:00"}
        },
        note: "move an appointment"
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

  defp view(%{event: event, reminders: reminders}) do
    event
    |> Registry.event_view()
    |> Map.merge(%{
      "status" => "updated",
      "planned_reminders" => Enum.map(reminders, &Registry.reminder_view/1)
    })
  end
end
