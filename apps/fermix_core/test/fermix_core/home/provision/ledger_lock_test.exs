defmodule FermixCore.Home.Provision.Ledger.LockTest do
  # The one owner of the ledger files' locks: writers wait their turn in the
  # order they asked and are handed the file the moment the one before is
  # done, with no retry or backoff, and an exit hands it on. Each test runs a
  # lock of its own and traces it, so a wait is for the lock's own receipt of
  # a request, never for time.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Provision.Ledger
  alias FermixCore.Home.Provision.Ledger.Lock
  alias FermixTestSupport.SafeRm

  @file_a "/invented/home/device/provision/hetzner.json"
  @file_b "/invented/other/device/provision/hetzner.json"

  setup context do
    server = start_supervised!({Lock, name: :"ledger_lock_#{:erlang.phash2(context.test)}"})
    1 = :erlang.trace(server, true, [:receive])
    %{server: server}
  end

  test "writers are served in the order they asked, each once the one before is done", ctx do
    assert :ok = Lock.acquire(@file_a, server: ctx.server)

    waiters =
      for n <- 1..3 do
        pid = waiter(ctx.server, @file_a, n)
        await_asked(ctx.server, @file_a, pid)
        pid
      end

    assert waiting(ctx.server, @file_a) == 3
    refute_received {:holding, _n}
    assert :ok = Lock.release(@file_a, server: ctx.server)

    for {pid, n} <- Enum.with_index(waiters, 1) do
      assert_receive {:holding, ^n}
      refute_received {:holding, _later}
      send(pid, :release)
    end

    assert_receive {:released, 3}
    assert waiting(ctx.server, @file_a) == 0
  end

  test "a file held by one writer does not hold up another file", ctx do
    assert :ok = Lock.acquire(@file_a, server: ctx.server)
    assert :ok = Lock.acquire(@file_b, server: ctx.server)
  end

  test "a holder that exits hands the file to the next writer", ctx do
    test = self()

    holder =
      spawn(fn ->
        :ok = Lock.acquire(@file_a, server: ctx.server)
        send(test, :held)

        receive do
          :exit -> exit(:gone)
        end
      end)

    assert_receive :held
    pid = waiter(ctx.server, @file_a, 1)
    await_asked(ctx.server, @file_a, pid)

    ref = Process.monitor(holder)
    send(holder, :exit)
    assert_receive {:DOWN, ^ref, :process, ^holder, :gone}
    assert_receive {:holding, 1}
  end

  test "a writer that waits past its bound is refused by name and leaves the queue", ctx do
    assert :ok = Lock.acquire(@file_a, server: ctx.server)

    refused =
      Task.async(fn -> Lock.acquire(@file_a, server: ctx.server, wait_ms: 50) end)

    assert {:error, {:locked, @file_a}} = Task.await(refused)
    assert waiting(ctx.server, @file_a) == 0

    # It is never handed the file: the next writer after the holder is.
    assert :ok = Lock.release(@file_a, server: ctx.server)
    assert :ok = Lock.acquire(@file_a, server: ctx.server)
  end

  test "only the holder releases", ctx do
    assert :ok = Lock.acquire(@file_a, server: ctx.server)
    other = Task.async(fn -> Lock.release(@file_a, server: ctx.server) end)
    assert {:error, :not_held} = Task.await(other)
  end

  # The ledger takes the application's lock across its read, change and write,
  # so the change of a writer that waited lands on top of the one before it.
  test "an update waiting behind one in progress lands on top of it" do
    home = SafeRm.make_tmp_dir!("ledger_lock")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    test = self()

    holder =
      Task.async(fn ->
        Ledger.update(home, "hetzner", fn ledger ->
          send(test, :holding)

          receive do
            :go -> {:ok, %{ledger | ref: "a1b2"}}
          end
        end)
      end)

    assert_receive :holding
    ip = %{id: 7, type: "ipv4", ip: nil}

    waiter =
      Task.async(fn -> Ledger.update(home, "hetzner", &{:ok, %{&1 | primary_ips: [ip]}}) end)

    send(holder.pid, :go)

    assert {:ok, %{ref: "a1b2"}} = Task.await(holder)
    assert {:ok, %{ref: "a1b2", primary_ips: [^ip]}} = Task.await(waiter)
    assert {:ok, %{ref: "a1b2", primary_ips: [^ip]}} = Ledger.read(home, "hetzner")
  end

  # A writer that takes the file, says so, and lets it go when told.
  defp waiter(server, file, n) do
    test = self()

    {:ok, pid} =
      Task.start_link(fn ->
        :ok = Lock.acquire(file, server: server)
        send(test, {:holding, n})

        receive do
          :release -> :ok = Lock.release(file, server: server)
        end

        send(test, {:released, n})
      end)

    pid
  end

  # The lock has `pid`'s request in hand; it serves it before any later call.
  defp await_asked(server, file, pid),
    do:
      assert_receive({:trace, ^server, :receive, {:"$gen_call", {^pid, _tag}, {:acquire, ^file}}})

  defp waiting(server, file) do
    %{waiting: waiting} = :sys.get_state(server)
    waiting |> Map.get(file, :queue.new()) |> :queue.len()
  end
end
