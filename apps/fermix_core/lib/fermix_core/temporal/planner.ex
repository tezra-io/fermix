defmodule FermixCore.Temporal.Planner do
  @moduledoc """
  Pure local-calendar materialization for temporal events (M30 §8.3, §9).

  The planner never reads a clock, a config, or the database: `now` and the
  event's timezone are always arguments. It turns a validated event plus a
  bounded reminder plan into concrete reminder occurrences with resolved UTC
  `scheduled_for`/`valid_until` boundaries, keeping annual events materialized
  for the next two occurrences.

  Calendar rules it enforces:

    * yearly occurrences are built by local-calendar construction per target
      year, never by adding 365 days;
    * a February 29 annual event needs an explicit `leap_day_policy`;
    * date-only leads construct the local calendar date first and resolve the
      wall time afterwards, timed leads subtract an absolute duration;
    * a nonexistent (DST gap) or ambiguous (DST fold) wall time is refused with
      a tagged error instead of being silently shifted or folded;
    * lead rules already in the past are skipped.
  """

  alias FermixCore.Temporal.Defaults

  @annual_horizon 2
  @explicit_validity_seconds 7_200
  @day_start ~T[00:00:00]
  @utc "Etc/UTC"

  @type occurrence :: %{
          occurrence_key: String.t(),
          reminder_rule_id: String.t(),
          event_occurrence_at: DateTime.t(),
          scheduled_for: DateTime.t(),
          valid_until: DateTime.t(),
          payload: map()
        }

  @type plan :: %{
          occurrences: [occurrence()],
          next_occurrence_on: Date.t(),
          materialized_through_on: Date.t()
        }

  @doc "How many future annual occurrences stay materialized (§9.1)."
  @spec annual_horizon() :: pos_integer()
  def annual_horizon, do: @annual_horizon

  @doc """
  Materializes the bounded reminder plan for an event.

  Returns the concrete occurrences (past lead rules already skipped) plus the
  horizon caches the event row stores. Every failure is a tagged error; nothing
  is silently dropped or shifted.
  """
  @spec materialize(map(), DateTime.t()) :: {:ok, plan()} | {:error, term()}
  def materialize(event, %DateTime{} = now) when is_map(event) do
    with {:ok, spec} <- normalize_event(event),
         {:ok, dates} <- occurrence_dates(spec, now),
         {:ok, occurrences} <- build_occurrences(spec, dates, now) do
      {:ok,
       %{
         occurrences: occurrences,
         next_occurrence_on: List.first(dates),
         materialized_through_on: List.last(dates)
       }}
    end
  end

  @doc """
  Resolves a local wall time to a UTC instant through an IANA timezone.

  A DST gap is `{:error, {:dst_gap, timezone, date, time}}`. A DST fold is
  `{:error, {:dst_ambiguous, offsets}}` unless `utc_offset` (for example
  `"-04:00"`) selects exactly one of the two valid instants.
  """
  @spec resolve_local_datetime(Date.t(), Time.t(), String.t(), String.t() | nil) ::
          {:ok, DateTime.t()} | {:error, term()}
  def resolve_local_datetime(%Date{} = date, %Time{} = time, timezone, utc_offset)
      when is_binary(timezone) and (is_binary(utc_offset) or is_nil(utc_offset)) do
    case DateTime.new(date, time, timezone) do
      {:ok, resolved} -> {:ok, to_utc(resolved)}
      {:ambiguous, first, second} -> select_ambiguous(first, second, utc_offset)
      {:gap, _before, _after_gap} -> {:error, {:dst_gap, timezone, date, time}}
      {:error, :time_zone_not_found} -> {:error, {:invalid_timezone, timezone}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The UTC instant after which a one-time event has passed (§9.4): the stored
  instant for a timed event, the start of the next local day for a date-only
  event. A yearly event uses its cached `next_occurrence_on`.
  """
  @spec event_boundary_at(map()) :: {:ok, DateTime.t()} | {:error, term()}
  def event_boundary_at(%{time_kind: "datetime", occurrence_at: %DateTime{} = at}), do: {:ok, at}

  def event_boundary_at(%{time_kind: "date", timezone: timezone} = event)
      when is_binary(timezone) do
    with {:ok, date} <- boundary_date(event) do
      local_day_start(Date.add(date, 1), timezone)
    end
  end

  def event_boundary_at(%{time_kind: "datetime"}), do: {:error, {:invalid_event, :occurrence_at}}
  def event_boundary_at(_event), do: {:error, {:invalid_event, :time_kind}}

  defp boundary_date(%{recurrence_kind: "once", local_date: %Date{} = date}), do: {:ok, date}

  defp boundary_date(%{recurrence_kind: "yearly", next_occurrence_on: %Date{} = date}),
    do: {:ok, date}

  defp boundary_date(_event), do: {:error, {:invalid_event, :local_date}}

  # --- event normalization -------------------------------------------------

  defp normalize_event(event) do
    with {:ok, timezone} <- fetch_timezone(event),
         :ok <- validate_shape(event),
         {:ok, rules} <- fetch_plan(event) do
      {:ok, %{event | timezone: timezone, reminder_plan: rules}}
    end
  end

  defp fetch_timezone(%{timezone: timezone}) when is_binary(timezone) and timezone != "" do
    case DateTime.new(~D[2000-01-01], @day_start, timezone) do
      {:error, :time_zone_not_found} -> {:error, {:invalid_timezone, timezone}}
      _resolved -> {:ok, timezone}
    end
  end

  defp fetch_timezone(_event), do: {:error, {:invalid_event, :timezone}}

  defp fetch_plan(%{reminder_plan: rules}) do
    Defaults.validate_plan(rules, allow_empty: true)
  end

  defp fetch_plan(_event), do: {:error, {:invalid_event, :reminder_plan}}

  defp validate_shape(%{recurrence_kind: "yearly"} = event) do
    with :ok <- validate_month_day(event) do
      validate_leap_policy(event)
    end
  end

  defp validate_shape(%{recurrence_kind: "once", time_kind: "datetime"} = event) do
    with :ok <- require_date(event) do
      require_occurrence_at(event)
    end
  end

  defp validate_shape(%{recurrence_kind: "once", time_kind: "date"} = event) do
    require_date(event)
  end

  defp validate_shape(_event), do: {:error, {:invalid_event, :recurrence_kind}}

  defp validate_month_day(%{recurrence_month: month, recurrence_day: day})
       when is_integer(month) and month in 1..12 and is_integer(day) and day in 1..31,
       do: :ok

  defp validate_month_day(%{recurrence_month: month})
       when not (is_integer(month) and month in 1..12),
       do: {:error, {:invalid_event, :recurrence_month}}

  defp validate_month_day(_event), do: {:error, {:invalid_event, :recurrence_day}}

  defp validate_leap_policy(%{recurrence_month: 2, recurrence_day: 29, leap_day_policy: policy})
       when policy in ["feb_28", "mar_1"],
       do: :ok

  defp validate_leap_policy(%{recurrence_month: 2, recurrence_day: 29}),
    do: {:error, :leap_day_policy_required}

  defp validate_leap_policy(_event), do: :ok

  defp require_date(%{local_date: %Date{}}), do: :ok
  defp require_date(_event), do: {:error, {:invalid_event, :local_date}}

  defp require_occurrence_at(%{occurrence_at: %DateTime{}}), do: :ok
  defp require_occurrence_at(_event), do: {:error, {:invalid_event, :occurrence_at}}

  # --- occurrence dates ----------------------------------------------------

  defp occurrence_dates(%{recurrence_kind: "once", local_date: date}, _now), do: {:ok, [date]}

  defp occurrence_dates(%{recurrence_kind: "yearly"} = spec, now) do
    local_today = now |> DateTime.shift_zone!(spec.timezone) |> DateTime.to_date()

    with {:ok, first_year} <- first_annual_year(spec, local_today) do
      collect_annual_dates(spec, first_year)
    end
  end

  defp first_annual_year(spec, local_today) do
    with {:ok, this_year} <- annual_date(spec, local_today.year) do
      case Date.compare(this_year, local_today) do
        :lt -> {:ok, local_today.year + 1}
        _not_past -> {:ok, local_today.year}
      end
    end
  end

  defp collect_annual_dates(spec, first_year) do
    Enum.reduce_while(0..(@annual_horizon - 1), {:ok, []}, fn offset, {:ok, acc} ->
      case annual_date(spec, first_year + offset) do
        {:ok, date} -> {:cont, {:ok, acc ++ [date]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp annual_date(%{recurrence_month: 2, recurrence_day: 29} = spec, year) do
    case Date.new(year, 2, 29) do
      {:ok, date} -> {:ok, date}
      {:error, :invalid_date} -> leap_day_date(year, spec.leap_day_policy)
    end
  end

  defp annual_date(spec, year) do
    case Date.new(year, spec.recurrence_month, spec.recurrence_day) do
      {:ok, date} -> {:ok, date}
      {:error, :invalid_date} -> {:error, {:invalid_event, :recurrence_day}}
    end
  end

  defp leap_day_date(year, "feb_28"), do: Date.new(year, 2, 28)
  defp leap_day_date(year, "mar_1"), do: Date.new(year, 3, 1)

  # --- occurrence building -------------------------------------------------

  defp build_occurrences(spec, dates, now) do
    Enum.reduce_while(dates, {:ok, []}, fn date, {:ok, acc} ->
      case build_occurrence(spec, date, now) do
        {:ok, rows} -> {:cont, {:ok, acc ++ rows}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_occurrence(spec, date, now) do
    with {:ok, begins_at} <- occurrence_begins_at(spec, date),
         {:ok, boundary_at} <- occurrence_boundary_at(spec, date),
         {:ok, resolved} <- resolve_rules(spec, date, begins_at),
         {:ok, dated} <- assign_validity(resolved, begins_at, boundary_at, date_only?(spec)) do
      rows =
        dated
        |> Enum.reject(&past?(&1, now))
        |> Enum.map(&occurrence_row(spec, date, begins_at, &1))

      {:ok, rows}
    end
  end

  defp date_only?(%{time_kind: "date"}), do: true
  defp date_only?(_spec), do: false

  defp occurrence_begins_at(%{time_kind: "datetime", occurrence_at: at}, _date), do: {:ok, at}

  defp occurrence_begins_at(%{time_kind: "date"} = spec, date),
    do: local_day_start(date, spec.timezone)

  defp occurrence_boundary_at(%{time_kind: "datetime", occurrence_at: at}, _date), do: {:ok, at}

  defp occurrence_boundary_at(%{time_kind: "date"} = spec, date),
    do: local_day_start(Date.add(date, 1), spec.timezone)

  defp resolve_rules(spec, date, begins_at) do
    with {:ok, resolved} <- resolve_each_rule(spec, date, begins_at) do
      {:ok,
       Enum.sort_by(resolved, &{DateTime.to_unix(&1.scheduled_for, :microsecond), &1.rule_id})}
    end
  end

  defp resolve_each_rule(spec, date, begins_at) do
    Enum.reduce_while(spec.reminder_plan, {:ok, []}, fn rule, {:ok, acc} ->
      case resolve_rule(rule, spec, date, begins_at) do
        {:ok, at} -> {:cont, {:ok, acc ++ [%{rule_id: rule.rule_id, scheduled_for: at}]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_rule(%{kind: :days_before, days: days, at: at}, spec, date, _begins_at) do
    resolve_local_datetime(Date.add(date, -days), at, spec.timezone, nil)
  end

  defp resolve_rule(%{kind: :duration_before, seconds: seconds, rule_id: id}, spec, _date, begins) do
    with :ok <- require_timed(spec, id) do
      {:ok, DateTime.add(begins, -seconds, :second)}
    end
  end

  defp resolve_rule(%{kind: :at_occurrence, rule_id: id}, spec, _date, begins_at) do
    with :ok <- require_timed(spec, id) do
      {:ok, begins_at}
    end
  end

  defp require_timed(%{time_kind: "datetime"}, _rule_id), do: :ok
  defp require_timed(_spec, rule_id), do: {:error, {:rule_requires_datetime, rule_id}}

  # Validity walks the resolved rules in order (§8.3): an early rule is valid
  # until the next rule is due; the last rule is valid until the event begins,
  # to the end of the local day for a date-only event, or two hours past an
  # exact-time reminder scheduled at/after the event boundary. Bounded by the
  # plan cap.
  defp assign_validity([], _begins_at, _boundary_at, _date_only?), do: {:ok, []}

  defp assign_validity([last], begins_at, boundary_at, date_only?) do
    valid_until = last_validity(last, begins_at, boundary_at, date_only?)

    with :ok <- validate_window(last, valid_until),
         do: {:ok, [Map.put(last, :valid_until, valid_until)]}
  end

  defp assign_validity([current, next | rest], begins_at, boundary_at, date_only?) do
    with :ok <- validate_window(current, next.scheduled_for),
         {:ok, tail} <- assign_validity([next | rest], begins_at, boundary_at, date_only?) do
      {:ok, [Map.put(current, :valid_until, next.scheduled_for) | tail]}
    end
  end

  defp last_validity(rule, begins_at, boundary_at, date_only?) do
    cond do
      DateTime.compare(rule.scheduled_for, begins_at) == :lt -> begins_at
      date_only? -> boundary_at
      true -> DateTime.add(rule.scheduled_for, @explicit_validity_seconds, :second)
    end
  end

  defp validate_window(rule, valid_until) do
    case DateTime.compare(rule.scheduled_for, valid_until) do
      :lt -> :ok
      _not_before -> {:error, {:invalid_rule_time, rule.rule_id}}
    end
  end

  defp past?(rule, now), do: DateTime.compare(rule.scheduled_for, now) != :gt

  defp occurrence_row(spec, date, begins_at, rule) do
    %{
      occurrence_key: Date.to_iso8601(date),
      reminder_rule_id: rule.rule_id,
      event_occurrence_at: begins_at,
      scheduled_for: rule.scheduled_for,
      valid_until: rule.valid_until,
      payload: payload(spec, date, rule.rule_id)
    }
  end

  defp payload(spec, date, rule_id) do
    %{
      "title" => spec.title,
      "kind" => spec.kind,
      "rule_id" => rule_id,
      "occurrence_key" => Date.to_iso8601(date),
      "event_local_date" => Date.to_iso8601(date),
      "event_local_time" => optional_time(spec.local_time),
      "timezone" => spec.timezone
    }
  end

  defp optional_time(nil), do: nil
  defp optional_time(%Time{} = time), do: Time.to_iso8601(time)

  # --- timezone helpers ----------------------------------------------------

  # A calendar-day boundary is structural, not owner input: a midnight that
  # falls in a DST gap resolves to the instant the gap ends, and an ambiguous
  # midnight to the first valid instant, so a date-only event always has one
  # boundary. Owner-facing wall times use the strict resolver above.
  defp local_day_start(date, timezone) do
    case DateTime.new(date, @day_start, timezone) do
      {:ok, resolved} -> {:ok, to_utc(resolved)}
      {:ambiguous, first, _second} -> {:ok, to_utc(first)}
      {:gap, _before, after_gap} -> {:ok, to_utc(after_gap)}
      {:error, :time_zone_not_found} -> {:error, {:invalid_timezone, timezone}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_ambiguous(first, second, nil) do
    {:error, {:dst_ambiguous, [offset_string(first), offset_string(second)]}}
  end

  defp select_ambiguous(first, second, utc_offset) do
    case Enum.filter([first, second], &(offset_string(&1) == utc_offset)) do
      [only] -> {:ok, to_utc(only)}
      _none_or_both -> {:error, {:dst_ambiguous, [offset_string(first), offset_string(second)]}}
    end
  end

  @doc false
  # Shared with `Temporal.Registry`, which renders the stored instant's offset
  # in the same `±HH:MM` form the DST-fold selection accepts.
  @spec offset_string(DateTime.t()) :: String.t()
  def offset_string(%DateTime{utc_offset: utc_offset, std_offset: std_offset}) do
    total = utc_offset + std_offset
    sign = if total < 0, do: "-", else: "+"
    magnitude = abs(total)

    sign <>
      pad2(div(magnitude, 3600)) <> ":" <> pad2(div(rem(magnitude, 3600), 60))
  end

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp to_utc(%DateTime{} = value), do: DateTime.shift_zone!(value, @utc)
end
