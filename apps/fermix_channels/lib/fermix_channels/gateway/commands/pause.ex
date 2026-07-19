defmodule FermixChannels.Gateway.Commands.Pause do
  @moduledoc false

  @behaviour FermixChannels.Gateway.Command

  alias FermixChannels.Gateway.Commands.Authorization

  @impl true
  def name, do: "pause"

  @impl true
  def aliases, do: []

  @impl true
  def description, do: "Pause computer use and hand the cursor and keyboard back to you."

  @impl true
  def authorize(message, metadata, context),
    do: Authorization.owner_only(message, metadata, context)

  # Dispatched at ingress (like /stop), so it lands immediately — casting the pause to
  # the running session between its serialized actions — rather than queueing behind
  # the very turn it is trying to interrupt. Distinct from /stop: /pause keeps the
  # session alive and resumable; /stop tears it down.
  @impl true
  def execute(_message, reply_fn, context) do
    reply_fn.({:text, reply(FermixCore.ComputerUse.pause(context))})
    :ok
  end

  defp reply(:paused),
    do: "Computer use paused — the cursor and keyboard are yours. Run /resume to let me continue."

  defp reply(:no_session), do: "No active computer-use session to pause."
end
