defmodule FermixCore.Temporal.Access do
  @moduledoc """
  The one attended-owner predicate behind the whole temporal event family
  (MILESTONE_30 §12.1, §14).

  Both halves of every event tool's gate — the `advertise?/1` callback that
  decides what the model is offered and the `execute/2` check that decides what
  actually runs — call `attended_operator_turn?/1`. Two hand-rolled copies of
  four conditions drift; one predicate cannot.

  All four conditions must hold:

    * `source_trust == :operator` — the owner, not a guest;
    * `subagent_depth` absent or `0` — a top-level turn, not a delegated worker;
    * `computer_use_origin in [:interactive, :voice]` — an attended surface with
      a live owner. `TurnRunner` assigns `:interactive` as the catch-all for
      every non-`"background"` channel, realtime marks a live call `:voice`,
      background marks `:unattended`, and a scheduled run omits the marker;
    * `harness_continuation_depth` absent or `0` — the owner typed this turn,
      rather than a synthesized coding-run notice re-entering their channel.

  Missing trust or origin fails closed: absence is never read as authority, and
  a malformed depth is never read as zero.
  """

  @attended_origins [:interactive, :voice]

  @doc """
  Whether `context` is an attended, top-level, non-synthesized operator turn.
  """
  @spec attended_operator_turn?(map()) :: boolean()
  def attended_operator_turn?(context) when is_map(context) do
    Map.get(context, :source_trust) == :operator and
      Map.get(context, :computer_use_origin) in @attended_origins and
      top_level?(context, :subagent_depth) and
      top_level?(context, :harness_continuation_depth)
  end

  @doc """
  The refusal a gated tool returns to the model, naming the refused tool so the
  trace shows which call was denied.
  """
  @spec refusal(String.t()) :: String.t()
  def refusal(tool_name) when is_binary(tool_name) and tool_name != "" do
    "#{tool_name} is available only on an attended, top-level turn the owner is " <>
      "present for. Guest, scheduled, background, delegated, and coding-continuation " <>
      "runs cannot read or change stored events."
  end

  # Absent means zero (an owner-typed turn carries no depth key at all); every
  # other value that is not the integer zero is treated as non-top-level, so a
  # malformed context can only narrow the gate, never widen it.
  defp top_level?(context, key) do
    case Map.get(context, key) do
      nil -> true
      0 -> true
      _deeper_or_malformed -> false
    end
  end
end
