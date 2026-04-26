defmodule FermixCore.Setup.WizardState do
  @moduledoc """
  Deterministic shared onboarding state used by web and CLI surfaces.
  """

  @enforce_keys [:step, :config_snapshot, :enabled_channels, :validation_errors, :dirty?]
  defstruct [:step, :config_snapshot, :enabled_channels, :validation_errors, :dirty?]

  @type step :: :provider | :channel | :personalization | :review

  @type t :: %__MODULE__{
          step: step(),
          config_snapshot: map(),
          enabled_channels: [atom()],
          validation_errors: [map()],
          dirty?: boolean()
        }
end
