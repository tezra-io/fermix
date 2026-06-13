defmodule FermixCore.Prompt.ModelOverlays do
  @moduledoc """
  Constrained per-model-family prompt overlays (M10 P3, OpenClaw pattern).

  Model-family steering is additive and slot-shaped — never a fork of the
  base prompt. An overlay is a fixed set of named, XML-tagged micro-contracts
  appended at the END of the instructions string: the composed prefix stays
  byte-identical, so provider prompt caching is unaffected, and the overlay
  itself is static per session.

  Overlays are incident-derived (the hermes gate): a family gets one only for
  observed failure modes. Currently only the Codex/GPT-5 family carries one —
  tool-call discipline and completion gating, adapted from OpenClaw's
  field-tested GPT-5 behavior contract — applied by the Codex adapter, which
  is inherently that family's surface. Well-behaved families get nothing.
  """

  @codex_overlay """
  <tool_discipline>
  Prefer tool evidence over recall when action, state, or mutable facts matter. \
  Do not stop early when another tool call would materially improve correctness \
  or grounding. Resolve prerequisite lookups before dependent or irreversible \
  actions. Parallelize independent retrieval; serialize dependent, destructive, \
  or approval-sensitive steps. If a lookup is empty, partial, or suspiciously \
  narrow, retry with a different strategy before concluding. Do not narrate \
  routine tool calls. Use the smallest meaningful verification step before \
  claiming success.
  </tool_discipline>

  <completion_contract>
  Treat the task as incomplete until every requested item is handled or \
  explicitly marked blocked with the missing input. Before finalizing, check \
  requirements, grounding, and format. Prefer the smallest meaningful gate: a \
  test, diff, lookup, or direct inspection. If no gate can run, say why.
  </completion_contract>
  """

  @doc """
  Append the Codex/GPT-5 family behavior contract to an instructions string.
  Idempotent: re-application (e.g. a retried build) never doubles the overlay.
  """
  @spec apply_codex(String.t()) :: String.t()
  def apply_codex(instructions) when is_binary(instructions) do
    if String.contains?(instructions, "<tool_discipline>") do
      instructions
    else
      String.trim_trailing(instructions) <> "\n\n" <> String.trim_trailing(@codex_overlay)
    end
  end
end
