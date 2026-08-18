defmodule FermixCore.ComputerHistory.SingletonLockTest do
  @moduledoc """
  MILESTONE_32 §8.6 — the machine-wide capture lock. Acquire/heartbeat/release,
  stale-break, and the property that matters most: two daemons racing to break the
  SAME stale lock never both win (no double-recording). The lock path is a temp
  path throughout, so the suite never touches the real machine lock.
  """
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.SingletonLock

  setup do
    path =
      Path.join(System.tmp_dir!(), "fermix-ch-lock-#{System.unique_integer([:positive])}.lock")

    on_exit(fn ->
      FermixTestSupport.SafeRm.rm(path)
      # Any stale-break claim files left by a failed rename path.
      Path.wildcard(path <> ".break.*") |> Enum.each(&FermixTestSupport.SafeRm.rm/1)
    end)

    %{path: path}
  end

  defp make_stale(path, home) do
    File.write!(path, "#{home}\nstale-holder\n")
    old = System.os_time(:second) - 3_600
    File.touch!(path, old)
  end

  describe "acquire / release" do
    test "acquires a free lock and records the holder home", %{path: path} do
      assert :ok = SingletonLock.acquire(path, home: "/tmp/home-a")
      assert File.exists?(path)
      assert {:ok, contents} = File.read(path)
      assert contents =~ "/tmp/home-a"
    end

    test "a second acquire of a live lock yields with the holder home", %{path: path} do
      assert :ok = SingletonLock.acquire(path, home: "/tmp/home-a")

      assert {:error, {:held_by, "/tmp/home-a"}} =
               SingletonLock.acquire(path, home: "/tmp/home-b")
    end

    test "release frees the lock for re-acquisition", %{path: path} do
      assert :ok = SingletonLock.acquire(path, home: "/tmp/home-a")
      assert :ok = SingletonLock.release(path)
      refute File.exists?(path)
      assert :ok = SingletonLock.acquire(path, home: "/tmp/home-b")
    end

    test "release is idempotent on a missing lock", %{path: path} do
      assert :ok = SingletonLock.release(path)
    end
  end

  describe "heartbeat + staleness" do
    test "heartbeat refreshes the mtime, keeping the lock live", %{path: path} do
      assert :ok = SingletonLock.acquire(path, home: "/tmp/home-a")
      old = System.os_time(:second) - 3_600
      File.touch!(path, old)

      assert :ok = SingletonLock.heartbeat(path)
      assert {:ok, %File.Stat{mtime: mtime}} = File.stat(path, time: :posix)
      assert System.os_time(:second) - mtime < 60
    end

    test "a stale lock is broken by a new acquire", %{path: path} do
      make_stale(path, "/tmp/home-crashed")
      assert :ok = SingletonLock.acquire(path, stale_after_ms: 1_000, home: "/tmp/home-new")
      assert {:ok, contents} = File.read(path)
      assert contents =~ "/tmp/home-new"
    end

    test "a live (heartbeated) lock is NOT broken", %{path: path} do
      # Fresh mtime → not stale → the contender yields even with a short window.
      assert :ok = SingletonLock.acquire(path, home: "/tmp/home-a")

      assert {:error, {:held_by, _}} =
               SingletonLock.acquire(path, stale_after_ms: 1, home: "/tmp/home-b")
    end
  end

  describe "concurrent stale-break admits exactly one winner (no double-recording)" do
    # The threat model (§8.6) is exactly TWO daemons — the live `~/.fermix` and a
    # dev `~/.fermix-dev` — racing to break a lock a crashed holder left stale.
    # Looping the pairwise race many times shakes out the timing interleavings; a
    # single persistent double-winner would mean both capturers heartbeat forever
    # and double-record, so this asserts the property that actually matters.
    test "two daemons racing to break the same stale lock — never both win, over many trials", %{
      path: path
    } do
      results =
        Enum.map(1..200, fn _trial ->
          make_stale(path, "/tmp/home-crashed")

          winners =
            [1, 2]
            |> Task.async_stream(
              fn i ->
                SingletonLock.acquire(path, stale_after_ms: 300, home: "/tmp/home-#{i}")
              end,
              max_concurrency: 2,
              timeout: 5_000
            )
            |> Enum.count(fn {:ok, result} -> result == :ok end)

          SingletonLock.release(path)
          winners
        end)

      # Every trial admits EXACTLY one winner — never two (double-capture), never
      # zero (a stale lock left un-broken bricks capture forever).
      assert Enum.all?(results, &(&1 == 1)),
             "some trial did not have exactly one winner: #{inspect(Enum.frequencies(results))}"
    end
  end
end
