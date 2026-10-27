defmodule FermixCore.OpenLoops.Access do
  @moduledoc """
  Who may see and change open loops (MILESTONE_78 §08, §18).

  Owner only, everywhere. Recording and settling a loop needs an attended,
  top-level operator turn, the same predicate the temporal event family uses
  (`Temporal.Access.attended_operator_turn?/1`), so guests, scheduled,
  background, delegated and coding-continuation runs are refused by one rule.

  A check-in run is marked by the `:open_loop_checkin` key of its loop context,
  and that key is the whole gate between the two surfaces: a check-in may read
  loops but never note or settle one, and the main agent's turn never carries
  the key.
  """

  alias FermixCore.Temporal.Access, as: TemporalAccess

  @doc "Whether `context` is an attended, top-level owner turn."
  @spec attended?(map()) :: boolean()
  def attended?(context) when is_map(context), do: TemporalAccess.attended_operator_turn?(context)

  @doc "Whether `context` is a check-in run's."
  @spec checkin?(map()) :: boolean()
  def checkin?(context) when is_map(context), do: Map.has_key?(context, :open_loop_checkin)

  @doc "Whether `context` may list loops: an attended owner turn or a check-in run."
  @spec read?(map()) :: boolean()
  def read?(context) when is_map(context), do: attended?(context) or checkin?(context)

  @doc "Whether `context` may note or settle a loop: attended, and not a check-in."
  @spec mutate?(map()) :: boolean()
  def mutate?(context) when is_map(context), do: attended?(context) and not checkin?(context)

  @typedoc """
  Why a gated open-loop tool refused before doing anything: the feature is off,
  the turn may not note or settle (`mutate?/1`), may not read (`read?/1`), or is
  not the check-in run the outcome tool belongs to (`checkin?/1`).
  """
  @type refusal_reason :: :disabled | :not_attended | :not_readable | :not_checkin

  @doc """
  The one sentence a gated tool returns to the model, naming the refused tool so
  the trace shows which call was denied, and why.
  """
  @spec refusal(String.t(), refusal_reason()) :: String.t()
  def refusal(tool_name, :disabled) when is_binary(tool_name) and tool_name != "" do
    "#{tool_name} is unavailable because open loops are turned off on this install, so do " <>
      "not record or mention one."
  end

  def refusal(tool_name, :not_attended) when is_binary(tool_name) and tool_name != "" do
    "#{tool_name} is available only on an attended, top-level turn the owner is present " <>
      "for; guest, scheduled, background, delegated, coding-continuation and check-in runs " <>
      "cannot record or settle an open loop."
  end

  def refusal(tool_name, :not_readable) when is_binary(tool_name) and tool_name != "" do
    "#{tool_name} is available only on an attended, top-level owner turn or inside an " <>
      "open-loop check-in run; guest, scheduled, background, delegated and " <>
      "coding-continuation runs cannot read open loops."
  end

  def refusal(tool_name, :not_checkin) when is_binary(tool_name) and tool_name != "" do
    "#{tool_name} is available only inside an open-loop check-in run, as its one way to " <>
      "report a decision; no other turn can use it."
  end
end
