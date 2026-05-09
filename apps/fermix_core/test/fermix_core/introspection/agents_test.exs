defmodule FermixCore.Introspection.AgentsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Introspection.Agents

  defmodule FakeMainAgent do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :status))
    end

    @impl true
    def init(status), do: {:ok, status}

    @impl true
    def handle_call(:status, _from, status), do: {:reply, status, status}
  end

  test "returns an error when the main agent is unavailable" do
    assert {:error, {:main_agent_unavailable, reason}} =
             Agents.snapshot(main_agent: :missing_main_agent)

    assert reason != nil
  end

  test "returns an error when the skill worker supervisor is unavailable" do
    {:ok, main_agent} =
      start_supervised(
        {FakeMainAgent,
         status: %{
           name: "main",
           status: :idle,
           active_conversations: 0,
           pending_conversations: 0
         }}
      )

    assert {:error, {:agent_supervisor_unavailable, reason}} =
             Agents.snapshot(main_agent: main_agent, agent_supervisor: :missing_agent_supervisor)

    assert reason != nil
  end

  test "separates main-agent process health from request activity" do
    {:ok, main_agent} =
      start_supervised(
        {FakeMainAgent,
         status: %{
           name: "main",
           status: :idle,
           active_conversations: 0,
           pending_conversations: 0
         }}
      )

    supervisor = :"agents_snapshot_sup_#{System.unique_integer([:positive, :monotonic])}"
    {:ok, _pid} = start_supervised({AgentSupervisor, name: supervisor})

    assert {:ok, snapshot} = Agents.snapshot(main_agent: main_agent, agent_supervisor: supervisor)
    assert snapshot.main.health == :online
    assert snapshot.main.activity == :idle
    assert snapshot.main.status == :idle
  end
end
