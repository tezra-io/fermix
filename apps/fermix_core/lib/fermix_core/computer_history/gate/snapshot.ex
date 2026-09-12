defmodule FermixCore.ComputerHistory.Gate.Snapshot do
  @moduledoc """
  The per-turn Computer History Gate snapshot (MILESTONE_32 §9.1). Built once
  by `Gate.snapshot/2` from inputs the turn already carries, then consulted by
  every sink through `Gate.allow?/2`. Immutable for the turn — snapshot it,
  never re-resolve per use (the M30 discipline), so the section and the wire
  read the identical state.

  Two chains, deliberately both recorded (§9.4 chain pinning):

    * `routes` — the EFFECTIVE chain, and the one every reader in the turn rides:
      `MainAgent` puts it in `turn_state.ordered_routes`, so the agent loop, the
      taint/replay masks and a subagent's inherited chain all read it. It is the
      pinned list when pinning applied (an attended owner turn whose lead is
      permitted for history), else `chain` verbatim. `dropped_hops` names the
      providers pinning removed, and is `[]` whenever the chain was left alone.
    * `chain` — the chain the turn arrived with, kept so the status surfaces can
      name the LEAD the operator configured even when nothing was pinned (an
      ungranted lead is exactly what `Gate.chain_posture/1` has to report). No
      turn reader consults it.
  """

  @type summarizer :: :local | {:provider, atom()}

  @type t :: %__MODULE__{
          operative?: boolean(),
          attended_operator?: boolean(),
          granted: MapSet.t(atom()),
          summarizer_target: summarizer(),
          chain: term(),
          routes: term(),
          dropped_hops: [atom()],
          chain_ok?: boolean()
        }

  @enforce_keys [
    :operative?,
    :attended_operator?,
    :granted,
    :summarizer_target,
    :chain,
    :routes,
    :dropped_hops,
    :chain_ok?
  ]
  defstruct operative?: false,
            attended_operator?: false,
            granted: nil,
            summarizer_target: :local,
            chain: nil,
            routes: nil,
            dropped_hops: [],
            chain_ok?: false
end
