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

  # Dispatched at ingress (like /stop), so it lands immediately — reaching the
  # running session, and through it the helper's own control reader, rather than
  # queueing behind the very turn it is trying to interrupt. Distinct from /stop:
  # /pause keeps the session alive and resumable; /stop tears it down.
  #
  # Every sentence below reports what the helper ACKNOWLEDGED, never what was sent.
  @impl true
  def execute(_message, reply_fn, context) do
    reply_fn.({:text, reply(FermixCore.ComputerUse.pause(context))})
    :ok
  end

  defp reply(:paused),
    do: "Computer use paused — the cursor and keyboard are yours. Run /resume to let me continue."

  # The helper acknowledged the barrier and named the action it had already begun.
  # That one finishes; nothing after it starts. Promising the machine back this
  # instant would be a lie the human watches being broken.
  defp reply(:paused_in_flight),
    do:
      "Pausing. One action is already under way and will finish; nothing further will be " <>
        "sent. The cursor and keyboard are yours once it completes."

  # No acknowledgement means no proof the barrier installed, and saying "paused"
  # would hand back a machine that might still be driven. The helper is ended
  # instead, which definitely returns it.
  defp reply(:unconfirmed),
    do:
      "Stopping, unconfirmed — the computer-use helper did not confirm the pause, so it was " <>
        "shut down instead. The cursor and keyboard are yours. Anything it had already " <>
        "started may have finished, so check the screen."

  defp reply(:no_session), do: "No active computer-use session to pause."
end
