defmodule FermixChannels.Gateway.Commands.Tasks do
  @moduledoc false

  @behaviour FermixChannels.Gateway.Command

  alias FermixChannels.Gateway.Commands.Authorization
  alias FermixChannels.Gateway.WorkRegistry

  @default_registry FermixChannels.Gateway.WorkRegistry

  @impl true
  def name, do: "tasks"

  @impl true
  def aliases, do: []

  @impl true
  def description, do: "List running and recent background work."

  @impl true
  def authorize(message, metadata, context),
    do: Authorization.owner_only(message, metadata, context)

  # Scoped to the requesting conversation: a caller only sees background work
  # started from this conversation, not every source sharing the daemon (§17.7).
  @impl true
  def execute(_message, reply_fn, context) do
    scope = Map.get(context, :conversation_key)
    reply_fn.({:text, render(WorkRegistry.list(registry(context), scope))})
    :ok
  end

  defp render([]), do: "No background work."

  defp render(entries) do
    "Background work:\n" <> Enum.map_join(entries, "\n", &line/1)
  end

  defp line(entry) do
    "• #{entry.work_id} [#{entry.status}] #{entry.command}: #{entry.prompt_preview}"
  end

  defp registry(context), do: Map.get(context, :work_registry, @default_registry)
end
