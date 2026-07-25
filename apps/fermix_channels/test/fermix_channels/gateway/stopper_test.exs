defmodule FermixChannels.Gateway.StopperTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Gateway.Stopper

  # Stands in for `Gateway.Queue` / `Gateway.WorkRegistry` / `Harness.Manager`:
  # each `stop_all/1` is a `:stop_all` call, so a GenServer that replies with the
  # count shape exercises the mapping.
  defmodule StubServer do
    use GenServer

    def start_link(counts), do: GenServer.start_link(__MODULE__, counts)

    @impl true
    def init(counts), do: {:ok, counts}

    @impl true
    def handle_call(:stop_all, _from, counts), do: {:reply, counts, counts}
  end

  test "maps queue + work-registry + harness stop counts into the reported counts" do
    {:ok, queue} = StubServer.start_link(%{active_stopped: 2, pending_cleared: 1})
    {:ok, registry} = StubServer.start_link(%{cancelled: 3})
    {:ok, harness} = StubServer.start_link(%{cancelled: 4})

    assert Stopper.stop_all(queue: queue, work_registry: registry, harness: harness) ==
             %{active_turns: 2, queued_messages: 1, background_tasks: 3, harness_runs: 4}
  end

  test "reports zeros when nothing was running" do
    {:ok, queue} = StubServer.start_link(%{active_stopped: 0, pending_cleared: 0})
    {:ok, registry} = StubServer.start_link(%{cancelled: 0})
    {:ok, harness} = StubServer.start_link(%{cancelled: 0})

    assert Stopper.stop_all(queue: queue, work_registry: registry, harness: harness) ==
             %{active_turns: 0, queued_messages: 0, background_tasks: 0, harness_runs: 0}
  end
end
