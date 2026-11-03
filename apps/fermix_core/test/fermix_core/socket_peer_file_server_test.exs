defmodule FermixCore.SocketPeerFileServerTest do
  # Sync: it suspends the VM's file server, which every other test's file calls
  # queue on.
  use ExUnit.Case, async: false

  alias FermixCore.SocketPeer

  @arrival_ms 10_000

  # `admit/2` runs in every Fermix socket's accept loop, so its read of the
  # peer's /proc status must not wait on the file server: a busy node held a
  # browser-host handshake past its reply under load.
  test "a peer's status is read while the VM's file server is busy" do
    proc = FermixTestSupport.SafeRm.make_tmp_dir!("socket-peer-proc")
    File.mkdir_p!(Path.join(proc, "4242"))
    File.write!(Path.join([proc, "4242", "status"]), "Name:\tsh\nNoNewPrivs:\t1\n")

    server = Process.whereis(:file_server_2)
    :ok = :sys.suspend(server)

    read =
      try do
        task = Task.async(fn -> SocketPeer.proc_status(4242, proc) end)
        Task.yield(task, @arrival_ms) || Task.shutdown(task, :brutal_kill)
      after
        :ok = :sys.resume(server)
      end

    FermixTestSupport.SafeRm.rm_rf!(proc)

    assert read == {:ok, {:ok, "Name:\tsh\nNoNewPrivs:\t1\n"}}
  end

  test "a status that cannot be read names the pid and the reason" do
    proc = FermixTestSupport.SafeRm.make_tmp_dir!("socket-peer-proc")

    assert SocketPeer.proc_status(4242, proc) ==
             {:error, {:proc_status_unreadable, 4242, :enoent}}

    FermixTestSupport.SafeRm.rm_rf!(proc)
  end
end
