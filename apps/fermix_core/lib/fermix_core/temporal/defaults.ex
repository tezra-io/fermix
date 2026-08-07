defmodule FermixCore.Temporal.Defaults do
  @moduledoc """
  Finite default reminder plans (M30 §8.1) and the plan caps (§8.2).

  Pure data: no clock reads, no I/O, no configuration. A plan is a bounded list
  of rules with stable `rule_id`s; explicit owner instructions replace a default
  plan for an event, they never silently append to it.

  Rule kinds:

    * `:days_before` — a date-only lead. The notification local date is the
      occurrence date minus `days`; its wall time is `at`.
    * `:duration_before` — an absolute lead. `seconds` are subtracted from the
      event's resolved UTC instant, so it requires a timed event.
    * `:at_occurrence` — the event instant itself; requires a timed event.
  """

  @max_rules 10
  @morning ~T[09:00:00]

  @type rule :: %{
          required(:rule_id) => String.t(),
          required(:kind) => :days_before | :duration_before | :at_occurrence,
          optional(:days) => non_neg_integer(),
          optional(:at) => Time.t(),
          optional(:seconds) => pos_integer()
        }

  @type validate_error ::
          {:too_many_rules, pos_integer()}
          | {:duplicate_rule_id, String.t()}
          | {:invalid_rule, term()}
          | :empty_plan_not_allowed
          | :invalid_plan

  @doc "Maximum reminder rules per event (§8.2)."
  @spec max_rules() :: pos_integer()
  def max_rules, do: @max_rules

  @doc """
  The default plan for an event shape, or `{:error, {:no_default_plan, kind,
  time_kind}}` when the combination has no default (the tool then asks the owner
  for an explicit plan).
  """
  @spec plan_for(String.t(), String.t()) :: {:ok, [rule()]} | {:error, term()}
  def plan_for(kind, time_kind) when is_binary(kind) and is_binary(time_kind) do
    case default_rules(kind, time_kind) do
      nil -> {:error, {:no_default_plan, kind, time_kind}}
      rules -> {:ok, rules}
    end
  end

  defp default_rules(kind, "date") when kind in ["birthday", "anniversary"] do
    [days_before("week_before", 7), days_before("day_of", 0)]
  end

  defp default_rules(kind, "datetime") when kind in ["appointment", "event", "deadline"] do
    [duration_before("hours_24_before", 86_400), duration_before("hour_1_before", 3_600)]
  end

  defp default_rules(kind, "date") when kind in ["appointment", "event", "deadline"] do
    [days_before("week_before", 7), days_before("day_before", 1), days_before("day_of", 0)]
  end

  defp default_rules(kind, "datetime") when kind in ["follow_up", "explicit_reminder"] do
    [%{rule_id: "at_time", kind: :at_occurrence}]
  end

  defp default_rules(kind, "date") when kind in ["follow_up", "explicit_reminder"] do
    [days_before("day_of", 0)]
  end

  defp default_rules(_kind, _time_kind), do: nil

  defp days_before(rule_id, days) do
    %{rule_id: rule_id, kind: :days_before, days: days, at: @morning}
  end

  defp duration_before(rule_id, seconds) do
    %{rule_id: rule_id, kind: :duration_before, seconds: seconds}
  end

  @doc """
  Validates a plan against the §8.2 caps: at most #{@max_rules} rules, a stable
  unique `rule_id` per rule, well-formed rule shapes, and a non-empty plan
  unless the caller passes `allow_empty: true` (the owner explicitly asked for
  an event without notifications).
  """
  @spec validate_plan([rule()], keyword()) :: {:ok, [rule()]} | {:error, validate_error()}
  def validate_plan(rules, opts \\ [])

  def validate_plan(rules, opts) when is_list(rules) and is_list(opts) do
    with :ok <- validate_size(rules, Keyword.get(opts, :allow_empty, false)),
         :ok <- validate_rules(rules),
         :ok <- validate_unique_ids(rules) do
      {:ok, rules}
    end
  end

  def validate_plan(_rules, _opts), do: {:error, :invalid_plan}

  defp validate_size([], false), do: {:error, :empty_plan_not_allowed}

  defp validate_size(rules, _allow_empty) when length(rules) > @max_rules do
    {:error, {:too_many_rules, length(rules)}}
  end

  defp validate_size(_rules, _allow_empty), do: :ok

  defp validate_rules(rules) do
    case Enum.find(rules, &(not valid_rule?(&1))) do
      nil -> :ok
      rule -> {:error, {:invalid_rule, rule}}
    end
  end

  defp valid_rule?(%{rule_id: id, kind: :days_before, days: days, at: %Time{}})
       when is_binary(id) and id != "" and is_integer(days) and days >= 0,
       do: true

  defp valid_rule?(%{rule_id: id, kind: :duration_before, seconds: seconds})
       when is_binary(id) and id != "" and is_integer(seconds) and seconds > 0,
       do: true

  defp valid_rule?(%{rule_id: id, kind: :at_occurrence}) when is_binary(id) and id != "", do: true
  defp valid_rule?(_rule), do: false

  defp validate_unique_ids(rules) do
    duplicate =
      rules
      |> Enum.map(& &1.rule_id)
      |> Enum.frequencies()
      |> Enum.find(fn {_id, count} -> count > 1 end)

    case duplicate do
      nil -> :ok
      {id, _count} -> {:error, {:duplicate_rule_id, id}}
    end
  end

  @doc "Encodes a validated plan into JSON-safe string-keyed maps for storage."
  @spec encode_plan([rule()]) :: [map()]
  def encode_plan(rules) when is_list(rules), do: Enum.map(rules, &encode_rule/1)

  defp encode_rule(%{rule_id: id, kind: :days_before, days: days, at: %Time{} = at}) do
    %{"rule_id" => id, "kind" => "days_before", "days" => days, "at" => Time.to_iso8601(at)}
  end

  defp encode_rule(%{rule_id: id, kind: :duration_before, seconds: seconds}) do
    %{"rule_id" => id, "kind" => "duration_before", "seconds" => seconds}
  end

  defp encode_rule(%{rule_id: id, kind: :at_occurrence}) do
    %{"rule_id" => id, "kind" => "at_occurrence"}
  end

  @doc """
  Decodes a stored plan back into rules. An unrecognized rule shape is an
  error, never a guess.
  """
  @spec decode_plan([map()]) :: {:ok, [rule()]} | {:error, validate_error()}
  def decode_plan(encoded) when is_list(encoded) do
    Enum.reduce_while(encoded, {:ok, []}, fn raw, {:ok, acc} ->
      case decode_rule(raw) do
        {:ok, rule} -> {:cont, {:ok, acc ++ [rule]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def decode_plan(_encoded), do: {:error, :invalid_plan}

  defp decode_rule(%{"rule_id" => id, "kind" => "days_before", "days" => days, "at" => at})
       when is_binary(id) and is_integer(days) do
    case Time.from_iso8601(at) do
      {:ok, time} -> validated_rule(%{rule_id: id, kind: :days_before, days: days, at: time})
      {:error, _reason} -> {:error, {:invalid_rule, at}}
    end
  end

  defp decode_rule(%{"rule_id" => id, "kind" => "duration_before", "seconds" => seconds}) do
    validated_rule(%{rule_id: id, kind: :duration_before, seconds: seconds})
  end

  defp decode_rule(%{"rule_id" => id, "kind" => "at_occurrence"}) do
    validated_rule(%{rule_id: id, kind: :at_occurrence})
  end

  defp decode_rule(raw), do: {:error, {:invalid_rule, raw}}

  defp validated_rule(rule) do
    if valid_rule?(rule), do: {:ok, rule}, else: {:error, {:invalid_rule, rule}}
  end
end
