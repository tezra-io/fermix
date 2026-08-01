defmodule FermixCore.TimeoutsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Timeouts

  describe "expired/3" do
    test "returns the firing-site error shape" do
      assert {:error, {:timeout, :cu_sidecar_action, 30_000}} =
               with_capture_off(fn ->
                 Timeouts.expired(:cu_sidecar_action, 30_000, %{session_id: "cua_1"})
               end)
    end

    test "logs a greppable line carrying the name, ms, and session_id" do
      log =
        capture_log(fn ->
          with_capture_off(fn ->
            Timeouts.expired(:cu_sidecar_action, 30_000, %{session_id: "cua_1"})
          end)
        end)

      assert log =~ "timeout: cu_sidecar_action after 30000ms"
      assert log =~ "session_id=cua_1"
    end

    test "emits a single stable [:fermix, :timeout, :expired] event with name in metadata" do
      attach([:fermix, :timeout, :expired])

      with_capture_off(fn ->
        Timeouts.expired(:cu_session_call, 40_000, %{session_id: "cua_2"})
      end)

      assert_receive {:event, [:fermix, :timeout, :expired], %{ms: 40_000}, meta}
      assert meta.name == :cu_session_call
      assert meta.session_id == "cua_2"
    end

    test "guards reject a bad name or negative ms" do
      assert_raise FunctionClauseError, fn -> Timeouts.expired("not-an-atom", 1, %{}) end
      assert_raise FunctionClauseError, fn -> Timeouts.expired(:x, -1, %{}) end
    end
  end

  describe "computer-use cushion invariant" do
    test "the outer Session call outlives the inner sidecar receive by a real cushion" do
      # Not a bare `>`: a 1ms gap lets the GenServer.call exit before the inner
      # receive reports, re-creating the desync the incident exposed.
      assert Timeouts.cu_session_call() >=
               Timeouts.cu_sidecar_action() + Timeouts.cu_call_cushion()
    end
  end

  describe "coding-harness tiered stall watchdog invariant" do
    test "first_event < inactivity < wall_clock at the config defaults" do
      # Establish the default `[fermix_core.harness]` baseline in the test itself
      # (the inactivity/wall-clock delegators read global app env; a leaked
      # override must not decide the assertion — hermetic-config rule).
      with_harness_defaults(fn ->
        assert Timeouts.harness_first_event() == 120_000
        assert Timeouts.harness_first_event() < Timeouts.harness_inactivity()
        assert Timeouts.harness_inactivity() < Timeouts.harness_wall_clock()
      end)
    end

    test "the config delegators track [fermix_core.harness] at call time" do
      prior = Application.get_env(:fermix_core, :harness)

      Application.put_env(:fermix_core, :harness,
        inactivity_minutes: 3,
        default_timeout_minutes: 7
      )

      on_exit(fn -> restore_harness(prior) end)

      assert Timeouts.harness_inactivity() == 3 * 60_000
      assert Timeouts.harness_wall_clock() == 7 * 60_000
    end
  end

  describe "ACP bridge handshake deadline" do
    test "is one named value both ends of the handshake read" do
      # The daemon's `Channels.Acp.Peer` refuses a connection that has not sent
      # its hello line in time; `Fermix.CLI.AcpCommand` gives up waiting for the
      # ack. Two ends, one deadline — a local constant on either side would drift.
      assert Timeouts.acp_bridge_hello() == 5_000
    end
  end

  describe "ctx gating (FermixCore.Timeouts.Telemetry)" do
    test "correlation ids ride always-on; context is omitted when capture is off" do
      attach([:fermix, :timeout, :expired])

      with_capture_off(fn ->
        Timeouts.expired(:cu_sidecar_action, 30_000, %{session_id: "s", parent_session: "p"})
      end)

      assert_receive {:event, _e, _m, meta}
      assert meta.session_id == "s"
      assert meta.parent_session == "p"
      refute Map.has_key?(meta, :context)
    end

    test "context is attached (and redacted) when capture is on" do
      attach([:fermix, :timeout, :expired])

      with_capture_on(fn ->
        Timeouts.expired(:cu_sidecar_action, 30_000, %{session_id: "s", note: "hi"})
      end)

      assert_receive {:event, _e, _m, meta}
      assert meta.session_id == "s"
      assert Map.has_key?(meta, :context)
    end
  end

  defp attach(event) do
    test_pid = self()
    handler = "timeouts-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      event,
      fn e, m, meta, _ -> send(test_pid, {:event, e, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # The capture-content flag is global app env; establish the precondition in the
  # test itself rather than depending on a clean global (hermetic-config rule).
  defp with_capture_off(fun), do: with_capture(false, fun)
  defp with_capture_on(fun), do: with_capture(true, fun)

  defp with_capture(value, fun) do
    prior = Application.get_env(:fermix_core, :telemetry, [])
    Application.put_env(:fermix_core, :telemetry, Keyword.put(prior, :capture_content, value))
    on_exit(fn -> Application.put_env(:fermix_core, :telemetry, prior) end)
    fun.()
  end

  defp with_harness_defaults(fun) do
    prior = Application.get_env(:fermix_core, :harness)
    Application.put_env(:fermix_core, :harness, [])
    on_exit(fn -> restore_harness(prior) end)
    fun.()
  end

  defp restore_harness(nil), do: Application.delete_env(:fermix_core, :harness)
  defp restore_harness(value), do: Application.put_env(:fermix_core, :harness, value)
end
