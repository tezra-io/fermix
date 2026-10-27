defmodule FermixCore.OpenLoops.Access do
  @moduledoc """
  Who may see and change open loops (MILESTONE_78 §08, §18).

  Owner only, in a private chat. Recording, settling and seeing a loop, and
  carrying its due note, need the owner's attended, top-level turn in a private
  chat (`private_owner_turn?/1`): the access gate's private turn
  (`Capabilities.AccessGate.owner_private_turn?/1`: a direct-message label or
  the owner's paired phone or Mac app), or the owner's own voice call. So
  guests, group chats (a Slack channel mention, which carries no label, among
  them), shared Buzz sessions, and scheduled, background, delegated and
  coding-continuation runs are refused by one rule.

  A check-in run is marked by the `:open_loop_checkin` key of its loop context,
  and that key is the whole gate between the two surfaces: a check-in may read
  loops but never note or settle one, and the main agent's turn never carries
  the key.

  What the turn had read is the other fact this module answers
  (`read_outside?/1`): a loop noted after outside content is stamped, and an
  answer given after it must quote the owner (`OpenLoops.Registry`). That
  holds turn by turn, as the access gate's does: only the turn that read the
  content is held to the owner's own words, so an instruction it left in the
  conversation's history can still steer the answer of a later turn that read
  nothing. A voice call is the exception that carries over: every hand-off
  starts with what the call's earlier ones read.
  """

  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Temporal.Access, as: TemporalAccess

  @doc """
  Whether `context` is the owner's attended, top-level turn in a private chat:
  the access gate's private turn, or the owner's own voice call.
  """
  @spec private_owner_turn?(map()) :: boolean()
  def private_owner_turn?(context) when is_map(context),
    do: AccessGate.owner_private_turn?(context) or owner_voice_call?(context)

  # A realtime call's tool context names no channel and no chat type, so the
  # access gate's private chats leave it out, and its own rules keep refusing
  # watcher changes there. The call is the owner's alone, and open loops have
  # always served it, so it counts here.
  defp owner_voice_call?(context),
    do: TemporalAccess.attended_operator_turn?(context) and voice_call?(context)

  @doc """
  Whether `context` is a voice call's: the realtime session's own tool context
  or a Live or Grok hand-off turn, the only two marked a voice origin.
  """
  @spec voice_call?(map()) :: boolean()
  def voice_call?(context) when is_map(context),
    do: Map.get(context, :computer_use_origin) == :voice

  @doc "Whether `context` is a check-in run's."
  @spec checkin?(map()) :: boolean()
  def checkin?(context) when is_map(context), do: Map.has_key?(context, :open_loop_checkin)

  @doc "Whether `context` may list loops: the owner's private turn or a check-in run."
  @spec read?(map()) :: boolean()
  def read?(context) when is_map(context), do: private_owner_turn?(context) or checkin?(context)

  @doc "Whether `context` may note or settle a loop: the owner's private turn, not a check-in."
  @spec mutate?(map()) :: boolean()
  def mutate?(context) when is_map(context),
    do: private_owner_turn?(context) and not checkin?(context)

  @doc """
  Whether the turn in `context` may have read content someone else could have
  written: anything but an empty `:outside_sources` set the loop stamped. As
  the access gate reads it, an absent or malformed set counts, since absence is
  no proof the turn read nothing.
  """
  # The same rule as `Capabilities.AccessGate`'s private `read_outside?/2` and
  # `read_nothing?/1`, which stay private there: "absent or malformed counts"
  # lives in both, so a change to one is a change to the other.
  @spec read_outside?(map()) :: boolean()
  def read_outside?(context) when is_map(context) do
    case Map.fetch(context, :outside_sources) do
      {:ok, %MapSet{} = sources} -> MapSet.size(sources) > 0
      _absent_or_malformed -> true
    end
  end

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
    "#{tool_name} is available only on the owner's attended, top-level turn in a private " <>
      "chat; group chats and guest, scheduled, background, delegated, coding-continuation " <>
      "and check-in runs cannot record or settle an open loop."
  end

  def refusal(tool_name, :not_readable) when is_binary(tool_name) and tool_name != "" do
    "#{tool_name} is available only on the owner's attended, top-level turn in a private " <>
      "chat or inside an open-loop check-in run; group chats and guest, scheduled, " <>
      "background, delegated and coding-continuation runs cannot read open loops."
  end

  def refusal(tool_name, :not_checkin) when is_binary(tool_name) and tool_name != "" do
    "#{tool_name} is available only inside an open-loop check-in run, as its one way to " <>
      "report a decision; no other turn can use it."
  end
end
