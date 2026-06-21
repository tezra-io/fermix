defmodule FermixCore.ComputerUse.Config do
  @moduledoc """
  Runtime configuration for the computer-use subsystem — GUI control of a desktop
  (`:host`) or a browser context (`:browser`).

  Off by default. `:host` mode drives the real logged-in desktop and is dangerous
  (ambient authority, no rollback, unsolved screenshot prompt-injection); it is
  gated behind an explicit grant + loud consent at the tool/session boundary, and
  `confirm_consequential?` defaults to true so every mutating action is confirmed
  (docs/design/COMPUTER_USE.md §7). This module is pure config normalization with
  fail-loud validation; it mirrors `FermixCore.Realtime.Config`.
  """

  @modes [:browser, :host]

  # Long-edge cap per design §5 (oversized captures 400 on Anthropic and ground
  # worse); a sane floor so a typo can't request a 1px display.
  @min_dimension_px 320
  @max_dimension_px 1366

  @type mode :: :browser | :host

  @type t :: %__MODULE__{
          enabled?: boolean(),
          mode: mode(),
          display: non_neg_integer(),
          display_width_px: pos_integer(),
          display_height_px: pos_integer(),
          allowed_apps: [String.t()],
          allowed_domains: [String.t()],
          confirm_consequential?: boolean(),
          screenshot_after?: boolean(),
          max_actions: pos_integer(),
          max_retained_screenshots: pos_integer(),
          approval_timeout_ms: pos_integer()
        }

  defstruct enabled?: false,
            mode: :browser,
            display: 0,
            display_width_px: 1280,
            display_height_px: 800,
            allowed_apps: [],
            allowed_domains: [],
            confirm_consequential?: true,
            screenshot_after?: true,
            max_actions: 40,
            max_retained_screenshots: 3,
            approval_timeout_ms: 300_000

  @spec current() :: t()
  def current do
    :fermix_core
    |> Application.get_env(:computer_use, [])
    |> normalize()
  end

  @spec enabled?() :: boolean()
  def enabled?, do: current().enabled?

  @spec normalize(keyword() | map() | nil) :: t()
  def normalize(nil), do: normalize([])

  def normalize(config) when is_list(config) or is_map(config) do
    cu = %__MODULE__{
      enabled?: bool(config, :enabled, false),
      mode: mode(config, :mode, :browser),
      display: non_neg_int(config, :display, 0),
      display_width_px: dimension(config, :display_width_px, 1280),
      display_height_px: dimension(config, :display_height_px, 800),
      allowed_apps: string_list(config, :allowed_apps),
      allowed_domains: string_list(config, :allowed_domains),
      confirm_consequential?: bool(config, :confirm_consequential, true),
      screenshot_after?: bool(config, :screenshot_after, true),
      max_actions: positive_int(config, :max_actions, 40),
      max_retained_screenshots: positive_int(config, :max_retained_screenshots, 3),
      approval_timeout_ms: positive_int(config, :approval_timeout_ms, 300_000)
    }

    validate!(cu)
  end

  @doc """
  Round-trips a normalized config back to the persisted keyword shape (TOML keys
  carry no `?` suffix). Mirrors `FermixCore.Realtime.Config.to_keyword/1`; used by
  `ConfigStore.persistable_snapshot/1` so the section survives save→load→apply.
  """
  @spec to_keyword(t()) :: keyword()
  def to_keyword(%__MODULE__{} = cu) do
    [
      enabled: cu.enabled?,
      mode: cu.mode,
      display: cu.display,
      display_width_px: cu.display_width_px,
      display_height_px: cu.display_height_px,
      allowed_apps: cu.allowed_apps,
      allowed_domains: cu.allowed_domains,
      confirm_consequential: cu.confirm_consequential?,
      screenshot_after: cu.screenshot_after?,
      max_actions: cu.max_actions,
      max_retained_screenshots: cu.max_retained_screenshots,
      approval_timeout_ms: cu.approval_timeout_ms
    ]
  end

  # Host mode against a real session must keep the long edge within the cap so a
  # screenshot is actually sendable; both dimensions are bounded already. Nothing
  # else is cross-field, so validation is mostly per-field (above).
  defp validate!(%__MODULE__{} = cu), do: cu

  defp mode(config, key, default) do
    case lookup(config, key) do
      nil ->
        default

      value when value in @modes ->
        value

      "browser" ->
        :browser

      "host" ->
        :host

      value ->
        raise ArgumentError,
              "computer_use.#{key} must be one of #{inspect(@modes)}, got: #{inspect(value)}"
    end
  end

  defp dimension(config, key, default) do
    value = positive_int(config, key, default)

    if value < @min_dimension_px or value > @max_dimension_px do
      raise ArgumentError,
            "computer_use.#{key} must be between #{@min_dimension_px} and #{@max_dimension_px} px " <>
              "(design §5 caps the long edge so a capture stays sendable), got: #{value}"
    end

    value
  end

  defp string_list(config, key) do
    case lookup(config, key) do
      nil ->
        []

      value when is_list(value) ->
        Enum.map(value, fn
          item when is_binary(item) and item != "" ->
            item

          item ->
            raise ArgumentError,
                  "computer_use.#{key} entries must be non-empty strings, got: #{inspect(item)}"
        end)

      value ->
        raise ArgumentError,
              "computer_use.#{key} must be a list of strings, got: #{inspect(value)}"
    end
  end

  defp bool(config, key, default) do
    case lookup(config, key) do
      nil ->
        default

      value when is_boolean(value) ->
        value

      "true" ->
        true

      "false" ->
        false

      value ->
        raise ArgumentError, "computer_use.#{key} must be a boolean, got: #{inspect(value)}"
    end
  end

  defp positive_int(config, key, default) do
    case lookup(config, key) do
      nil ->
        default

      value when is_integer(value) and value > 0 ->
        value

      value ->
        raise ArgumentError,
              "computer_use.#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp non_neg_int(config, key, default) do
    case lookup(config, key) do
      nil ->
        default

      value when is_integer(value) and value >= 0 ->
        value

      value ->
        raise ArgumentError,
              "computer_use.#{key} must be a non-negative integer, got: #{inspect(value)}"
    end
  end

  defp lookup(config, key) when is_list(config) do
    case Keyword.fetch(config, key) do
      {:ok, value} -> value
      :error -> keyword_string_value(config, Atom.to_string(key))
    end
  end

  defp lookup(config, key) when is_map(config) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key))
  end

  defp keyword_string_value(config, string_key) do
    Enum.find_value(config, fn
      {^string_key, value} -> value
      _other -> nil
    end)
  end
end
