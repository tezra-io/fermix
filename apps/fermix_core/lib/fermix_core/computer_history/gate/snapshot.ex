defmodule FermixCore.ComputerHistory.Gate.Snapshot do
  @moduledoc """
  The per-turn Computer History Gate snapshot (MILESTONE_32 §9.1). Built once
  by `Gate.snapshot/2` from inputs the turn already carries, then consulted by
  every sink through `Gate.allow?/2`. Immutable for the turn — snapshot it,
  never re-resolve per use (the M30 discipline), so the section and the wire
  read the identical state.
  """

  @type summarizer :: :local | {:provider, atom()}

  @type t :: %__MODULE__{
          operative?: boolean(),
          attended_operator?: boolean(),
          granted: MapSet.t(atom()),
          summarizer_target: summarizer(),
          chain: term(),
          chain_ok?: boolean()
        }

  @enforce_keys [
    :operative?,
    :attended_operator?,
    :granted,
    :summarizer_target,
    :chain,
    :chain_ok?
  ]
  defstruct operative?: false,
            attended_operator?: false,
            granted: nil,
            summarizer_target: :local,
            chain: nil,
            chain_ok?: false
end
