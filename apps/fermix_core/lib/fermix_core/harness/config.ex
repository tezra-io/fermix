defmodule FermixCore.Harness.Config do
  @moduledoc """
  Typed accessors and validation for the coding-harness settings block
  (`[fermix_core.harness]`).

  Modeled on `FermixCore.Memory.CompactionConfig`: defaults live as module
  attributes, `normalize/1` builds a keyword of only the present keys — each
  value passed through a fail-loud validator that names the offending key and
  value — and one reader function per key reads the runtime keyword (defaulting
  to `Application.get_env(:fermix_core, :harness, [])`).

  There is no `config.exs` baseline for this section: the daemon runs without
  the harness by default (`enabled` defaults `true` per the design, but the
  feature only advertises when a vendor binary is also present). So the persisted
  TOML is the sole source and `Setup.ConfigStore` applies it replace-style.

  Numeric bounds fail loud on invalid input. Counters, sizes, and durations that
  would break the feature at zero (`max_active`, timeouts, byte/size caps, poll
  intervals, delivery counts) require a positive integer; `max_framing_errors`
  and `min_free_gb` are non-negative because zero is a coherent setting
  (zero framing tolerance; no free-space floor).
  """

  @type t :: keyword()

  @default_enabled true
  @default_approved false
  @default_cloud_enabled false
  @default_default_vendor nil
  @default_max_active 2
  @default_default_timeout_minutes 30
  @default_inactivity_minutes 10
  @default_prompt_argv_max_kb 200
  @default_max_event_bytes 1_048_576
  @default_max_framing_errors 20
  @default_max_run_artifact_mb 64
  @default_artifact_quota_gb 5
  @default_min_free_gb 2
  @default_artifact_retention_days 30
  @default_delivery_max_attempts 20
  @default_delivery_max_age_hours 24
  @default_cloud_poll_seconds 120
  @default_cloud_poll_max_minutes 90
  @default_codex_home nil
  @default_claude_config_dir nil

  @config_keys [
    :enabled,
    :approved,
    :cloud_enabled,
    :default_vendor,
    :max_active,
    :default_timeout_minutes,
    :inactivity_minutes,
    :prompt_argv_max_kb,
    :max_event_bytes,
    :max_framing_errors,
    :max_run_artifact_mb,
    :artifact_quota_gb,
    :min_free_gb,
    :artifact_retention_days,
    :delivery_max_attempts,
    :delivery_max_age_hours,
    :cloud_poll_seconds,
    :cloud_poll_max_minutes,
    :codex_home,
    :claude_config_dir
  ]

  @non_negative_int_keys [:max_framing_errors, :min_free_gb]

  @positive_int_keys [
    :max_active,
    :default_timeout_minutes,
    :inactivity_minutes,
    :prompt_argv_max_kb,
    :max_event_bytes,
    :max_run_artifact_mb,
    :artifact_quota_gb,
    :artifact_retention_days,
    :delivery_max_attempts,
    :delivery_max_age_hours,
    :cloud_poll_seconds,
    :cloud_poll_max_minutes
  ]

  @doc """
  Canonical list of allowed `[fermix_core.harness]` keys, used by the config
  store to reject typo'd keys at the parse boundary.
  """
  @spec config_keys() :: [atom()]
  def config_keys, do: @config_keys

  @spec normalize(nil | map() | keyword()) :: t()
  def normalize(nil), do: []

  def normalize(config) when is_map(config) or is_list(config) do
    Enum.reduce(@config_keys, [], fn key, acc ->
      put_if_present(acc, key, normalize_value(key, lookup(config, Atom.to_string(key), key)))
    end)
  end

  @spec enabled?(t()) :: boolean()
  def enabled?(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :enabled, @default_enabled)
  end

  @doc """
  Owner consent to launch coding agents on this machine (the first-use gate,
  owner decision 2026-07-21; a setup decision since design §23.3). Independent of
  `enabled?/1`: `enabled` says the feature exists, `approved` says the owner has
  consented on this host. Defaults `false` — until it is set (Setup → Coding
  Agents, or this config key) the run tools neither advertise nor execute.
  """
  @spec approved?(t()) :: boolean()
  def approved?(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :approved, @default_approved)
  end

  @doc """
  Whether the Codex **cloud** rail is on (owner decision 2026-07-23). Defaults
  `false` — the cloud tools (`codex_cloud_run` / `stop_tracking_coding_run`) do
  not seed and never advertise or dispatch until this key is set `true`. The
  cloud lifecycle code stays in the tree; this flag is the single gate that keeps
  it dormant. Independent of `enabled?/1` (the whole-harness gate).
  """
  @spec cloud_enabled?(t()) :: boolean()
  def cloud_enabled?(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :cloud_enabled, @default_cloud_enabled)
  end

  @spec default_vendor(t()) :: String.t() | nil
  def default_vendor(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :default_vendor, @default_default_vendor)
  end

  @spec max_active(t()) :: pos_integer()
  def max_active(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :max_active, @default_max_active)
  end

  @spec default_timeout_minutes(t()) :: pos_integer()
  def default_timeout_minutes(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :default_timeout_minutes, @default_default_timeout_minutes)
  end

  @spec inactivity_minutes(t()) :: pos_integer()
  def inactivity_minutes(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :inactivity_minutes, @default_inactivity_minutes)
  end

  @spec prompt_argv_max_kb(t()) :: pos_integer()
  def prompt_argv_max_kb(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :prompt_argv_max_kb, @default_prompt_argv_max_kb)
  end

  @spec max_event_bytes(t()) :: pos_integer()
  def max_event_bytes(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :max_event_bytes, @default_max_event_bytes)
  end

  @spec max_framing_errors(t()) :: non_neg_integer()
  def max_framing_errors(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :max_framing_errors, @default_max_framing_errors)
  end

  @spec max_run_artifact_mb(t()) :: pos_integer()
  def max_run_artifact_mb(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :max_run_artifact_mb, @default_max_run_artifact_mb)
  end

  @spec artifact_quota_gb(t()) :: pos_integer()
  def artifact_quota_gb(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :artifact_quota_gb, @default_artifact_quota_gb)
  end

  @spec min_free_gb(t()) :: non_neg_integer()
  def min_free_gb(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :min_free_gb, @default_min_free_gb)
  end

  @spec artifact_retention_days(t()) :: pos_integer()
  def artifact_retention_days(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :artifact_retention_days, @default_artifact_retention_days)
  end

  @spec delivery_max_attempts(t()) :: pos_integer()
  def delivery_max_attempts(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :delivery_max_attempts, @default_delivery_max_attempts)
  end

  @spec delivery_max_age_hours(t()) :: pos_integer()
  def delivery_max_age_hours(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :delivery_max_age_hours, @default_delivery_max_age_hours)
  end

  @spec cloud_poll_seconds(t()) :: pos_integer()
  def cloud_poll_seconds(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :cloud_poll_seconds, @default_cloud_poll_seconds)
  end

  @spec cloud_poll_max_minutes(t()) :: pos_integer()
  def cloud_poll_max_minutes(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :cloud_poll_max_minutes, @default_cloud_poll_max_minutes)
  end

  @spec codex_home(t()) :: String.t() | nil
  def codex_home(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :codex_home, @default_codex_home)
  end

  @spec claude_config_dir(t()) :: String.t() | nil
  def claude_config_dir(config \\ Application.get_env(:fermix_core, :harness, [])) do
    Keyword.get(config, :claude_config_dir, @default_claude_config_dir)
  end

  defp normalize_value(_key, nil), do: nil
  defp normalize_value(:enabled, value), do: normalize_enabled(value)
  defp normalize_value(:approved, value), do: normalize_approved(value)
  defp normalize_value(:cloud_enabled, value), do: normalize_cloud_enabled(value)
  defp normalize_value(:default_vendor, value), do: normalize_default_vendor(value)
  defp normalize_value(:codex_home, value), do: normalize_path(:codex_home, value)
  defp normalize_value(:claude_config_dir, value), do: normalize_path(:claude_config_dir, value)

  defp normalize_value(key, value) when key in @non_negative_int_keys,
    do: normalize_non_negative_int(key, value)

  defp normalize_value(key, value) when key in @positive_int_keys,
    do: normalize_positive_int(key, value)

  defp normalize_enabled(value) when is_boolean(value), do: value

  defp normalize_enabled(value) do
    raise ArgumentError,
          "invalid harness.enabled #{inspect(value)}; expected boolean true or false"
  end

  defp normalize_approved(value) when is_boolean(value), do: value

  defp normalize_approved(value) do
    raise ArgumentError,
          "invalid harness.approved #{inspect(value)}; expected boolean true or false"
  end

  defp normalize_cloud_enabled(value) when is_boolean(value), do: value

  defp normalize_cloud_enabled(value) do
    raise ArgumentError,
          "invalid harness.cloud_enabled #{inspect(value)}; expected boolean true or false"
  end

  defp normalize_default_vendor(value) when value in [:codex, "codex"], do: "codex"
  defp normalize_default_vendor(value) when value in [:claude, "claude"], do: "claude"

  defp normalize_default_vendor(value) do
    raise ArgumentError,
          "invalid harness.default_vendor #{inspect(value)}; expected \"codex\" or \"claude\""
  end

  defp normalize_path(_key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_path(key, value) do
    raise ArgumentError, "invalid harness.#{key} #{inspect(value)}; expected a string path"
  end

  defp normalize_positive_int(_key, value) when is_integer(value) and value > 0, do: value

  defp normalize_positive_int(key, value) do
    raise ArgumentError, "invalid harness.#{key} #{inspect(value)}; expected a positive integer"
  end

  defp normalize_non_negative_int(_key, value) when is_integer(value) and value >= 0, do: value

  defp normalize_non_negative_int(key, value) do
    raise ArgumentError,
          "invalid harness.#{key} #{inspect(value)}; expected a non-negative integer"
  end

  defp lookup(config, string_key, atom_key) when is_map(config) do
    Map.get(config, string_key, Map.get(config, atom_key))
  end

  defp lookup(config, _string_key, atom_key) when is_list(config) do
    Keyword.get(config, atom_key)
  end

  defp put_if_present(keyword, _key, nil), do: keyword
  defp put_if_present(keyword, key, value), do: Keyword.put(keyword, key, value)
end
