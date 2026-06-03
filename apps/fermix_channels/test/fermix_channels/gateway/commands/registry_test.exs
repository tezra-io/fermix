defmodule FermixChannels.Gateway.Commands.RegistryTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.Commands.Registry

  # Minimal command stub whose name collides with the built-in `/new`.
  defmodule DupName do
    def name, do: "new"
    def aliases, do: []
  end

  setup do
    previous = Application.get_env(:fermix_channels, :commands)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_channels, :commands)
        value -> Application.put_env(:fermix_channels, :commands, value)
      end
    end)
  end

  test "the default command set has no duplicate triggers" do
    Application.delete_env(:fermix_channels, :commands)
    assert :ok = Registry.validate!()
  end

  test "resolves /stop to the Stop command" do
    Application.delete_env(:fermix_channels, :commands)
    assert {:ok, FermixChannels.Gateway.Commands.Stop} = Registry.lookup("stop")
  end

  test "raises on a duplicate name or alias" do
    Application.put_env(:fermix_channels, :commands, [
      FermixChannels.Gateway.Commands.New,
      __MODULE__.DupName
    ])

    assert_raise ArgumentError, ~r/duplicate command trigger: "new"/, fn ->
      Registry.validate!()
    end
  end
end
