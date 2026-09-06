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

  Pass the turn's frozen Gate snapshot as `opts[:snapshot]` — the identical
  seam `tainted_turn?/2` documents — so every mask in one turn decides against
  one grant set and a mid-turn `/history off` cannot move it. Without a
  snapshot the decision is re-derived live.
  """
  @spec mask_for_chain([map()], term(), keyword()) :: [map()]
  def mask_for_chain(messages, routes, opts \\ []) when is_list(messages) and is_list(opts) do
    if chain_permits_history?(routes, opts) do
      messages
    else
      Enum.map(messages, &mask/1)
    end
  end

  @doc """
  Whether the model saw activity-derived content **unmasked** in `messages`:
  the chain permits history (so `mask_for_chain/3` left it in place) *and* at
  least one message carries the marker. A reply generated from that replay is
  itself activity-derived, so it inherits the stamp — the same transitivity the
  compactor already applies to a checkpoint summary distilled from a tainted
  turn. Persisted checkpoints carry the marker through `ConversationStore`, so
  a tainted checkpoint in the replay window counts too.
  """
  @spec carries_unmasked_taint?([map()], term(), keyword()) :: boolean()
  def carries_unmasked_taint?(messages, routes, opts \\ [])
      when is_list(messages) and is_list(opts) do
    Enum.any?(messages, &tainted?/1) and chain_permits_history?(routes, opts)
  end

  @doc """
  Whether one message (or history entry) carries the taint marker. The single
  home of the marker predicate: rows read back through the Repo are
  string-keyed, in-memory messages are atom-keyed, and both spell the same
  fact.
  """
  @spec tainted?(map()) :: boolean()
  def tainted?(message) when is_map(message),
    do: Map.get(message, :history_tainted, Map.get(message, "history_tainted")) == true

  # The chain decision, read from the turn's frozen grant set when the caller
  # has one, else from the live config. Both spellings are the identical rule
  # (`chain_permits_history?/1` is `{:history_replay, routes}` against the
  # current grants); the snapshot form just pins the grants for the turn.
  defp chain_permits_history?(routes, opts) do
    case Keyword.get(opts, :snapshot) do
      nil -> Gate.chain_permits_history?(routes)
      snapshot -> Gate.allow?(snapshot, {:history_replay, routes})
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
