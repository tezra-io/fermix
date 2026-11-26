defmodule FermixCore.Cues.CardHolder do
  @moduledoc """
  One holder of cards on the owner's answer rail (`Cues.Proposals`): a kind of
  card the owner answers by its token, or with a bare `/confirm`, `/deny` or
  `/always`, from the chat it was sent to. The rail owns the token's lookup,
  which holder an id belongs to, the dispatch, the bare-command list and the
  refusal of Always allow; a holder answers for its own cards only.

  The holders, in the order the rail asks them: a mandate's proposal
  (`Cues.Proposals`, `cpr_`), a watcher's follow-up card (`Cues.FollowUps`,
  `cft_`) and a heal's proposal (`Jobs.HealCard`, the heal's id, `jhl_`,
  M106 §5.7). Every holder's token is a `cp_` token (`Cues.Proposals.new_token/0`)
  stored only as its digest, beside the chat it was sent to.

  The apps' proposal family (`Cues.Proposals.waiting_cards/1`, `decide/4`,
  `records/2`, the companion's and the management socket's proposal lists) is
  the watcher cards' alone and is no part of this behaviour.
  """

  @typedoc "Where a chat's answer came from, as the rail checked it."
  @type origin :: %{platform: String.t(), chat_id: String.t(), user_id: String.t()}

  @typedoc "One card waiting in a chat, as a bare answer lists it."
  @type waiting :: %{kind: atom(), id: String.t(), title: String.t()}

  @typedoc "A card as the rail found it: by its token, or by its id."
  @type card_ref :: {:token, String.t()} | {:id, String.t()}

  @doc "The kind a bare answer's list names this holder's cards by."
  @callback card_kind() :: atom()

  @doc "The prefix of this holder's card ids: four bytes, ending in `_`."
  @callback card_id_prefix() :: String.t()

  @doc "Whether this holder's cards offer Always allow."
  @callback offers_always_allow?() :: boolean()

  @doc "Whether this holder holds a card under the token digest `digest`."
  @callback holds_token?(digest :: String.t(), opts :: keyword()) ::
              {:ok, boolean()} | {:error, term()}

  @doc """
  The owner's answer to one of this holder's cards from the checked `origin`.
  A card found by token is answered only from the chat it was sent to, which
  the holder checks; one found by id the rail has already found waiting in
  that chat. Returns the reply for the owner. Never called with
  `:always_allow` unless `offers_always_allow?/0`.
  """
  @callback answer_card(card_ref(), :confirm | :deny | :always_allow, origin(), keyword()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc "This holder's cards waiting in the chat `origin`, oldest first."
  @callback waiting_in_chat_cards(origin(), keyword()) :: {:ok, [waiting()]} | {:error, term()}
end
