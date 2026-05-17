defmodule FermixChannels.Commands.Registry do
  @moduledoc """
  Registry for channel command modules.
  """

  @default_commands [
    FermixChannels.Commands.Compact,
    FermixChannels.Commands.New,
    FermixChannels.Commands.Help,
    FermixChannels.Commands.Whoami,
    FermixChannels.Commands.Sandbox
  ]

  @spec list() :: [module()]
  def list do
    Application.get_env(:fermix_channels, :commands, @default_commands)
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
