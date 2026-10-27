defmodule FermixCore.ComputerHistory.SingletonLockFileServerTest do
  # Sync: it suspends the VM's one file server, which every test uses.
  use ExUnit.Case, async: false

  alias FermixCore.ComputerHistory.SingletonLock

  @arrival_ms 10_000

  # The lock ran every call through the VM's one file server
  # (`:file_server_2`), so on a loaded runner each acquire queued behind every
  # other test's file calls: the stale-break race test overran 60 s on
  # macos-x64. An acquire, a stale break and a release now make their calls in
  # the caller's own process.
  test "acquire, a stale break and release need nothing from the VM's file server" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("singleton-lock-no-file-server")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    fresh = Path.join(root, "fresh.lock")
    stale = Path.join(root, "stale.lock")
    File.write!(stale, "/tmp/home-crashed\nstale-holder\n")
    File.touch!(stale, System.os_time(:second) - 3_600)

    server = Process.whereis(:file_server_2)
    :ok = :sys.suspend(server)

    outcome =
      try do
        task =
          Task.async(fn ->
            {SingletonLock.acquire(fresh, home: "/tmp/home-a"),
             SingletonLock.acquire(fresh, home: "/tmp/home-b"),
             SingletonLock.acquire(stale, home: "/tmp/home-c"), SingletonLock.release(fresh)}
          end)

        Task.yield(task, @arrival_ms) || Task.shutdown(task, :brutal_kill)
      after
        :ok = :sys.resume(server)
      end

    assert outcome == {:ok, {:ok, {:error, {:held_by, "/tmp/home-a"}}, :ok, :ok}}
    assert File.read!(stale) =~ "/tmp/home-c"
    refute File.exists?(fresh)
  end
end
