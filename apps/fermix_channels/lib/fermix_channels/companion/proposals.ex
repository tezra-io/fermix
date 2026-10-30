defmodule FermixChannels.Companion.Proposals do
  @moduledoc """
  A mandate's proposals on the Mac's chat (companion protocol 4; M60 app
  surface §3.7, D28): the card the owner decides from, the proposal's end, and
  the owner's answer. Since protocol 5 a watcher's follow-up card and an
  automatic follow-up's approval prompt are cards too
  (M60_WATCHER_CODING_RUNS.md §6.2): announced, listed and answered the same
  way, by id, through `Cues.Proposals`, and written only to a connection on
  version 5 (`Protocol.server_payload_version/2`).

  Core announces through the listener `FermixChannels.Application` registers
  as `:cue_proposal_listener`: `proposal_event/1` turns `{:offered, card}` into
  a `proposal` event and `{:resolved, resolved}` into `proposal_resolved`, and
  broadcasts each to the companion registry. A connection writes them only
  when its hello declared version 4 and the daemon placed its peer as the
  owner's (`Companion.Connection`), so a process the daemon started never
  holds a proposal. The phones are not told: their wire carries proposals at
  its next version.

  The card travels as this wire carries every value: string keys, and an
  absent key where core has nil, nested as at the top.

  `waiting/1` is the `proposal` event of every proposal still waiting, which a
  connection writes right after its `server_hello`; `answer/3` serves a
  `proposal_answer`: from the owner's connection it is
  `Cues.Proposals.decide/4` with surface `companion`, from any other it is
  refused and runs nothing.
  """

  require Logger

  alias FermixChannels.Channels.Companion
  alias FermixCore.Cues.Proposals, as: CueProposals
  alias FermixCore.Text

  @profile "main"
  @max_message_bytes 512
  @not_owner "Only the owner can answer a proposal, from the Fermix app or a paired phone."

  @doc "The sentence a `proposal_answer` from a connection not placed as the owner's is refused with."
  @spec not_owner_sentence() :: String.t()
  def not_owner_sentence, do: @not_owner

  @doc "Core's listener (`:cue_proposal_listener`): announce `event` to the Mac's connections."
  @spec proposal_event(CueProposals.event()) :: :ok
  def proposal_event(event), do: announce(event, Companion.registry())

  @doc "Announce `event` to the connections of `registry` watching the owner's chat."
  @spec announce(CueProposals.event(), atom()) :: :ok
  def announce({:offered, %{} = card}, registry) when is_atom(registry),
    do: Companion.broadcast(@profile, offered(card), registry)

  def announce({:resolved, %{} = resolved}, registry) when is_atom(registry),
    do: Companion.broadcast(@profile, resolved(resolved), registry)

  @doc "The `proposal` event of `card`."
  @spec offered(map()) :: map()
  def offered(%{proposal_id: id} = card) when is_binary(id),
    do: %{"t" => "proposal", "profile_id" => @profile, "proposal" => wire(card)}

  @doc "The `proposal_resolved` event of what core resolved."
  @spec resolved(CueProposals.resolved()) :: map()
  def resolved(%{proposal_id: id, state: state, sentence: sentence} = resolved)
      when is_binary(id) and is_binary(state) and is_binary(sentence) do
    resolved
    |> Map.take([:proposal_id, :state, :result_status, :sentence, :result_text])
    |> wire()
    |> Map.merge(%{"t" => "proposal_resolved", "profile_id" => @profile})
  end

  @doc """
  The `proposal` event of every proposal still waiting, oldest first; none with
  memory off. A read that fails is logged and sends
  none: the cards come back at the next connect.
  """
  @spec waiting(keyword()) :: [map()]
  def waiting(opts) when is_list(opts) do
    case CueProposals.waiting_cards(opts) do
      {:ok, cards} ->
        Enum.map(cards, &offered/1)

      {:error, :memory_off} ->
        []

      {:error, reason} ->
        Logger.warning(
          "companion connection could not read waiting proposals: #{inspect(reason)}"
        )

        []
    end
  end

  @doc """
  A `proposal_answer` from a connection placed as `caller`: the owner's
  (`:independent`) decides through `Cues.Proposals.decide/4`; any other is
  refused. Answers Fermix's record, or the sentence that refused it (bounded
  for the wire's `error.message`); a refusal ran nothing.
  """
  @spec answer(map(), FermixCore.SocketPeer.caller() | nil, keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def answer(%{"proposal_id" => id, "decision" => decision}, :independent, opts)
      when is_binary(id) and decision in ["confirm", "deny"] and is_list(opts) do
    origin = %{surface: :companion, device_id: nil}

    case CueProposals.decide(id, decision_atom(decision), origin, opts) do
      {:ok, record} -> {:ok, record}
      {:error, sentence} -> {:error, Text.truncate_utf8(sentence, @max_message_bytes)}
    end
  end

  # Anything but the owner's placement is refused, an unplaced (nil) caller
  # included, so the gate is closed by construction.
  def answer(%{"proposal_id" => _id}, caller, _opts)
      when caller in [nil, :daemon_descendant, :detached],
      do: {:error, @not_owner}

  defp decision_atom("confirm"), do: :confirm
  defp decision_atom("deny"), do: :deny

  # String keys, and no nil: an absent value is an absent key on this wire.
  defp wire(%{} = map) when not is_struct(map) do
    for {key, value} <- map, not is_nil(value), into: %{}, do: {to_string(key), wire(value)}
  end

  defp wire(values) when is_list(values), do: Enum.map(values, &wire/1)
  defp wire(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
end
