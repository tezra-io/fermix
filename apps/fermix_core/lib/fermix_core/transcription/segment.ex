defmodule FermixCore.Transcription.Segment do
  @moduledoc """
  One finalized (or interim) span of transcribed speech from a stream session.

  `t0_ms`/`t1_ms` are milliseconds from **stream start**, derived from the
  session's sample-count clock (`div(samples * 1000, 16_000)`) and never from
  wall clock — a stalled uplink must not shift a segment's place in the
  transcript. `final?` is always `true` in this phase (interim results are
  disabled on every backend); the field exists so interim segments are an
  additive change later. `words` is `nil` for backends that return no word
  timings.

  There is no constructor: the three producers (the chunked adapter and the two
  native streamers) build the struct directly and carry the guards, so the
  invariants `t1_ms >= t0_ms` and a non-empty binary `text` are enforced where
  the values are computed. An empty-text segment is never emitted.
  """

  @enforce_keys [:text, :t0_ms, :t1_ms]
  defstruct [:text, :t0_ms, :t1_ms, final?: true, words: nil]

  @typedoc "Optional per-word timing: text plus millisecond bounds relative to stream start."
  @type word :: %{text: String.t(), t0_ms: non_neg_integer(), t1_ms: non_neg_integer()}

  @type t :: %__MODULE__{
          text: String.t(),
          t0_ms: non_neg_integer(),
          t1_ms: non_neg_integer(),
          final?: boolean(),
          words: [word()] | nil
        }
end
