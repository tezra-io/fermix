defmodule FermixChannels.Gateway.Commands.New do
  @moduledoc false

  @behaviour FermixChannels.Gateway.Command

  alias FermixChannels.Gateway.Commands.Authorization
  alias FermixCore.Memory.ConversationStore

  @impl true
  def name, do: "new"

  @impl true
  def aliases, do: ["clear"]

  @impl true
  def description, do: "Start a fresh conversation session."

  @impl true
  def authorize(message, metadata, context),
    do: Authorization.owner_only(message, metadata, context)

  @impl true
  def execute(_message, reply_fn, context) do
    conversation_key = Map.fetch!(context, :conversation_key)
    conversation_store = Map.fetch!(context, :conversation_store)

    :ok = ConversationStore.clear(conversation_key, server: conversation_store)
    reply_fn.({:text, "Started a fresh session. Long-term memory is preserved."})
    :ok
  end
end
