defmodule FermixCore.Meetings.Sidecar.PortTest do
  use ExUnit.Case, async: false

  alias FermixCore.Meetings.Sidecar.Port, as: SidecarPort

  @fake Path.expand("fake_meetbot_sidecar.pl", __DIR__)

  # Liveness is polled, never slept for: the fake's exit races the assertion on
  # a loaded machine, and a fixed sleep would either flake or waste seconds.
  @poll_max 40
  @poll_ms 50

  setup do
    tmp =
      Path.join([
        System.tmp_dir!(),
        "fermix-meetbot-port",
        "t-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(tmp)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(tmp) end)

    %{
      profile_dir: Path.join(tmp, "profile"),
      marker: "meetbot-fake-#{System.unique_integer([:positive])}"
    }
  end

  describe "launch/2" do
    test "handshakes with a v1 sidecar and hands back the port state", ctx do
      assert {:ok, state} = launch(ctx)
      assert %{port: port, os_pid: os_pid, owner: owner} = state
      assert is_port(port)
      assert is_integer(os_pid) and os_pid > 0
      assert owner == self()

      assert SidecarPort.stop(state) == :ok
    end

    test "creates the Chromium profile directory 0700 before spawning", ctx do
      assert {:ok, state} = launch(ctx)
      on_exit(fn -> SidecarPort.stop(state) end)

      assert {:ok, %File.Stat{mode: mode, type: :directory}} = File.stat(ctx.profile_dir)
      assert Bitwise.band(mode, 0o777) == 0o700
    end

    test "refuses a protocol mismatch and leaves no sidecar behind", ctx do
      assert {:error, {:protocol_mismatch, %{daemon: 1, sidecar: 2}}} =
               launch(ctx, env: [{~c"FAKE_PROTO", ~c"2"}])

      assert await_gone(ctx.marker) == :gone
    end

    test "gives up on a sidecar that never says hello", ctx do
      started = System.monotonic_time(:millisecond)

      assert {:error, {:handshake_timeout, 300}} =
               launch(ctx,
                 handshake_timeout_ms: 300,
                 env: [{~c"FAKE_SCENARIO", ~c"hang_hello"}]
               )

      assert System.monotonic_time(:millisecond) - started < 3_000
      assert await_gone(ctx.marker) == :gone
    end

    test "fails loud when the binary is absent", ctx do
      assert {:error, {:sidecar_missing, "/no/such/fermix-meetbot"}} =
               SidecarPort.launch(self(),
                 binary_path: "/no/such/fermix-meetbot",
                 profile_dir: ctx.profile_dir
               )
    end
  end

  describe "the join exchange" do
    test "an admitted sidecar streams control frames and audio", ctx do
      assert {:ok, state} = launch(ctx)
      on_exit(fn -> SidecarPort.stop(state) end)

      assert :ok = SidecarPort.send_control(state, %{"type" => "join", "platform" => "meet"})

      assert %{"type" => "state", "phase" => "joining"} = next_control(state)
      assert %{"type" => "join_result", "status" => "admitted"} = next_control(state)
      assert %{"type" => "roster", "participants" => [_, _]} = next_control(state)
      assert %{"type" => "active_speaker"} = next_control(state)
      assert {:sidecar_audio, pcm} = next_message(state)
      assert byte_size(pcm) == 3_200
    end

    test "ping is answered with pong", ctx do
      assert {:ok, state} = launch(ctx)
      on_exit(fn -> SidecarPort.stop(state) end)

      assert :ok = SidecarPort.send_control(state, %{"type" => "ping"})
      assert %{"type" => "pong"} = next_control(state)
    end
  end

  describe "teardown" do
    test "stop/1 kills the sidecar and is safe to repeat", ctx do
      assert {:ok, state} = launch(ctx)
      assert await_present(ctx.marker) == :present

      assert SidecarPort.stop(state) == :ok
      assert await_gone(ctx.marker) == :gone
      assert SidecarPort.stop(state) == :ok
    end

    test "stdin EOF alone ends the sidecar — daemon death removes the bot", ctx do
      assert {:ok, state} = launch(ctx)
      assert await_present(ctx.marker) == :present

      # No signal, only EOF: this is the contract that makes a crashed daemon
      # leave the meeting instead of parking a silent bot in it.
      Port.close(state.port)
      assert await_gone(ctx.marker) == :gone
    end

    test "send_control on a closed port reports :closed rather than raising", ctx do
      assert {:ok, state} = launch(ctx)
      assert SidecarPort.stop(state) == :ok

      assert SidecarPort.send_control(state, %{"type" => "leave"}) == {:error, :closed}
    end
  end

  describe "spawn_plan/4" do
    test "macOS without the disclaim shim refuses instead of spawning bare" do
      assert {:error, {:disclaim_shim_missing, message}} =
               SidecarPort.spawn_plan("/bin/meetbot", [], {:unix, :darwin}, nil)

      assert message ==
               "macOS disclaim shim is not built — rebuild fermix (mix compile) or reinstall"
    end

    test "macOS with the shim execs the sidecar through it" do
      assert SidecarPort.spawn_plan("/bin/meetbot", ["--x"], {:unix, :darwin}, "/priv/disclaim") ==
               {:ok, {"/priv/disclaim", ["/bin/meetbot", "--x"]}}
    end

    test "every other OS spawns the sidecar directly" do
      assert SidecarPort.spawn_plan("/bin/meetbot", ["--x"], {:unix, :linux}, nil) ==
               {:ok, {"/bin/meetbot", ["--x"]}}
    end
  end

  defp launch(ctx, opts \\ []) do
    SidecarPort.launch(
      self(),
      Keyword.merge(
        [binary_path: @fake, profile_dir: ctx.profile_dir, args: [ctx.marker]],
        opts
      )
    )
  end

  defp next_message(state) do
    receive do
      message -> SidecarPort.handle_message(state, message)
    after
      2_000 -> flunk("no frame from the fake sidecar")
    end
  end

  defp next_control(state) do
    assert {:sidecar_control, msg} = next_message(state)
    msg
  end

  defp running?(marker) do
    {_out, status} = System.cmd("pgrep", ["-f", marker], stderr_to_stdout: true)
    status == 0
  end

  defp await_present(marker), do: poll(marker, true, :present, :absent)
  defp await_gone(marker), do: poll(marker, false, :gone, :alive)

  defp poll(marker, want, hit, miss) do
    Enum.reduce_while(1..@poll_max, miss, fn _attempt, acc ->
      if running?(marker) == want do
        {:halt, hit}
      else
        Process.sleep(@poll_ms)
        {:cont, acc}
      end
    end)
  end
end
