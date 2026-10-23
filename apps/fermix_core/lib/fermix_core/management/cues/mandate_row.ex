defmodule FermixCore.Management.Cues.MandateRow do
  @moduledoc """
  One mandate as the management socket publishes it (M60 app surface §3.4),
  and the translation of a mandate form's `values` into the section
  `Cues.Settings.save_mandate/3` saves.

  Every field is always present, null where it does not apply. `load` is
  `Cues.Mandates`' verdict (active, or inactive with the check's sentence);
  `approval` is `Cues.Pins.status/2` (`unapproved`, `approved`, `changed`,
  `disabled`), with a null `state` where memory is off and the approval
  cannot be read. A client switches on `primary_action` (`approve` or null)
  and `actions` (closed: `approve`, `enable`, `disable`), never on a state.

  Durations travel as whole seconds (`approve_within_s`, `max_cue_age_s`); the
  section holds the duration the config reads ("30m"). Paths are the owner's
  own configuration and are published as written.
  """

  alias FermixCore.Cues.Mandates

  @actions ~w(approve enable disable)
  @memory_off "Cues keep their records in memory, which is off."
  @approve_consent "Each call waits for your yes before it runs."
  @auto_consent "Calls run without asking you. Only its validator or pinned arguments limit them."

  @text_values %{
    "job" => :job,
    "validator" => :validator,
    "interpreter" => :interpreter,
    "idempotency_arg" => :idempotency_arg
  }
  @list_values %{
    "tools" => :tools,
    "read_tools" => :read_tools,
    "validator_env" => :validator_env,
    "unpinned" => :unpinned
  }
  # A section key the config's check names, as the mandate form's key.
  @form_keys %{
    "job" => "job",
    "enabled" => "enabled",
    "mode" => "mode",
    "approve_within" => "approve_within_s",
    "max_cue_age" => "max_cue_age_s",
    "tools" => "tools",
    "read_tools" => "read_tools",
    "validator" => "validator",
    "interpreter" => "interpreter",
    "validator_env" => "validator_env",
    "idempotency_arg" => "idempotency_arg",
    "unpinned" => "unpinned",
    "pin_args" => "pin_args"
  }
  @max_approve_within_s 86_400
  @max_list_items 200

  @type facts :: %{counts: map(), window_s: pos_integer()}
  @type refusal :: {String.t(), String.t()}

  @doc "Every action a mandate row can carry."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc "The row of one `Cues.Overview.mandates/2` entry."
  @spec build(%{mandate: Mandates.t(), approval: term()}, facts()) :: map()
  def build(%{mandate: %Mandates{} = mandate, approval: approval}, facts) when is_map(facts) do
    approval = approval_view(approval)
    primary = primary_action(mandate, approval)

    %{
      "name" => mandate.name,
      "enabled" => mandate.enabled?,
      "job" => %{"id" => mandate.job, "name" => mandate.job_name},
      "mode" => Atom.to_string(mandate.mode),
      "approve_within_s" => mandate.approve_within_s,
      "max_cue_age_s" => mandate.max_cue_age_s,
      "tools" => mandate.tools,
      "read_tools" => mandate.read_tools,
      "validator" => validator(mandate),
      "idempotency_arg" => mandate.idempotency_arg,
      "unpinned" => mandate.unpinned,
      "pin_args" => pin_args(mandate.pin_args),
      "load" => load(mandate.status),
      "approval" => approval,
      "counts" => counts(Map.get(facts.counts, mandate.name), facts.window_s),
      "consent_sentence" => consent(mandate.mode),
      "status_sentence" => sentence(mandate, approval),
      "primary_action" => primary,
      "actions" => [switch(mandate) | if(primary, do: [primary], else: [])]
    }
  end

  @doc """
  The form key a refusal of `Cues.Config` is about: the key its
  `cues.mandates.<name>.<key>` names, else `fallback`.
  """
  @spec field_of(String.t(), String.t()) :: String.t()
  def field_of(sentence, fallback) when is_binary(sentence) and is_binary(fallback) do
    case Regex.run(~r/cues\.mandates\.[a-z0-9-]+\.([a-z_]+)/, sentence) do
      [_match, key] -> Map.get(@form_keys, key, fallback)
      nil -> fallback
    end
  end

  @doc """
  The section a mandate form's `values` make, applied over `section` (the
  persisted shape; `[]` for a new mandate). A value replaces its key, and a
  blank text, an empty list or no pinned arguments removes it. Refused, with
  the key it names, when a value is not a field of the form or not its shape.
  """
  @spec section(keyword(), map()) :: {:ok, keyword()} | {:error, refusal()}
  def section(section, values) when is_list(section) and is_map(values) do
    Enum.reduce_while(values, {:ok, section}, fn {key, value}, {:ok, acc} ->
      case entry(key, value) do
        {:ok, {config, entry}} -> {:cont, {:ok, apply_entry(acc, config, entry)}}
        {:error, refusal} -> {:halt, {:error, refusal}}
      end
    end)
  end

  # --- row -------------------------------------------------------------------------

  defp approval_view({:ok, status}) do
    %{
      "state" => Atom.to_string(status.state),
      "approved_at" => stamp(status.approved_at),
      "approved_from" => status.approved_from,
      "disabled_at" => stamp(status.disabled_at),
      "disabled_reason" => status.disabled_reason,
      "detail" => status.detail
    }
  end

  defp approval_view({:error, :memory_off}), do: unread_approval(@memory_off)
  defp approval_view({:error, _reason}), do: unread_approval("Its approval could not be read.")

  defp unread_approval(detail) do
    %{
      "state" => nil,
      "approved_at" => nil,
      "approved_from" => nil,
      "disabled_at" => nil,
      "disabled_reason" => nil,
      "detail" => detail
    }
  end

  defp primary_action(%Mandates{status: :active}, %{"state" => state})
       when state in ["unapproved", "changed", "disabled"],
       do: "approve"

  defp primary_action(_mandate, _approval), do: nil

  defp switch(%Mandates{enabled?: true}), do: "disable"
  defp switch(%Mandates{}), do: "enable"

  defp load({:inactive, sentence}), do: %{"state" => "inactive", "sentence" => sentence}
  defp load(_active), do: %{"state" => "active", "sentence" => nil}

  defp sentence(%Mandates{enabled?: false}, _approval), do: "Off."
  defp sentence(%Mandates{status: {:inactive, sentence}}, _approval), do: sentence
  defp sentence(_mandate, %{"state" => nil, "detail" => detail}), do: detail
  defp sentence(_mandate, %{"state" => "unapproved"}), do: "Not approved yet."

  defp sentence(_mandate, %{"state" => "changed"}),
    do: "Changed since you approved it. Approve it again before it acts."

  defp sentence(_mandate, %{"state" => "disabled"}),
    do: "Turned off until you approve it again."

  defp sentence(%Mandates{mode: :approve}, _approval), do: "Approved. Each call asks you first."
  defp sentence(_mandate, _approval), do: "Approved. Calls run without asking you."

  defp consent(:approve), do: @approve_consent
  defp consent(:auto), do: @auto_consent

  defp validator(%Mandates{validator: nil}), do: nil

  defp validator(mandate) do
    %{
      "path" => mandate.validator,
      "interpreter" => mandate.interpreter,
      "env" => mandate.validator_env
    }
  end

  defp pin_args(pins) do
    pins
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} -> %{"key" => key, "value" => value} end)
  end

  defp counts(nil, window_s), do: counts(%{allowed: 0, proposed: 0, refused: 0}, window_s)

  defp counts(counts, window_s) do
    %{
      "window_s" => window_s,
      "allowed" => counts.allowed,
      "proposed" => counts.proposed,
      "refused" => counts.refused
    }
  end

  defp stamp(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp stamp(_absent), do: nil

  # --- values ------------------------------------------------------------------------

  defp entry(key, value) when is_map_key(@text_values, key),
    do: text_entry(key, Map.fetch!(@text_values, key), value)

  defp entry(key, value) when is_map_key(@list_values, key),
    do: list_entry(key, Map.fetch!(@list_values, key), value)

  defp entry("enabled", value) when is_boolean(value), do: {:ok, {:enabled, value}}
  defp entry("mode", value) when value in ["approve", "auto"], do: {:ok, {:mode, value}}

  defp entry("approve_within_s", seconds)
       when is_integer(seconds) and seconds >= 1 and seconds <= @max_approve_within_s,
       do: {:ok, {:approve_within, duration(seconds)}}

  defp entry("approve_within_s", _value),
    do: {:error, {"approve_within_s", "A proposal waits from 1 second to 24 hours."}}

  defp entry("max_cue_age_s", 0), do: {:ok, {:max_cue_age, "0"}}

  defp entry("max_cue_age_s", seconds) when is_integer(seconds) and seconds > 0,
    do: {:ok, {:max_cue_age, duration(seconds)}}

  defp entry("max_cue_age_s", _value),
    do: {:error, {"max_cue_age_s", "This takes a whole number of seconds, 0 for no limit."}}

  defp entry("pin_args", pins) when is_list(pins), do: pin_entry(pins)
  defp entry("enabled", _value), do: {:error, {"enabled", "This setting takes true or false."}}
  defp entry("mode", _value), do: {:error, {"mode", "A mandate's mode is approve or auto."}}
  defp entry("pin_args", _value), do: {:error, {"pin_args", pin_sentence()}}
  defp entry(key, _value), do: {:error, {key, "A mandate has no setting by that name."}}

  defp text_entry(key, config, value) when is_binary(value) do
    line = String.trim(value)

    if String.match?(line, ~r/[\x00-\x1F\x7F]/),
      do: {:error, {key, "This setting takes a single line of text."}},
      else: {:ok, {config, line}}
  end

  defp text_entry(key, _config, _value), do: {:error, {key, "This setting takes text."}}

  defp list_entry(key, config, values)
       when is_list(values) and length(values) <= @max_list_items do
    if Enum.all?(values, &is_binary/1),
      do: {:ok, {config, values |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))}},
      else: {:error, {key, "This setting takes a list of text values."}}
  end

  defp list_entry(key, _config, _values),
    do: {:error, {key, "This setting takes at most #{@max_list_items} text values."}}

  defp pin_entry(pins) do
    if length(pins) <= @max_list_items and Enum.all?(pins, &pin?/1),
      do: {:ok, {:pin_args, Map.new(pins, &{&1["key"], &1["value"]})}},
      else: {:error, {"pin_args", pin_sentence()}}
  end

  defp pin?(%{"key" => key, "value" => value} = pin) when map_size(pin) == 2 and is_binary(key),
    do: is_binary(value) or is_boolean(value) or is_number(value)

  defp pin?(_pin), do: false

  defp pin_sentence,
    do: "Each pinned argument is a key and a value: text, true or false, or a number."

  # The largest unit that divides the seconds, as the config writes it.
  defp duration(seconds) when rem(seconds, 3_600) == 0, do: "#{div(seconds, 3_600)}h"
  defp duration(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)}m"
  defp duration(seconds), do: "#{seconds}s"

  defp apply_entry(section, config, value) when value in [nil, "", []] or value == %{},
    do: Keyword.delete(section, config)

  defp apply_entry(section, config, value) do
    if Keyword.has_key?(section, config),
      do: List.keyreplace(section, config, 0, {config, value}),
      else: section ++ [{config, value}]
  end
end
