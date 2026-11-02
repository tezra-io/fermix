defmodule FermixCore.Home.MoveAwakeTest do
  # The platform, the BEAM's pid, the spawner and the group kill are seams:
  # no case starts caffeinate or systemd-inhibit, which would hold the test
  # host awake. The fake inhibitor's port is a reference the case speaks for.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Home.MoveAwake

  @why "Fermix is moving to your server"

  describe "plan/2" do
    test "on a Mac: caffeinate through the disclaim shim, watching the BEAM's own pid" do
      paths = [disclaim: "/opt/fermix/priv/disclaim", caffeinate: "/usr/bin/caffeinate"]

      assert MoveAwake.plan({:unix, :darwin}, [os_pid: "4711"] ++ paths) ==
               {:ok, {"/opt/fermix/priv/disclaim", ["/usr/bin/caffeinate", "-i", "-w", "4711"]}}
    end

    test "on a Mac with no shim, or no caffeinate, nothing is spawned undisclaimed" do
      assert {:error, {:disclaim_shim_missing, _sentence}} =
               MoveAwake.plan({:unix, :darwin}, os_pid: "4711", disclaim: nil)

      assert MoveAwake.plan({:unix, :darwin},
               os_pid: "4711",
               disclaim: "/opt/fermix/priv/disclaim",
               caffeinate: nil
             ) == {:error, {:not_found, "caffeinate"}}
    end

    test "on Linux: systemd-inhibit holding a tail that ends with the BEAM" do
      found = fn
        "systemd-inhibit" -> "/usr/bin/systemd-inhibit"
        "tail" -> "/usr/bin/tail"
      end

      assert MoveAwake.plan({:unix, :linux}, os_pid: "4711", find_executable: found) ==
               {:ok,
                {"/usr/bin/systemd-inhibit",
                 [
                   "--what=sleep:idle",
                   "--who=Fermix",
                   "--why=#{@why}",
                   "--mode=block",
                   "/usr/bin/tail",
                   "--pid=4711",
                   "-f",
                   "/dev/null"
                 ]}}

      # A move back names its own reason.
      assert {:ok, {_inhibit, args}} =
               MoveAwake.plan({:unix, :linux},
                 os_pid: "4711",
                 find_executable: found,
                 why: "Fermix is moving back to this computer"
               )

      assert "--why=Fermix is moving back to this computer" in args

      missing = fn
        "systemd-inhibit" -> nil
        "tail" -> "/usr/bin/tail"
      end

      assert MoveAwake.plan({:unix, :linux}, os_pid: "4711", find_executable: missing) ==
               {:error, {:not_found, "systemd-inhibit"}}
    end

    test "elsewhere there is nothing to hold" do
      assert MoveAwake.plan({:win32, :nt}, os_pid: "4711") == {:error, {:unsupported, :nt}}
    end
  end

  describe "hold/1 and release/1" do
    test "holds from the start until released, then ends the inhibitor's group" do
      assert {:ok, holder} = MoveAwake.hold(seams())
      assert_received {:spawned, "/usr/bin/systemd-inhibit", ["--what=sleep:idle" | _rest]}
      refute_received {:killed, _pid}

      assert :ok = MoveAwake.release(holder)
      assert_received {:killed, 4242}
      refute Process.alive?(holder)
    end

    # The owner is the process that took the hold, here a move worker; however
    # it ends, a crash or a kill included, the inhibitor goes with it.
    test "an owner that dies, killed or crashed, takes the inhibitor with it" do
      test = self()

      owner =
        spawn(fn ->
          {:ok, _holder} = MoveAwake.hold(seams(test))
          send(test, :holding)
          receive do: (:never_sent -> :ok)
        end)

      assert_receive :holding
      Process.exit(owner, :kill)
      assert_receive {:killed, 4242}
    end

    test "an inhibitor that ends by itself is logged with its words, and the hold ends" do
      test = self()
      port = make_ref()
      seams = Keyword.put(seams(test), :spawn, fn _exe, _args -> {:ok, inhibitor(port)} end)
      {:ok, holder} = MoveAwake.hold(seams)
      ref = Process.monitor(holder)

      log =
        capture_log(fn ->
          send(holder, {port, {:data, "Failed to inhibit: Access denied\n"}})
          send(holder, {port, {:exit_status, 1}})
          assert_receive {:DOWN, ^ref, :process, ^holder, :normal}
        end)

      assert log =~ "the sleep guard ended by itself (exit 1)"
      assert log =~ "Access denied"
      assert :ok = MoveAwake.release(holder)
    end

    test "a spawn that fails holds nothing, and says why" do
      seams = Keyword.put(seams(), :spawn, fn exe, _args -> {:error, {:spawn_failed, exe}} end)
      assert MoveAwake.hold(seams) == {:error, {:spawn_failed, "/usr/bin/systemd-inhibit"}}

      plan_fails = Keyword.put(seams(), :find_executable, fn _name -> nil end)
      assert MoveAwake.hold(plan_fails) == {:error, {:not_found, "systemd-inhibit"}}
      refute_received {:spawned, _exe, _args}
    end

    # Bounded: at most a day and two hours, past the longest a move waits.
    test "it lets go at its bound and says so" do
      {:ok, holder} = MoveAwake.hold(seams())
      ref = Process.monitor(holder)

      log =
        capture_log(fn ->
          send(holder, :expired)
          assert_receive {:DOWN, ^ref, :process, ^holder, :normal}
        end)

      assert_received {:killed, 4242}
      assert log =~ "26 hours"
      assert MoveAwake.max_hold_ms() == 26 * 3_600_000
    end

    test "release/1 of nothing held is nothing to do" do
      assert MoveAwake.release(nil) == :ok
    end
  end

  test "describe/1 says why the computer may sleep, in the owner's words" do
    assert MoveAwake.describe({:not_found, "systemd-inhibit"}) ==
             "systemd-inhibit is not installed"

    assert MoveAwake.describe({:unsupported, :nt}) == "this system has no sleep guard Fermix uses"
  end

  defp seams(test \\ self()) do
    [
      os_type: {:unix, :linux},
      os_pid: "4711",
      find_executable: fn name -> "/usr/bin/#{name}" end,
      spawn: fn exe, args ->
        send(test, {:spawned, exe, args})
        {:ok, inhibitor(make_ref())}
      end,
      kill: fn os_pid -> send(test, {:killed, os_pid}) && :ok end
    ]
  end

  defp inhibitor(port), do: %{port: port, os_pid: 4242}
end
