defmodule FermixChannels.Desktop.TwoEnginesScreenTest do
  # M97 §6.4, §7.4: Fermix on the server sees and controls a linked computer's
  # screen, over the real link of two engines in one test VM. The session
  # (budget, images, pause) is the server's; the computer's helper is a double
  # (`ScreenHelperDouble`) under the computer's own seat, which decides the
  # origin again, the access level from its own sandbox mode, courtesy from its
  # own idle signal, and the person's Stop. No real input is ever sent.
  use ExUnit.Case, async: false

  alias Compux.Protocol
  alias FermixChannels.Test.TwoEngines
  alias FermixCore.Computers
  alias FermixCore.Computers.Capabilities.Screen
  alias FermixCore.Computers.Journal
  alias FermixCore.Computers.Outcome
  alias FermixCore.Computers.Switches
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Seat
  alias FermixCore.ComputerUse.Session
  alias FermixCore.ComputerUse.SessionManager
  alias FermixCore.ComputerUse.Supervisor, as: CuSupervisor
  alias FermixCore.Management.Computer, as: ComputerMethods
  alias FermixCore.Tools.ComputerUse
  alias FermixTestSupport.ScreenHelperDouble
  alias FermixTestSupport.TelemetryCapture

  @screen %{actions: Protocol.actions(), input_methods: ["ax"]}

  setup context do
    previous = Application.get_env(:fermix_core, :computer_use)
    # The server has no screen of its own.
    Application.put_env(:fermix_core, :computer_use, enabled: false)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_core, :computer_use)
        value -> Application.put_env(:fermix_core, :computer_use, value)
      end
    end)

    engines =
      TwoEngines.start!(
        offers: [:computer_use],
        sandbox: [mode: Map.get(context, :computer_sandbox, :standard)],
        facts: [screen: @screen]
      )

    test = self()
    {spec, knobs} = ScreenHelperDouble.driver(test)

    # The computer's seat first, so the server's sessions end before it does.
    start_supervised!(
      {Seat,
       driver: fn -> {:ok, spec} end,
       config: fn ->
         Config.normalize(enabled: true, courtesy: "yield", courtesy_idle_ms: 1_000)
       end,
       switches: fn -> Agent.get(engines.switch_agent, & &1) end,
       home: engines.root,
       changed: fn -> send(test, :screen_changed) end,
       timer: fn message, _delay ->
         send(test, {:lapse_armed, message})
         make_ref()
       end}
    )

    start_supervised!(CuSupervisor)

    session_id = "main-#{System.unique_integer([:positive])}"
    TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: session_id)
    %{engines: engines, knobs: knobs, session_id: session_id}
  end

  describe "a read and an effect across the link" do
    test "a screenshot is a look, and its image comes back as the part", ctx do
      assert {:ok, %{success: true, output: output, images: [image]}} =
               ComputerUse.execute(%{"action" => "screenshot"}, turn(ctx))

      assert output =~ "On studio Mac:"
      assert image.data == ScreenHelperDouble.png()
      assert image.mime_type == "image/png"
      assert_received {:screen_helper, "screenshot", _request}
      assert_received :screen_changed
      assert %{since: %DateTime{}} = Seat.view()

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measure, metadata}
      assert metadata.tool == "computer_use"
      assert metadata.computer == ctx.engines.device_id
      assert metadata.success
      refute_received {:telemetry, [:fermix, :tool, :exec], _measure, _more}
    end

    test "a click is an action, run once on the computer after its courtesy step", ctx do
      {:ok, %{success: true}} = ComputerUse.execute(%{"action" => "screenshot"}, turn(ctx))
      click = %{"action" => "left_click", "observation_id" => "obs-full", "x" => 10, "y" => 20}

      assert {:ok, %{success: true, output: output}} = ComputerUse.execute(click, turn(ctx))

      assert output =~ "On studio Mac:"
      assert_received {:screen_helper, "idle_ms", _probe}
      assert_received {:screen_helper, "left_click", %{"x" => 10, "y" => 20}}
      refute_received {:screen_helper, "left_click", _again}
    end

    test "the server's session holds the budget, the images and the seat; the computer the helper",
         ctx do
      {:ok, _result} = ComputerUse.execute(%{"action" => "screenshot"}, turn(ctx))
      {:ok, session} = SessionManager.lookup(turn(ctx))

      assert Session.action_count(session) == 1
      assert SessionManager.session_id(session) |> is_binary()
      assert Seat.watch_state(SessionManager.session_id(session)) == :held
    end
  end

  describe "courtesy, on the computer" do
    test "a person typing at the computer holds an action back, and nothing is sent", ctx do
      {:ok, _result} = ComputerUse.execute(%{"action" => "screenshot"}, turn(ctx))
      ScreenHelperDouble.set(ctx.knobs, :idle_ms, 10)
      ScreenHelperDouble.set(ctx.knobs, :idle, false)

      assert {:ok, %{success: false, error: error}} =
               ComputerUse.execute(%{"action" => "type", "text" => "hello"}, turn(ctx))

      assert error =~ "On studio Mac:"
      assert error =~ "actively using the machine"
      assert_received {:screen_helper, "wait_for_idle", _wait}
      refute_received {:screen_helper, "type", _request}
    end
  end

  describe "the access level is the computer's own" do
    # The computer said `standard` in its offer, and its sandbox is strict now.
    @tag computer_sandbox: :strict
    test "a strict computer refuses an action that changes something, and lets a look run", ctx do
      assert {:ok, %{success: true}} = ComputerUse.execute(%{"action" => "screenshot"}, turn(ctx))

      assert {:ok, %{success: false, error: error}} =
               ComputerUse.execute(%{"action" => "key", "chord" => "cmd+s"}, turn(ctx))

      assert error =~ "On studio Mac:"
      assert error =~ "strict"
      refute_received {:screen_helper, "key", _request}
    end
  end

  describe "the person at the computer is in charge" do
    test "Stop at the computer ends the session there and here, and the model is told", ctx do
      {:ok, _result} = ComputerUse.execute(%{"action" => "screenshot"}, turn(ctx))
      assert_received {:screen_helper, "screenshot", _first}
      {:ok, session} = SessionManager.lookup(turn(ctx))
      ref = Process.monitor(session)

      assert {:ok, %{"stopped" => true}} = ComputerMethods.screen_stop(%{})

      assert_receive :screen_helper_stopped
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 10_000
      assert Seat.view() == nil

      # The rest of this turn is held, as for the helper's own Stop button.
      assert {:ok, %{success: false, error: error}} =
               ComputerUse.execute(%{"action" => "screenshot"}, turn(ctx))

      assert error =~ "pressed Stop"
      refute_received {:screen_helper, "screenshot", _request}
    end

    test "Stop during an action answers it: the person at the computer stopped it", ctx do
      {:ok, _result} = ComputerUse.execute(%{"action" => "screenshot"}, turn(ctx))
      ScreenHelperDouble.set(ctx.knobs, :hold, true)
      click = %{"action" => "left_click", "observation_id" => "obs-full", "x" => 1, "y" => 1}
      call = Task.async(fn -> ComputerUse.execute(click, turn(ctx)) end)
      assert_receive {:screen_helper, "left_click", _request}, 10_000

      assert Seat.stop() == :stopped

      assert {:ok, %{success: false, error: error}} = Task.await(call, 15_000)
      assert error =~ "The person at studio Mac stopped it."
      assert error =~ "Do NOT take another computer-use action"
    end

    test "the screen switch going off mid-session ends it there and here", ctx do
      {:ok, _result} = ComputerUse.execute(%{"action" => "screenshot"}, turn(ctx))
      assert_received {:screen_helper, "screenshot", _first}
      {:ok, session} = SessionManager.lookup(turn(ctx))
      ref = Process.monitor(session)

      Agent.update(ctx.engines.switch_agent, fn _on -> Switches.only([]) end)
      GenServer.cast(Switches.screen_listener(), :switches_changed)

      assert_receive :screen_helper_stopped
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 10_000

      # A later turn reaches a computer whose screen is switched off.
      next =
        Map.merge(turn(ctx), %{session_id: ctx.session_id <> "-next", tool_call_id: "call-2"})

      assert {:ok, %{success: false, error: error}} =
               ComputerUse.execute(%{"action" => "screenshot"}, next)

      assert error =~ "switched off"
      refute_received {:screen_helper, "screenshot", _request}
    end
  end

  # C1: the computer lets go of a screen only when its server went quiet. A
  # session that exists renews its hold, paused or not, so a long gap between
  # steps resets nothing, and a pause holds until /resume.
  describe "a session's hold lasts as long as the session" do
    test "a paused session keeps the screen across a long gap, and stays paused", ctx do
      {:ok, _result} = ComputerUse.execute(%{"action" => "screenshot"}, turn(ctx))
      assert_received {:screen_helper, "screenshot", _first}
      {:ok, session} = SessionManager.lookup(turn(ctx))
      seat = SessionManager.session_id(session)
      ref = Process.monitor(session)

      assert Session.pause(session) in [:paused, :paused_in_flight]
      assert_receive {:screen_helper_control, :pause}, 10_000
      stale = last_lapse()

      # The server renews its hold, as it does every 30 s while the session
      # exists; the lapse armed before is stale.
      send(watch_of(session), :keep)
      assert_receive {:lapse_armed, {:lapse, renewed}}, 10_000
      send(Process.whereis(Seat.name()), {:lapse, stale})

      assert Seat.watch_state(seat) == :held
      assert Session.paused?(session)

      assert {:ok, %{success: false, error: error}} =
               ComputerUse.execute(%{"action" => "screenshot"}, turn(ctx))

      assert error =~ "paused"
      refute_received {:screen_helper, "screenshot", _second}

      # A server that went quiet is let go of after the lapse: the bound holds.
      send(Process.whereis(Seat.name()), {:lapse, last_lapse(renewed)})
      assert_receive {:DOWN, ^ref, :process, ^session, _ended}, 10_000
      assert Seat.view() == nil
    end
  end

  # A renewal is no thing Fermix did on that computer: "What Fermix did on
  # this computer" holds its real steps, however long a session holds the
  # screen.
  describe "the computer's journal" do
    test "a paused session held across several renewals adds nothing to the journal", ctx do
      {:ok, _result} = ComputerUse.execute(%{"action" => "screenshot"}, turn(ctx))
      {:ok, session} = SessionManager.lookup(turn(ctx))
      assert Session.pause(session) in [:paused, :paused_in_flight]
      assert_receive {:screen_helper_control, :pause}, 10_000
      _stale = last_lapse()
      before = journal_ids(ctx)

      for _renewal <- 1..3 do
        send(watch_of(session), :keep)
        assert_receive {:lapse_armed, {:lapse, _renewed}}, 10_000
      end

      assert journal_ids(ctx) == before
      assert Session.paused?(session)
    end
  end

  describe "attended only, on both sides" do
    test "each unattended origin is refused on the server before anything is sent", ctx do
      for {origin, more} <- unattended() do
        assert {:ok, %{success: false, error: error}} =
                 ComputerUse.execute(%{"action" => "screenshot"}, Map.merge(turn(ctx), more)),
               "#{origin}"

        assert error =~ "attended", "#{origin}: #{error}"
      end

      refute_received {:screen_helper, _action, _request}
      assert Seat.view() == nil
    end

    test "each unattended origin is refused again on the computer", ctx do
      computer = TwoEngines.computer(ctx.engines)
      opts = TwoEngines.call_opts(ctx.engines)

      for {origin, more} <- unattended() do
        context = Map.merge(%{session_id: ctx.session_id, tool_call_id: "call-1"}, more)

        for {op, request} <- [{"screen.look", "screenshot"}, {"screen.act", "key"}] do
          args = %{"seat" => "cua_direct", "request" => %{"action" => request}}

          assert {:error, %Outcome{status: :refused, refusal: :not_attended}} =
                   Computers.call(computer, Screen, op, args, context, opts),
                 "#{origin} #{op}"
        end
      end

      refute_received {:screen_helper, _action, _request}
    end
  end

  describe "one conversation holds one screen" do
    test "a second conversation is refused with who holds it", ctx do
      {:ok, _result} = ComputerUse.execute(%{"action" => "screenshot"}, turn(ctx))

      other =
        Map.merge(turn(ctx), %{
          conversation_key: {"companion", "chat-9", :root},
          session_id: ctx.session_id <> "-other"
        })

      assert {:ok, %{success: false, error: error}} =
               ComputerUse.execute(%{"action" => "screenshot"}, other)

      assert error =~ "another of your conversations (on telegram)"
      assert error =~ "studio Mac"
    end
  end

  defp turn(ctx) do
    %{
      agent_name: "main",
      conversation_key: {"telegram", "chat-7", :root},
      session_id: ctx.session_id,
      tool_call_id: "call-1",
      computer_use_origin: :interactive,
      source_trust: :operator,
      computer: TwoEngines.computer(ctx.engines),
      computer_call_opts: TwoEngines.call_opts(ctx.engines)
    }
  end

  defp journal_ids(ctx) do
    {:ok, %{entries: entries}} = Journal.list(Journal.dir(ctx.engines.root), limit: 200)
    Enum.map(entries, & &1.id)
  end

  # The newest lapse the computer's seat armed, all older ones taken.
  defp last_lapse(last \\ nil) do
    receive do
      {:lapse_armed, {:lapse, ref}} -> last_lapse(ref)
    after
      0 -> last || flunk("the seat armed no lapse")
    end
  end

  # The server's watch over the computer's screen, which the session's
  # driver holds.
  defp watch_of(session) do
    {_driver, %{watch: watch}} = :sys.get_state(session).driver
    watch
  end

  # Every origin that is not the owner in the conversation now, as a turn
  # carries it (`Computers.Origin`).
  defp unattended do
    [
      scheduled: %{trigger: "schedule"},
      cue: %{trigger: "cue"},
      worker: %{subagent_depth: 1},
      background: %{computer_use_origin: :unattended}
    ]
  end
end
