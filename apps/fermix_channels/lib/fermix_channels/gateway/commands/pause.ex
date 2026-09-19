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

  # An action already handed to the helper cannot be recalled (one request, one
  # response, no control channel), so promising the machine back immediately would
  # be a lie the human watches being broken.
  defp reply(:paused_in_flight),
    do:
      "Pausing. One action is already under way and will finish; nothing further will be " <>
        "sent. The cursor and keyboard are yours once it completes."

  defp reply(:no_session), do: "No active computer-use session to pause."
end
