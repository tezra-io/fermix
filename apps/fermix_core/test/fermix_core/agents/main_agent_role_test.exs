defmodule FermixCore.Agents.MainAgentRoleTest do
  # The one admission every turn crosses: the gateway queue's checkout for each
  # channel, and a background run's. A device-role engine refuses it by name
  # before any runtime context is built.
  use ExUnit.Case, async: true

  alias FermixCore.Agents.MainAgent
  alias FermixCore.Home.Role

  # Stands in for the provider adapter, so starting the agent resolves no route.
  defmodule NoAdapter do
  end

  @msg %{content: "hello", sender: "owner", channel: "companion", chat_id: "main"}

  defp start_agent(engine_role) do
    name = :"main_agent_role_#{System.unique_integer([:positive])}"

    start_supervised!(
      {MainAgent, name: name, adapter: NoAdapter, engine_role: engine_role},
      id: name
    )

    name
  end

  test "a device-role engine refuses a turn by name and says where the primary is" do
    agent = start_agent(%{role: :device, primary: "aws i-0f3b1c"})

    assert MainAgent.checkout_turn_state(agent, @msg) ==
             {:error,
              {:device_role, "This engine runs in the device role; the primary is aws i-0f3b1c."}}
  end

  test "a device-role engine that knows no primary says it is elsewhere" do
    agent = start_agent(%{role: :device, primary: nil})

    assert {:error,
            {:device_role, "This engine runs in the device role; the primary is elsewhere."}} =
             MainAgent.checkout_turn_state(agent, @msg)
  end

  test "an agent started with no role reads the one this boot recorded" do
    name = :"main_agent_role_#{System.unique_integer([:positive])}"
    pid = start_supervised!({MainAgent, name: name, adapter: NoAdapter}, id: name)

    assert :sys.get_state(pid).engine_role == Role.recorded()
  end
end
