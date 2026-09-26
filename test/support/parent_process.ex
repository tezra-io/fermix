defmodule FermixTestSupport.ParentProcess do
  @moduledoc """
  The OS process that started this test VM.

  `FermixCore.SocketPeer` places a socket's client beneath the daemon's own OS
  process. A test's client runs in this VM, so a test that needs "a client the
  daemon started" names this VM's parent as the daemon.
  """

  @doc "The OS pid of the process that started this VM."
  @spec os_pid() :: pos_integer()
  def os_pid do
    {out, 0} = System.cmd("/bin/ps", ["-o", "ppid=", "-p", System.pid()])

    case out |> String.trim() |> String.to_integer() do
      ppid when ppid > 0 -> ppid
      0 -> raise "this VM runs as pid 1, so no parent process can stand in for the daemon"
    end
  end
end
