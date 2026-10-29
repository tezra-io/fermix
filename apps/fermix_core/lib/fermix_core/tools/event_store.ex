defmodule FermixCore.Tools.EventStore do
  @moduledoc """
  Store a durable personal event and its finite reminder plan (MILESTONE_30 §12.1).

  The tool owns the clock, the timezone, the dedupe identity, and the default
  delivery snapshot; the model supplies a title, a kind, and one tagged time
  form. The result is the canonical stored event, its next occurrence, its
  planned reminder times, its recurrence, and its delivery platform, so the
  acknowledgement can quote values that were actually persisted (§5.2). A
  failure returns a tool error and stores nothing.

  Attended-owner-only at both advertisement and execution through the one
  `Temporal.Access` predicate.

  `delivery: "computer"` (M76 §4.6) rings the reminder on this computer
  instead of the default target. The schema publishes it, and `when_to_use/1`
  the rule for choosing it, only where the build offers this computer
  (`Native.Notifications.offered?/1`), a fact of the build, so both are stable
  for the daemon's life. A test names the host as the context's `:host`
  (`BootProfile.host/0`'s shape), as `place_search` takes it.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Native.Notifications
  alias FermixCore.Temporal.Access
  alias FermixCore.Temporal.Registry
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @kinds ~w(birthday anniversary appointment deadline event follow_up explicit_reminder)

  @impl true
  @spec name() :: String.t()
  def name, do: "event_store"

  @impl true
  @spec description() :: String.t()
  def description do
    "Store a personal event — a birthday, anniversary, appointment, deadline, or an " <>
      "explicit 'remind me' — with a finite reminder plan Fermix delivers proactively " <>
      "through the configured default channel. Use this whenever the only future action " <>
      "is to notify the owner; use schedule_job when the future run must do work. " <>
      "A stored event sharing a name with this one but carrying a different date may " <>
      "belong to a different person or occasion, so ask the owner which it is before " <>
      "changing or duplicating it — unless they are correcting a date they themselves " <>
      "gave you, which needs no question. " <>
      "In the small hours after midnight a relative day word paired with a morning time " <>
      "does not name one date — the coming morning and the following calendar day are " <>
      "both live readings — so ask which is meant, naming both dates, before storing; " <>
      "settling the time instead leaves the day unsettled. " <>
      "Confirm back the date this actually stored, absolutely and with its weekday, as " <>
      "the result's stated_as gives it: a relative phrase alone hands the ambiguity back " <>
      "to the owner instead of resolving it."
  end

  @doc "The schema for this build (`dynamic_parameters/1`)."
  @impl true
  @spec parameters() :: map()
  def parameters, do: dynamic_parameters(%{})

  @doc "The provider-visible schema, with `delivery` only where this build offers this computer."
  @spec dynamic_parameters(map()) :: map()
  def dynamic_parameters(context) when is_map(context) do
    %{
      type: "object",
      required: ["title", "kind", "when"],
      properties: Map.merge(properties(), delivery_property(context))
    }
  end

  defp properties do
    %{
      title: %{type: "string", description: "Short event title, e.g. \"Sarah's birthday\"."},
      description: %{type: "string", description: "Optional extra detail."},
      kind: %{type: "string", enum: @kinds, description: "The event's shape."},
      when: %{
        type: "object",
        description:
          ~s(One tagged time form: {"type":"date","date":"YYYY-MM-DD"}, ) <>
            ~s({"type":"datetime","date":"YYYY-MM-DD","time":"HH:MM:SS"} with an ) <>
            ~s(optional "utc_offset" when the local time is ambiguous, ) <>
            ~s({"type":"relative","amount":2,"unit":"minutes"|"hours"|"days"|"weeks"}, ) <>
            ~s(days and weeks with an optional "time", or ) <>
            ~s({"type":"annual","month":9,"day":14} for a yearly date.)
      },
      timezone: %{
        type: "string",
        description:
          "IANA zone, only when the owner explicitly named one. Otherwise the tool " <>
            "reads the configured personalization timezone itself."
      },
      leap_day_policy: %{
        type: "string",
        enum: ["feb_28", "mar_1"],
        description: "Required for a yearly February 29 event. Ask the owner first."
      },
      reminders: %{
        type: "array",
        description:
          "Optional explicit plan that REPLACES the defaults. Each rule is " <>
            ~s({"type":"days_before","days":7,"at":"09:00:00"}, ) <>
            ~s({"type":"duration_before","minutes":60}, or {"type":"at_time"}.),
        items: %{type: "object"}
      },
      no_reminders: %{
        type: "boolean",
        description: "Store the date with no notifications. Only when the owner asks."
      }
    }
  end

  defp delivery_property(context) do
    if Notifications.offered?(native_opts(context)) do
      %{
        delivery: %{
          type: "string",
          enum: ["computer"],
          description:
            "Ring on this computer instead of the default target. Leave it out to use the " <>
              "default."
        }
      }
    else
      %{}
    end
  end

  @impl true
  def when_to_use, do: when_to_use(%{})

  @doc "The catalog rule, with the rule for choosing this computer only where it is offered."
  @spec when_to_use(map()) :: String.t()
  def when_to_use(context) when is_map(context) do
    "Store a date the owner stated whose only future action is notifying them: a " <>
      "birthday, anniversary, appointment, deadline, or an explicit reminder." <>
      computer_rule(Notifications.offered?(native_opts(context)))
  end

  defp computer_rule(true) do
    " Pass delivery \"computer\" when the owner asks for it to ring on this computer, or " <>
      "for a timer or a reminder minutes or hours away asked from this computer's own chat, " <>
      "a terminal, an editor, or a voice call; from a phone or a chat app, leave it out " <>
      "unless they name this computer."
  end

  defp computer_rule(false), do: ""

  @impl true
  def examples do
    [
      %{
        args: %{
          "title" => "Sarah's birthday",
          "kind" => "birthday",
          "when" => %{"type" => "annual", "month" => 9, "day" => 14}
        },
        note: "a yearly personal date"
      },
      %{
        args: %{
          "title" => "Submit the report",
          "kind" => "explicit_reminder",
          "when" => %{"type" => "relative", "amount" => 2, "unit" => "weeks"}
        },
        note: "an explicit one-shot reminder"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_parameters", description: "title, kind, or when is absent"},
      %{tag: "no_default_target", description: "no configured default delivery target"},
      %{tag: "ambiguous_local_time", description: "a DST gap or fold needs a clarification"},
      %{
        tag: "identity_conflict",
        description:
          "an active event of this identity is stored on a different date; the refusal " <>
            "names it so the owner can say whether it is the same one"
      },
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
      store(args, context)
    else
      {:ok, Tool.error(Access.refusal(name()))}
    end
  end

  defp store(args, context) do
    case Registry.create_event(params(args), context, registry_opts(context)) do
      {:ok, stored} -> {:ok, Tool.success(Jason.encode!(view(stored)))}
      {:error, reason} -> {:ok, Tool.error(Registry.describe_error(reason))}
    end
  end

  defp params(args) do
    %{
      title: Map.get(args, "title"),
      description: Map.get(args, "description"),
      kind: Map.get(args, "kind"),
      when: Map.get(args, "when"),
      timezone: Map.get(args, "timezone"),
      leap_day_policy: Map.get(args, "leap_day_policy"),
      reminders: Map.get(args, "reminders"),
      no_reminders: Map.get(args, "no_reminders"),
      delivery: Map.get(args, "delivery")
    }
  end

  # The host a test names; a turn names none, and this build's host decides.
  defp registry_opts(context), do: [native: native_opts(context)]

  defp native_opts(%{host: %{profile: _profile, os: _os} = host}), do: [host: host]
  defp native_opts(_context), do: []

  # `similar_events` is the owner's other active events of this kind: a twin
  # stored under a different title is invisible to the dedupe key, so the
  # acknowledgement carries it and the model can raise it before two people's
  # dates drift apart under one name. `stated_as` is the date this call actually
  # persisted, stated absolutely, so the confirmation quotes a stored value
  # rather than repeating the owner's relative phrasing back at them.
  defp view(%{status: status, event: event, reminders: reminders} = stored) do
    planned = Enum.map(reminders, &Registry.reminder_view/1)

    event
    |> Registry.event_view()
    |> Map.merge(%{
      "status" => Atom.to_string(status),
      "stated_as" => stored.stated_as,
      "planned_reminders" => planned,
      "similar_events" => stored.similar_events,
      "note" => note(status, planned)
    })
  end

  # §8.2: an event whose lead rules have all passed is still stored, and the
  # acknowledgement must say plainly that nothing is scheduled.
  defp note(:existing, _planned) do
    "This event was already stored; no second event or extra reminders were created."
  end

  defp note(:created, []) do
    "Stored, but no future reminder remains — add one with event_update if the owner wants one."
  end

  defp note(:created, _planned), do: nil
end
