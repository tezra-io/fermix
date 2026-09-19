defmodule FermixCore.ComputerUse.SessionTest do
  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.InputOwner
  alias FermixCore.ComputerUse.Session
  alias FermixTestSupport.ComputerUseReceipts

  # A stub Driver: no native code, speaks the Protocol response shape. It records
  # execute/stop calls to the test pid and returns a configurable response. Every
  # reply to a MUTATING action carries the wire's `receipt` (M42 slice 2 §3), as a
  # real sidecar's does: the session derives its `outcome` from the receipt's
  # dispatch and refuses to infer one, so a double without it would be describing
  # a sidecar that cannot exist.
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
         # The acknowledgement this double gives a control, so a Session that
         # pauses gets the same shape the wire returns. `nil` in_flight means the
         # helper had nothing under way when the barrier installed.
         ack: Keyword.get(opts, :ack, %{ok: true, in_flight_request_id: nil})
       }}
    end

    @impl true
    def control(%{test_pid: pid, ack: ack}, action) do
      send(pid, {:driver_control, action})

      case ack do
        :unconfirmed ->
          {:error, :control_unconfirmed}

        # A helper wedged inside its own control reader: the call does not return
        # within any budget a caller cares about. Bounded so a test can never hang,
        # but far longer than a teardown is allowed to wait on it.
        :never_answers ->
          Process.sleep(30_000)
          {:error, :control_unconfirmed}

        ack ->
          {:ok, Map.put(ack, :action, action)}
      end
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

    defp response_for(state, request),
      do: FermixTestSupport.ComputerUseReceipts.stamp(state.response, request)
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

  # A Driver whose reply is chosen PER ACTION, so a post-action check can fail while
  # the action before it succeeded — the shape every truthful-receipt path needs.
  # Anything unscripted answers a bare ack, which keeps the session's one-time
  # input-control probe and the courtesy arbiter out of each test's way.
  defmodule ScriptedDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         replies: Keyword.get(opts, :replies, %{})
       }}
    end

    @impl true
    def execute(%{test_pid: pid, replies: replies}, %{"action" => action} = request) do
      send(pid, {:driver_execute, request})

      case Map.fetch(replies, action) do
        {:ok, scripted} -> scripted
        :error -> {:ok, FermixTestSupport.ComputerUseReceipts.stamp(%{"ok" => true}, request)}
      end
    end

    @impl true
    def stop(%{test_pid: pid}) do
      send(pid, :driver_stop)
      :ok
    end
  end

  # A Driver whose action call BLOCKS until the test releases it, so the window
  # "an action is inside the driver" can be held open and the session probed while
  # it is. The one-time probe and the courtesy arbiter answer immediately, so only
  # the model's own action blocks. Its control answers from a SEPARATE call, as
  # the real wire does — the helper's control reader is not its action worker — so
  # `control:` steers what that answer is while an action is genuinely under way.
  defmodule BlockingDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         control: Keyword.get(opts, :control, %{ok: true, in_flight_request_id: nil})
       }}
    end

    @impl true
    def execute(_state, %{"action" => "probe"}), do: {:ok, %{"input_control" => true}}

    def execute(_state, %{"action" => "idle_ms"}),
      do: {:ok, %{"ok" => true, "idle_ms" => 10_000}}

    def execute(%{test_pid: pid}, request) do
      send(pid, {:driver_blocked, request, self()})

      receive do
        {:driver_release, response} -> {:ok, response}
      after
        5_000 -> {:error, :test_driver_never_released}
      end
    end

    @impl true
    def control(%{control: :unconfirmed}, _action), do: {:error, :control_unconfirmed}
    def control(%{control: ack}, action), do: {:ok, Map.put(ack, :action, action)}

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

    test "an empty elements response preserves pixel interaction guidance" do
      session = start_session(driver_opts: [response: %{"ok" => true, "elements" => []}])
      assert {:ok, request} = wrap_classify(session, %{"action" => "elements"})
      assert {:ok, result} = Session.execute(session, request)

      assert result.image == nil
      assert result.summary =~ "accessibility-backed"
      assert result.summary =~ "pixel coordinates"
      refute result.summary =~ "non-interactive"
    end

    # Empty `elements` is exactly the moment a board/canvas is reached, and the
    # managed browser has an EXACT route there (`get field=rect` + `click_coords`)
    # that pixels only approximate. Steering to pixels alone here contradicts the
    # tool description's own AIMING paragraph at the one moment it matters.
    test "the empty-elements guidance names the exact browser route before pixels" do
      session = start_session(driver_opts: [response: %{"ok" => true, "elements" => []}])
      assert {:ok, request} = wrap_classify(session, %{"action" => "elements"})
      assert {:ok, result} = Session.execute(session, request)

      assert result.summary =~ "get field=rect"
      assert result.summary =~ "click_coords"
      # ...and pixels remain the answer for every other surface.
      assert result.summary =~ "pixel coordinates"
    end

    test "a malformed-only elements response uses the empty-result guidance" do
      response = %{
        "ok" => true,
        "elements" => [%{"role" => "AXButton"}, %{"x" => "nope", "y" => 5}]
      }

      session = start_session(driver_opts: [response: response])
      assert {:ok, request} = wrap_classify(session, %{"action" => "elements"})
      assert {:ok, result} = Session.execute(session, request)

      assert result.image == nil
      assert result.summary =~ "accessibility-backed"
      assert result.summary =~ "pixel coordinates"
      refute result.summary =~ "0 interactive element"
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

  # The sidecar's death is reported to the `ActionWorker` — the driver's owner —
  # and the session reads its reason. The stale-frame drain that used to live here
  # is gone with the wire that needed it: a reply now reaches the request that
  # asked for it by id, so a late frame can never answer a different one.
  describe "the sidecar ending" do
    test "an exit status the sidecar chose for itself stops the session, classified here" do
      {session, ref} = start_monitored(StubDriver)

      send(worker(session), {:compux_sidecar_exit, self(), 2})

      assert_receive {:DOWN, ^ref, :process, ^session, {:sidecar_exited, 2}}
    end

    # 75 is compux's designed capture-stall self-reap: a clean, retryable reset
    # that feeds the capture breaker, never a crash.
    test "the capture-stall status stays a clean completion" do
      {session, ref} = start_monitored(StubDriver)

      send(worker(session), {:compux_sidecar_exit, self(), 75})

      assert_receive {:DOWN, ^ref, :process, ^session, {:shutdown, {:sidecar_exited, 75}}}
    end

    # A transport that killed the sidecar over an unusable wire is a FAULT. Its
    # payload is a term, never a number, so it can never be read as a status the
    # sidecar chose — and 75 in particular can never be forged from one.
    test "a poisoned wire is a fault reason, never a status the sidecar chose" do
      {session, ref} = start_monitored(StubDriver)

      send(
        worker(session),
        {:compux_sidecar_exit, self(), {:poisoned, :sidecar_response_too_large}}
      )

      assert_receive {:DOWN, ^ref, :process, ^session,
                      {:shutdown, {:sidecar_poisoned, :sidecar_response_too_large}}}
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

      # The verdict is the helper's acknowledgement of the barrier, not the fact
      # that a control was sent.
      assert :paused = Session.pause(session)
      assert Session.paused?(session)
      assert_received {:driver_control, :pause}

      assert {:error, {:refused, :paused}} =
               Session.classify(session, %{"action" => "screenshot"})

      assert {:error, {:refused, :paused}} =
               Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert :resumed = Session.resume(session)
      refute Session.paused?(session)
      assert_received {:driver_control, :resume}
      assert {:ok, :auto, _request} = Session.classify(session, %{"action" => "screenshot"})
    end

    # The race `/pause` exists to close: a turn classifies, the human pauses, and the
    # already-classified request is executed anyway. Classify's check alone cannot
    # see a pause that lands after it returned, so execute re-checks — the refusal
    # must happen with NO driver call, not even the courtesy probe.
    test "a pause landing between classify and execute refuses the action, untouched" do
      session = start_session([])

      {:ok, :auto, request} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert :paused = Session.pause(session)
      assert Session.paused?(session)

      assert {:error, {:refused, :paused}} = Session.execute(session, request)

      refute_received {:driver_execute, %{"action" => "left_click"}}
      refute_received {:driver_execute, %{"action" => "idle_ms"}}
      # The refused action never counted against the budget either.
      assert Session.action_count(session) == 0
    end

    test "pause and resume emit their lifecycle events, once per state change" do
      test_pid = self()
      handler = "cu-pause-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [
          [:fermix, :computer_use, :session_pause],
          [:fermix, :computer_use, :session_resume]
        ],
        fn event, _m, meta, _ -> send(test_pid, {:lifecycle, List.last(event), meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      session = start_session([])

      assert :paused = Session.pause(session)
      assert Session.paused?(session)
      assert_receive {:lifecycle, :session_pause, %{session_id: "cua_test", mode: :host}}

      # A repeated pause is not a second event — a trace showing two pauses and one
      # resume would read as a session that is still held when it is running. The
      # control IS re-sent: re-confirming a barrier costs nothing and can still
      # report an action that started in between.
      assert :paused = Session.pause(session)
      assert Session.paused?(session)
      refute_receive {:lifecycle, :session_pause, %{session_id: "cua_test"}}, 50

      assert :resumed = Session.resume(session)
      refute Session.paused?(session)
      assert_receive {:lifecycle, :session_resume, %{session_id: "cua_test"}}

      assert :resumed = Session.resume(session)
      refute Session.paused?(session)
      refute_receive {:lifecycle, :session_resume, %{session_id: "cua_test"}}, 50
    end

    # The ack names the request the helper had already begun. That is the same
    # fact the Registry in-flight flag used to carry, from the side that knows it.
    test "an ack naming an action under way reports it, so /pause can say so" do
      session = start_session(driver_opts: [ack: %{ok: true, in_flight_request_id: "r7"}])

      assert :paused_in_flight = Session.pause(session)
      assert Session.paused?(session)
    end

    # No acknowledgement means no proof the barrier installed. Claiming a pause
    # would hand back a machine that may still be driven, so the helper is ended,
    # which definitively returns it — and the session says so rather than "paused".
    test "a pause the helper never acknowledged is unconfirmed, and resets the session" do
      Process.flag(:trap_exit, true)

      {:ok, session} =
        Session.start_link(
          config: Config.normalize(enabled: true),
          driver: {StubDriver, [test_pid: self(), ack: :unconfirmed]},
          session_id: "cua_unconfirmed"
        )

      ref = Process.monitor(session)

      assert :unconfirmed = Session.pause(session)
      assert_receive {:DOWN, ^ref, :process, ^session, {:shutdown, :control_unconfirmed}}
      assert_receive :driver_stop
    end

    # Held input is released BEFORE the helper is killed, because a SIGKILL runs
    # none of the helper's own release guards — this is the only thing that
    # un-presses a key it is holding.
    test "teardown releases held input before it ends the helper" do
      session = start_session([])

      :ok = Session.abort(session)

      assert_received {:driver_control, :release}
      assert_receive :driver_stop
    end
  end

  # M42 slice 2 §6: one execute makes up to FOUR blocking driver calls, each with a
  # 30 s budget. While the Session owned the driver it sat inside them, so `/pause`,
  # `paused?` and teardown queued behind the very action they exist to interrupt.
  # The driver now lives in an `ActionWorker` and the Session answers its caller
  # from `handle_info`, so the control surface is live for the whole action.
  describe "a Session that stays responsive" do
    defp start_blocking do
      Process.flag(:trap_exit, true)

      {:ok, session} =
        Session.start_link(
          config: Config.normalize(enabled: true),
          driver: {BlockingDriver, [test_pid: self()]},
          session_id: "cua_busy"
        )

      {session, Process.monitor(session)}
    end

    # The request is classified here rather than in the spawned caller so the test
    # controls exactly when the execute lands.
    defp execute_async(session, params) do
      {:ok, :auto, request} = Session.classify(session, params)
      Task.async(fn -> Session.execute(session, request) end)
    end

    defp await_blocked do
      assert_receive {:driver_blocked, request, worker}
      {request, worker}
    end

    test "pause, paused? and action_count are answered while an action is inside the driver" do
      {session, _ref} = start_blocking()
      caller = execute_async(session, %{"action" => "left_click", "x" => 1, "y" => 2})
      {_request, worker} = await_blocked()

      # Every one of these is a call or a cast that had to queue behind a 30 s
      # driver receive before the split.
      refute Session.paused?(session)
      assert Session.action_count(session) == 0
      # …including the control itself, which reaches the helper's control reader
      # rather than queueing behind the action it is pausing.
      assert :paused = Session.pause(session)
      assert Session.paused?(session)

      send(worker, {:driver_release, %{"ok" => true, "receipt" => sent_receipt()}})
      assert {:ok, %{outcome: :performed}} = Task.await(caller)

      # The Session keeps ITS OWN pause across the hand-off: the worker's state
      # snapshot is a moment older than the session's, and applying it wholesale
      # would silently un-pause the machine the human just took back.
      assert Session.paused?(session)
      assert Session.action_count(session) == 1
    end

    test "a second execute while one is in flight is refused as busy, not queued" do
      {session, _ref} = start_blocking()
      caller = execute_async(session, %{"action" => "left_click", "x" => 1, "y" => 2})
      {_request, worker} = await_blocked()

      {:ok, :auto, second} = Session.classify(session, %{"action" => "screenshot"})
      assert {:error, :busy} = Session.execute(session, second)

      send(worker, {:driver_release, %{"ok" => true, "receipt" => sent_receipt()}})
      assert {:ok, _result} = Task.await(caller)

      # …and the seat frees the moment the first one is answered.
      retry = Task.async(fn -> Session.execute(session, second) end)
      {_request, worker} = await_blocked()
      send(worker, {:driver_release, %{"ok" => true}})

      assert {:ok, %{outcome: :read}} = Task.await(retry)
    end

    # A caller always gets its receipt before the session dies, on every one of the
    # five reply-then-stop sites — and the worker dying under the action is a sixth
    # way the answer can go missing.
    test "a worker that dies mid-action answers its caller, then stops the session" do
      {session, ref} = start_blocking()
      caller = execute_async(session, %{"action" => "left_click", "x" => 1, "y" => 2})
      {_request, worker} = await_blocked()

      Process.exit(worker, :kill)

      assert {:error, {:helper_fault, :killed}} = Task.await(caller)
      assert_receive {:DOWN, ^ref, :process, ^session, :killed}
    end

    # THE headline path of this slice, and the one place a caller can be orphaned:
    # `/pause` ends a session that has an action inside the helper. The caller is
    # blocked in `Session.execute/2`, whose catch covers only its OWN deadline — so
    # a session that dies without answering does not time that caller out, it kills
    # it, and the model's tool call then records nothing at all.
    test "an unconfirmed pause answers the action it interrupts before the session dies" do
      Process.flag(:trap_exit, true)

      {:ok, session} =
        Session.start_link(
          config: Config.normalize(enabled: true),
          driver: {BlockingDriver, [test_pid: self(), control: :unconfirmed]},
          session_id: "cua_pause_pending"
        )

      ref = Process.monitor(session)
      caller = execute_async(session, %{"action" => "left_click", "x" => 1, "y" => 2})
      {_request, worker} = await_blocked()

      assert :unconfirmed = Session.pause(session)

      assert {:error, {:helper_fault, :control_unconfirmed}} = Task.await(caller)
      assert_receive {:DOWN, ^ref, :process, ^session, {:shutdown, :control_unconfirmed}}

      send(worker, {:driver_release, %{"ok" => true}})
    end

    # Every other way a session can stop with an action pending — a conversation
    # ending mid-action is the one a supervisor produces.
    test "a shutdown mid-action answers the caller rather than killing it" do
      Process.flag(:trap_exit, true)

      {:ok, session} =
        Session.start_link(
          config: Config.normalize(enabled: true),
          driver: {BlockingDriver, [test_pid: self()]},
          session_id: "cua_shutdown_pending"
        )

      caller = execute_async(session, %{"action" => "left_click", "x" => 1, "y" => 2})
      {_request, worker} = await_blocked()

      Process.exit(session, :shutdown)

      assert {:error, {:helper_fault, :shutdown}} = Task.await(caller)
      send(worker, {:driver_release, %{"ok" => true}})
    end

    # The lifecycle row is the only record a dead session leaves. Teardown does two
    # best-effort things that can each wait on a wedged helper, so the row is
    # written BEFORE them — and the whole teardown stays well inside the child
    # spec's shutdown, or the supervisor brutal-kills the session and the row with it.
    test "the lifecycle row survives a helper that never answers the release" do
      test_pid = self()
      handler = "cu-teardown-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:fermix, :computer_use, :session_complete],
        fn _e, _m, meta, _ -> send(test_pid, {:completed, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, session} =
        Session.start_link(
          config: Config.normalize(enabled: true),
          driver: {StubDriver, [test_pid: self(), ack: :never_answers]},
          session_id: "cua_slow_release"
        )

      started = System.monotonic_time(:millisecond)
      :ok = Session.abort(session)
      elapsed = System.monotonic_time(:millisecond) - started

      assert_receive {:completed, %{session_id: "cua_slow_release"}}
      assert elapsed < 5_000, "teardown took #{elapsed} ms; it must finish inside its budget"
    end

    # The budget the child spec promises its supervisor has to exceed what teardown
    # can actually spend, or the guarantee above is a hope rather than a bound.
    test "the child spec's shutdown budget exceeds the worst-case teardown" do
      assert %{shutdown: shutdown} = Session.child_spec([])
      assert is_integer(shutdown) and shutdown >= 5_000
    end

    # The session's teardown guarantee now spans two processes: whatever kills the
    # Session, the worker must still release the sidecar.
    test "a Session killed outright still leaves no sidecar behind" do
      {session, _ref} = start_blocking()
      Process.exit(session, :kill)

      assert_receive :driver_stop
    end
  end

  # M42 slice 2 §6: one cursor, one keyboard, one focused window. Two conversations
  # driving them at once is not concurrency — each moves the pointer the other just
  # aimed and reads a screen the other is changing.
  describe "the native input seat" do
    setup do
      start_supervised!(InputOwner)
      :ok
    end

    test "a disturbing action is refused while another conversation holds the seat" do
      session = start_session([])
      assert :ok = InputOwner.acquire(spawn_holder())

      {:ok, :auto, click} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:error, {:refused, :input_busy}} = Session.execute(session, click)

      # Nothing reached the driver — not the action, and not the courtesy probe
      # that precedes it — and the refusal did not spend the action budget.
      refute_received {:driver_execute, %{"action" => "left_click"}}
      refute_received {:driver_execute, %{"action" => "idle_ms"}}
      assert Session.action_count(session) == 0
    end

    # Two conversations may LOOK at the same screen all they like; only input is
    # exclusive.
    test "a read-only action never needs the seat" do
      session = start_session([])
      assert :ok = InputOwner.acquire(spawn_holder())

      {:ok, :auto, request} = Session.classify(session, %{"action" => "screenshot"})

      assert {:ok, %{outcome: :read}} = Session.execute(session, request)
    end

    test "the session that holds the seat keeps acting on it" do
      session = start_session([])

      {:ok, :auto, click} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:ok, %{outcome: :performed}} = Session.execute(session, click)
      assert {:ok, %{outcome: :performed}} = Session.execute(session, click)
    end

    defp spawn_holder do
      pid = spawn(fn -> receive do: (:done -> :ok) end)
      on_exit(fn -> send(pid, :done) end)
      pid
    end
  end

  # M42 slice 1 §4: a receipt says what is known. A check that never came back is not
  # a failed action, and a helper that died is not a session that may keep running.
  # A timeout on any driver call resets the session for the same reason it always
  # did — a helper that stopped answering is not one to hand real input to next —
  # though no longer because a late frame could answer the following request: the
  # wire correlates a reply to the request that asked for it.
  describe "truthful receipts" do
    @region %{"x" => 0, "y" => 0, "w" => 600, "h" => 380}

    defp start_scripted(replies) do
      Process.flag(:trap_exit, true)

      {:ok, session} =
        Session.start_link(
          config: Config.normalize(enabled: true),
          driver: {ScriptedDriver, [test_pid: self(), replies: replies]},
          session_id: "cua_receipts"
        )

      {session, Process.monitor(session)}
    end

    defp click_in_region(session) do
      {:ok, :auto, click} =
        Session.classify(session, %{
          "action" => "left_click",
          "x" => 40,
          "y" => 30,
          "region" => @region
        })

      Session.execute(session, click)
    end

    test "a read reports the read outcome" do
      session = start_session([])
      {:ok, :auto, request} = Session.classify(session, %{"action" => "screenshot"})

      assert {:ok, %{outcome: :read}} = Session.execute(session, request)
    end

    test "a mutating action whose check came back reports performed" do
      session = start_session([])

      {:ok, :auto, request} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:ok, %{outcome: :performed}} = Session.execute(session, request)
    end

    # The swallowed timeout: the check turned `{:timeout, …}` into a string, so the
    # reset never fired and the session carried on against a helper that had stopped
    # answering.
    test "a check timeout says the action was performed, unverified, then resets the session" do
      {session, ref} =
        start_scripted(%{"screenshot" => {:error, {:timeout, :cu_sidecar_action, 30_000}}})

      assert {:ok, result} = click_in_region(session)
      assert result.outcome == :performed_unverified
      assert result.summary =~ "action performed"
      assert result.summary =~ "the action itself was sent"
      assert result.summary =~ "session was reset"
      refute result.summary =~ "action failed"

      # Reply FIRST, then stop: an error reply would have bought a second real click.
      assert_receive {:DOWN, ^ref, :process, ^session, {:shutdown, :sidecar_timeout}}
      assert_receive :driver_stop
    end

    test "a check whose helper exits says the same and resets the session" do
      {session, ref} = start_scripted(%{"screenshot" => {:error, {:sidecar_exited, 2}}})

      assert {:ok, result} = click_in_region(session)
      assert result.outcome == :performed_unverified
      assert result.summary =~ "the action itself was sent"

      assert_receive {:DOWN, ^ref, :process, ^session, {:sidecar_exited, 2}}
    end

    # The courtesy probe ran BEFORE any input, so this action definitively did not
    # happen — a different fact from an action that timed out, and a different
    # sentence. The Port is poisoned either way, so the session still resets.
    test "an idle-probe timeout dispatches nothing and resets the session" do
      {session, ref} =
        start_scripted(%{"idle_ms" => {:error, {:timeout, :cu_sidecar_action, 30_000}}})

      {:ok, :auto, click} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:error, {:not_dispatched, {:timeout, :cu_sidecar_action, 30_000}}} =
               Session.execute(session, click)

      refute_received {:driver_execute, %{"action" => "left_click"}}
      assert_receive {:DOWN, ^ref, :process, ^session, {:shutdown, :sidecar_timeout}}
    end

    # `Compux.PortDriver` consumes `{:exit_status, n}` inside its own receive and
    # answers `{:error, {:sidecar_exited, n}}`, so the handle_info stop clause never
    # fires for a sidecar that dies mid-action: without this the session survives on
    # a dead Port and every later action answers `:sidecar_unavailable`.
    test "a helper that exits on the action itself replies and stops the session" do
      {session, ref} = start_scripted(%{"screenshot" => {:error, {:sidecar_exited, 2}}})

      {:ok, :auto, request} = Session.classify(session, %{"action" => "screenshot"})

      assert {:error, {:sidecar_exited, 2}} = Session.execute(session, request)
      assert_receive {:DOWN, ^ref, :process, ^session, {:sidecar_exited, 2}}
      assert_receive :driver_stop
    end

    # The check frame arrived whole and was paired, so the Port is healthy — but the
    # image inside it cannot be decoded. For a READ that is the whole result and it
    # still fails loud (see "invalid base64 from the sidecar fails loud"); for a
    # mutating action the click was already sent, and reporting a failure would buy
    # a second one.
    test "a check image that cannot be read still reports the action performed" do
      {session, _ref} =
        start_scripted(%{
          "screenshot" => {:ok, %{"data" => "!!!not-base64!!!", "mime" => "image/png"}}
        })

      assert {:ok, result} = click_in_region(session)
      assert result.outcome == :performed_unverified
      assert result.summary =~ "the action itself was sent"
      assert result.summary =~ "invalid base64"
      refute result.summary =~ "action failed"
      # The helper answered — a whole frame arrived and was paired — so the session
      # keeps it; only the picture inside was unreadable.
      refute result.summary =~ "session was reset"
      assert Process.alive?(session)
    end

    # `Compux.PortDriver` answers `:sidecar_unavailable` when the Port is already
    # closed. Replying and living on meant every later action in the conversation
    # answered the same thing forever — a zombie no caller could recover from.
    test "a helper that is no longer running stops the session instead of zombieing it" do
      {session, ref} = start_scripted(%{"screenshot" => {:error, :sidecar_unavailable}})
      {:ok, :auto, request} = Session.classify(session, %{"action" => "screenshot"})

      assert {:error, :sidecar_unavailable} = Session.execute(session, request)
      assert_receive {:DOWN, ^ref, :process, ^session, {:shutdown, :sidecar_unavailable}}
      assert_receive :driver_stop
    end

    # `{:shutdown, _}` keeps the supervisor quiet; it must not also make the run look
    # healthy. A session that died on a poison reset leaving a row that says it
    # finished normally defeats the whole point of the lifecycle family.
    test "a poison reset leaves a session_error row, not a clean completion" do
      test_pid = self()
      handler = "cu-fault-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [
          [:fermix, :computer_use, :session_complete],
          [:fermix, :computer_use, :session_error]
        ],
        fn event, _m, meta, _ -> send(test_pid, {:lifecycle, List.last(event), meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {session, ref} =
        start_scripted(%{"screenshot" => {:error, {:timeout, :cu_sidecar_action, 30_000}}})

      {:ok, :auto, request} = Session.classify(session, %{"action" => "screenshot"})

      assert {:error, {:timeout, :cu_sidecar_action, 30_000}} = Session.execute(session, request)
      assert_receive {:DOWN, ^ref, :process, ^session, {:shutdown, :sidecar_timeout}}

      assert_receive {:lifecycle, :session_error, %{session_id: "cua_receipts"} = meta}
      assert meta.reason =~ "sidecar_timeout"
      refute_received {:lifecycle, :session_complete, %{session_id: "cua_receipts"}}
    end

    # M42 slice 2 §6: the five outcomes are READ off the wire's receipt now, not
    # inferred from what the check happened to return. Inferring is what produced a
    # run of clicks all reporting success while none of them landed.
    test "a receipt saying the input was never sent reports a refusal" do
      {session, _ref} =
        start_scripted(%{
          "left_click" => {:ok, %{"ok" => true, "receipt" => receipt(:not_sent)}}
        })

      {:ok, :auto, click} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:ok, %{outcome: :refused}} = Session.execute(session, click)
    end

    test "a receipt saying the input was only half sent reports an unknown outcome" do
      {session, _ref} =
        start_scripted(%{
          "left_click" => {:ok, %{"ok" => true, "receipt" => receipt(:partial)}}
        })

      {:ok, :auto, click} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:ok, %{outcome: :unknown}} = Session.execute(session, click)
    end

    test "a receipt that cannot account for the input reports an unknown outcome" do
      {session, _ref} =
        start_scripted(%{
          "left_click" => {:ok, %{"ok" => true, "receipt" => receipt(:unknown)}}
        })

      {:ok, :auto, click} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:ok, %{outcome: :unknown}} = Session.execute(session, click)
    end

    # A read-only action dispatches nothing and carries no receipt by protocol, so
    # requiring one would refuse every look.
    test "a read-only action needs no receipt" do
      {session, _ref} = start_scripted(%{"screenshot" => {:ok, %{"ok" => true}}})
      {:ok, :auto, request} = Session.classify(session, %{"action" => "screenshot"})

      assert {:ok, %{outcome: :read}} = Session.execute(session, request)
      assert Process.alive?(session)
    end

    # No fallback to the slice-1 inference: a helper that will not say what it did
    # with the input has broken the contract the whole verdict rests on, so it is
    # reported as the fault it is and the session takes a fresh helper. The caller
    # still gets its receipt first.
    test "a mutating action with no receipt is a protocol fault, never an inference" do
      {session, ref} = start_scripted(%{"left_click" => {:ok, %{"ok" => true}}})

      {:ok, :auto, click} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:error, {:protocol_error, :missing_receipt}} = Session.execute(session, click)
      assert_receive {:DOWN, ^ref, :process, ^session, {:shutdown, :protocol_error}}
      assert_receive :driver_stop
    end

    test "a receipt whose dispatch is not a value the wire defines is the same fault" do
      {session, ref} =
        start_scripted(%{
          "left_click" => {:ok, %{"ok" => true, "receipt" => %{"dispatch" => "probably"}}}
        })

      {:ok, :auto, click} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:error, {:protocol_error, :missing_receipt}} = Session.execute(session, click)
      assert_receive {:DOWN, ^ref, :process, ^session, {:shutdown, :protocol_error}}
    end

    # A refusal is a wire frame like a success, minus the payload: it carries the
    # same receipt, so the same rule reads it. The session lives — a live helper
    # saying "no" is it doing its job, not a reason to take a fresh one.
    test "a refusal's outcome comes from its receipt, and the session lives" do
      {session, _ref} =
        start_scripted(%{
          "left_click" => {:error, {:action_failed, refusal("paused", :not_sent)}}
        })

      {:ok, :auto, click} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:error, {:action_failed, %{code: "paused", outcome: :refused}}} =
               Session.execute(session, click)

      assert Process.alive?(session)
    end

    # The sequence was stopped part way through, so some of the input landed. The
    # code alone cannot say that; the receipt does.
    test "a refusal that half sent the input is an unknown outcome" do
      {session, _ref} =
        start_scripted(%{
          "left_click" => {:error, {:action_failed, refusal("cancelled", :partial)}}
        })

      {:ok, :auto, click} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:error, {:action_failed, %{code: "cancelled", outcome: :unknown}}} =
               Session.execute(session, click)
    end

    # A refusal owes a receipt exactly as a success does — it is the same frame.
    # Inferring one from the error code is the habit the receipt exists to end.
    test "a refusal with no receipt is the same protocol fault" do
      {session, ref} =
        start_scripted(%{
          "left_click" => {:error, {:action_failed, %{"error" => "paused"}}}
        })

      {:ok, :auto, click} =
        Session.classify(session, %{"action" => "left_click", "x" => 1, "y" => 2})

      assert {:error, {:protocol_error, :missing_receipt}} = Session.execute(session, click)
      assert_receive {:DOWN, ^ref, :process, ^session, {:shutdown, :protocol_error}}
    end

    # A read-only action dispatches nothing, so a refusal of one carries no receipt
    # and needs none — and it is still a read, never an unknown dispatch.
    test "a read-only action refused without a receipt is still a read" do
      {session, _ref} =
        start_scripted(%{
          "screenshot" => {:error, {:action_failed, %{"error" => "no_active_display"}}}
        })

      {:ok, :auto, request} = Session.classify(session, %{"action" => "screenshot"})

      assert {:error, {:action_failed, %{code: "no_active_display", outcome: :read}}} =
               Session.execute(session, request)

      assert Process.alive?(session)
    end

    # The sentence has to follow the receipt too. "The action itself was sent" is
    # true for a `sent` dispatch and a lie for any other, and a lie here is what
    # makes a model repeat an action that may already be half done.
    test "a check that failed after a half-sent action never claims the input was sent" do
      {session, _ref} =
        start_scripted(%{
          "left_click" => {:ok, %{"ok" => true, "receipt" => receipt(:partial)}},
          "screenshot" => {:ok, %{"data" => "!!!not-base64!!!", "mime" => "image/png"}}
        })

      assert {:ok, result} = click_in_region(session)
      assert result.outcome == :unknown
      assert result.summary =~ "outcome unknown"
      refute result.summary =~ "the action itself was sent"
      refute result.summary =~ "action performed"
    end

    # 75 is compux's INTENTIONAL capture-stall fail-fast, so it stays a clean
    # completion (`session_complete`, no crash report) on this path too.
    test "a helper exiting 75 on the action is a clean completion" do
      test_pid = self()
      handler = "cu-exit75-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:fermix, :computer_use, :session_complete],
        fn _e, _m, meta, _ -> send(test_pid, {:completed, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {session, ref} = start_scripted(%{"screenshot" => {:error, {:sidecar_exited, 75}}})
      {:ok, :auto, request} = Session.classify(session, %{"action" => "screenshot"})

      assert {:error, {:sidecar_exited, 75}} = Session.execute(session, request)
      assert_receive {:DOWN, ^ref, :process, ^session, {:shutdown, {:sidecar_exited, 75}}}
      assert_receive {:completed, %{session_id: "cua_receipts"}}
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

  # The `ActionWorker` a session started. Read out of the session's state rather
  # than published as an API: it is the driver's owner, so the Port-matched
  # clauses live there, and nothing in production has any business addressing it.
  defp worker(session), do: :sys.get_state(session).worker

  # The receipt a real sidecar returns on every mutating action (M42 slice 2 §3):
  # dispatch is what the session's `outcome` is derived from, and an absent one is
  # a protocol fault, so a double that answers a mutating action must carry it.
  defp sent_receipt, do: ComputerUseReceipts.receipt(:sent)

  defp receipt(dispatch), do: ComputerUseReceipts.receipt(dispatch)

  # The payload an `ok: false` response carries: the helper's own code, and the
  # same receipt a success carries.
  defp refusal(code, dispatch),
    do: %{"error" => code, "receipt" => ComputerUseReceipts.receipt(dispatch)}

  # classify an action and return just the request (helper for execute tests)
  defp wrap_classify(session, params) do
    case Session.classify(session, params) do
      {:ok, :auto, request} -> {:ok, request}
      other -> other
    end
  end
end
