defmodule FermixCore.ComputerHistory.Taint do
  @moduledoc """
  The strict compaction/replay taint (MILESTONE_32 §13.6, owner decision §20.0
  #2 = strict). When the agent replies on a turn that injected the Recent
  Activity section, the persisted assistant turn is **message-level tainted**,
  and any surface that re-sends conversation to a provider — compaction or
  ordinary replay — masks that turn's content before it can reach an
  **ungranted-remote** provider. A marked turn is never re-sent on an
  ungranted-remote chain (inv. 20, second clause).

  Message-level, not span-level: the reply is free model text with no per-word
  provenance, so the whole marked assistant turn is masked (§13.6). The taint
  status is re-derived from the same Gate the section injection uses, so the
  stamp and the section cannot disagree.
  """

  alias FermixCore.ComputerHistory.Gate

  # Replaces a tainted assistant turn's content when it would ride an
  # ungranted-remote chain. Neutral, carries no activity content.
  @masked "[an activity-related reply was omitted here because this turn runs on a model not granted access to your computer history]"

  @doc "The metadata stamped on a tainted assistant message at persist time."
  @spec metadata() :: %{history_tainted: true}
  def metadata, do: %{history_tainted: true}

  @doc """
  Whether the just-completed assistant turn should be stamped history-tainted:
  true exactly when the Recent Activity section was Gate-permitted this turn
  (the section's own predicate). Pass the turn's frozen Gate snapshot as
  `opts[:snapshot]` so the stamp reads the SAME decision the section injection
  read — a `/history off` (or grant edit) landing mid-turn must not make the
  two disagree. Without a snapshot it is re-derived from `gate_context`
  (`source_trust`, `ordered_routes`, origin, depths).
  """
  @spec tainted_turn?(map(), keyword()) :: boolean()
  def tainted_turn?(gate_context, opts \\ []) when is_map(gate_context) and is_list(opts) do
    {snapshot, opts} = Keyword.pop(opts, :snapshot)
    snapshot = snapshot || Gate.snapshot(gate_context, opts)
    Gate.allow?(snapshot, {:prompt_section, gate_context})
  end

  @doc """
  Mask every history-tainted assistant message in `messages` **iff** `routes`
  is not permitted to carry history (an ungranted-remote hop). On a permitted
  (all-local-or-granted) chain the messages pass through untouched.
  """
  @spec mask_for_chain([map()], term()) :: [map()]
  def mask_for_chain(messages, routes) when is_list(messages) do
    if Gate.chain_permits_history?(routes) do
      messages
    else
      Enum.map(messages, &mask/1)
    end
  end

  # The masked copy drops the marker: its content is the neutral placeholder,
  # so a downstream consumer (compaction summarizing a masked tail, a replace
  # persisting it) treats it as clean rather than re-protecting placeholder
  # text — which would otherwise taint a checkpoint summary that contains no
  # activity content at all.
  defp mask(%{history_tainted: true} = message),
    do: message |> Map.put(:content, @masked) |> Map.delete(:history_tainted)

  defp mask(message), do: message
end
