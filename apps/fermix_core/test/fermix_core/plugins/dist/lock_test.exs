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
end
