defmodule FermixChannels.Gateway.Commands.Resume do
  @moduledoc false

  @behaviour FermixChannels.Gateway.Command

  alias FermixChannels.Gateway.Commands.Authorization

  @impl true
  def name, do: "resume"

  @impl true
  def aliases, do: []

  @impl true
  def description, do: "Resume computer use after a /pause."

  @impl true
  def authorize(message, metadata, context),
    do: Authorization.owner_only(message, metadata, context)

  @impl true
  def execute(_message, reply_fn, context) do
    reply_fn.({:text, reply(FermixCore.ComputerUse.resume(context))})
    :ok
  end

  defp reply(:resumed),
    do: "Computer use resumed — tell me what to do next and I'll pick it back up."

  # Lifting the barrier was not acknowledged, so it may still be installed — and a
  # helper that is still barred would refuse every action while this side believed
  # it was free. It is shut down instead; the next action starts a clean one.
  defp reply(:unconfirmed),
    do:
      "The computer-use helper did not confirm the resume, so it was shut down. Tell me what " <>
        "to do next and a fresh one starts."

  defp reply(:no_session), do: "No paused computer-use session to resume."
end
