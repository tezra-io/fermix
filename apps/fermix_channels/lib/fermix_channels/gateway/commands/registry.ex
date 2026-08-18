defmodule FermixChannels.Gateway.Commands.Registry do
  @moduledoc """
  Registry for channel command modules.
  """

  @default_commands [
    FermixChannels.Gateway.Commands.Compact,
    FermixChannels.Gateway.Commands.New,
    FermixChannels.Gateway.Commands.Help,
    FermixChannels.Gateway.Commands.Whoami,
    FermixChannels.Gateway.Commands.Sandbox,
    FermixChannels.Gateway.Commands.Skills,
    FermixChannels.Gateway.Commands.Soul,
    FermixChannels.Gateway.Commands.Stop,
    FermixChannels.Gateway.Commands.Pause,
    FermixChannels.Gateway.Commands.Resume,
    FermixChannels.Gateway.Commands.Background,
    FermixChannels.Gateway.Commands.Tasks,
    FermixChannels.Gateway.Commands.Ultra,
    FermixChannels.Gateway.Commands.History
  ]

  @spec list() :: [module()]
  def list do
    Application.get_env(:fermix_channels, :commands, @default_commands)
  end

  @doc """
  Assert the configured commands have no duplicate name or alias. `lookup/1`
  returns the first match, so a duplicate trigger would silently shadow one
  command with another. Raises with the offending trigger; called at boot to
  fail fast on a misconfigured command list.
  """
  @spec validate!() :: :ok
  def validate! do
    triggers =
      Enum.flat_map(list(), fn command ->
        Enum.map([command.name() | command.aliases()], &String.downcase/1)
      end)

    case triggers -- Enum.uniq(triggers) do
      [] ->
        :ok

      [duplicate | _rest] ->
        raise ArgumentError, "duplicate command trigger: #{inspect(duplicate)}"
    end
  end

  @spec lookup(String.t()) :: {:ok, module()} | :error
  def lookup(name) when is_binary(name) do
    normalized = String.downcase(name)

    Enum.find_value(list(), :error, fn command ->
      names = [command.name() | command.aliases()]

      if normalized in Enum.map(names, &String.downcase/1) do
        {:ok, command}
      end
    end)
  end
end
