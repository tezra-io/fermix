defmodule FermixChannels.Commands.Help do
  @moduledoc false

  @behaviour FermixChannels.Command

  alias FermixChannels.Commands.Registry

  @impl true
  def name, do: "help"

  @impl true
  def aliases, do: []

  @impl true
  def description, do: "List available commands."

  @impl true
  def authorize(_message, _metadata, _context), do: :ok

  @impl true
  def execute(message, reply_fn, context) do
    metadata = message.metadata || %{}

    body =
      Registry.list()
      |> Enum.sort_by(& &1.name())
      |> Enum.filter(&authorized?(&1, message, metadata, context))
      |> Enum.map_join("\n", fn command ->
        "#{command_label(command)} - #{command.description()}"
      end)

    reply_fn.({:text, "Available commands:\n#{body}"})
    :ok
  end

  defp authorized?(command, message, metadata, context) do
    case command.authorize(message, metadata, context) do
      :ok -> true
      {:error, :unauthorized} -> false
    end
  end

  defp command_label(command) do
    case command.aliases() do
      [] ->
        "/#{command.name()}"

      aliases ->
        alias_text = Enum.map_join(aliases, ", ", &"/#{&1}")
        "/#{command.name()} (#{alias_text})"
    end
  end
end
