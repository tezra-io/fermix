defmodule FermixChannels.Gateway.OwnerInboxApproval do
  @moduledoc """
  Sends an access-sensitive confirmation to the owner's own chat when the turn
  that asked has no in-chat approval (a channel without slash commands, such as
  ACP). The gateway hands `request/1` to such a turn as `owner_inbox_approval_fn`,
  and `Capabilities.AccessGate` calls it with the parked intent id and a
  Fermix-authored prompt.

  It composes three existing seams and adds no delivery path of its own:

    1. `FermixCore.Delivery.OwnerInbox.resolve/1`, the one answer to "where is
       the owner's inbox". Only a Telegram, Signal or WhatsApp inbox qualifies:
       on those the DM's chat id is the owner's user id, so the owner's
       `/confirm` there passes the pending record's origin check.
    2. `Commands.Sandbox.store_pending_grant/2`, binding the token to that DM.
       A repeat while the token lives answers `:existing` and sends nothing.
    3. `Gateway.Delivery`, the single channel-delivery path, so Telegram renders
       its one-tap button and every other channel the tap-to-copy command.

  A failed delivery takes the token back, so no confirmable record exists that
  the owner never saw.
  """

  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Gateway.Commands.Sandbox
  alias FermixChannels.Gateway.Commands.Sandbox.Confirmations
  alias FermixChannels.Gateway.Delivery
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.ReplyContext
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Delivery.OwnerInbox

  @dm_platforms ["telegram", "signal", "whatsapp"]

  @type request :: %{access_sensitive: String.t(), prompt: String.t()}

  @doc """
  Store and deliver the owner's confirmation. Seams: `:jobs_config` and
  `:configured_owners` (for `OwnerInbox.resolve/1`) and `:adapter` (the channel
  module; otherwise the registry's adapter for the inbox platform).
  """
  @spec request(request(), keyword()) ::
          {:ok, String.t(), :new | :existing} | {:error, term()}
  def request(%{access_sensitive: intent_id, prompt: prompt}, opts \\ [])
      when is_binary(intent_id) and is_binary(prompt) and is_list(opts) do
    with {:ok, inbox} <- owner_dm(opts),
         {:ok, adapter} <- adapter(inbox.platform, opts) do
      case Sandbox.store_pending_grant(%{access_sensitive: intent_id}, origin(inbox)) do
        {:ok, token, :existing} -> {:ok, token, :existing}
        {:ok, token, :new} -> deliver(adapter, inbox, prompt, token)
      end
    end
  end

  defp owner_dm(opts) do
    case OwnerInbox.resolve(Keyword.take(opts, [:jobs_config, :configured_owners])) do
      {:ok, %{platform: platform} = inbox} when platform in @dm_platforms -> {:ok, inbox}
      {:ok, _other_inbox} -> {:error, :no_owner_inbox}
      :no_delivery_target -> {:error, :no_owner_inbox}
    end
  end

  defp adapter(platform, opts) do
    case Keyword.get_lazy(opts, :adapter, fn -> ChannelRegistry.adapter(platform) end) do
      nil -> {:error, {:no_adapter, platform}}
      adapter -> {:ok, adapter}
    end
  end

  defp origin(%{platform: platform, destination: owner}) do
    %{channel: platform, chat_id: owner, thread_ts: nil, user_id: owner, resume: nil}
  end

  defp deliver(adapter, inbox, prompt, token) do
    text = prompt <> "\n\n" <> AccessGate.approval_line(token, %{chat_type: "private"})

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
