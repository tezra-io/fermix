defmodule FermixCore.Temporal.Registry do
  @moduledoc """
  Validation and orchestration for temporal events (MILESTONE_30 §6.2, §7, §11.1,
  §12.2).

  This is the only layer that turns model-supplied event arguments into a
  persisted event. It owns:

    * **the clock and the timezone** — structured time input (§12.2) is resolved
      here against the configured `[fermix_core.personalization].timezone` (or an
      owner-named IANA zone) and the tool's current clock. A missing or invalid
      zone is an actionable error; UTC is never substituted for a personal date;
    * **the dedupe key** — derived from normalized identity, never model-authored
      (§7.1). Yearly events hash kind/title, one-time events also hash their
      resolved occurrence;
    * **the delivery-target snapshot** — the existing
      `[fermix_core.jobs] default_delivery_mode`/`default_delivery_target` pair
      read exactly as `Jobs.DeliveryDefaults` reads it, narrowed to the five
      proactive platforms and normalized through the §11.1 thread table; with
      no target configured, the owner's inbox is derived through the shared
      `Delivery.OwnerInbox` ladder (the same one skill-curation proposals use)
      and validated by those same §11.1 rules, so a fresh install with a
      configured channel can store events without a second config step;
    * **the compound Repo calls** — `Memory.Repo` owns every transaction; this
      module never opens one;
    * **the post-commit scheduler signal** — a best-effort cast that can never
      turn a committed write into a tool error (§10.3).

  It performs no channel I/O: adapter *resolvability* is checked at acceptance,
  the adapter itself is resolved live at delivery.
  """

  require Logger

  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Delivery.OwnerInbox
  alias FermixCore.Memory.Repo
  alias FermixCore.Temporal.Defaults
  alias FermixCore.Temporal.Planner
  alias FermixCore.Temporal.Telemetry, as: TemporalTelemetry

  # Referenced as a registered NAME only: the scheduler module is built
  # separately and this module must not compile-depend on it.
  @scheduler FermixCore.Temporal.Scheduler

  @kinds ~w(birthday anniversary appointment deadline event follow_up explicit_reminder)
  @platforms ~w(telegram slack discord signal whatsapp)
  @leap_policies ~w(feb_28 mar_1)
  @destination_keys ~w(chat_id channel_id recipient target reply_target)
  @ephemeral_keys ~w(reply_to req_options)
  @channel_modes ["channel"]
  @rejected_modes ["none", "origin", "local"]
  @relative_units %{"days" => 1, "weeks" => 7}
  @max_relative_days 3_650

  # Snooze (§20). The lookback is what "that" may reach; the cap is what one
  # deferral may span before it stops being a snooze and becomes an event edit.
  @snooze_units %{"minutes" => 60, "hours" => 3_600, "days" => 86_400}
  @snooze_lookback_hours 24
  @max_snooze_days 90
  @snooze_validity_seconds 7_200

  # Duplicate visibility (§5.2): how many same-kind neighbours one create
  # acknowledgement carries, and the user-facing fields an edit reports the
  # prior value of.
  @max_similar_events 5
  @previous_fields [
    :title,
    :kind,
    :timezone,
    :local_date,
    :local_time,
    :occurrence_at,
    :recurrence_month,
    :recurrence_day,
    :leap_day_policy
  ]

  @title_max 240
  @description_max 2_000
  @owner_direction_max 240
  @max_rule_days 3_650
  @max_rule_minutes 525_600
  @morning ~T[09:00:00]
  @cursor_separator "|"
  @utc "Etc/UTC"

  @patchable [
    :title,
    :description,
    :kind,
    :timezone,
    :leap_day_policy,
    :when,
    :reminders,
    :no_reminders
  ]

  @target_keys %{
    "platform" => :platform,
    "chat_id" => :chat_id,
    "channel_id" => :channel_id,
    "recipient" => :recipient,
    "target" => :target,
    "reply_target" => :reply_target,
    "thread_ts" => :thread_ts,
    "message_thread_id" => :message_thread_id,
    "reply_to" => :reply_to,
    "req_options" => :req_options
  }

  @type target :: %{platform: String.t(), destination: String.t(), thread_scope: String.t()}

  @doc """
  Validates and creates one event with its materialized reminder plan.

  Returns `{:ok, %{status: :created | :existing, event: row, reminders: rows,
  similar_events: rows}}`; `:existing` means an identical active event was
  already stored, so the caller must not claim a second set of reminders was
  created (§5.2).

  `:similar_events` is the other active events of the same kind this one could
  be a duplicate of, so a differently-titled twin is visible in the very
  acknowledgement that created it.
  """
  @spec create_event(map(), map(), keyword()) ::
          {:ok,
           %{
             status: :created | :existing,
             event: map(),
             reminders: [map()],
             similar_events: [map()]
           }}
          | {:error, term()}
  def create_event(params, context, opts \\ [])
      when is_map(params) and is_map(context) and is_list(opts) do
    now = now(opts)

    with {:ok, spec} <- build_spec(params, now, opts),
         {:ok, target} <- default_target(opts),
         {:ok, plan} <- materialize(spec, now),
         {:ok, origin} <- created_by_origin(context),
         attrs = create_attrs(spec, target, context, origin),
         {:ok, {status, event, reminders}} <-
           Repo.create_temporal_event(attrs, plan, now, server: repo(context)) do
      emit_materialized(status, event)
      notify(context)

      {:ok,
       %{
         status: status,
         event: with_delivery_source(event, target),
         reminders: reminders,
         similar_events: similar_events(status, event, context)
       }}
    end
  end

  @doc """
  Applies an owner edit (§7.3): merges the patch over the stored event,
  re-resolves its time, and re-materializes the bounded plan under a new
  revision. `rebind_delivery_to_default: true` snapshots the current configured
  default target instead of keeping the stored one.

  `:previous` carries the prior value of every user-facing field this edit
  actually changed, so the acknowledgement can state was-and-now from stored
  values alone (§5.2); it is empty when nothing user-facing moved.

  A patch carrying `:when` also requires `owner_direction`, a bounded excerpt of
  the owner's own directing words — the stored date is the one value an edit
  destroys rather than adds to. It is a control argument: never merged, never
  persisted, never read for content.
  """
  @spec update_event(String.t(), map(), map(), keyword()) ::
          {:ok, %{event: map(), reminders: [map()], previous: map()}} | {:error, term()}
  def update_event(id, patch, context, opts \\ [])
      when is_binary(id) and is_map(patch) and is_map(context) and is_list(opts) do
    now = now(opts)
    server = repo(context)

    with {:ok, existing} <- Repo.get_temporal_event(id, server: server),
         :ok <- ensure_active(existing),
         {:ok, fields} <- confirmed_patch(patch, existing),
         {:ok, params} <- merge_params(existing, fields),
         {:ok, spec} <- build_spec(params, now, opts),
         {:ok, target} <- patched_target(existing, fields, opts),
         {:ok, plan} <- materialize(spec, now),
         {:ok, {event, reminders}} <-
           Repo.update_temporal_event(id, column_map(spec, target), plan, now, server: server) do
      emit_materialized(event)
      notify(context)

      {:ok,
       %{
         event: with_delivery_source(event, target),
         reminders: reminders,
         previous: previous_values(existing, event)
       }}
    end
  end

  @doc "Soft-cancels an event and its unsent reminders; sent history stays queryable."
  @spec cancel_event(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def cancel_event(id, context, opts \\ [])
      when is_binary(id) and is_map(context) and is_list(opts) do
    with {:ok, event} <- Repo.cancel_temporal_event(id, now(opts), server: repo(context)) do
      emit_cancelled(event)
      notify(context)
      {:ok, event}
    end
  end

  @doc """
  Cancels the event behind the reminder this conversation last received (§8.4).

  "Cancel that" names no id, and the model cannot see the reminder it refers to —
  delivery inserts no conversation row. The referent is therefore resolved from
  the outbox through the same single lookup "snooze that" uses, and the resolved
  reminder's PARENT event is soft-cancelled with the ordinary `cancel_event`
  semantics. The resolved reminder comes back as the anchor, so the
  acknowledgement can name which reminder "that" was; the event comes back whole,
  so it can also name the scope that just ended — a yearly event takes every
  future occurrence with it. No match asks which event; nothing is ever guessed
  across conversations or owners.
  """
  @spec cancel_referent(map(), keyword()) ::
          {:ok, %{event: map(), source: map()}} | {:error, term()}
  def cancel_referent(context, opts \\ []) when is_map(context) and is_list(opts) do
    now = now(opts)
    server = repo(context)

    with {:ok, source} <- resolve_referent(context, now, server),
         {:ok, parent} <- owned_parent_event(source, context, server),
         {:ok, event} <- Repo.cancel_temporal_event(parent.id, now, server: server) do
      emit_cancelled(event)
      notify(context)
      {:ok, %{event: event, source: source}}
    end
  end

  @doc """
  Defers one delivered or pending reminder to a later instant (§20).

  `params` accepts an explicit `:reminder_id`, or none — in which case "that" is
  resolved from the outbox: the most recent reminder DELIVERED into the caller's
  own platform/destination/thread within the last 24 hours, for this owner. No
  match asks which event; nothing is ever guessed across conversations or owners.

  `:snooze` is one tagged form (`duration` or `datetime`); `:confirm_past_boundary`
  is the owner's explicit consent to a reminder that would land at or after the
  event itself.

  Returns `%{status: :created | :existing, ...}`; `:existing` means this exact
  deferral was already stored, so the caller must not claim a second reminder
  was scheduled (§5.2).
  """
  @spec snooze_reminder(map(), map(), keyword()) ::
          {:ok,
           %{
             status: :created | :existing,
             reminder: map(),
             source: map(),
             event: map(),
             timezone: String.t(),
             superseded: [String.t()]
           }}
          | {:error, term()}
  def snooze_reminder(params, context, opts \\ [])
      when is_map(params) and is_map(context) and is_list(opts) do
    now = now(opts)
    server = repo(context)

    with {:ok, zone} <- configured_timezone(opts),
         {:ok, source, selection} <- snooze_source(params, context, now, server),
         {:ok, event} <- owned_parent_event(source, context, server),
         {:ok, at} <- snooze_instant(Map.get(params, :snooze), now, zone),
         {:ok, valid_until} <- snooze_validity(event, at, params),
         attrs = snooze_attrs(source, selection, at, valid_until, context),
         {:ok, outcome} <- Repo.snooze_temporal_reminder(attrs, now, server: server) do
      emit_snooze(outcome, event)
      notify(context)
      {:ok, snooze_result(outcome, source, event, zone)}
    end
  end

  @doc """
  Lists the caller's events (§12.1). The returned `:cursor` is an opaque string
  the caller passes back verbatim for the next page, or `nil` at the end.

  With no `:from`, no `:to`, and no `:status` this answers "what is coming up"
  and starts at today; any explicit window or status asks for history and drops
  that floor.
  """
  @spec list_events(map(), map(), keyword()) ::
          {:ok, %{events: [map()], cursor: String.t() | nil}} | {:error, term()}
  def list_events(filter, context, opts \\ [])
      when is_map(filter) and is_map(context) and is_list(opts) do
    with {:ok, normalized} <- list_filter(filter, context, opts),
         {:ok, %{events: events, cursor: cursor}} <-
           Repo.list_temporal_events(normalized, server: repo(context)) do
      {:ok, %{events: events, cursor: encode_cursor(cursor)}}
    end
  end

  # --- duplicate and edit visibility (§5.2) --------------------------------

  # One bounded post-commit read: the owner's other ACTIVE events of the same
  # kind. A twin stored under a different title is the one duplicate the dedupe
  # key cannot catch, and this puts it in front of the model inside the very
  # acknowledgement that created its neighbour. An `:existing` result created
  # nothing, so it has nothing to be a twin of and reads nothing.
  defp similar_events(:existing, _event, _context), do: []

  defp similar_events(:created, event, context) do
    filter = %{
      owner_id: owner_id(context),
      kind: event.kind,
      status: "active",
      limit: @max_similar_events + 1
    }

    case Repo.list_temporal_events(filter, server: repo(context)) do
      {:ok, %{events: events}} -> compact_events(events, event.id)
      {:error, reason} -> log_similar_failure(event, reason)
    end
  end

  # One page over-read so excluding the new event still leaves a full cap.
  defp compact_events(events, created_id) do
    events
    |> Enum.reject(&(&1.id == created_id))
    |> Enum.take(@max_similar_events)
    |> Enum.map(
      &%{
        "event_id" => &1.id,
        "title" => &1.title,
        "next_occurrence_on" => iso(&1.next_occurrence_on)
      }
    )
  end

  # Best effort by contract, exactly like the scheduler signal below: the event
  # is already committed, so a failed neighbour read is logged loudly and the
  # acknowledgement simply lists none. It must never turn a stored event into a
  # tool error that tells the owner nothing was written.
  defp log_similar_failure(event, reason) do
    Logger.error(
      "Temporal.Registry: same-kind neighbour read failed for event #{event.id}: " <>
        inspect(reason)
    )

    []
  end

  # §5.2 for edits: the reply must be able to say what a field WAS from stored
  # values alone. Only fields this write actually moved appear, each rendered
  # exactly as `event_view/1` renders it, so a "was" and a "now" are the same
  # shape. Provenance, revision, and delivery columns are the Repo's, not the
  # owner's, and are deliberately absent.
  defp previous_values(existing, updated) do
    @previous_fields
    |> Enum.filter(&(Map.fetch!(existing, &1) != Map.fetch!(updated, &1)))
    |> Map.new(&{Atom.to_string(&1), previous_value(&1, Map.fetch!(existing, &1))})
  end

  defp previous_value(:recurrence_month, value), do: value
  defp previous_value(:recurrence_day, value), do: value
  defp previous_value(_field, value), do: iso(value)

  # --- canonical views -----------------------------------------------------

  @doc """
  The canonical stored event as a JSON-safe map (§5.2).

  One definition for all four tools, so the acknowledgement the model writes can
  only ever quote values that were actually persisted. `"status"` is reserved
  for the *operation* outcome the calling tool adds; the row's own lifecycle
  state is `"event_status"`.
  """
  @spec event_view(map()) :: map()
  def event_view(event) when is_map(event) do
    %{
      "event_id" => event.id,
      "title" => event.title,
      "description" => event.description,
      "kind" => event.kind,
      "event_status" => event.status,
      "revision" => event.revision,
      "timezone" => event.timezone,
      "recurrence" => recurrence_view(event),
      "local_date" => iso(event.local_date),
      "local_time" => iso(event.local_time),
      "occurrence_at" => iso(event.occurrence_at),
      "next_occurrence_on" => iso(event.next_occurrence_on),
      "reminder_plan" => event.reminder_plan,
      "delivery" => delivery_view(event)
    }
    |> Map.merge(delivery_state_view(event))
  end

  @doc "One concrete planned reminder as a JSON-safe map."
  @spec reminder_view(map()) :: map()
  def reminder_view(reminder) when is_map(reminder) do
    %{
      "reminder_id" => reminder.id,
      "rule_id" => reminder.reminder_rule_id,
      "occurrence_key" => reminder.occurrence_key,
      "scheduled_for" => iso(reminder.scheduled_for),
      "valid_until" => iso(reminder.valid_until),
      "status" => reminder.status
    }
  end

  @doc """
  The canonical snooze acknowledgement (§5.2, §20).

  Carries the source event's title and kind, the new reminder time both as the
  stored UTC instant and as an absolute local time with its zone, the delivery
  platform, and whether an earlier snooze was replaced — so the reply can only
  quote values that were persisted.
  """
  @spec snooze_view(map()) :: map()
  def snooze_view(%{reminder: reminder, source: source, event: event} = result)
      when is_map(reminder) and is_map(source) and is_map(event) do
    local = DateTime.shift_zone!(reminder.scheduled_for, result.timezone)
    replaced? = replaced_earlier_snooze?(result.superseded, source)

    reminder
    |> reminder_view()
    |> Map.merge(%{
      "status" => snooze_status(result.status),
      "source_reminder_id" => source.id,
      "event_id" => event.id,
      "title" => event.title,
      "kind" => event.kind,
      "timezone" => result.timezone,
      "scheduled_for_local" => DateTime.to_iso8601(local),
      "zone_abbr" => local.zone_abbr,
      "delivery" => %{
        "platform" => reminder.delivery_platform,
        "destination" => reminder.delivery_destination,
        "thread_scope" => reminder.delivery_thread_scope
      },
      "replaced_earlier_snooze" => replaced?,
      "note" => snooze_note(result.status, replaced?)
    })
  end

  # Retiring the pending SOURCE is part of every explicit snooze and says nothing
  # to the owner; only another snooze of the same source is a replacement.
  defp replaced_earlier_snooze?(superseded, source) do
    Enum.any?(superseded, &(&1 != source.id))
  end

  defp snooze_status(:created), do: "snoozed"
  defp snooze_status(:existing), do: "already_snoozed"

  defp snooze_note(:existing, _replaced?) do
    "This reminder was already snoozed to exactly this time; no second reminder was created."
  end

  defp snooze_note(:created, false), do: nil

  defp snooze_note(:created, true) do
    "This replaced the earlier snooze of the same reminder; only the new time will fire."
  end

  defp recurrence_view(event) do
    %{
      "kind" => event.recurrence_kind,
      "month" => event.recurrence_month,
      "day" => event.recurrence_day,
      "leap_day_policy" => event.leap_day_policy
    }
  end

  # §5.2: the acknowledgement may say where the target came from, so the model
  # can name a derived inbox ("through Telegram, derived from your configured
  # channel") and the owner can correct it. Provenance is not a stored column:
  # `"source"` appears only on the operation that RESOLVED the target — a
  # listing, a removal, or an update that kept the stored target says nothing
  # rather than re-resolving against configuration that may have moved since.
  defp delivery_view(event) do
    Map.merge(
      %{
        "platform" => event.delivery_platform,
        "destination" => event.delivery_destination,
        "thread_scope" => event.delivery_thread_scope
      },
      delivery_source_view(event)
    )
  end

  # `:configured` or `:derived` — the two rungs `default_target/1` can answer
  # from. Rendered as-is rather than matched against that pair, so an unexpected
  # value would be visible in the payload instead of silently vanishing from it.
  defp delivery_source_view(%{delivery_source: source}) when is_atom(source) do
    %{"source" => Atom.to_string(source)}
  end

  defp delivery_source_view(_no_resolution), do: %{}

  # `event_list` rows carry the delivery summary the plain row does not.
  defp delivery_state_view(event) do
    [:last_delivery_status, :last_delivery_error, :last_delivery_at, :next_reminder_at]
    |> Enum.filter(&Map.has_key?(event, &1))
    |> Map.new(fn key -> {Atom.to_string(key), iso(Map.fetch!(event, key))} end)
  end

  defp iso(nil), do: nil
  defp iso(%Date{} = value), do: Date.to_iso8601(value)
  defp iso(%Time{} = value), do: Time.to_iso8601(value)
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(value) when is_binary(value), do: value

  # --- error vocabulary ----------------------------------------------------

  @doc """
  Renders a tagged failure as one sentence the agent can relay to the owner.

  Every clarification the §12.2 contract owes the owner (a nonexistent local
  time, an ambiguous one, a missing zone, a missing target) is stated here, in
  one place, so all four tools say the same thing.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error(:timezone_not_configured) do
    "No timezone is configured. Set [fermix_core.personalization] timezone to the " <>
      "owner's IANA zone (for example America/New_York), or name the zone for this event."
  end

  def describe_error({:invalid_timezone, zone}) do
    "#{inspect(zone)} is not a known IANA timezone. Use a zone name like America/New_York."
  end

  def describe_error({:dst_gap, zone, date, time}) do
    "#{Time.to_string(time)} on #{Date.to_string(date)} does not exist in #{zone} — " <>
      "the clocks skip it for daylight saving. Ask the owner for a real local time."
  end

  def describe_error({:dst_ambiguous, offsets}) do
    "That local time happens twice when the clocks go back (offsets " <>
      Enum.join(offsets, " and ") <>
      "). Ask the owner which one they mean and pass it as utc_offset."
  end

  def describe_error(:no_default_delivery_target) do
    "No delivery target could be resolved. Either configure [fermix_core.jobs] " <>
      "default_delivery_target (platform plus a destination such as chat_id), or " <>
      "configure a channel with an owner id so Fermix can derive your inbox; " <>
      "Fermix never falls back to this conversation."
  end

  def describe_error(:no_default_delivery_destination) do
    "The configured [fermix_core.jobs] default_delivery_target has no destination. " <>
      "Add one of: #{Enum.join(@destination_keys, ", ")}."
  end

  def describe_error({:invalid_delivery_mode, mode}) do
    "default_delivery_mode #{inspect(mode)} cannot carry a proactive reminder. Events " <>
      "require a channel target: set default_delivery_mode to \"channel\" with a valid " <>
      "default_delivery_target."
  end

  def describe_error({:cli_delivery_platform, platform}) do
    "The configured default delivery platform is #{inspect(platform)}, which is a valid " <>
      "schedule_job target but not a durable reminder destination — the CLI is an " <>
      "interaction surface with nobody listening later. Configure a chat platform " <>
      "(#{Enum.join(@platforms, ", ")}) to store events."
  end

  def describe_error({:unsupported_delivery_platform, platform}) do
    "#{inspect(platform)} is not an available proactive delivery platform. Configure one " <>
      "of: #{Enum.join(@platforms, ", ")}."
  end

  def describe_error({:invalid_delivery_adapter, adapter}) do
    "The configured delivery adapter #{inspect(adapter)} cannot send messages."
  end

  def describe_error({:conflicting_thread_fields, platform}) do
    "The configured default target for #{platform} sets both message_thread_id and " <>
      "thread_ts. Keep only the one that platform uses; Fermix never guesses a thread."
  end

  def describe_error({:irrelevant_thread_field, platform, field}) do
    "#{field} does not apply to #{platform}. Remove it from the configured default " <>
      "delivery target."
  end

  def describe_error({:invalid_thread_value, platform, value}) do
    "#{inspect(value)} is not a valid thread id for #{platform}."
  end

  def describe_error({:unsupported_target_field, field}) do
    "#{field} is a per-message option, not a durable destination, so it cannot be " <>
      "snapshotted onto an event. Remove it from the configured default delivery target."
  end

  # The one failure only the OWNER can resolve: a stored event with this name
  # and a different date is either the same thing being corrected or a second
  # person who happens to share the name, and nothing in the request says which.
  # So the sentence hands the model the stored date to quote and the question to
  # ask, and names both remedies — never a rule for picking one unasked.
  def describe_error({:identity_conflict, existing}) when is_map(existing) do
    "An active event titled #{inspect(existing.title)} is already stored, dated " <>
      "#{conflict_date(existing)}, and this request gives a different one. Only the owner " <>
      "knows whether that is a correction to the same event or a different one that shares " <>
      "the name. Ask the owner which it is before writing: if it is the same event, change " <>
      "it with event_update; if it is a different one, store it under a title that tells " <>
      "the two apart. Do not choose for them."
  end

  # The same ambiguity as an identity conflict, met from the other side: here
  # the model has already decided this is the same event. The refusal carries
  # its own prompt material — the stored date to quote — so the question can be
  # put to the owner in the owner's own terms, and it names both outcomes
  # rather than a rule for choosing between them. What it asks for on the retry
  # is the owner's words, not an assertion about them: there is nothing to quote
  # until the owner has actually spoken.
  def describe_error({:overwrite_unconfirmed, existing}) when is_map(existing) do
    "The stored event titled #{inspect(existing.title)} is dated #{conflict_date(existing)}, " <>
      "and this patch changes that date; an overwritten date leaves nothing behind. Ask the " <>
      "owner whether to overwrite that date or keep both as separate events, and retry with " <>
      "owner_direction set to the owner's own words directing this change — only once they " <>
      "have directed it or answered the question."
  end

  # The one thing the checkpoint may say about the content, and it is a size,
  # not a judgement: a whole pasted message is not an excerpt, and the reader of
  # the trace needs the clause, not the transcript around it.
  def describe_error({:owner_direction_too_long, size}) when is_integer(size) do
    "owner_direction is #{size} bytes; at most #{@owner_direction_max} are accepted. Quote " <>
      "just the clause in which the owner directed this date change, not the whole message."
  end

  def describe_error(:delivery_in_progress) do
    "A reminder for this event is being sent right now and a send cannot be recalled. " <>
      "Wait for the attempt to finish and try again."
  end

  def describe_error({:invalid_snooze, raw}) do
    "#{inspect(raw)} is not a supported snooze time. Use " <>
      ~s({"type":"duration","amount":2,"unit":"minutes"|"hours"|"days"} or ) <>
      ~s({"type":"datetime","date":"YYYY-MM-DD","time":"HH:MM:SS"}.)
  end

  def describe_error(:snooze_in_past) do
    "That snooze time is not in the future. Ask the owner for a later time."
  end

  def describe_error(:snooze_too_far) do
    "A snooze may be at most #{@max_snooze_days} days out. To move the event itself, " <>
      "use event_update."
  end

  def describe_error(:snooze_past_boundary_unconfirmed) do
    "That time is at or after the event itself, so the reminder would arrive once the " <>
      "event has already started or passed. Confirm that with the owner first, then " <>
      "call again with confirm_past_boundary: true."
  end

  def describe_error(:no_recent_reminder) do
    "No reminder was delivered in this conversation within the last " <>
      "#{@snooze_lookback_hours} hours, so there is nothing here that \"that\" can mean. " <>
      "Ask the owner which event they mean and name it: its event_id to remove it, or " <>
      "its reminder_id to snooze it."
  end

  def describe_error(:no_conversation_target) do
    "This turn has no conversation to resolve \"that\" from. Ask the owner which event " <>
      "they mean and name it: its event_id to remove it, or its reminder_id to snooze it."
  end

  def describe_error(:parent_cancelled) do
    "That reminder's event was removed, so it cannot be snoozed. Store it again with " <>
      "event_store if the owner still wants it."
  end

  def describe_error(:source_terminal) do
    "That reminder already failed, expired, or was cancelled, so there is nothing to " <>
      "defer. Add a new reminder with event_update instead."
  end

  def describe_error(:source_delivering) do
    "That reminder is being sent right now and a send cannot be recalled. Wait for the " <>
      "attempt to finish and try again."
  end

  def describe_error(:snooze_delivery_in_progress) do
    "That reminder's earlier snooze is being delivered right now; try again in a moment."
  end

  def describe_error(:dedupe_conflict) do
    "Reactivating that event would collide with an active event of the same identity. " <>
      "Nothing was changed — resolve the duplicate with event_update or event_remove first."
  end

  def describe_error(:not_found), do: "That event was not found."
  def describe_error(:not_active), do: "That event is no longer active."
  def describe_error(:stale_event_revision), do: "That event changed; re-read it and retry."

  def describe_error(:leap_day_policy_required) do
    "A yearly February 29 event needs an explicit leap_day_policy: \"feb_28\" or " <>
      "\"mar_1\" for non-leap years. Ask the owner which they want."
  end

  def describe_error({:too_many_rules, count}) do
    "#{count} reminder rules exceeds the cap of #{Defaults.max_rules()} per event."
  end

  def describe_error({:duplicate_rule_id, id}) do
    "Two reminder rules resolve to the same rule #{inspect(id)}; each rule must be distinct."
  end

  def describe_error({:invalid_reminder_rule, raw}) do
    "#{inspect(raw)} is not a valid reminder rule. Use " <>
      ~s({"type":"days_before","days":7,"at":"09:00:00"}, ) <>
      ~s({"type":"duration_before","minutes":60}, or {"type":"at_time"}.)
  end

  def describe_error({:invalid_rule, rule}), do: describe_error({:invalid_reminder_rule, rule})

  def describe_error(:empty_plan_not_allowed) do
    "An event needs at least one reminder rule. Pass no_reminders: true if the owner " <>
      "explicitly wants the date stored without notifications."
  end

  def describe_error({:rule_requires_datetime, id}) do
    "Reminder rule #{inspect(id)} measures time before an exact moment, so it needs an " <>
      "event with a time, not a date-only one."
  end

  def describe_error({:invalid_rule_time, id}) do
    "Reminder rule #{inspect(id)} resolves at or after the moment it is meant to warn " <>
      "about. Move it earlier."
  end

  def describe_error({:invalid_when, raw}) do
    "#{inspect(raw)} is not a supported time form. Use " <>
      ~s({"type":"date","date":"YYYY-MM-DD"}, ) <>
      ~s({"type":"datetime","date":"YYYY-MM-DD","time":"HH:MM:SS"}, ) <>
      ~s({"type":"relative","amount":2,"unit":"weeks"}, or ) <>
      ~s({"type":"annual","month":9,"day":14}.)
  end

  def describe_error({:invalid_kind, kind}) do
    "#{inspect(kind)} is not a supported event kind. Use one of: #{Enum.join(@kinds, ", ")}."
  end

  def describe_error({:missing_param, key}), do: "#{key} is required."
  def describe_error({:invalid_param, key}), do: "#{key} is not valid."
  def describe_error({:too_long, key, max}), do: "#{key} must be at most #{max} bytes."

  def describe_error(:date_window_too_wide) do
    "That date window is wider than two years. Narrow it and page through the results."
  end

  def describe_error(:invalid_date_window), do: "The date window ends before it starts."
  def describe_error({:invalid_cursor, _value}), do: "That page cursor is not valid."

  def describe_error({:invalid_event, field}), do: "The event's #{field} is not valid."
  def describe_error({:invalid, field, problem}), do: "#{field} is #{problem}."
  def describe_error(reason), do: "Event operation failed: #{inspect(reason)}."

  # A yearly event's stored date is a calendar month and day with no year; a
  # one-time event's is its stored local date. A row carrying neither says so
  # and names itself, rather than rendering a date nobody stored.
  defp conflict_date(%{recurrence_kind: "yearly", recurrence_month: month, recurrence_day: day})
       when is_integer(month) and is_integer(day) do
    "every #{two_digits(month)}-#{two_digits(day)}"
  end

  defp conflict_date(%{local_date: %Date{} = date}), do: Date.to_iso8601(date)

  defp conflict_date(event), do: "a date event #{event.id} does not carry"

  defp two_digits(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  # --- specification building ----------------------------------------------

  defp build_spec(params, now, opts) do
    with {:ok, title} <- required_text(params, :title, @title_max),
         {:ok, description} <- optional_text(params, :description, @description_max),
         {:ok, kind} <- required_kind(params),
         {:ok, timezone} <- resolve_timezone(params, opts),
         {:ok, policy} <- leap_policy(params),
         {:ok, time} <- resolve_when(Map.get(params, :when), timezone, now),
         {:ok, rules} <- plan_rules(params, kind, time.time_kind) do
      {:ok,
       Map.merge(time, %{
         title: title,
         description: description,
         kind: kind,
         timezone: timezone,
         leap_day_policy: policy,
         reminder_plan: rules
       })}
    end
  end

  defp required_text(params, key, max) do
    case Map.get(params, key) do
      value when is_binary(value) -> bounded(String.trim(value), key, max)
      _absent -> {:error, {:missing_param, key}}
    end
  end

  defp bounded("", key, _max), do: {:error, {:missing_param, key}}

  defp bounded(value, key, max) do
    if byte_size(value) > max, do: {:error, {:too_long, key, max}}, else: {:ok, value}
  end

  defp optional_text(params, key, max) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> optional_bounded(String.trim(value), key, max)
      _other -> {:error, {:invalid_param, key}}
    end
  end

  defp optional_bounded("", _key, _max), do: {:ok, nil}
  defp optional_bounded(value, key, max), do: bounded(value, key, max)

  defp required_kind(params) do
    case Map.get(params, :kind) do
      kind when kind in @kinds -> {:ok, kind}
      other -> {:error, {:invalid_kind, other}}
    end
  end

  defp leap_policy(params) do
    case Map.get(params, :leap_day_policy) do
      nil -> {:ok, nil}
      policy when policy in @leap_policies -> {:ok, policy}
      other -> {:error, {:invalid_param, "leap_day_policy=#{inspect(other)}"}}
    end
  end

  # --- timezone ------------------------------------------------------------

  defp resolve_timezone(params, opts) do
    case Map.get(params, :timezone) do
      zone when is_binary(zone) and zone != "" -> validate_zone(zone)
      nil -> configured_timezone(opts)
      other -> {:error, {:invalid_timezone, other}}
    end
  end

  defp configured_timezone(opts) do
    opts
    |> Keyword.get_lazy(:personalization, fn ->
      Application.get_env(:fermix_core, :personalization, [])
    end)
    |> Keyword.get(:timezone)
    |> case do
      zone when is_binary(zone) and zone != "" -> validate_zone(zone)
      _missing -> {:error, :timezone_not_configured}
    end
  end

  # Real IANA validation against the shipped database: a name the tz database
  # does not know must fail loudly here rather than silently becoming UTC.
  defp validate_zone(zone) do
    case DateTime.shift_zone(DateTime.utc_now(), zone) do
      {:ok, _shifted} -> {:ok, zone}
      {:error, _reason} -> {:error, {:invalid_timezone, zone}}
    end
  end

  # --- structured time input (§12.2) ---------------------------------------

  defp resolve_when(%{"type" => "date", "date" => date}, _zone, _now) do
    with {:ok, parsed} <- parse_date(date) do
      {:ok, one_time_date(parsed)}
    end
  end

  defp resolve_when(%{"type" => "datetime", "date" => date, "time" => time} = form, zone, _now) do
    with {:ok, parsed_date} <- parse_date(date),
         {:ok, parsed_time} <- parse_time(time) do
      one_time_datetime(parsed_date, parsed_time, zone, Map.get(form, "utc_offset"))
    end
  end

  defp resolve_when(%{"type" => "relative", "amount" => amount, "unit" => unit} = form, zone, now) do
    with {:ok, days} <- relative_days(amount, unit),
         {:ok, today} <- local_today(now, zone) do
      relative_occurrence(Date.add(today, days), Map.get(form, "time"), zone)
    end
  end

  defp resolve_when(%{"type" => "annual", "month" => month, "day" => day}, _zone, _now) do
    with {:ok, valid} <- annual_month_day(month, day) do
      {:ok, valid}
    end
  end

  defp resolve_when(form, _zone, _now), do: {:error, {:invalid_when, form}}

  defp one_time_date(date) do
    %{
      time_kind: "date",
      recurrence_kind: "once",
      local_date: date,
      local_time: nil,
      occurrence_at: nil,
      recurrence_month: nil,
      recurrence_day: nil
    }
  end

  defp one_time_datetime(date, time, zone, utc_offset) do
    with {:ok, at} <- Planner.resolve_local_datetime(date, time, zone, utc_offset) do
      {:ok, %{one_time_date(date) | time_kind: "datetime", local_time: time, occurrence_at: at}}
    end
  end

  defp relative_occurrence(date, nil, _zone), do: {:ok, one_time_date(date)}

  defp relative_occurrence(date, time, zone) do
    with {:ok, parsed} <- parse_time(time) do
      one_time_datetime(date, parsed, zone, nil)
    end
  end

  defp relative_days(amount, unit)
       when is_integer(amount) and amount > 0 and is_map_key(@relative_units, unit) do
    days = amount * Map.fetch!(@relative_units, unit)

    if days > @max_relative_days do
      {:error, {:invalid_param, "amount=#{amount}"}}
    else
      {:ok, days}
    end
  end

  defp relative_days(amount, unit),
    do: {:error, {:invalid_when, %{"amount" => amount, "unit" => unit}}}

  defp annual_month_day(month, day)
       when is_integer(month) and month in 1..12 and is_integer(day) and day in 1..31 do
    {:ok,
     %{
       time_kind: "date",
       recurrence_kind: "yearly",
       local_date: nil,
       local_time: nil,
       occurrence_at: nil,
       recurrence_month: month,
       recurrence_day: day
     }}
  end

  defp annual_month_day(month, day),
    do: {:error, {:invalid_when, %{"month" => month, "day" => day}}}

  defp local_today(now, zone) do
    case DateTime.shift_zone(now, zone) do
      {:ok, local} -> {:ok, DateTime.to_date(local)}
      {:error, _reason} -> {:error, {:invalid_timezone, zone}}
    end
  end

  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, {:invalid_param, "date=#{value}"}}
    end
  end

  defp parse_date(value), do: {:error, {:invalid_param, "date=#{inspect(value)}"}}

  defp parse_time(%Time{} = time), do: {:ok, time}

  defp parse_time(value) when is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, time} -> {:ok, time}
      {:error, _reason} -> {:error, {:invalid_param, "time=#{value}"}}
    end
  end

  defp parse_time(value), do: {:error, {:invalid_param, "time=#{inspect(value)}"}}

  # --- reminder plans ------------------------------------------------------

  defp plan_rules(params, kind, time_kind) do
    cond do
      Map.get(params, :no_reminders) == true -> Defaults.validate_plan([], allow_empty: true)
      is_list(Map.get(params, :reminders)) -> explicit_rules(Map.fetch!(params, :reminders))
      is_list(Map.get(params, :plan_rules)) -> carried_rules(Map.fetch!(params, :plan_rules))
      true -> default_rules(kind, time_kind)
    end
  end

  defp explicit_rules(raw) do
    with {:ok, rules} <- parse_rules(raw) do
      Defaults.validate_plan(rules)
    end
  end

  # An event's stored plan was validated when it was written, so carrying it
  # through an unrelated patch must not re-reject a deliberately empty one.
  defp carried_rules(rules), do: Defaults.validate_plan(rules, allow_empty: true)

  defp default_rules(kind, time_kind) do
    with {:ok, rules} <- Defaults.plan_for(kind, time_kind) do
      Defaults.validate_plan(rules)
    end
  end

  defp parse_rules(raw) do
    Enum.reduce_while(raw, {:ok, []}, fn rule, {:ok, acc} ->
      case parse_rule(rule) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ [parsed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_rule(%{"type" => "days_before"} = rule) do
    with {:ok, days} <- rule_integer(rule, "days", 0..@max_rule_days),
         {:ok, at} <- rule_wall_time(rule) do
      {:ok, %{rule_id: "days_before_#{days}", kind: :days_before, days: days, at: at}}
    end
  end

  defp parse_rule(%{"type" => "duration_before"} = rule) do
    with {:ok, minutes} <- rule_integer(rule, "minutes", 1..@max_rule_minutes) do
      {:ok,
       %{rule_id: "minutes_before_#{minutes}", kind: :duration_before, seconds: minutes * 60}}
    end
  end

  defp parse_rule(%{"type" => "at_time"}), do: {:ok, %{rule_id: "at_time", kind: :at_occurrence}}
  defp parse_rule(rule), do: {:error, {:invalid_reminder_rule, rule}}

  defp rule_integer(rule, key, range) do
    case Map.get(rule, key) do
      value when is_integer(value) -> in_range(value, rule, range)
      _absent -> {:error, {:invalid_reminder_rule, rule}}
    end
  end

  defp in_range(value, rule, range) do
    if value in range, do: {:ok, value}, else: {:error, {:invalid_reminder_rule, rule}}
  end

  defp rule_wall_time(rule) do
    case Map.get(rule, "at") do
      nil -> {:ok, @morning}
      value -> parse_rule_time(value, rule)
    end
  end

  defp parse_rule_time(value, rule) do
    case parse_time(value) do
      {:ok, time} -> {:ok, time}
      {:error, _reason} -> {:error, {:invalid_reminder_rule, rule}}
    end
  end

  # --- implicit referent resolution (§8.4) ---------------------------------

  # "Snooze that" and "cancel that" name nothing the model can see, so both
  # resolve their referent HERE, through one lookup scoped to the caller's exact
  # conversation, this owner, and the lookback. There is deliberately no second,
  # looser attempt, and deliberately no second query.
  defp resolve_referent(context, now, server) do
    with {:ok, target} <- caller_target(context),
         {:ok, row} <-
           Repo.latest_delivered_reminder(lookback(target, context, now), server: server) do
      resolved_or_missing(row)
    end
  end

  defp lookback(target, context, now) do
    Map.merge(target, %{
      owner_id: owner_id(context),
      since: DateTime.add(now, -@snooze_lookback_hours * 3_600, :second)
    })
  end

  defp resolved_or_missing(nil), do: {:error, :no_recent_reminder}
  defp resolved_or_missing(row), do: {:ok, row}

  # The ingress conversation key and the outbound delivery triple are the same
  # canonical (platform, destination, thread) identity (§11.1); that is what lets
  # this match a target without drifting from routing.
  defp caller_target(context) do
    case Map.get(context, :conversation_key) do
      {channel, chat_id, scope} ->
        {:ok,
         %{
           platform: to_string(channel),
           destination: to_string(chat_id),
           thread_scope: thread_component(scope)
         }}

      _absent ->
        {:error, :no_conversation_target}
    end
  end

  # The parent is read here for its ownership and validity boundary; the Repo
  # re-reads it inside the transaction for every decision that writes.
  defp owned_parent_event(source, context, server) do
    with {:ok, event} <- Repo.get_temporal_event(source.event_id, server: server) do
      ensure_owner(event, owner_id(context))
    end
  end

  defp ensure_owner(%{owner_id: owner_id} = event, owner_id), do: {:ok, event}
  defp ensure_owner(_event, _owner_id), do: {:error, :not_found}

  # --- snooze (§20) --------------------------------------------------------

  defp snooze_source(params, context, now, server) do
    case Map.get(params, :reminder_id) do
      id when is_binary(id) and id != "" -> explicit_snooze_source(id, server)
      nil -> resolved_snooze_source(context, now, server)
      other -> {:error, {:invalid_param, "reminder_id=#{inspect(other)}"}}
    end
  end

  defp explicit_snooze_source(id, server) do
    with {:ok, row} <- Repo.get_temporal_reminder(id, server: server), do: {:ok, row, :explicit}
  end

  defp resolved_snooze_source(context, now, server) do
    with {:ok, row} <- resolve_referent(context, now, server), do: {:ok, row, :resolved}
  end

  defp snooze_instant(%{"type" => "duration", "amount" => amount, "unit" => unit}, now, _zone) do
    with {:ok, seconds} <- snooze_seconds(amount, unit) do
      future_instant(DateTime.add(now, seconds, :second), now)
    end
  end

  defp snooze_instant(%{"type" => "datetime", "date" => date, "time" => time} = form, now, zone) do
    with {:ok, parsed_date} <- parse_date(date),
         {:ok, parsed_time} <- parse_time(time),
         {:ok, at} <-
           Planner.resolve_local_datetime(
             parsed_date,
             parsed_time,
             zone,
             Map.get(form, "utc_offset")
           ) do
      future_instant(at, now)
    end
  end

  defp snooze_instant(form, _now, _zone), do: {:error, {:invalid_snooze, form}}

  # Bounds the requested DURATION before it reaches `DateTime.add/3`, so an
  # unbounded amount can never resolve to a year the fixed-width timestamp
  # cannot even serialize.
  defp snooze_seconds(amount, unit)
       when is_integer(amount) and amount >= 1 and is_map_key(@snooze_units, unit) do
    seconds = amount * Map.fetch!(@snooze_units, unit)

    if seconds > @max_snooze_days * 86_400 do
      {:error, :snooze_too_far}
    else
      {:ok, seconds}
    end
  end

  defp snooze_seconds(amount, unit),
    do: {:error, {:invalid_snooze, %{"amount" => amount, "unit" => unit}}}

  # The one horizon gate on the RESOLVED instant, so both forms are bounded by
  # the same rule — a named datetime is a deferral like any other. It runs
  # before `snooze_validity/3`: `confirm_past_boundary` is consent to a reminder
  # arriving after the event, never consent to a longer horizon.
  defp future_instant(at, now) do
    cond do
      DateTime.compare(at, now) != :gt -> {:error, :snooze_in_past}
      DateTime.diff(at, now, :second) > @max_snooze_days * 86_400 -> {:error, :snooze_too_far}
      true -> {:ok, at}
    end
  end

  # §8.3 for a deferral: two hours of retry room, never past the event it warns
  # about — and a reminder that would land after the event needs the owner to
  # say so, because Fermix will not silently notify about something already over.
  defp snooze_validity(event, at, params) do
    with {:ok, boundary} <- Planner.event_boundary_at(event) do
      clamp_snooze_validity(boundary, at, Map.get(params, :confirm_past_boundary) == true)
    end
  end

  defp clamp_snooze_validity(boundary, at, confirmed?) do
    full = DateTime.add(at, @snooze_validity_seconds, :second)

    cond do
      DateTime.compare(at, boundary) == :lt -> {:ok, earliest(full, boundary)}
      confirmed? -> {:ok, full}
      true -> {:error, :snooze_past_boundary_unconfirmed}
    end
  end

  defp earliest(left, right), do: if(DateTime.compare(left, right) == :lt, do: left, else: right)

  defp snooze_attrs(source, selection, at, valid_until, context) do
    %{
      id: generate_id("rem"),
      source_reminder_id: source.id,
      scheduled_for: at,
      valid_until: valid_until,
      owner_id: owner_id(context),
      selection: selection
    }
  end

  defp snooze_result({:created, reminder, superseded}, source, event, zone) do
    %{
      status: :created,
      reminder: reminder,
      source: source,
      event: event,
      timezone: zone,
      superseded: superseded
    }
  end

  defp snooze_result({:existing, reminder}, source, event, zone) do
    %{
      status: :existing,
      reminder: reminder,
      source: source,
      event: event,
      timezone: zone,
      superseded: []
    }
  end

  # --- materialization -----------------------------------------------------

  defp materialize(spec, now) do
    with {:ok, plan} <- Planner.materialize(spec, now) do
      {:ok, Map.update!(plan, :occurrences, &Enum.map(&1, fn row -> assign_id(row) end))}
    end
  end

  defp assign_id(row), do: Map.put(row, :id, generate_id("rem"))

  defp generate_id(prefix) do
    prefix <> "_" <> Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
  end

  # --- persistence attributes ----------------------------------------------

  defp create_attrs(spec, target, context, origin) do
    {channel, chat_id, thread_scope} = source_coordinates(context)

    spec
    |> column_map(target)
    |> Map.merge(%{
      id: generate_id("evt"),
      agent_id: Map.get(context, :memory_agent_id, "main"),
      owner_id: owner_id(context),
      source_channel: channel,
      source_chat_id: chat_id,
      source_thread_scope: thread_scope,
      source_session_id: Map.get(context, :session_id),
      created_by_trust: "operator",
      created_by_origin: origin
    })
  end

  defp column_map(spec, target) do
    %{
      dedupe_key: dedupe_key(spec),
      title: spec.title,
      description: spec.description,
      kind: spec.kind,
      time_kind: spec.time_kind,
      local_date: spec.local_date,
      local_time: spec.local_time,
      timezone: spec.timezone,
      occurrence_at: spec.occurrence_at,
      recurrence_kind: spec.recurrence_kind,
      recurrence_month: spec.recurrence_month,
      recurrence_day: spec.recurrence_day,
      leap_day_policy: spec.leap_day_policy,
      reminder_plan: Defaults.encode_plan(spec.reminder_plan),
      delivery_platform: target.platform,
      delivery_destination: target.destination,
      delivery_thread_scope: target.thread_scope
    }
  end

  # The stored row has no provenance column, so the resolved source rides back
  # on the returned row for `event_view/1` alone. A target that was kept rather
  # than resolved (an update without a rebind) carries no `:source` and stamps
  # nothing.
  defp with_delivery_source(event, %{source: source}) do
    Map.put(event, :delivery_source, source)
  end

  defp with_delivery_source(event, _kept_target), do: event

  defp source_coordinates(%{conversation_key: {channel, chat_id, scope}}) do
    {to_string(channel), to_string(chat_id), thread_component(scope)}
  end

  defp source_coordinates(_context), do: {"unknown", "unknown", "root"}

  defp thread_component(:root), do: "root"
  defp thread_component(scope) when is_binary(scope) and scope != "", do: scope
  defp thread_component(scope) when is_integer(scope), do: Integer.to_string(scope)
  defp thread_component(_scope), do: "root"

  defp owner_id(context), do: Map.get(context, :memory_owner_id, "default")

  defp created_by_origin(context) do
    case Map.get(context, :computer_use_origin) do
      :interactive -> {:ok, "interactive"}
      :voice -> {:ok, "voice"}
      other -> {:error, {:invalid_param, "computer_use_origin=#{inspect(other)}"}}
    end
  end

  # --- dedupe identity (§7.1) ----------------------------------------------

  defp dedupe_key(spec) do
    digest =
      [spec.kind, normalized_title(spec.title) | occurrence_identity(spec)]
      |> Enum.join("\n")

    hash = :crypto.hash(:sha256, digest) |> Base.encode16(case: :lower) |> binary_part(0, 32)
    "#{spec.kind}:#{hash}"
  end

  defp normalized_title(title) do
    title |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()
  end

  # §7.1: a yearly event's identity is its kind and title alone, so restating
  # "Sarah's birthday" on another day is an identity conflict the agent must
  # resolve with event_update, not a second birthday.
  defp occurrence_identity(%{recurrence_kind: "yearly"}), do: []

  defp occurrence_identity(%{local_date: %Date{} = date, local_time: time}) do
    [Date.to_iso8601(date), optional_time(time)]
  end

  defp occurrence_identity(_spec), do: []

  defp optional_time(nil), do: ""
  defp optional_time(%Time{} = time), do: Time.to_iso8601(time)

  # --- default delivery target (§11.1) -------------------------------------

  # One precedence, resolved once at acceptance: the explicitly configured
  # target, else the owner's inbox derived from a configured channel, else a
  # loud refusal naming both remedies. A hostile delivery MODE is answered
  # before either — `none`/`origin`/`local` is the operator saying background
  # delivery is off, and deriving an inbox would silently overrule that.
  defp default_target(opts) do
    jobs = jobs_config(opts)

    case configured_target(jobs) do
      {:ok, raw} -> snapshot_configured(raw, jobs)
      :absent -> derived_target(opts, jobs)
      {:error, reason} -> {:error, reason}
    end
  end

  defp snapshot_configured(raw, jobs) do
    with :ok <- reject_ephemeral_fields(raw),
         {:ok, platform} <- target_platform(raw),
         {:ok, destination} <- target_destination(raw),
         {:ok, scope} <- thread_scope(platform, raw),
         {:ok, _adapter} <- resolve_adapter(platform, jobs) do
      {:ok, target(platform, destination, scope, :configured)}
    end
  end

  # A derived candidate passes the same §11.1 validation the configured target
  # passes — the five-platform allowlist (so `cli` and any other interaction
  # surface is excluded here exactly as it is there) plus a resolvable adapter.
  # A candidate that fails is not a candidate: resolution moves deterministically
  # to the next one rather than reporting an error that would hide a valid later
  # channel. Derived inboxes are root-scoped, so there is no thread to normalize.
  defp derived_target(opts, jobs) do
    opts
    |> OwnerInbox.derived_candidates()
    |> Enum.find_value(&derivable_target(&1, jobs))
    |> case do
      nil -> {:error, :no_default_delivery_target}
      target -> {:ok, target}
    end
  end

  defp derivable_target(%{platform: platform, destination: destination}, jobs) do
    if platform in @platforms and match?({:ok, _adapter}, resolve_adapter(platform, jobs)) do
      target(platform, destination, "root", :derived)
    end
  end

  defp target(platform, destination, scope, source) do
    %{platform: platform, destination: destination, thread_scope: scope, source: source}
  end

  defp jobs_config(opts) do
    Keyword.get_lazy(opts, :jobs_config, fn -> Application.get_env(:fermix_core, :jobs, []) end)
  end

  defp resolve_adapter(platform, jobs) do
    ChannelSend.resolve_adapter(platform, channels: Keyword.get(jobs, :delivery_channels, %{}))
  end

  defp configured_target(jobs) do
    mode = normalized_mode(Keyword.get(jobs, :default_delivery_mode))
    target = Keyword.get(jobs, :default_delivery_target)

    cond do
      mode in @rejected_modes -> {:error, {:invalid_delivery_mode, mode}}
      is_nil(target) or target == [] -> :absent
      is_nil(mode) or mode in @channel_modes -> {:ok, target}
      true -> {:error, {:invalid_delivery_mode, mode}}
    end
  end

  defp normalized_mode(nil), do: nil
  defp normalized_mode(mode) when is_atom(mode), do: Atom.to_string(mode)
  defp normalized_mode(mode) when is_binary(mode), do: String.trim(mode)
  defp normalized_mode(mode), do: inspect(mode)

  defp reject_ephemeral_fields(target) do
    case Enum.find(@ephemeral_keys, &(not is_nil(lookup(target, &1)))) do
      nil -> :ok
      field -> {:error, {:unsupported_target_field, field}}
    end
  end

  defp target_platform(target) do
    case present(lookup(target, "platform")) do
      nil -> {:error, :no_default_delivery_target}
      "cli" -> {:error, {:cli_delivery_platform, "cli"}}
      platform when platform in @platforms -> {:ok, platform}
      other -> {:error, {:unsupported_delivery_platform, other}}
    end
  end

  defp target_destination(target) do
    @destination_keys
    |> Enum.find_value(fn key -> present(lookup(target, key)) end)
    |> case do
      nil -> {:error, :no_default_delivery_destination}
      destination -> {:ok, destination}
    end
  end

  # §11.1: exactly one accepted thread field per platform. Both fields, an
  # irrelevant field, or an invalid value is refused — Fermix never guesses.
  defp thread_scope(platform, target) do
    thread_id = present(lookup(target, "message_thread_id"))
    thread_ts = present(lookup(target, "thread_ts"))

    case {thread_id, thread_ts} do
      {nil, nil} -> {:ok, "root"}
      {value, nil} -> platform_thread(platform, "message_thread_id", value)
      {nil, value} -> platform_thread(platform, "thread_ts", value)
      {_both, _fields} -> {:error, {:conflicting_thread_fields, platform}}
    end
  end

  defp platform_thread("telegram", "message_thread_id", value), do: decimal_thread(value)
  defp platform_thread("slack", "thread_ts", value), do: {:ok, value}

  defp platform_thread(platform, field, _value),
    do: {:error, {:irrelevant_thread_field, platform, field}}

  defp decimal_thread(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, Integer.to_string(id)}
      _not_a_positive_integer -> {:error, {:invalid_thread_value, "telegram", value}}
    end
  end

  defp lookup(target, key) when is_list(target),
    do: Keyword.get(target, Map.fetch!(@target_keys, key))

  defp lookup(target, key) when is_map(target) do
    case Map.fetch(target, key) do
      {:ok, value} -> value
      :error -> Map.get(target, Map.fetch!(@target_keys, key))
    end
  end

  defp lookup(_target, _key), do: nil

  defp present(nil), do: nil
  defp present(value) when is_integer(value), do: Integer.to_string(value)
  defp present(value) when is_atom(value), do: present(Atom.to_string(value))

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  # --- update merging (§7.3) -----------------------------------------------

  defp ensure_active(%{status: "active"}), do: :ok
  defp ensure_active(_event), do: {:error, :not_active}

  # The date checkpoint (§5.2). Every other field an edit touches replaces one
  # value the owner just restated; `when` replaces the one value a same-named
  # event may not share, and an overwritten date leaves nothing to notice it by.
  # So the model has to carry the owner's own directing words through to the
  # write. A boolean was fillable by reflex — a trace showed one set on the very
  # first call for a bare restatement — while a quote has to be found, and if
  # there is nothing to quote there was nothing to overwrite.
  #
  # PRESENCE of `:when` is the trigger, never a comparison against the stored
  # date: a rule that fires the same way every time is a rule the model can
  # follow, and a resend that happens to change nothing costs one excerpt. The
  # refusal carries the row already fetched, so the sentence can quote the
  # stored date the owner has to be asked about.
  #
  # The guard is mechanical and never reads what the words SAY: presence, a
  # trim for emptiness, and a byte bound, nothing else. Judging the content
  # would be a lexical filter the model could learn to satisfy, and the reader
  # of the trace is the one who can actually tell a quote from an invention.
  # `owner_direction` is that evidence, not a stored field — it is stripped here
  # and never reaches the merge, the target, or the Repo.
  defp confirmed_patch(patch, existing) do
    fields = Map.delete(patch, :owner_direction)

    if Map.has_key?(fields, :when) do
      directed_patch(present(Map.get(patch, :owner_direction)), fields, existing)
    else
      {:ok, fields}
    end
  end

  defp directed_patch(nil, _fields, existing), do: {:error, {:overwrite_unconfirmed, existing}}

  defp directed_patch(direction, fields, _existing)
       when byte_size(direction) <= @owner_direction_max do
    {:ok, fields}
  end

  # No silent truncation: an excerpt the caller did not choose is not the
  # owner's words, and a trace that shows a clipped quote is worse than one that
  # shows the refusal.
  defp directed_patch(direction, _fields, _existing) do
    {:error, {:owner_direction_too_long, byte_size(direction)}}
  end

  defp merge_params(existing, patch) do
    with {:ok, rules} <- Defaults.decode_plan(existing.reminder_plan),
         {:ok, when_form} <- existing_when(existing) do
      base = %{
        title: existing.title,
        description: existing.description,
        kind: existing.kind,
        timezone: existing.timezone,
        leap_day_policy: existing.leap_day_policy,
        when: when_form,
        plan_rules: rules
      }

      {:ok, Map.merge(base, Map.take(patch, @patchable))}
    end
  end

  # Round-trips the stored row back into the tagged input form so one resolver
  # handles create and update. The stored instant supplies the offset, so an
  # event written for a DST fold re-resolves to the same instant.
  defp existing_when(%{recurrence_kind: "yearly"} = event) do
    {:ok, %{"type" => "annual", "month" => event.recurrence_month, "day" => event.recurrence_day}}
  end

  defp existing_when(%{time_kind: "datetime", local_date: %Date{}, local_time: %Time{}} = event) do
    with {:ok, offset} <- stored_offset(event) do
      {:ok,
       %{
         "type" => "datetime",
         "date" => Date.to_iso8601(event.local_date),
         "time" => Time.to_iso8601(event.local_time),
         "utc_offset" => offset
       }}
    end
  end

  defp existing_when(%{time_kind: "date", local_date: %Date{} = date}) do
    {:ok, %{"type" => "date", "date" => Date.to_iso8601(date)}}
  end

  defp existing_when(_event), do: {:error, {:invalid_event, :time_kind}}

  defp stored_offset(%{occurrence_at: %DateTime{} = at, timezone: zone}) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> {:ok, Planner.offset_string(local)}
      {:error, _reason} -> {:error, {:invalid_timezone, zone}}
    end
  end

  defp stored_offset(_event), do: {:error, {:invalid_event, :occurrence_at}}

  defp patched_target(existing, patch, opts) do
    if Map.get(patch, :rebind_delivery_to_default) == true do
      default_target(opts)
    else
      {:ok,
       %{
         platform: existing.delivery_platform,
         destination: existing.delivery_destination,
         thread_scope: existing.delivery_thread_scope
       }}
    end
  end

  # --- listing -------------------------------------------------------------

  defp list_filter(filter, context, opts) do
    with {:ok, cursor} <- decode_cursor(Map.get(filter, :cursor)) do
      {:ok,
       filter
       |> Map.take([:text, :kind, :status, :from, :to, :limit])
       |> Map.merge(%{owner_id: owner_id(context), cursor: cursor})
       |> Map.merge(upcoming_floor(filter, opts))}
    end
  end

  # The default list answers "what is coming up", so with no window and no
  # status of its own it starts at today. Without that floor a parent whose
  # occurrence already passed — exactly what a post-boundary snooze reactivates
  # — sorts FIRST in every default listing until it re-completes. Any explicit
  # window or status is the caller asking for history, and drops the floor
  # entirely. The Repo keeps a row with no cached occurrence visible: an
  # unexpected NULL must be seen, never hidden.
  #
  # The floor is the UTC date of the clock, the same date the completion scan
  # compares `next_occurrence_on` against, so the two agree on which day an
  # occurrence has passed.
  defp upcoming_floor(filter, opts) do
    if default_upcoming?(filter) do
      %{upcoming_from: opts |> now() |> DateTime.to_date() |> Date.to_iso8601()}
    else
      %{}
    end
  end

  defp default_upcoming?(filter) do
    is_nil(Map.get(filter, :from)) and is_nil(Map.get(filter, :to)) and
      is_nil(Map.get(filter, :status))
  end

  defp encode_cursor(nil), do: nil
  defp encode_cursor({key, id}), do: key <> @cursor_separator <> id

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(value) when is_binary(value) do
    case String.split(value, @cursor_separator, parts: 2) do
      [key, id] when id != "" -> {:ok, {key, id}}
      _malformed -> {:error, {:invalid_cursor, value}}
    end
  end

  defp decode_cursor(value), do: {:error, {:invalid_cursor, value}}

  # --- scheduler signal (§10.3) --------------------------------------------

  # Best effort by contract: the write is already committed, so a missing
  # scheduler is logged and left to the 60-second reconciliation scan. It can
  # never turn a committed event into a tool error.
  defp notify(context) do
    case Map.get(context, :temporal_scheduler, @scheduler) do
      nil -> :ok
      scheduler -> signal(scheduler)
    end
  end

  defp signal(pid) when is_pid(pid) do
    GenServer.cast(pid, :event_changed)
    :ok
  end

  defp signal(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> log_absent_scheduler(name)
      pid -> signal(pid)
    end
  end

  defp log_absent_scheduler(name) do
    Logger.warning(
      "Temporal.Registry: reminder scheduler #{inspect(name)} is unavailable; the " <>
        "committed event stands and reconciliation will pick up its reminders."
    )

    TemporalTelemetry.emit(:scheduler_error, result: {:error, :scheduler_unavailable})
  end

  # --- lifecycle telemetry (§15.2) -----------------------------------------

  # An idempotent repeat create materialized nothing — the event and its plan
  # were already stored — so it emits nothing rather than claiming work.
  defp emit_materialized(:existing, _event), do: :ok
  defp emit_materialized(:created, event), do: emit_materialized(event)

  defp emit_materialized(event) do
    TemporalTelemetry.emit(:materialized,
      event_id: event.id,
      platform: event.delivery_platform,
      result: :ok,
      content: event.title
    )
  end

  # One cancellation phase whether the owner named the event or said "cancel
  # that": the trace must not depend on how the referent was chosen.
  defp emit_cancelled(event) do
    TemporalTelemetry.emit(:cancelled,
      event_id: event.id,
      platform: event.delivery_platform,
      result: :ok
    )
  end

  # A snooze writes one row and may retire another, and the closed phase
  # vocabulary already names both. An idempotent repeat wrote nothing, so it
  # emits nothing (the §15.2 rule the repeat create follows).
  defp emit_snooze({:existing, _reminder}, _event), do: :ok

  defp emit_snooze({:created, reminder, superseded}, event) do
    TemporalTelemetry.emit(
      :materialized,
      TemporalTelemetry.reminder(reminder) ++ [result: :ok, content: event.title]
    )

    Enum.each(superseded, &emit_snooze_superseded(&1, reminder))
  end

  defp emit_snooze_superseded(id, reminder) do
    TemporalTelemetry.emit(:superseded,
      event_id: reminder.event_id,
      reminder_id: id,
      occurrence_key: reminder.occurrence_key,
      platform: reminder.delivery_platform,
      result: :ok
    )
  end

  # --- shared helpers ------------------------------------------------------

  defp now(opts) do
    opts
    |> Keyword.get_lazy(:now, &DateTime.utc_now/0)
    |> DateTime.shift_zone!(@utc)
  end

  defp repo(context), do: Map.get(context, :memory_repo, Repo)
end
