defmodule FermixChannels.Gateway.OwnerInboxApproval do
  @moduledoc """
  Sends an access-sensitive confirmation to the owner's own chat when the turn
  that asked has no in-chat approval (a channel without slash commands, such as
  ACP). The gateway hands `request/1` to such a turn as `owner_inbox_approval_fn`,
  and `Capabilities.AccessGate` calls it with the parked intent id and a
  Fermix-authored prompt.

  It composes three existing seams and adds no delivery path of its own:

    1. `FermixCore.Delivery.OwnerInbox.for_approval/2`, the one answer to "where
       is the owner's inbox" for an approval card that waits on the owner (the
       Fermix app first while a phone is paired; iMessage that a computer
       carries comes last, and never while that computer is away). Only an
       inbox an answer can be held to qualifies: a DM `OwnerInbox.dm_origin/1`
       answers for (Telegram, Signal, WhatsApp, iMessage), whose chat id is the
       owner's user id, or the Fermix app's inbox (M106 §8, D12), answered
       from the Mac chat or a paired phone as the app's one origin
       (`OwnerInbox.answer_origin/1`). That rule lives in core alone.
    2. `Commands.Sandbox.store_pending_grant/2`, binding the token to that
       origin. A repeat while the token lives answers `:existing` and sends
       nothing.
    3. `Gateway.Delivery`, the single channel-delivery path, so Telegram renders
       its one-tap button, the app its approval card on the Mac and the
       phones, and every other channel the tap-to-copy command.

  A failed delivery takes the token back, so no confirmable record exists that
  the owner never saw. A request marked `in_call: true` is a call that waits in
  its own process for the answer (`AccessGate.ask_in_call/3`), so its prompt
  ends with that promise instead of the daemon running a command. A request
  carrying `after_confirm` and `ttl_ms` is an effect outside the machine (a
  phone call's start): its prompt ends with the promise its own rendering
  makes, and its token and card live for its own window.
  """

  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Gateway.Commands.Sandbox
  alias FermixChannels.Gateway.Commands.Sandbox.Confirmations
  alias FermixChannels.Gateway.Delivery
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.ReplyContext
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Cues.Card, as: CueCard
  alias FermixCore.Cues.Mandates
  alias FermixCore.Cues.Proposals, as: CueProposals
  alias FermixCore.Delivery.OwnerInbox

  require Logger

  # Where a card went when only an app can show it: no token and no chat.
  @app_only %{token_digest: nil, platform: nil, chat_id: nil, user_id: nil}

  @type request :: %{
          required(:access_sensitive) => String.t(),
          required(:prompt) => String.t(),
          optional(:in_call) => true,
          optional(:after_confirm) => String.t(),
          optional(:ttl_ms) => pos_integer()
        }

  @doc """
  Store and deliver the owner's confirmation. Seams: `:jobs_config` and
  `:configured_owners` (for `OwnerInbox.resolve/1`) and `:adapter` (the channel
  module; otherwise the registry's adapter for the inbox platform).
  """
  @spec request(request(), keyword()) ::
          {:ok, String.t(), :new | :existing} | {:error, term()}
  def request(%{access_sensitive: intent_id, prompt: prompt} = request, opts \\ [])
      when is_binary(intent_id) and is_binary(prompt) and is_list(opts) do
    with {:ok, inbox, dm_origin} <- owner_dm(opts),
         {:ok, adapter} <- adapter(inbox.platform, opts) do
      case Sandbox.store_pending_grant(grant(request), origin(dm_origin)) do
        {:ok, token, :existing} -> {:ok, token, :existing}
        {:ok, token, :new} -> deliver(adapter, inbox, approval(request, token), token)
      end
    end
  end

  defp grant(%{access_sensitive: intent_id, ttl_ms: ttl_ms}),
    do: %{access_sensitive: intent_id, ttl_ms: ttl_ms}

  defp grant(%{access_sensitive: intent_id}), do: %{access_sensitive: intent_id}

  # The prompt as the turn's own chat would draw it: an effect's as a card
  # that names its window, every other as the prompt and its token.
  defp approval(%{ttl_ms: ttl_ms} = request, token) do
    {:approval_prompt,
     %{kind: :sandbox, text: prompt_text(request, token), token: token, ttl_s: div(ttl_ms, 1_000)}}
  end

  defp approval(request, token), do: {:approval_prompt, prompt_text(request, token), token}

  defp prompt_text(%{prompt: prompt} = request, token),
    do:
      prompt <> "\n\n" <> AccessGate.approval_line(token, %{chat_type: "private"}, kind(request))

  defp kind(%{in_call: true}), do: :in_call
  defp kind(%{after_confirm: promise}) when is_binary(promise), do: {:effect, promise}
  defp kind(_parked), do: :parked

  @doc """
  Sends a card of the answer rail (`Cues.Proposals.send_card/3`): a mandate
  proposal (M60 §10.9), or a heal's proposal for a job (M106 §5.7), to the
  owner's chat `inbox` that core resolved and recorded on it, through
  `Gateway.Delivery` as its compact card (`spec`, `Cues.Card.spec/2`):
  Telegram draws it with its two answers, whose taps send the same
  `/confirm <token>` and `/deny <token>` the card's text answers for every
  other channel. The inbox must be one a card's answer can come from
  (`OwnerInbox.answer_origin/1`: the owner's DM, the Fermix app's inbox, or
  the local `cli` chat, the last two of which a watcher's reach never
  chooses). A spec's `proactive_key` rides on
  the message the channel is handed, so a channel whose helper answers a
  repeated send by its key (iMessage) never shows a retried card twice.
  Nothing is stored here: the card and its token's digest are durable in
  core, which checks the answer's origin. Core reaches this through `config
  :fermix_core, :cue_proposal_sender`, registered by
  `FermixChannels.Application`. Seam: `:adapter`.
  """
  @spec send_cue_proposal(
          %{required(:platform) => String.t(), required(:destination) => String.t()},
          FermixCore.Reply.approval_spec(),
          keyword()
        ) :: :ok | {:error, term()}
  def send_cue_proposal(%{platform: platform} = inbox, %{token: token} = spec, opts \\ [])
      when is_binary(platform) and is_binary(token) and is_list(opts) do
    with {:ok, _origin} <- card_inbox(inbox),
         {:ok, adapter} <- adapter(platform, opts) do
      deliver_card(adapter, inbox, spec)
    end
  end

  defp card_inbox(inbox) do
    case OwnerInbox.answer_origin(inbox) do
      {:ok, origin} -> {:ok, origin}
      :error -> {:error, :no_owner_inbox}
    end
  end

  @doc """
  Sends a watcher's card (M60_WATCHER_CODING_RUNS.md §6): a follow-up waiting
  to run, as core read it (`Cues.FollowUps.card/2`). The way a proposal goes,
  beside it: the reach rule (`Cues.Proposals.owner_chat/1`), a fresh `cp_`
  token, the compact card (`Cues.Card.follow_up/2`) delivered to the
  owner's DM, and where it went answered for core to record: the token's
  digest and the DM's origin. With no DM, or a send that failed, while an
  app can show it, it is answered with no chat, and only the apps show it;
  with neither, it is refused. Core reaches this through `config
  :fermix_core, :cue_follow_up_sender`, registered by
  `FermixChannels.Application`. Seams: `:adapter`, `:now`, and
  `Cues.Proposals.owner_chat/1`'s.
  """
  @spec send_follow_up(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_follow_up(card, opts \\ []) when is_map(card) and is_list(opts) do
    case CueProposals.owner_chat(opts) do
      {:ok, {inbox, origin}} -> send_follow_up_card(card, inbox, origin, opts)
      {:ok, nil} -> {:ok, @app_only}
      {:refuse, sentence} -> {:error, {:unreachable, sentence}}
    end
  end

  defp send_follow_up_card(card, inbox, origin, opts) do
    token = CueProposals.new_token()
    card_opts = [now: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0), chat: origin]
    spec = card |> CueCard.follow_up(card_opts) |> CueCard.spec(token)

    with {:ok, adapter} <- adapter(inbox.platform, opts),
         :ok <- deliver_card(adapter, inbox, spec) do
      {:ok,
       Map.put(
         Map.take(origin, [:platform, :chat_id, :user_id]),
         :token_digest,
         CueProposals.digest(token)
       )}
    else
      {:error, reason} -> app_only_or_refused(reason, opts)
    end
  end

  # A chat that could not be reached refuses the card only where no app can
  # show it (the reach rule).
  defp app_only_or_refused(reason, opts) do
    if Mandates.app_surface?(opts) do
      Logger.warning("A watcher's card did not reach the owner's chat: #{inspect(reason)}")
      {:ok, @app_only}
    else
      {:error, reason}
    end
  end

  defp deliver_card(adapter, inbox, spec) do
    message = inbox_message(inbox)

    message =
      case Map.get(spec, :proactive_key) do
        key when is_binary(key) ->
          %{message | metadata: Map.put(message.metadata, :proactive_key, key)}

        nil ->
          message
      end

    adapter
    |> ReplyContext.new(message)
    |> Delivery.deliver({:approval_prompt, spec})
  end

  defp owner_dm(opts) do
    case OwnerInbox.for_approval(
           :approval_card,
           Keyword.take(opts, [:jobs_config, :configured_owners, :imessage_carrier])
         ) do
      {:ok, inbox} -> with {:ok, origin} <- confirm_origin(inbox), do: {:ok, inbox, origin}
      :no_delivery_target -> {:error, :no_owner_inbox}
    end
  end

  # The owner's DM, or the Fermix app's inbox (an answer from its Mac chat
  # or a paired phone). Never the local cli chat, whose confirmation this
  # path has never sent.
  defp confirm_origin(inbox) do
    result =
      if OwnerInbox.app?(inbox),
        do: OwnerInbox.answer_origin(inbox),
        else: OwnerInbox.dm_origin(inbox)

    case result do
      {:ok, origin} -> {:ok, origin}
      :error -> {:error, :no_owner_inbox}
    end
  end

  defp adapter(platform, opts) do
    case Keyword.get_lazy(opts, :adapter, fn -> ChannelRegistry.adapter(platform) end) do
      nil -> {:error, {:no_adapter, platform}}
      adapter -> {:ok, adapter}
    end
  end

  defp origin(%{platform: platform, chat_id: chat_id, user_id: user_id}) do
    %{channel: platform, chat_id: chat_id, thread_ts: nil, user_id: user_id, resume: nil}
  end

  defp deliver(adapter, inbox, approval, token) do
    context = ReplyContext.new(adapter, inbox_message(inbox))

    case Delivery.deliver(context, approval) do
      :ok ->
        {:ok, token, :new}

      {:error, reason} ->
        :ok = take_back(token)
        {:error, {:owner_inbox_unreachable, reason}}
    end
  end

  # A racing `/deny` or the expiry sweep may already have taken the token; either
  # way none is left for a prompt the owner never saw, which is what this wants.
  defp take_back(token) do
    case Confirmations.take(token) do
      {:ok, _record} -> :ok
      :error -> :ok
    end
  end

  # Marked `owner_inbox`: no turn raised what goes through it, so a channel
  # that keeps a turn's card for that turn's transport alone (the Mac chat)
  # gives it to the owner's inbox as a whole (`Channels.Companion`).
  defp inbox_message(%{platform: platform, destination: owner}) do
    Message.new!(%{
      id: "owner-inbox-#{System.unique_integer([:positive])}",
      content: "",
      sender: "fermix",
      channel: platform,
      chat_id: owner,
      reply_target: owner,
      thread_ts: nil,
      metadata: %{user_id: owner, chat_type: "private", owner_inbox: true}
    })
  end
end
