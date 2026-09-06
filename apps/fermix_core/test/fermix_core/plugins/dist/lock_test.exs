defmodule FermixCore.Plugins.Dist.LockTest do
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.Dist.Lock

  setup do
    tmp = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-dist-lock")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(tmp) end)
    %{lock: Path.join(tmp, ".lock")}
  end

  test "runs the function while holding the lock and releases after", %{lock: lock} do
    assert :held = Lock.with_lock(lock, fn -> :held end)
    refute File.exists?(lock), "lock file should be removed after the critical section"
  end

  test "releases the lock even when the function raises", %{lock: lock} do
    assert_raise RuntimeError, fn ->
      Lock.with_lock(lock, fn -> raise "boom" end)
    end

    refute File.exists?(lock)
    # a subsequent acquire still works
    assert :ok = Lock.with_lock(lock, fn -> :ok end)
  end

  test "fails loud (bounded) when the lock is already held", %{lock: lock} do
    File.write!(lock, "someone else\n")

    # tiny budget so the test is fast; stale threshold high so it is NOT broken
    assert {:error, :lock_unavailable} =
             Lock.with_lock(lock, fn -> :should_not_run end,
               attempts: 3,
               delay_ms: 1,
               stale_after_ms: 600_000
             )

    assert File.exists?(lock), "a live lock must not be removed"
  end

  test "breaks a stale lock (older than the threshold) and proceeds", %{lock: lock} do
    File.write!(lock, "crashed holder\n")
    # backdate the lock's mtime well past the stale threshold
    old = System.os_time(:second) - 10_000
    File.touch!(lock, old)

    assert :done =
             Lock.with_lock(lock, fn -> :done end,
               attempts: 5,
               delay_ms: 1,
               stale_after_ms: 1_000
             )

    refute File.exists?(lock)
  end

  test "serializes two concurrent holders (one waits for the other)", %{lock: lock} do
    parent = self()

    first =
      Task.async(fn ->
        Lock.with_lock(lock, fn ->
          send(parent, :first_in)
          Process.sleep(50)
          :first_done
        end)
      end)

    assert_receive :first_in, 1_000

    # second contends while first holds; with a budget that outlasts the 50ms hold it succeeds
    second =
      Task.async(fn ->
        Lock.with_lock(lock, fn -> :second_done end, attempts: 100, delay_ms: 10)
      end)

    assert Task.await(first) == :first_done
    assert Task.await(second) == :second_done
    refute File.exists?(lock)
  end

  # A cancelled management job stops the run with an exit signal, which skips
  # `after` entirely. The lockfile must still go, or one Cancel refuses every
  # plugin operation until the stale threshold expires.
  test "releases when the holder is stopped with an exit signal", %{lock: lock} do
    holder = spawn_holder(lock)

    Process.exit(holder, :shutdown)

    assert_lock_released(lock)
    assert :reacquired = Lock.with_lock(lock, fn -> :reacquired end, tight_budget())
  end

  test "releases when the holder is brutally killed", %{lock: lock} do
    holder = spawn_holder(lock)

    Process.exit(holder, :kill)

    assert_lock_released(lock)
    assert :reacquired = Lock.with_lock(lock, fn -> :reacquired end, tight_budget())
  end

  # Unlinked on purpose: the test process has to survive the signal it sends.
  defp spawn_holder(lock) do
    parent = self()

    holder =
      spawn(fn ->
        Lock.with_lock(lock, fn ->
          send(parent, :holding)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :holding, 1_000
    assert File.exists?(lock)
    holder
  end

  # Release runs in the owning process just after the holder dies, so the wait
  # is bounded and reported rather than assumed.
  defp assert_lock_released(lock, attempts \\ 200)

  defp assert_lock_released(lock, 0), do: flunk("lock #{lock} was never released")

  defp assert_lock_released(lock, attempts) do
    if File.exists?(lock) do
      Process.sleep(5)
      assert_lock_released(lock, attempts - 1)
    else
      :ok
    end
  end

  # Small enough that a still-held lock fails fast, and stale-breaking is off so
  # a pass can only come from a real release.
  defp tight_budget, do: [attempts: 2, delay_ms: 5, stale_after_ms: 600_000]
end
