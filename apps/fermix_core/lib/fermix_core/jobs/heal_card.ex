defmodule FermixCore.Jobs.HealCard do
  @moduledoc """
  A heal's proposal on its card (M106 §5.7, decision D5, stage S4b), and the
  card's place on the owner's answer rail (`Cues.Proposals`, whose third
  holder this is, `Cues.CardHolder`).

  The card is the approval card Fermix already sends for a watcher's
  proposal (`Cues.Card`, kind `:job_change`): its lines are the proposal's
  short ask (`Jobs.HealMessage.card_lines/2`: what failed, the diagnosis's
  note, one line per changed field, and that Fermix has not made it), its
  detail every changed field exactly, as it is and as it would become
  (`Jobs.HealMessage.change_detail/1`), and its answers Approve and Deny. A
  chat with buttons draws those; any other gets the whole card as text,
  ending with how to reply. Everything but the note is built by code from the
  stored change. A card is never cut: one whose whole text would pass
  `Cues.Card.max_chars/0` is never offered (`Jobs.HealDecision.fit_card/3`).

  The heal run binds the card to the chat its answer must come from before
  the first send (`Delivery.OwnerInbox.answer_origin/1`), under a `cp_` token
  stored as its digest, and every retry of the send carries that token
  (`Memory.Repo.JobHealsSql`). It sends through the rail's one card sender
  (`Cues.Proposals.send_card/3`).

  On the rail a heal's card answers by its token only from that chat and
  that user, or by its id (the heal's) from a bare answer in that chat while
  it waits there; a yes is `Jobs.HealAnswer.apply_change/4` and a no
  `leave/3`, recorded as answered from the rail's own label for a chat
  (`<platform>:<chat>:<user>`, `Memory.Repo.CuesSql.origin_text/1`), and the
  owner's reply is that module's sentence, which also says what became of a
  proposal that ended another way. It offers no Always allow. No model is
  between the answer and the change, and the cues feature need not be on.

  Seams (the rail's opts): `:repo`, `:now`, `:scheduler`, `:skill_registry`,
  `:capability_registry`.
  """

  @behaviour FermixCore.Cues.CardHolder

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Cues.Card
  alias FermixCore.Cues.Proposals
  alias FermixCore.Jobs.HealAnswer
  alias FermixCore.Jobs.HealMessage
  alias FermixCore.Jobs.Scheduler
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql

  @actions %{confirm: "Approve", deny: "Deny"}
  @reply "Reply /confirm to make this change, or /deny to leave the job as it is."
  @wrong_chat "Answer it from the chat Fermix sent it to; nothing was changed."
  @unknown "That card is not known to Fermix; nothing was changed."
  @unread "Nothing was changed: Fermix could not read that card."

  @doc """
  The card of a proposal: `lines`, its short ask as stored on the heal, and
  `change`, the stored change its detail shows whole.
  """
  @spec card([String.t()], map()) :: Card.t()
  def card([_first | _rest] = lines, change) when is_map(change) and map_size(change) > 0 do
    %{
      kind: :job_change,
      lines: lines,
      detail: HealMessage.change_detail(change),
      actions: @actions,
      reply: @reply
    }
  end

  @doc "How long the whole card is as one plain message: what its bound holds."
  @spec chars(Card.t()) :: non_neg_integer()
  def chars(card), do: card |> Card.text() |> String.length()

  @doc """
  The approval spec a channel delivers for the card of `heal` with its
  `token`: the send key of the heal's message rides with it
  (`Jobs.HealMessage.send_key/1`, the key its text would carry), so a channel
  whose helper answers a repeated send by its key (iMessage) never shows it
  twice.
  """
  @spec spec(Card.t(), String.t(), map()) :: FermixCore.Reply.approval_spec()
  def spec(card, token, %{id: _id, conclusion: _conclusion} = heal) when is_binary(token),
    do: card |> Card.spec(token) |> Map.put(:proactive_key, HealMessage.send_key(heal))

  @doc """
  What the history of the owner's chat keeps of a card: the lines and the
  detail as sent, without the reply line, the note left out
  (`Jobs.HealMessage.history_copy/2`).
  """
  @spec history_text(Card.t()) :: String.t()
  def history_text(%{lines: lines, detail: detail}),
    do: Enum.join(lines, "\n") <> "\n\n" <> detail

  # --- the answer rail (`Cues.CardHolder`) ------------------------------------------

  @impl true
  def card_kind, do: :job_heal

  @impl true
  def card_id_prefix, do: "jhl_"

  @impl true
  def offers_always_allow?, do: false

  @impl true
  def holds_token?(digest, opts) when is_binary(digest) and is_list(opts),
    do: Repo.job_heals_call({:card_held, digest}, repo(opts))

  @impl true
  def answer_card({:token, token}, decision, origin, opts) when is_binary(token) do
    case Repo.job_heals_call({:card_by_digest, Proposals.digest(token)}, repo(opts)) do
      {:ok, %{id: id, origin: ^origin}} -> answer(id, decision, origin, opts)
      {:ok, %{id: _id}} -> {:error, @wrong_chat}
      {:ok, nil} -> {:error, @unknown}
      {:error, _reason} -> {:error, @unread}
    end
  end

  def answer_card({:id, id}, decision, origin, opts) when is_binary(id),
    do: answer(id, decision, origin, opts)

  @impl true
  def waiting_in_chat_cards(origin, opts) when is_map(origin) and is_list(opts) do
    with {:ok, cards} <- Repo.job_heals_call({:cards_in_chat, origin}, repo(opts)) do
      {:ok, Enum.map(cards, &waiting/1)}
    end
  end

  defp waiting(%{id: id, job_name: name}) do
    %{kind: :job_heal, id: id, title: ~s(Change job "#{HealMessage.shown_name(name || "")}"?)}
  end

  # A yes applies the recorded change; a no leaves it. Each says, in
  # `HealAnswer`'s words, what it did or why it did nothing.
  defp answer(id, :confirm, origin, opts) do
    id
    |> HealAnswer.apply_change(CuesSql.origin_text(origin), checks(opts),
      scheduler: Keyword.get(opts, :scheduler, Scheduler)
    )
    |> reply()
  end

  defp answer(id, :deny, origin, opts),
    do: id |> HealAnswer.leave(CuesSql.origin_text(origin), checks(opts)) |> reply()

  defp reply({:ok, _done, sentence}), do: {:ok, sentence}
  defp reply({:error, _reason, sentence}), do: {:error, sentence}

  # What the answer's checks read: an owner's edit's.
  defp checks(opts) do
    %{
      repo: Keyword.get(opts, :repo, Repo),
      skill_registry: Keyword.get(opts, :skill_registry, SkillRegistry),
      capability_registry: Keyword.get(opts, :capability_registry, CapabilityRegistry),
      now: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    }
  end

  defp repo(opts), do: [server: Keyword.get(opts, :repo, Repo)]
end
