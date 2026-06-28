defmodule FermixCore.ComputerUse.SessionTest do
  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Session

  # A stub Driver: no native code, speaks the Protocol response shape. It records
  # execute/stop calls to the test pid and returns a configurable response.
  defmodule StubDriver do
    @behaviour FermixCore.ComputerUse.Driver

    @impl true
    def start(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         response: Keyword.get(opts, :response, %{"ok" => true}),
         # An optional fake port so handle_info port-matched clauses can be
         # exercised without a real Port/sidecar.
         port: Keyword.get(opts, :port)
       }}
    end

    @impl true
    def execute(%{test_pid: pid} = state, request) do
      send(pid, {:driver_execute, request})
      {:ok, state.response}
    end

    @impl true
    def stop(%{test_pid: pid}) do
      send(pid, :driver_stop)
      :ok
    end
  end

  # A Driver whose action always reports the inner sidecar timeout (the shape
  # FermixCore.Timeouts.expired/3 returns) — exercises the poison-reset path
  # without a 30s wall-clock wait.
  defmodule TimeoutDriver do
    @behaviour FermixCore.ComputerUse.Driver

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
                 config: Config.normalize(enabled: true, mode: :host),
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

      start_session(config: Config.normalize(enabled: true, mode: :host), origin: :voice)

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
      assert result == %{summary: "ok", image: nil}
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
      assert_receive {:DOWN, ^ref, :process, ^session, :sidecar_timeout}
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
