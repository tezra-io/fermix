defmodule FermixChannels.Commands.Whoami do
  @moduledoc false

  @behaviour FermixChannels.Command

  @impl true
  def name, do: "whoami"

  @impl true
  def aliases, do: []

  @impl true
  def description, do: "Show your stable channel user id."

  @impl true
  def authorize(_message, _metadata, _context), do: :ok

  @impl true
  def execute(%{channel: "cli"}, reply_fn, _context) do
    # CLI is an implicit-owner channel; no external stable id discovery is needed.
    reply_fn.("Your user id on this channel: cli")
    :ok
  end

  def execute(message, reply_fn, _context) do
    user_id = stable_user_id(message.metadata || %{})
    reply_fn.("Your user id on this channel: #{user_id || "unknown"}")
    :ok
  end

  defp stable_user_id(metadata) when is_map(metadata) do
    Map.get(metadata, :user_id) || Map.get(metadata, "user_id")
  end
end
