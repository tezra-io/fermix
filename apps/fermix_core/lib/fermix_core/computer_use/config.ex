defmodule FermixCore.ComputerUse.Config do
  @moduledoc """
  Runtime configuration for the computer-use subsystem — GUI control of a desktop
  (`:host`) or a browser context (`:browser`).

  Off by default. `:host` mode drives the real logged-in desktop and is dangerous
  (ambient authority, no rollback, unsolved screenshot prompt-injection).

  The safety posture, `access`, is DERIVED 1:1 from `[sandbox] mode` — there is NO
  separate computer-use posture knob (COMPUTER_USE.md §14): an `open` sandbox is an
  `open` desktop. Three tiers:

    * `:strict`   — look only: read-only actions run; any mutating action is refused
      (the one deterministic floor).
    * `:standard` — acts freely; the agent confirms IRREVERSIBLE actions
      conversationally before doing them (its own judgment — most destructive things).
    * `:open`     — acts autonomously; pauses to confirm ONLY a TRULY dangerous /
      catastrophic action — a HIGHER bar than standard (mass deletion, sending money,
      wiping data), not every little change.

  `access` is set by `current/0` from the live sandbox mode; the computer-use config
  never stores it. The standard/open confirm is a prompt principle (Tools.ComputerUse),
  not a gate; only `:strict` (refuse-all) and the attended-origin gate are hard floors.
  This module is pure config normalization with fail-loud validation.
  """

  alias FermixCore.Sandbox.Config, as: SandboxConfig

  @modes [:browser, :host]

  # Long-edge cap per design §5 (oversized captures 400 on Anthropic and ground
  # worse); a sane floor so a typo can't request a 1px display.
  @min_dimension_px 320
  @max_dimension_px 1366

  @type mode :: :browser | :host
  @type access :: :strict | :standard | :open

  @type t :: %__MODULE__{
          enabled?: boolean(),
          mode: mode(),
          access: access(),
          display: non_neg_integer(),
          display_width_px: pos_integer(),
          display_height_px: pos_integer(),
          screenshot_after?: boolean(),
          max_actions: pos_integer(),
          max_retained_screenshots: pos_integer()
        }

  defstruct enabled?: false,
            mode: :browser,
            access: :standard,
            display: 0,
            display_width_px: 1280,
            display_height_px: 800,
            screenshot_after?: true,
            max_actions: 40,
            max_retained_screenshots: 3

  @spec current() :: t()
  def current do
    cu =
      :fermix_core
      |> Application.get_env(:computer_use, [])
      |> normalize()

    # Posture is one knob: mirror the live sandbox mode (strict/standard/open).
    %{cu | access: SandboxConfig.current().mode}
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
      screenshot_after?: bool(config, :screenshot_after, true),
      max_actions: positive_int(config, :max_actions, 40),
      max_retained_screenshots: positive_int(config, :max_retained_screenshots, 3)
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
      screenshot_after: cu.screenshot_after?,
      max_actions: cu.max_actions,
      max_retained_screenshots: cu.max_retained_screenshots
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
    case Map.fetch(config, key) do
      {:ok, value} -> value
      :error -> Map.get(config, Atom.to_string(key))
    end
  end

  defp keyword_string_value(config, string_key) do
    Enum.find_value(config, fn
      {^string_key, value} -> value
      _other -> nil
    end)
  end
end
