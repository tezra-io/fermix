defmodule FermixCore.Memory.SchedulerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Scheduler

  defmodule TestRebuilder do
    def start_link(test_pid) do
      Agent.start_link(fn -> %{calls: [], blocked_reasons: MapSet.new(), test_pid: test_pid} end)
    end

    def block(agent, reason) do
      Agent.update(agent, fn state ->
        %{state | blocked_reasons: MapSet.put(state.blocked_reasons, reason)}
      end)
    end

    def calls(agent) do
      Agent.get(agent, & &1.calls)
    end

    def rebuild(agent_id, owner_id, reason, opts) do
      state_agent = Keyword.fetch!(opts, :state_agent)

      {test_pid, should_block} =
        Agent.get_and_update(state_agent, fn state ->
          next_calls = state.calls ++ [{agent_id, owner_id, reason}]

          {
            {state.test_pid, MapSet.member?(state.blocked_reasons, reason)},
            %{state | calls: next_calls}
          }
        end)

      send(test_pid, {:rebuild_started, agent_id, owner_id, reason, self()})

      if should_block do
        receive do
          {:release_rebuild, ^reason} -> :ok
        end
      end

      send(test_pid, {:rebuild_finished, agent_id, owner_id, reason})
      {:ok, %{user: nil, memory: nil}}
    end
  end

  setup do
    task_supervisor =
      start_supervised!(
        {Task.Supervisor, name: :"memory_scheduler_task_#{System.unique_integer([:positive])}"}
      )

    rebuilder_state =
      start_supervised!(%{
        id: :"memory_rebuilder_state_#{System.unique_integer([:positive])}",
        start: {TestRebuilder, :start_link, [self()]}
      })

    %{task_supervisor: task_supervisor, rebuilder_state: rebuilder_state}
  end

  test "dedupes concurrent rebuild requests and favors fresh event work", %{
    task_supervisor: task_supervisor,
    rebuilder_state: rebuilder_state
  } do
    scheduler =
      start_scheduler(task_supervisor, rebuilder_state,
        periodic_interval_ms: 10_000,
        periodic_agent_ids: []
      )

    TestRebuilder.block(rebuilder_state, :event)

    assert :ok = Scheduler.request_rebuild("main", "default", :event, server: scheduler)

    assert_receive {:rebuild_started, "main", "default", :event, blocked_pid}, 1_000

    assert :ok = Scheduler.request_rebuild("main", "default", :periodic, server: scheduler)
    assert :ok = Scheduler.request_rebuild("main", "default", :event, server: scheduler)

    refute_receive {:rebuild_started, "main", "default", :periodic, _pid}, 100
    refute_receive {:rebuild_started, "main", "default", :event, _pid}, 100

    send(blocked_pid, {:release_rebuild, :event})

    assert_receive {:rebuild_finished, "main", "default", :event}, 1_000
    assert_receive {:rebuild_started, "main", "default", :event, next_pid}, 1_000
    send(next_pid, {:release_rebuild, :event})
    assert_receive {:rebuild_finished, "main", "default", :event}, 1_000

    assert TestRebuilder.calls(rebuilder_state) == [
             {"main", "default", :event},
             {"main", "default", :event}
           ]
  end

  test "enqueues periodic rebuilds", %{
    task_supervisor: task_supervisor,
    rebuilder_state: rebuilder_state
  } do
    _scheduler = start_scheduler(task_supervisor, rebuilder_state, periodic_interval_ms: 30)

    assert_receive {:rebuild_started, "main", "default", :periodic, _pid}, 1_000
    assert_receive {:rebuild_finished, "main", "default", :periodic}, 1_000
    assert TestRebuilder.calls(rebuilder_state) != []
  end

  defp start_scheduler(task_supervisor, rebuilder_state, opts) do
    start_supervised!(
      {Scheduler,
       [
         name: :"memory_scheduler_#{System.unique_integer([:positive])}",
         scheduler_enabled: true,
         task_supervisor: task_supervisor,
         rebuild_module: TestRebuilder,
         rebuild_opts: [state_agent: rebuilder_state],
         periodic_interval_ms: Keyword.get(opts, :periodic_interval_ms, 30),
         periodic_agent_ids: Keyword.get(opts, :periodic_agent_ids, ["main"]),
         periodic_owner_id: "default"
       ]}
    )
  end
end
