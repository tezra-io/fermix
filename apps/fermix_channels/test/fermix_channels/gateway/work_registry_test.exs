defmodule FermixChannels.Gateway.WorkRegistryTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Gateway.WorkRegistry

  # Upper bound on the probe below, so a regression that stops refusing fails
  # this test instead of spawning forever.
  @start_attempt_cap 64

  setup do
    work_sup = start_supervised!({Task.Supervisor, []})

    registry =
      start_supervised!(
        {WorkRegistry,
         name: :"wr_#{System.unique_integer([:positive])}", work_supervisor: work_sup}
      )

    %{registry: registry}
  end

  # A runner that announces its pid, then blocks until told to finish or crash.
  defp controllable_run(test_pid) do
    fn _work_id ->
      send(test_pid, {:running, self()})

      receive do
        :finish -> :ok
        :crash -> raise "boom"
      after
        10_000 -> :ok
      end
    end
  end

  defp start_item(registry, test_pid, overrides \\ %{}) do
    request =
      Map.merge(
        %{
          run: controllable_run(test_pid),
          command: "background",
          profile: :normal,
          channel: "telegram",
          prompt_preview: "summarize    the\nnews please"
        },
        overrides
      )

    {:ok, work_id} = WorkRegistry.start(registry, request)

    assert_receive {:running, task_pid}, 2_000
    {work_id, task_pid}
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  # Drive the real (module-constant) running ceiling rather than an injected
  # one: start items until the registry refuses, and report how many were
  # accepted alongside the cap it reported.
  defp fill_to_running_cap(_registry, _test_pid, started) when started >= @start_attempt_cap do
    flunk("WorkRegistry accepted #{started} concurrent items without refusing")
  end

  defp fill_to_running_cap(registry, test_pid, started) do
    request = %{run: controllable_run(test_pid), command: "background"}

    case WorkRegistry.start(registry, request) do
      {:ok, _work_id} ->
        assert_receive {:running, _pid}, 2_000
        fill_to_running_cap(registry, test_pid, started + 1)

      {:error, {:max_running_work, cap}} ->
        {started, cap}
    end
  end

  defp status_of(registry, work_id) do
    case Enum.find(WorkRegistry.list(registry), &(&1.work_id == work_id)) do
      nil -> nil
      entry -> entry.status
    end
  end

  test "tracks a running item and exposes only redacted metadata", %{registry: registry} do
    {work_id, _pid} = start_item(registry, self())

    [entry] = WorkRegistry.list(registry)
    assert entry.work_id == work_id
    assert entry.status == :running
    assert entry.command == "background"
    assert entry.profile == :normal
    # whitespace collapsed, capped at 80 chars, no raw prompt body retained
    assert entry.prompt_preview == "summarize the news please"
    refute Map.has_key?(entry, :pid)
    refute Map.has_key?(entry, :ref)
  end

  test "normal completion transitions to :completed", %{registry: registry} do
    {work_id, task_pid} = start_item(registry, self())
    send(task_pid, :finish)
    assert eventually(fn -> status_of(registry, work_id) == :completed end)
  end

  test "a fast successful job is recorded as :completed, not :failed", %{registry: registry} do
    test_pid = self()

    # Returns immediately — without the start handshake the monitor could be
    # installed after exit and a :noproc :DOWN would mis-record this as :failed.
    {:ok, work_id} =
      WorkRegistry.start(registry, %{
        run: fn _work_id ->
          send(test_pid, :ran)
          :ok
        end,
        command: "background"
      })

    assert_receive :ran, 2_000
    assert eventually(fn -> status_of(registry, work_id) == :completed end)
  end

  test "a crash transitions to :failed", %{registry: registry} do
    {work_id, task_pid} = start_item(registry, self())

    ExUnit.CaptureLog.capture_log(fn ->
      send(task_pid, :crash)
      assert eventually(fn -> status_of(registry, work_id) == :failed end)
    end)
  end

  test "stop_all cancels running items and returns a count", %{registry: registry} do
    {id_a, pid_a} = start_item(registry, self())
    {id_b, pid_b} = start_item(registry, self())

    ref_a = Process.monitor(pid_a)
    ref_b = Process.monitor(pid_b)

    assert %{cancelled: 2} = WorkRegistry.stop_all(registry)

    assert_receive {:DOWN, ^ref_a, :process, ^pid_a, _reason}, 2_000
    assert_receive {:DOWN, ^ref_b, :process, ^pid_b, _reason}, 2_000

    assert status_of(registry, id_a) == :cancelled
    assert status_of(registry, id_b) == :cancelled
    # a cancelled item's terminal status is not overwritten by its task DOWN
    refute eventually(fn -> status_of(registry, id_a) == :failed end, 10)
  end

  test "stop_all with nothing running returns zero", %{registry: registry} do
    assert %{cancelled: 0} = WorkRegistry.stop_all(registry)
  end

  test "missing run thunk is rejected", %{registry: registry} do
    assert {:error, :missing_run} = WorkRegistry.start(registry, %{command: "background"})
  end

  test "refuses a start past the running cap and names the cap in the reason", %{
    registry: registry
  } do
    {started, cap} = fill_to_running_cap(registry, self(), 0)

    assert started == cap
    assert length(WorkRegistry.list(registry)) == cap

    assert {:error, {:max_running_work, ^cap}} =
             WorkRegistry.start(registry, %{run: controllable_run(self()), command: "background"})
  end

  # The running cap and the terminal cap are separate bounds: cancelling frees
  # running slots even though the cancelled entries are still retained.
  test "cancelling running work frees running slots", %{registry: registry} do
    {started, _cap} = fill_to_running_cap(registry, self(), 0)

    assert %{cancelled: ^started} = WorkRegistry.stop_all(registry)
    assert length(WorkRegistry.list(registry)) == started

    assert {:ok, _work_id} =
             WorkRegistry.start(registry, %{run: controllable_run(self()), command: "background"})
  end

  test "stop_all evicts cancelled entries beyond the bounded cap" do
    work_sup = start_supervised!({Task.Supervisor, []}, id: :evict_work_sup)

    registry =
      start_supervised!(
        {WorkRegistry,
         name: :"wr_evict_#{System.unique_integer([:positive])}",
         work_supervisor: work_sup,
         max_terminal: 2},
        id: :evict_registry
      )

    for _ <- 1..3 do
      {:ok, _work_id} =
        WorkRegistry.start(registry, %{run: controllable_run(self()), command: "background"})

      assert_receive {:running, _pid}, 2_000
    end

    assert %{cancelled: 3} = WorkRegistry.stop_all(registry)
    # all three are terminal (:cancelled), but only max_terminal (2) are retained
    assert length(WorkRegistry.list(registry)) == 2
  end
end
