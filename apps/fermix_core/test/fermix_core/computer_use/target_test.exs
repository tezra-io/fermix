defmodule FermixCore.ComputerUse.TargetTest do
  @moduledoc """
  Binding one window, working inside it, and giving it back (M42 slice 5 §4).

  Every test here runs with the experimental flag ON, because that is the only
  world in which any of it exists; `ComputerUse.BackgroundGateTest` owns the
  other world and proves none of this is reachable there.
  """

  use ExUnit.Case, async: false

  alias Compux.Protocol
  alias FermixCore.ComputerUse.ActionWorker
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Session
  alias FermixTestSupport.ComputerUseObservations
  alias FermixTestSupport.ComputerUseReceipts

  @obs ComputerUseObservations.id()

  # A helper that binds a window, answers inside it, and records every request
  # and control so a test can say what did NOT go out as well as what did.
  defmodule TargetDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         capabilities: Keyword.get(opts, :capabilities, %{}),
         idle_ms: Keyword.get(opts, :idle_ms, 10_000),
         front_is_target: Keyword.get(opts, :front_is_target),
         reached_idle: Keyword.get(opts, :reached_idle, true),
         children: Keyword.get(opts, :children),
         refuse: Keyword.get(opts, :refuse)
       }}
    end

    @impl true
    def execute(%{capabilities: capabilities}, %{"action" => "hello"}) do
      {:ok, %{"protocol_version" => Protocol.protocol_version(), "capabilities" => capabilities}}
    end

    @impl true
    def execute(%{refuse: code} = state, request) when is_binary(code) do
      send(state.test_pid, {:driver_execute, request})

      {:error,
       {:action_failed,
        %{"error" => code, "detail" => nil, "receipt" => ComputerUseReceipts.receipt(:not_sent)}}}
    end

    def execute(%{test_pid: pid} = state, request) do
      send(pid, {:driver_execute, request})
      {:ok, response(state, request)}
    end

    @impl true
    def control(%{test_pid: pid}, action) do
      send(pid, {:driver_control, action})
      {:ok, %{action: action, ok: true, in_flight_request_id: nil}}
    end

    @impl true
    def stop(_state), do: :ok

    defp response(state, %{"action" => "idle_ms"}) do
      %{"ok" => true, "idle_ms" => state.idle_ms}
      |> put_front(state.front_is_target)
    end

    defp response(state, %{"action" => "wait_for_idle"}),
      do: %{"ok" => true, "idle" => state.reached_idle}

    defp response(state, %{"action" => "select_target"}) do
      %{
        "ok" => true,
        "target_id" => "t1",
        "target_generation" => 1,
        "window_id" => 7,
        "app" => "Fixture",
        "title" => "Fixture window",
        "methods" => ["foreground_hid", "ax"],
        "ax_binding" => "bound",
        "observation_id" => "obs-target",
        "observation_kind" => "image",
        "data" => Base.encode64("png"),
        "mime" => "image/png",
        "width" => 100,
        "height" => 80
      }
      |> put_children(state.children)
    end

    defp response(_state, %{"action" => "release_target"}),
      do: %{"ok" => true, "released" => true}

    defp response(_state, request) do
      %{"ok" => true, "data" => Base.encode64("png"), "mime" => "image/png"}
      |> put_marks(request)
      |> ComputerUseObservations.stamp(request)
      |> ComputerUseReceipts.stamp(request, receipt_opts(request))
    end

    defp put_marks(response, %{"marks" => true}),
      do: Map.put(response, "marks", [%{"id" => 1, "x" => 40, "y" => 32, "role" => "AXButton"}])

    defp put_marks(response, _request), do: response

    defp receipt_opts(%{"action" => action}) when action in ~w(press set_value),
      do: [input_method: "ax", effect: "verified"]

    defp receipt_opts(_request), do: []

    defp put_front(response, nil), do: response
    defp put_front(response, front), do: Map.put(response, "front_is_target", front)

    defp put_children(response, nil), do: response
    defp put_children(response, children), do: Map.put(response, "children", children)
  end

  setup do
    previous = Application.get_env(:fermix_core, :computer_use, [])
    Application.put_env(:fermix_core, :computer_use, enabled: true, background: true)
    on_exit(fn -> Application.put_env(:fermix_core, :computer_use, previous) end)
    :ok
  end

  @capable %{"targets" => true, "indicator" => "present"}

  defp start_session(opts \\ []) do
    driver_opts = Keyword.merge([test_pid: self(), capabilities: @capable], opts)

    start_supervised!(
      {Session,
       [
         config: Config.current(),
         driver: {TargetDriver, driver_opts},
         origin: :interactive,
         session_id: "cua_target_#{System.unique_integer([:positive])}"
       ]},
      id: {:target_session, System.unique_integer([:positive])}
    )
  end

  defp run(session, params) do
    {:ok, :auto, request} = Session.classify(session, params)
    {request, Session.execute(session, request)}
  end

  defp bind(session) do
    {_request, {:ok, result}} = run(session, %{"action" => "select_target", "window_id" => 7})
    result
  end

  describe "selecting a window" do
    test "binds it, says what it bound and how it can be reached, and hands back a first look" do
      session = start_session()
      result = bind(session)

      assert result.summary =~ ~s(Bound to Fixture "Fixture window" as target t1)
      assert result.summary =~ "answered from the window's own picture even when something covers"
      assert result.summary =~ "pressed BY NAME"
      assert result.summary =~ "Image obs-target"
      assert result.image.mime_type == "image/png"
      assert result.target_kind == "window"
    end

    test "every action that acts inside one window carries its id, and `windows` does not" do
      session = start_session()
      bind(session)

      {request, {:ok, _}} = run(session, %{"action" => "screenshot"})
      assert request["target_id"] == "t1"

      {request, {:ok, _}} = run(session, %{"action" => "windows"})
      refute Map.has_key?(request, "target_id")
    end

    test "the images read inside one window are dropped when the binding changes" do
      session = start_session()
      bind(session)
      {_request, {:ok, _}} = run(session, %{"action" => "screenshot", "marks" => true})

      marked = %{"action" => "left_click", "observation_id" => @obs, "mark" => 1}

      # Read in that window's image, a mark resolves to the point it was badged at.
      assert {:ok, :auto, %{"x" => 40, "y" => 32}} = Session.classify(session, marked)

      # Bind again: the helper replaces the target, and the pictures taken in the
      # old one are not pictures of the new one, so nothing from them resolves.
      bind(session)

      assert {:error, :no_marks} = Session.classify(session, marked)
    end

    test "the other windows this application opened are reported, never followed" do
      session =
        start_session(children: [%{"window_id" => 9, "app" => "Notes", "title" => "Save sheet"}])

      result = bind(session)

      assert result.summary =~ "has opened 1 other window(s) since you bound this one"
      assert result.summary =~ ~s(window 9: Notes "Save sheet")
      assert result.summary =~ "Nothing follows them for you"
    end
  end

  describe "acting with no window bound" do
    test "a mutating action is refused before any driver call, and says how to choose" do
      session = start_session()

      assert {:error, :target_required} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "observation_id" => @obs,
                 "x" => 1,
                 "y" => 2
               })

      refute_received {:driver_execute, %{"action" => "left_click"}}
    end

    test "a look is never refused: finding the window is how one is chosen" do
      session = start_session()

      assert {:ok, :auto, _request} = Session.classify(session, %{"action" => "windows"})
      assert {:ok, :auto, _request} = Session.classify(session, %{"action" => "screenshot"})
    end
  end

  describe "the whole desktop, chosen explicitly" do
    test "is a different mode in the reply, and puts no target on the wire" do
      session = start_session()

      {_request, {:ok, result}} =
        run(session, %{"action" => "select_target", "window_id" => "desktop"})

      assert result.summary =~ "Working on the WHOLE DESKTOP"
      assert result.summary =~ "the person sees everything you do"
      assert result.target_kind == "desktop"

      {request, {:ok, _}} =
        run(session, %{
          "action" => "left_click",
          "observation_id" => ComputerUseObservations.id(),
          "x" => 1,
          "y" => 2
        })

      refute Map.has_key?(request, "target_id"), "the desktop is the ABSENCE of a target"
    end

    test "drops a window binding that was held, and nothing else" do
      session = start_session()
      bind(session)

      {_request, {:ok, result}} =
        run(session, %{"action" => "select_target", "window_id" => "desktop"})

      assert_received {:driver_execute, %{"action" => "release_target"}}
      assert result.summary =~ "WHOLE DESKTOP"
    end

    test "chosen with nothing bound costs no driver call at all" do
      session = start_session()
      assert_received {:driver_execute, %{"action" => "probe"}}

      {_request, {:ok, _result}} =
        run(session, %{"action" => "select_target", "window_id" => "desktop"})

      refute_received {:driver_execute, _request}
    end
  end

  describe "choosing a window badly" do
    test "a window_id that is neither an id nor the word for the screen is refused" do
      session = start_session()

      assert {:error, :window_id_required} =
               Session.classify(session, %{"action" => "select_target", "window_id" => "Safari"})

      assert {:error, :window_id_required} =
               Session.classify(session, %{"action" => "select_target"})

      refute_received {:driver_execute, %{"action" => "select_target"}}
    end
  end

  describe "waiting" do
    # The helper takes no target on `wait_for_change`, so a display-level wait
    # inside a bound window would answer about a different picture entirely.
    test "a screen-wide wait is refused inside a bound window, with the way round it" do
      session = start_session()
      bind(session)

      assert {:error, :wait_for_change_unbound} =
               Session.classify(session, %{"action" => "wait_for_change"})

      refute_received {:driver_execute, %{"action" => "wait_for_change"}}
    end

    test "and works as it always has on the whole desktop" do
      session = start_session()

      {_request, {:ok, _}} =
        run(session, %{"action" => "select_target", "window_id" => "desktop"})

      assert {:ok, :auto, request} = Session.classify(session, %{"action" => "wait_for_change"})
      refute Map.has_key?(request, "target_id")
    end
  end

  describe "releasing" do
    test "gives the window back and says the pointer is visible again" do
      session = start_session()
      bind(session)

      {_request, {:ok, result}} = run(session, %{"action" => "release_target"})

      assert result.summary =~ "window binding is released"
      assert result.summary =~ "whole desktop again"
      refute Map.has_key?(result, :target_kind)
    end

    test "a mutating action after it is refused again for want of a window" do
      session = start_session()
      bind(session)
      {_request, {:ok, _}} = run(session, %{"action" => "release_target"})

      assert {:error, :target_required} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "observation_id" => "obs-target",
                 "x" => 1,
                 "y" => 2
               })
    end
  end

  describe "courtesy inside a bound window" do
    test "a control pressed by name waits only when the person is in THAT window" do
      session = start_session(idle_ms: 0, front_is_target: false, reached_idle: false)
      bind(session)

      assert {_request, {:ok, _result}} =
               run(session, %{
                 "action" => "press",
                 "observation_id" => "obs-target",
                 "element_ref" => "e1"
               })
    end

    test "and does wait when they are" do
      session = start_session(idle_ms: 0, front_is_target: true, reached_idle: false)
      bind(session)

      {:ok, :auto, request} =
        Session.classify(session, %{
          "action" => "press",
          "observation_id" => "obs-target",
          "element_ref" => "e1"
        })

      assert {:error, :user_active} = Session.execute(session, request)
    end

    test "a click keeps today's wait however the window was chosen" do
      session = start_session(idle_ms: 0, front_is_target: false, reached_idle: false)
      bind(session)

      {:ok, :auto, request} =
        Session.classify(session, %{
          "action" => "left_click",
          "observation_id" => "obs-target",
          "x" => 1,
          "y" => 2
        })

      assert {:error, :user_active} = Session.execute(session, request)
    end
  end

  describe "the trace row" do
    test "says what the action was pointed at and how it reached the screen" do
      session = start_session()
      bind(session)

      {_request, {:ok, clicked}} =
        run(session, %{
          "action" => "left_click",
          "observation_id" => "obs-target",
          "x" => 1,
          "y" => 2
        })

      assert clicked.target_kind == "window"

      assert clicked.cu_mode == "foreground",
             "a pointer click moves the cursor wherever it is aimed"

      {_request, {:ok, pressed}} =
        run(session, %{
          "action" => "press",
          "observation_id" => "obs-target",
          "element_ref" => "e1"
        })

      assert pressed.target_kind == "window"
      assert pressed.cu_mode == "background"
      refute Map.has_key?(pressed, :app)
      refute pressed.summary == nil
    end
  end

  describe "what the helper can refuse a binding with" do
    # A platform that cannot bind a window says so in its handshake, and the
    # surface does not run against it — the same second gate a missing indicator
    # trips, from the other half of the capability.
    test "a build that publishes no window binding turns the surface off here" do
      session = start_session(capabilities: %{"targets" => false, "indicator" => "present"})

      assert {:error, {:background_unavailable, :no_targets}} =
               Session.classify(session, %{"action" => "select_target", "window_id" => 7})
    end

    # Binding is read-only, so this side admits it while paused — but the helper
    # bars its own gate for everything, and its refusal is the same hold from the
    # other side, so it reads as the one pause sentence.
    test "a helper that refuses the binding as paused reads as a pause" do
      session = start_session(refuse: "paused")

      {:ok, :auto, request} =
        Session.classify(session, %{"action" => "select_target", "window_id" => 7})

      assert {:error, {:action_failed, %{code: "paused"}}} = Session.execute(session, request)
    end

    test "screen recording that was never granted is an operator fact on the window path" do
      session = start_session(refuse: "screen_recording_not_granted")

      {:ok, :auto, request} =
        Session.classify(session, %{"action" => "select_target", "window_id" => 7})

      assert {:error, {:action_failed, %{code: "screen_recording_not_granted"}}} =
               Session.execute(session, request)
    end
  end

  describe "the on-screen indicator's buttons" do
    test "the worker hands each one to its session under one name" do
      worker =
        start_supervised!(
          {ActionWorker, [driver: {TargetDriver, [test_pid: self()]}, session: self()]}
        )

      for {kind, control} <- [
            {"operator_pause", :pause},
            {"operator_resume", :resume},
            {"operator_stop", :stop}
          ] do
        send(
          worker,
          {:compux_session_event, self(), %{"kind" => "indicator", "event" => kind}}
        )

        assert_receive {:operator_control, ^control}
      end
    end

    test "a pause from the badge holds the session without sending a second control" do
      session = start_session()

      send(session, {:operator_control, :pause})
      assert Session.paused?(session)

      refute_received {:driver_control, :pause},
                      "the helper's own gate already holds; a second barrier is not sent"

      assert {:error, {:refused, :paused}} =
               Session.classify(session, %{"action" => "screenshot"})
    end

    test "a resume from the badge lifts it, also without a control" do
      session = start_session()
      send(session, {:operator_control, :pause})
      assert Session.paused?(session)

      send(session, {:operator_control, :resume})
      refute Session.paused?(session)
      refute_received {:driver_control, :resume}
    end

    # The helper cannot end a session: its Stop applies a PAUSE to its own gate
    # and reports the button. So this side records the hold and then tears down,
    # rather than ending a session whose trace never showed the machine handed
    # back.
    test "a stop from the badge holds the machine and then ends the session" do
      session = start_session()
      ref = Process.monitor(session)

      send(session, {:operator_control, :stop})

      assert_receive {:DOWN, ^ref, :process, ^session, :normal}
      refute_received {:driver_control, :pause}
      refute_received {:driver_control, :stop}
    end
  end

  describe "a helper restart" do
    test "leaves the next session with no window, so the model is told to choose again" do
      session = start_session()
      bind(session)

      # A helper that ends takes its session with it (slice 2), so the binding
      # cannot outlive it: the next session starts holding nothing.
      fresh = start_session()

      assert {:error, :target_required} =
               Session.classify(fresh, %{
                 "action" => "left_click",
                 "observation_id" => "obs-target",
                 "x" => 1,
                 "y" => 2
               })

      assert Process.alive?(session)
    end
  end
end
