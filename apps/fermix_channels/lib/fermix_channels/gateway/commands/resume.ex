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

  defp reply(:no_session), do: "No paused computer-use session to resume."
end
