defmodule FermixCore.TimeoutsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Timeouts
  alias FermixCore.Transcription.Outbox

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

  describe "remote MCP startup invariant" do
    test "the startup window can contain one full connect + initialize + discover" do
      # Not a bare `>`: if the outer window were tighter than its three inner
      # phases, startup would report a generic window expiry and hide which
      # phase actually stalled — the inner deadline must be the one that fires.
      assert Timeouts.mcp_remote_startup() >
               Timeouts.mcp_remote_connect() + Timeouts.mcp_remote_initialize() +
                 Timeouts.mcp_remote_discover()
    end

    test "every remote deadline is a fixed constant, not operator-tunable" do
      # A remote endpoint is a signed-manifest contract. Config-driven values
      # would let an operator hold a hostile server's connection open past what
      # the signature was reviewed against.
      prior = Application.get_env(:fermix_core, :mcp_remote)
      Application.put_env(:fermix_core, :mcp_remote, call_ms: 1, startup_ms: 1)
      on_exit(fn -> restore_env(:mcp_remote, prior) end)

      assert Timeouts.mcp_remote_startup() == 60_000
      assert Timeouts.mcp_remote_connect() == 10_000
      assert Timeouts.mcp_remote_initialize() == 15_000
      assert Timeouts.mcp_remote_discover() == 15_000
      assert Timeouts.mcp_remote_call() == 60_000
      assert Timeouts.mcp_remote_teardown() == 10_000
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

  describe "transcription streaming deadlines" do
    test "the WS connect and close-drain budgets are named constants" do
      assert Timeouts.transcription_ws_connect() == 10_000
      assert Timeouts.transcription_ws_close_drain() == 10_000
    end

    test "the send-stall budget recovers a wedged socket inside the outbox buffer" do
      # The deadline bounds a full in-flight window: audio cast to the socket
      # process and never acknowledged. What arrives during the stall has to fit
      # in the 30 s buffer alongside the window itself, or the recovery this
      # deadline exists to trigger would drop audio on its way in.
      assert Timeouts.transcription_ws_send_stall() == 10_000

      stalled_bytes = div(Timeouts.transcription_ws_send_stall(), 1_000) * 32_000
      assert stalled_bytes + Outbox.inflight_max_bytes() < Outbox.buffer_max_bytes()
    end

    test "the local STT sidecar deadlines bound spawn, one batch, and the flush" do
      # hello precedes model load, so it bounds process start only; a batch is a
      # whole-file recognition and needs minutes of headroom.
      assert Timeouts.stt_sidecar_hello() == 10_000
      assert Timeouts.stt_sidecar_batch() == 300_000
      assert Timeouts.stt_sidecar_flush() == 30_000
      assert Timeouts.stt_sidecar_hello() < Timeouts.stt_sidecar_flush()
      assert Timeouts.stt_sidecar_flush() < Timeouts.stt_sidecar_batch()
    end
  end

  describe "meetings deadlines" do
    test "handshake, join, and summarize escalate in that order" do
      # Join contains a human step (the host admitting the bot), and summarize
      # contains the transcript drain plus a map-reduce over the whole meeting —
      # so each stage is strictly longer than the one before it.
      assert Timeouts.meetbot_handshake() == 15_000
      assert Timeouts.meetbot_join() == 90_000
      assert Timeouts.meeting_summarize() == 600_000
      assert Timeouts.meetbot_handshake() < Timeouts.meetbot_join()
      assert Timeouts.meetbot_join() < Timeouts.meeting_summarize()
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

  defp restore_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_env(key, value), do: Application.put_env(:fermix_core, key, value)
end
