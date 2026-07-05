defmodule FermixCore.ComputerUse.Config do
  @moduledoc """
  Runtime configuration for the computer-use subsystem — GUI control of the host
  desktop (docs/design/COMPUTER_USE_V2.md).

  Off by default. It drives the real logged-in desktop and is dangerous (ambient
  authority, no rollback, unsolved screenshot prompt-injection). There is no
  `mode` knob: computer-use is host-desktop control only — web automation is the
  separate `browser` tool. A lingering `mode` key in an old config is ignored (it
  self-heals on the next save); the behavior is uniformly the stricter
  attended-origin gate that the removed `browser` mode used to relax.

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

  @type access :: :strict | :standard | :open

  @type t :: %__MODULE__{
          enabled?: boolean(),
          access: access(),
          display: non_neg_integer(),
          screenshot_after?: boolean(),
          max_actions: pos_integer(),
          max_retained_screenshots: pos_integer()
        }

  defstruct enabled?: false,
            access: :standard,
            display: 0,
            screenshot_after?: true,
            max_actions: 80,
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
      display: non_neg_int(config, :display, 0),
      screenshot_after?: bool(config, :screenshot_after, true),
      max_actions: positive_int(config, :max_actions, 80),
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
      display: cu.display,
      screenshot_after: cu.screenshot_after?,
      max_actions: cu.max_actions,
      max_retained_screenshots: cu.max_retained_screenshots
    ]
  end

  # No cross-field constraints today, so validation is per-field (above). Kept as a
  # normalization seam for any future cross-field rule.
  defp validate!(%__MODULE__{} = cu), do: cu

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
