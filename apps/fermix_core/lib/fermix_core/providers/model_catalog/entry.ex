defmodule FermixCore.Providers.ModelCatalog.Entry do
  @moduledoc """
  One catalog model.

  `max_output_tokens` is Anthropic-only — the per-model `max_tokens` ceiling
  Anthropic requires on every request; `nil` for every other provider, which
  falls back to the conservative default. `reasoning_effort?` is xAI-only —
  whether the model accepts the `reasoning.effort` request field; `true` for
  every other provider (none of them consult it). `vision?` is whether the
  model accepts image (vision) input; defaults to `true`, set `false` only for
  models known to be text-only (the capability gate fails loud on a mismatch).
  """
  @enforce_keys [:id, :label, :context_window]
  defstruct [
    :id,
    :label,
    :context_window,
    :max_output_tokens,
    reasoning_effort?: true,
    vision?: true
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          context_window: pos_integer(),
          max_output_tokens: pos_integer() | nil,
          reasoning_effort?: boolean(),
          vision?: boolean()
        }
end
