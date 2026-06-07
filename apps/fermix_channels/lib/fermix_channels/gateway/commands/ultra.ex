defmodule FermixChannels.Gateway.Commands.Ultra do
  @moduledoc false

  @behaviour FermixChannels.Gateway.Command

  alias FermixChannels.Gateway.Commands.Authorization

  @impl true
  def name, do: "ultra"

  @impl true
  def aliases, do: []

  @impl true
  def description,
    do: "Run a complex task in exhaustive mode (wide fan-out). Usage: /ultra <prompt>"

  @impl true
  def authorize(message, metadata, context),
    do: Authorization.owner_only(message, metadata, context)

  # `/ultra` is not handled inline: it runs as a normal foreground turn tagged
  # with `run_profile: :ultra`. Core (TurnRunner) consumes that tag to run the
  # ordinary agent loop in exhaustive mode — wide `subagents` fan-out + an
  # exhaustive-mode prompt addendum — not a separate orchestrator. Returning
  # `{:enqueue, tagged_message}` is the third dispatch outcome — the gateway
  # enqueues the already-prefix-stripped message with the profile tag in
  # metadata (no Message struct change).
  @impl true
  def execute(message, reply_fn, _context) do
    case String.trim(message.content) do
      "" ->
        reply_fn.({:text, "Usage: /ultra <prompt>"})
        :ok

      _prompt ->
        {:enqueue, tag_ultra(message)}
    end
  end

  defp tag_ultra(message) do
    %{message | metadata: Map.put(message.metadata || %{}, :run_profile, :ultra)}
  end
end
