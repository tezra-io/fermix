defmodule FermixCore.SocketPeerTest do
  use ExUnit.Case, async: true

  alias FermixCore.SocketPeer
  alias FermixTestSupport.ParentProcess

  describe "classify_pid/3" do
    # pid => {parent pid, process group, has a controlling terminal}. 20 is the
    # daemon, leading its own group; 25 is its port helper, in that group; 30 is a
    # shell command, the leader of its own group as every command the daemon runs is.
    @table %{
      1 => {0, 1, false},
      20 => {1, 20, false},
      25 => {20, 20, false},
      30 => {25, 30, false},
      40 => {30, 30, false},
      # A job the shell command backgrounded: reparented to init, still in 30.
      45 => {1, 30, false},
      # Left in the daemon's own group, then reparented to init.
      60 => {1, 20, false},
      # A terminal's client, leading its own job.
      50 => {1, 50, true},
      # The last command of a terminal pipeline whose first command has exited.
      70 => {1, 99, true},
      # A job left behind by a command that ran in a session of its own and has
      # exited, as a coding harness's commands do: no leader, no terminal.
      75 => {1, 98, false}
    }

    test "a process whose parent chain reaches the daemon is a daemon descendant" do
      assert SocketPeer.classify_pid(40, 20, @table) == {:ok, :daemon_descendant}
      assert SocketPeer.classify_pid(30, 20, @table) == {:ok, :daemon_descendant}
    end

    test "a job its command backgrounded is placed by its process group's leader" do
      assert SocketPeer.classify_pid(45, 20, @table) == {:ok, :daemon_descendant}
    end

    test "a process left in the daemon's own process group is a daemon descendant" do
      assert SocketPeer.classify_pid(60, 20, @table) == {:ok, :daemon_descendant}
    end

    test "a process the daemon did not start is independent" do
      assert SocketPeer.classify_pid(50, 20, @table) == {:ok, :independent}
    end

    test "a group whose leader has exited places nothing: a member with a terminal is independent" do
      assert SocketPeer.classify_pid(70, 20, @table) == {:ok, :independent}
    end

    test "a member left with neither its group's leader nor a terminal is detached" do
      assert SocketPeer.classify_pid(75, 20, @table) == {:ok, :detached}
    end

    # An eval runner starts the daemon and `fermix ask` in its own process group,
    # so the daemon's port helper shares the client's group. The group is placed
    # by its leader, the runner, and never by that helper.
    test "a process group is placed by its leader, never by another member" do
      runner = %{
        1 => {0, 1, false},
        80 => {1, 80, false},
        81 => {80, 80, false},
        82 => {81, 80, false},
        83 => {80, 80, false}
      }

      assert SocketPeer.classify_pid(83, 81, runner) == {:ok, :independent}
    end

    test "the daemon's own process is not its own descendant" do
      assert SocketPeer.classify_pid(20, 20, @table) == {:ok, :independent}
    end

    test "a peer missing from the process table is an error, never a verdict" do
      assert SocketPeer.classify_pid(77, 20, @table) == {:error, {:peer_not_running, 77}}
    end

    test "a parent chain that never ends stops at the depth cap" do
      looped = %{5 => {6, 5, false}, 6 => {5, 5, false}}

      assert SocketPeer.classify_pid(5, 20, looped) == {:error, :process_tree_too_deep}
    end
  end

  describe "peer_os_pid/2" do
    test "names the process on the other end of a local socket" do
      with_connected_socket(fn accepted ->
        assert SocketPeer.peer_os_pid(accepted) == {:ok, own_os_pid()}
      end)
    end

    # macOS keeps no peer pid once the client hangs up; Linux keeps the one it
    # recorded at connect, so there the answer is still the client.
    test "a socket whose client has hung up names the peer only where the kernel kept it" do
      with_listener(fn listener, path ->
        {:ok, client} = :gen_tcp.connect({:local, to_charlist(path)}, 0, [:binary, active: false])
        {:ok, accepted} = :gen_tcp.accept(listener, 1_000)
        :ok = :gen_tcp.close(client)

        expected =
          case :os.type() do
            {:unix, :darwin} -> {:error, :peer_closed}
            {:unix, :linux} -> {:ok, own_os_pid()}
          end

        assert SocketPeer.peer_os_pid(accepted) == expected
        :gen_tcp.close(accepted)
      end)
    end

    test "refuses a platform it has no peer-credential option for" do
      with_connected_socket(fn accepted ->
        assert SocketPeer.peer_os_pid(accepted, {:win32, :nt}) ==
                 {:error, {:unsupported_os, {:win32, :nt}}}
      end)
    end
  end

  describe "classify/3 against the live process table" do
    test "a client in the daemon's own process is independent" do
      with_connected_socket(fn accepted ->
        assert SocketPeer.classify(accepted, own_os_pid()) == {:ok, :independent}
      end)
    end

    test "a client started by the given daemon process is a daemon descendant" do
      # This VM is a child of whatever launched it, so with that process standing
      # in for the daemon the real kernel peer pid and the real process table
      # must place this client beneath it.
      with_connected_socket(fn accepted ->
        assert SocketPeer.classify(accepted, ParentProcess.os_pid()) ==
                 {:ok, :daemon_descendant}
      end)
    end

    test "refuses a platform it cannot place a client on" do
      with_connected_socket(fn accepted ->
        assert SocketPeer.classify(accepted, own_os_pid(), {:win32, :nt}) ==
                 {:error, {:unsupported_os, {:win32, :nt}}}
      end)
    end

    # `(fermix ask … &)` inside a shell tool's command: the subshell exits at
    # once, so the job is reparented to init and its own parent chain no longer
    # reaches the daemon. It keeps the command's process group, whose leader the
    # daemon (this VM) started.
    test "a client its shell command backgrounded is still a daemon descendant" do
      with_listener(fn listener, path ->
        shell = background_client(path)

        try do
          {:ok, accepted} = :gen_tcp.accept(listener, 30_000)
          assert SocketPeer.classify(accepted, own_os_pid()) == {:ok, :daemon_descendant}
          :gen_tcp.close(accepted)
        after
          Port.close(shell)
        end
      end)
    end

    # A coding harness runs each shell command in a session of its own (Claude
    # Code starts every one with setsid) and does not reap what it backgrounds.
    # So `(fermix ask … &)` there outlives its parent and its group's leader, and
    # has no terminal: nothing the kernel keeps places it beneath the daemon.
    test "a client a finished command left behind in its own session is detached" do
      with_listener(fn listener, path ->
        harness = detached_client(path)

        try do
          {:ok, accepted} = :gen_tcp.accept(listener, 30_000)
          assert_receive {^harness, {:data, "command exited\n"}}, 30_000
          assert SocketPeer.classify(accepted, own_os_pid()) == {:ok, :detached}
          :gen_tcp.close(accepted)
        after
          Port.close(harness)
        end
      end)
    end
  end

  # A real `sh -c` port child, as the shell tool runs one. Its subshell
  # backgrounds a fresh VM of this OTP install, which connects to `path` and
  # exits once the connection closes; the shell waits on its stdin, so closing
  # the port ends it.
  defp background_client(path) do
    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      args: ["-c", ~s|(exec "$0" -noshell -eval "$1" &) ; read _line|, erl(), connect(path)]
    ])
  end

  # A real `sh -c` port child standing in for a coding harness. Its command
  # shell starts in a session of its own (perl's setsid), backgrounds the same
  # client VM and exits at once. The port's shell reports once it has reaped that
  # command, so the test places the client only after its group's leader is
  # gone; then it waits on its stdin.
  defp detached_client(path) do
    command = ~s|(exec "$0" -noshell -eval "$1" &)|

    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      args: [
        "-c",
        ~s|perl -MPOSIX -e 'defined(POSIX::setsid()) or die "setsid: $!"; exec @ARGV' | <>
          ~s|/bin/sh -c '#{command}' "$0" "$1"; echo command exited; read _line|,
        erl(),
        connect(path)
      ]
    ])
  end

  defp erl, do: Path.join([:code.root_dir(), "bin", "erl"])

  defp connect(path) do
    ~s|{ok, S} = gen_tcp:connect({local, "#{path}"}, 0, [binary, {active, false}]), | <>
      ~s|gen_tcp:recv(S, 0), halt().|
  end

  defp with_connected_socket(fun) do
    with_listener(fn listener, path ->
      {:ok, client} = :gen_tcp.connect({:local, to_charlist(path)}, 0, [:binary, active: false])
      {:ok, accepted} = :gen_tcp.accept(listener, 1_000)

      try do
        fun.(accepted)
      after
        Enum.each([accepted, client], &:gen_tcp.close/1)
      end
    end)
  end

  defp with_listener(fun) do
    dir = Path.join(System.tmp_dir!(), "fermix-peer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "p.sock")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, path}])

    try do
      fun.(listener, path)
    after
      :gen_tcp.close(listener)
    end
  end

  defp own_os_pid, do: String.to_integer(System.pid())
end
