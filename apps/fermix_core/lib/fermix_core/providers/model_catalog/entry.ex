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

  `max_reasoning_effort` is the highest reasoning-effort level this model
  accepts, when it is *lower* than its provider's ceiling — e.g. `max` is a
  current-generation OpenAI capability, so the older gpt-5.5/gpt-5.4 carry
  `:xhigh` here. `nil`
  (the default) means "no per-model cap; use the provider ceiling". Consumed
  via `ModelCatalog.model_effort_ceiling/2` and applied with
  `ReasoningEffort.cap/2`.
  """
  @enforce_keys [:id, :label, :context_window]
  defstruct [
    :id,
    :label,
    :context_window,
    :max_output_tokens,
    :max_reasoning_effort,
    reasoning_effort?: true,
    vision?: true
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          context_window: pos_integer(),
          max_output_tokens: pos_integer() | nil,
          max_reasoning_effort: atom() | nil,
          reasoning_effort?: boolean(),
          vision?: boolean()
        }
end
