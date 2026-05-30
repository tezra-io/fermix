defmodule FermixCore.Sandbox.CommandCapabilitiesTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry
  alias FermixCore.Sandbox.CommandCapabilities
  alias FermixCore.Sandbox.Config

  setup do
    original_secret = System.get_env("FERMIX_TEST_SECRET")

    on_exit(fn ->
      case original_secret do
        nil -> System.delete_env("FERMIX_TEST_SECRET")
        value -> System.put_env("FERMIX_TEST_SECRET", value)
      end
    end)

    name = :"sandbox_command_caps_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name})
    %{registry: name}
  end

  test "registers explicit command capabilities and passes only declared env", %{
    registry: registry
  } do
    System.put_env("FERMIX_TEST_SECRET", "visible")
    System.put_env("FERMIX_OTHER_SECRET", "hidden")

    config =
      Config.normalize(
        env: [allow: ["FERMIX_TEST_SECRET", "FERMIX_OTHER_SECRET"]],
        commands: [
          explicit: %{
            "echo_secret" => [
              enabled: true,
              command: "/bin/sh",
              args: ["-c", "printf \"$FERMIX_TEST_SECRET:$FERMIX_OTHER_SECRET:$1\"", "sh"],
              pass_env: ["FERMIX_TEST_SECRET"]
            ]
          }
        ]
      )

    assert :ok = CommandCapabilities.refresh(registry, config)
    assert {:ok, capability} = Registry.find(registry, "echo_secret")
    assert capability.policy_class == :exec
    assert capability.metadata[:sandbox_command?]

    assert {:ok, %{success: true, output: "visible::hello"}} =
             Capability.execute(capability, %{"prompt" => "hello"}, %{sandbox_config: config})
  end
end
