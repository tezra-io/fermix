defmodule FermixCore.SoulCuration.Proposal do
  @moduledoc """
  A pending, owner-reviewable edit to an agent's persona (`SOUL.md`).

  Built by `FermixCore.SoulCuration.propose/2` from one bounded provider call
  and applied by `FermixCore.SoulCuration.apply/3` after the owner confirms.
  It carries the *whole* proposed file (`content`) — the diff is only for the
  human to read — plus `base_disk_hash`, the SHA256 of the on-disk SOUL.md the
  draft was built from, so apply can refuse a stale base (the file changed
  since the proposal was drafted).
  """

  @enforce_keys [:content, :base_disk_hash]
  defstruct [
    :content,
    :diff,
    :rationale,
    :route_key,
    :base_revision,
    :base_disk_hash,
    :byte_delta,
    :line_delta,
    :provenance
  ]

  @type t :: %__MODULE__{
          content: String.t(),
          diff: String.t() | nil,
          rationale: String.t() | nil,
          route_key: term() | nil,
          base_revision: pos_integer() | nil,
          base_disk_hash: String.t(),
          byte_delta: integer() | nil,
          line_delta: integer() | nil,
          provenance: map() | nil
        }
end
