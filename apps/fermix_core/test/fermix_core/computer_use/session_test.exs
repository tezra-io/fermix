defmodule FermixCore.ComputerUse.SessionTest do
  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Session

  # A stub Driver: no native code, speaks the Protocol response shape. It records
  # execute/stop calls to the test pid and returns a configurable response.
  defmodule StubDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         response: Keyword.get(opts, :response, %{"ok" => true}),
         # Coexistence (V3 R0): the courtesy arbiter probes `idle_ms` before a
         # disturbing action and may `wait_for_idle`. Default to "human idle 10s"
         # (not active) + "reached idle", so existing disturbing-action tests proceed
         # untouched; courtesy tests override these to exercise defer/yield.
         idle_response: Keyword.get(opts, :idle_response, %{"ok" => true, "idle_ms" => 10_000}),
         wait_for_idle_response:
           Keyword.get(opts, :wait_for_idle_response, %{"ok" => true, "idle" => true}),
         # An optional fake port so handle_info port-matched clauses can be
         # exercised without a real Port/sidecar.
         port: Keyword.get(opts, :port)
       }}
    end

    @impl true
    def execute(%{test_pid: pid} = state, request) do
      send(pid, {:driver_execute, request})
      {:ok, response_for(state, request)}
    end

    @impl true
    def stop(%{test_pid: pid}) do
      send(pid, :driver_stop)
      :ok
    end

    defp response_for(state, %{"action" => "idle_ms"}), do: state.idle_response
    defp response_for(state, %{"action" => "wait_for_idle"}), do: state.wait_for_idle_response
    defp response_for(state, _request), do: state.response
  end

  # A Driver whose action always reports the inner sidecar timeout (the shape
  # FermixCore.Timeouts.expired/3 returns) — exercises the poison-reset path
  # without a 30s wall-clock wait.
  defmodule TimeoutDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def execute(_state, _request), do: {:error, {:timeout, :cu_sidecar_action, 30_000}}

    @impl true
    def stop(%{test_pid: pid}) do
      send(pid, :driver_stop)
      :ok
    end
  end

  defp start_session(opts) do
    config = Keyword.get(opts, :config, Config.normalize(enabled: true))
    driver_opts = [test_pid: self()] ++ Keyword.get(opts, :driver_opts, [])

    start_supervised!(
      {Session,
       [
         config: config,
         driver: {StubDriver, driver_opts},
         origin: Keyword.get(opts, :origin, :interactive),
         session_id: "cua_test",
         agent: "main"
       ]}
    )
  end

  describe "init / host-start gate" do
    test "a host session refuses to start from an unattended origin (fail closed)" do
      # start_link links to us; an init {:stop, _} exits non-normally, so trap the
      # EXIT to observe the {:error, reason} instead of being killed by the link.
      Process.flag(:trap_exit, true)

      assert {:error, {:host_start_refused, :scheduled}} =
               Session.start_link(
                 config: Config.normalize(enabled: true),
                 driver: {StubDriver, [test_pid: self()]},
                 origin: :scheduled
               )

      # the driver is never even started when the origin gate fails
      refute_receive :driver_stop, 50
    end

    test "a host session starts from an attended origin and emits session_start" do
      test_pid = self()
      handler = "cu-start-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:fermix, :computer_use, :session_start],
        fn _e, _m, meta, _ -> send(test_pid, {:started, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      start_session(config: Config.normalize(enabled: true), origin: :voice)

      assert_receive {:started, meta}
      assert meta.session_id == "cua_test"
      assert meta.mode == :host
      assert meta.origin == :voice
    end
  end

  describe "classify/2" do
    test "a read-only action auto-runs and gets a display default but no screenshot_after" do
      session = start_session([])

      assert {:ok, :auto, request} = Session.classify(session, %{"action" => "screenshot"})
      assert request["display"] == 0
      refute Map.has_key?(request, "screenshot_after")
    end

    test "a mutating action auto-runs under standard access and gets screenshot_after from config" do
      session = start_session([])

      assert {:ok, :auto, request} =
               Session.classify(session, %{"action" => "left_click", "x" => 10, "y" => 20})

      assert request["screenshot_after"] == true
    end

    test "a mutating action is refused under strict access (the look-only floor)" do
      session = start_session(config: %{Config.normalize(enabled: true) | access: :strict})

      assert {:error, {:refused, :strict_mode}} =
               Session.classify(session, %{"action" => "left_click", "x" => 10, "y" => 20})

      # read-only still classifies fine in strict
      assert {:ok, :auto, _request} = Session.classify(session, %{"action" => "screenshot"})
    end

    test "an invalid action is rejected (fail loud)" do
      session = start_session([])
      assert {:error, _} = Session.classify(session, %{"action" => "teleport"})
    end

    test "classify refuses once the action budget is exhausted" do
      session = start_session(config: Config.normalize(enabled: true, max_actions: 1))

      # consume the one allowed action
      assert {:ok, :auto, request} = Session.classify(session, %{"action" => "screenshot"})
      assert {:ok, _} = Session.execute(session, request)

      assert {:error, :action_budget_exhausted} =
               Session.classify(session, %{"action" => "screenshot"})
    end
  end

  describe "execute/2" do
    test "a screenshot response becomes an image content part (Phase-0 path)" do
      png = <<137, 80, 78, 71>>

      response = %{
        "ok" => true,
        "data" => Base.encode64(png),
        "mime" => "image/png",
        "width" => 1280,
        "height" => 800,
        "display" => 0
      }

      session = start_session(driver_opts: [response: response])

      assert {:ok, request} = wrap_classify(session, %{"action" => "screenshot"})
      assert {:ok, result} = Session.execute(session, request)

      assert result.image == %{type: :image, mime_type: "image/png", data: png}
      assert result.summary =~ "screenshot 1280x800"
      assert_received {:driver_execute, ^request}
    end

    test "a bare ack response becomes a text summary with no image" do
      session = start_session([])

      assert {:ok, :auto, request} =
               Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:ok, result} = Session.execute(session, request)
      assert %{summary: "ok", image: nil} = result
    end

    test "an inspect response becomes a text summary describing the element (no image)" do
      response = %{
        "ok" => true,
        "found" => true,
        "role" => "AXButton",
        "title" => "Delete",
        "description" => nil,
        "value" => nil
      }

      session = start_session(driver_opts: [response: response])

      assert {:ok, request} = wrap_classify(session, %{"action" => "inspect", "x" => 5, "y" => 6})
      assert {:ok, result} = Session.execute(session, request)

      assert result.image == nil
      assert result.summary =~ "AXButton"
      assert result.summary =~ "Delete"
    end

    test "an inspect miss reports no element" do
      response = %{"ok" => true, "found" => false}
      session = start_session(driver_opts: [response: response])

      assert {:ok, request} = wrap_classify(session, %{"action" => "inspect", "x" => 5, "y" => 6})
      assert {:ok, result} = Session.execute(session, request)
      assert %{summary: "no UI element at that point", image: nil} = result
    end

    test "an elements response becomes a text list of clickable elements (no image)" do
      response = %{
        "ok" => true,
        "elements" => [
          %{"role" => "AXButton", "title" => "Send", "x" => 100, "y" => 200},
          %{"role" => "AXTextField", "title" => nil, "x" => 50, "y" => 60}
        ]
      }

      session = start_session(driver_opts: [response: response])
      assert {:ok, request} = wrap_classify(session, %{"action" => "elements"})
      assert {:ok, result} = Session.execute(session, request)

      assert result.image == nil
      assert result.summary =~ "2 interactive element"
      assert result.summary =~ "AXButton \"Send\" at (100,200)"
      assert result.summary =~ "AXTextField at (50,60)"
    end

    test "an empty elements response reports none found" do
      session = start_session(driver_opts: [response: %{"ok" => true, "elements" => []}])
      assert {:ok, request} = wrap_classify(session, %{"action" => "elements"})
      assert {:ok, result} = Session.execute(session, request)
      assert %{summary: "no interactive UI elements found", image: nil} = result
    end

    test "a malformed elements entry is skipped, never crashed on" do
      response = %{
        "ok" => true,
        "elements" => [
          %{"role" => "AXButton", "title" => "OK", "x" => 1, "y" => 2},
          %{"role" => "AXButton"},
          %{"x" => "nope", "y" => 5}
        ]
      }

      session = start_session(driver_opts: [response: response])
      assert {:ok, request} = wrap_classify(session, %{"action" => "elements"})
      assert {:ok, result} = Session.execute(session, request)

      assert result.summary =~ "AXButton \"OK\" at (1,2)"
      assert result.summary =~ "1 interactive element"
    end

    test "a wait_for_change response returns the new frame with a change note" do
      png = <<137, 80, 78, 71>>

      response = %{
        "ok" => true,
        "data" => Base.encode64(png),
        "mime" => "image/png",
        "width" => 1280,
        "height" => 800,
        "changed" => true
      }

      session = start_session(driver_opts: [response: response])
      assert {:ok, request} = wrap_classify(session, %{"action" => "wait_for_change"})
      assert {:ok, result} = Session.execute(session, request)

      assert result.image == %{type: :image, mime_type: "image/png", data: png}
      assert result.summary =~ "screen changed"
    end

    test "a wait_for_change timeout frame notes no change" do
      png = <<137, 80, 78, 71>>

      response = %{
        "ok" => true,
        "data" => Base.encode64(png),
        "mime" => "image/png",
        "changed" => false
      }

      session = start_session(driver_opts: [response: response])
      assert {:ok, request} = wrap_classify(session, %{"action" => "wait_for_change"})
      assert {:ok, result} = Session.execute(session, request)
      assert result.summary =~ "no change before the wait timed out"
    end

    test "a screenshot cursor position is surfaced in the summary" do
      png = <<137, 80, 78, 71>>

      response = %{
        "ok" => true,
        "data" => Base.encode64(png),
        "mime" => "image/png",
        "width" => 1280,
        "height" => 800,
        "cursor" => %{"x" => 640, "y" => 400}
      }

      session = start_session(driver_opts: [response: response])
      assert {:ok, request} = wrap_classify(session, %{"action" => "screenshot"})
      assert {:ok, result} = Session.execute(session, request)
      assert result.summary =~ "Cursor at (640,400)"
    end

    test "the action count increments per executed action" do
      session = start_session([])
      assert Session.action_count(session) == 0

      {:ok, _, request} = Session.classify(session, %{"action" => "screenshot"})
      {:ok, _} = Session.execute(session, request)
      assert Session.action_count(session) == 1
    end

    test "invalid base64 from the sidecar fails loud" do
      response = %{"ok" => true, "data" => "!!!not-base64!!!", "mime" => "image/png"}
      session = start_session(driver_opts: [response: response])

      {:ok, _, request} = Session.classify(session, %{"action" => "screenshot"})
      assert {:error, msg} = Session.execute(session, request)
      assert msg =~ "invalid base64"
    end
  end

  describe "teardown" do
    test "abort stops the driver (releasing held input) and emits the lifecycle bookend" do
      test_pid = self()
      handler = "cu-stop-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:fermix, :computer_use, :session_complete],
        fn _e, m, meta, _ -> send(test_pid, {:completed, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, session} =
        Session.start_link(
          config: Config.normalize(enabled: true),
          driver: {StubDriver, [test_pid: self()]},
          origin: :interactive,
          session_id: "cua_teardown"
        )

      :ok = Session.abort(session)

      assert_receive :driver_stop
      assert_receive {:completed, %{actions: 0}, %{session_id: "cua_teardown"}}
    end
  end

  describe "sidecar timeout / poison-reset" do
    test "a sidecar-action timeout replies the structured error and stops the session" do
      {session, ref} = start_monitored(TimeoutDriver)

      {:ok, :auto, request} = Session.classify(session, %{"action" => "screenshot"})
      assert {:error, {:timeout, :cu_sidecar_action, 30_000}} = Session.execute(session, request)

      # poisoned Port → session stops so the next action gets a clean driver,
      # and terminate still tears the driver down (releasing held input).
      assert_receive {:DOWN, ^ref, :process, ^session, {:shutdown, :sidecar_timeout}}
      assert_receive :driver_stop
    end
  end

  describe "handle_info" do
    test "drains a stale sidecar response after a prior timeout without crashing" do
      port = make_ref()
      session = start_session(driver_opts: [port: port])

      # the cryptic-incident message: a late {port,{:data,_}} after a timeout
      send(session, {port, {:data, {:eol, "stale"}}})

      # still alive and serving (no crash, no unexpected-message error)
      assert Session.action_count(session) == 0
    end

    test "stops the session when the sidecar exits" do
      port = make_ref()
      {session, ref} = start_monitored(StubDriver, port: port)

      send(session, {port, {:exit_status, 2}})

      assert_receive {:DOWN, ^ref, :process, ^session, {:sidecar_exited, 2}}
    end
  end

  describe "coexistence — courtesy arbiter (V3 R0)" do
    test "proceeds without deferring when the human is idle" do
      # default idle_response = idle 10s → not active → proceed, no wait_for_idle
      session = start_session([])

      {:ok, :auto, request} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:ok, %{courtesy: :proceeded}} = Session.execute(session, request)
      assert_received {:driver_execute, %{"action" => "idle_ms"}}
      assert_received {:driver_execute, %{"action" => "left_click"}}
      refute_received {:driver_execute, %{"action" => "wait_for_idle"}}
    end

    test "defers then proceeds when an active human pauses within the window" do
      session =
        start_session(
          driver_opts: [
            idle_response: %{"ok" => true, "idle_ms" => 200},
            wait_for_idle_response: %{"ok" => true, "idle" => true}
          ]
        )

      {:ok, :auto, request} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:ok, %{courtesy: :deferred}} = Session.execute(session, request)
      assert_received {:driver_execute, %{"action" => "wait_for_idle"}}
      assert_received {:driver_execute, %{"action" => "left_click"}}
    end

    test "yields (refuses the action) when the human stays active" do
      session =
        start_session(
          driver_opts: [
            idle_response: %{"ok" => true, "idle_ms" => 200},
            wait_for_idle_response: %{"ok" => true, "idle" => false}
          ]
        )

      {:ok, :auto, request} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:error, :user_active} = Session.execute(session, request)
      # the action itself never ran — only the idle probe + the wait
      refute_received {:driver_execute, %{"action" => "left_click"}}
    end

    test "a read-only action never triggers the arbiter, even when the human is active" do
      session = start_session(driver_opts: [idle_response: %{"ok" => true, "idle_ms" => 0}])
      {:ok, :auto, request} = Session.classify(session, %{"action" => "screenshot"})

      assert {:ok, %{courtesy: :off}} = Session.execute(session, request)
      refute_received {:driver_execute, %{"action" => "idle_ms"}}
    end

    test "courtesy = :off skips the arbiter entirely" do
      config = Config.normalize(enabled: true, courtesy: "off")

      session =
        start_session(
          config: config,
          driver_opts: [idle_response: %{"ok" => true, "idle_ms" => 0}]
        )

      {:ok, :auto, request} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:ok, %{courtesy: :off}} = Session.execute(session, request)
      refute_received {:driver_execute, %{"action" => "idle_ms"}}
    end

    test "an unavailable idle signal fails OPEN (proceeds), never bricks the action" do
      # a malformed idle reply (no idle_ms) — e.g. the macOS-only probe on Linux
      session = start_session(driver_opts: [idle_response: %{"ok" => true}])

      {:ok, :auto, request} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:ok, %{courtesy: :unavailable}} = Session.execute(session, request)
      assert_received {:driver_execute, %{"action" => "left_click"}}
    end
  end

  describe "coexistence — /pause and /resume" do
    test "pause refuses every action at classify; resume restores it" do
      session = start_session([])
      refute Session.paused?(session)

      :ok = Session.pause(session)
      # cast lands before the next call (same mailbox, serialized)
      assert Session.paused?(session)

      assert {:error, {:refused, :paused}} =
               Session.classify(session, %{"action" => "screenshot"})

      assert {:error, {:refused, :paused}} =
               Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      :ok = Session.resume(session)
      refute Session.paused?(session)
      assert {:ok, :auto, _request} = Session.classify(session, %{"action" => "screenshot"})
    end
  end

  # Start a session via start_link (trapping exits so an abnormal stop is a
  # message, not a test kill) and monitor it, so a {:stop, …} can be observed.
  defp start_monitored(driver_mod, driver_opts \\ []) do
    Process.flag(:trap_exit, true)

    {:ok, session} =
      Session.start_link(
        config: Config.normalize(enabled: true),
        driver: {driver_mod, [test_pid: self()] ++ driver_opts},
        session_id: "cua_mon"
      )

    {session, Process.monitor(session)}
  end

  # classify an action and return just the request (helper for execute tests)
  defp wrap_classify(session, params) do
    case Session.classify(session, params) do
      {:ok, :auto, request} -> {:ok, request}
      other -> other
    end
  end
end
