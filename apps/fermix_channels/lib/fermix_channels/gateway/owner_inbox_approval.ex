defmodule FermixChannels.Gateway.OwnerInboxApproval do
  @moduledoc """
  Sends an access-sensitive confirmation to the owner's own chat when the turn
  that asked has no in-chat approval (a channel without slash commands, such as
  ACP). The gateway hands `request/1` to such a turn as `owner_inbox_approval_fn`,
  and `Capabilities.AccessGate` calls it with the parked intent id and a
  Fermix-authored prompt.

  It composes three existing seams and adds no delivery path of its own:

    1. `FermixCore.Delivery.OwnerInbox.resolve/1`, the one answer to "where is
       the owner's inbox". Only an inbox `OwnerInbox.dm_origin/1` answers for
       qualifies (Telegram, Signal, WhatsApp, iMessage): on those the DM's chat
       id is the owner's user id, so the owner's `/confirm` there passes the
       pending record's origin check. That rule lives in core alone.
    2. `Commands.Sandbox.store_pending_grant/2`, binding the token to that DM.
       A repeat while the token lives answers `:existing` and sends nothing.
    3. `Gateway.Delivery`, the single channel-delivery path, so Telegram renders
       its one-tap button and every other channel the tap-to-copy command.

  A failed delivery takes the token back, so no confirmable record exists that
  the owner never saw. A request marked `in_call: true` is a call that waits in
  its own process for the answer (`AccessGate.ask_in_call/3`), so its prompt
  ends with that promise instead of the daemon running a command.
  """

  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Gateway.Commands.Sandbox
  alias FermixChannels.Gateway.Commands.Sandbox.Confirmations
  alias FermixChannels.Gateway.Delivery
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.ReplyContext
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Delivery.OwnerInbox

  @type request :: %{
          required(:access_sensitive) => String.t(),
          required(:prompt) => String.t(),
          optional(:in_call) => true
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
      case Sandbox.store_pending_grant(%{access_sensitive: intent_id}, origin(dm_origin)) do
        {:ok, token, :existing} -> {:ok, token, :existing}
        {:ok, token, :new} -> deliver(adapter, inbox, prompt_text(request, token), token)
      end
    end
  end

  defp prompt_text(%{prompt: prompt} = request, token),
    do:
      prompt <> "\n\n" <> AccessGate.approval_line(token, %{chat_type: "private"}, kind(request))

  defp kind(%{in_call: true}), do: :in_call
  defp kind(_parked), do: :parked

  @doc """
  Sends a mandate proposal (M60 §10.9) to the owner DM `inbox` that core
  resolved and recorded on the proposal, through `Gateway.Delivery` as an
  approval prompt: Telegram shows its one-tap buttons, whose taps send the
  same `/confirm <token>` and `/deny <token>` the text carries for every other
  channel. Nothing is stored here: the proposal and its token's digest are
  durable in core, which checks the answer's origin. Core reaches this through
  `config :fermix_core, :cue_proposal_sender`, registered by
  `FermixChannels.Application`. Seam: `:adapter`.
  """
  @spec send_cue_proposal(
          %{required(:platform) => String.t(), required(:destination) => String.t()},
          String.t(),
          String.t(),
          keyword()
        ) :: :ok | {:error, term()}
  def send_cue_proposal(%{platform: platform} = inbox, text, token, opts \\ [])
      when is_binary(platform) and is_binary(text) and is_binary(token) and is_list(opts) do
    with {:ok, _origin} <- dm_inbox(inbox),
         {:ok, adapter} <- adapter(platform, opts) do
      adapter
      |> ReplyContext.new(inbox_message(inbox))
      |> Delivery.deliver({:approval_prompt, text, token})
    end
  end

  defp owner_dm(opts) do
    case OwnerInbox.resolve(Keyword.take(opts, [:jobs_config, :configured_owners])) do
      {:ok, inbox} -> with {:ok, origin} <- dm_inbox(inbox), do: {:ok, inbox, origin}
      :no_delivery_target -> {:error, :no_owner_inbox}
    end
  end

  defp dm_inbox(inbox) do
    case OwnerInbox.dm_origin(inbox) do
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

  defp deliver(adapter, inbox, text, token) do
    context = ReplyContext.new(adapter, inbox_message(inbox))

    case Delivery.deliver(context, {:approval_prompt, text, token}) do
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

  defp inbox_message(%{platform: platform, destination: owner}) do
    Message.new!(%{
      id: "owner-inbox-#{System.unique_integer([:positive])}",
      content: "",
      sender: "fermix",
      channel: platform,
      chat_id: owner,
      reply_target: owner,
      thread_ts: nil,
      metadata: %{user_id: owner, chat_type: "private"}
    })
  end
end
