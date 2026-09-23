defmodule FermixCore.ComputerUse.OperatorStopTest do
  @moduledoc """
  Stop on the on-screen indicator has to HOLD (M42 slice 5 §4).

  Ending the session is not ending the work: the model is mid-turn, and without
  these gates its next `computer_use` call opens a fresh session with a fresh,
  unbarred helper and the person's Stop lasts a couple of seconds. The turn
  cancellation `/stop` uses lives in the channels layer, which core cannot call,
  so the hold is made at the two places core owns — the reply the interrupted
  caller reads, and the door a session is opened through.
  """

  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.OperatorStop
  alias FermixCore.ComputerUse.Session
  alias FermixCore.ComputerUse.SessionManager
  alias FermixCore.ComputerUse.Supervisor, as: CuSupervisor
  alias FermixCore.Tools.ComputerUse
  alias FermixTestSupport.ComputerUseObservations

  @conversation {"cli", "stopped", :root}
  @turn "main-turn-1"

  # Blocks inside the action, so a Stop can land while a caller is waiting on it.
  defmodule BlockingDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def execute(_state, %{"action" => "probe"}), do: {:ok, %{"input_control" => true}}

    def execute(_state, %{"action" => "hello"}),
      do: {:ok, %{"capabilities" => %{"targets" => true, "indicator" => "present"}}}

    # The courtesy probe runs before the action; only the action itself blocks.
    def execute(_state, %{"action" => "idle_ms"}), do: {:ok, %{"ok" => true, "idle_ms" => 10_000}}

    def execute(_state, %{"action" => "wait_for_idle"}),
      do: {:ok, %{"ok" => true, "idle" => true}}

    def execute(%{test_pid: pid}, request) do
      send(pid, {:driver_entered, request})

      receive do
        :driver_release -> {:ok, %{"ok" => true}}
      after
        2_000 -> {:error, :test_driver_never_released}
      end
    end

    @impl true
    def control(_state, action), do: {:ok, %{action: action, ok: true}}

    @impl true
    def stop(_state), do: :ok
  end

  setup do
    previous = Application.get_env(:fermix_core, :computer_use, [])
    Application.put_env(:fermix_core, :computer_use, enabled: true)
    on_exit(fn -> Application.put_env(:fermix_core, :computer_use, previous) end)

    start_supervised!(CuSupervisor)
    %{config: Config.normalize(enabled: true)}
  end

  defp context(turn) do
    %{
      agent_name: "main",
      conversation_key: @conversation,
      computer_use_origin: :interactive,
      session_id: turn
    }
  end

  describe "the record itself" do
    test "holds the turn it was made in, and lets the next one through" do
      assert :ok = OperatorStop.check(@conversation, @turn)

      OperatorStop.record(@conversation, @turn)
      assert {:error, :operator_stopped} = OperatorStop.check(@conversation, @turn)

      # The person speaking again is a NEW turn, and it clears the hold on its
      # way through rather than leaving it to expire.
      assert :ok = OperatorStop.check(@conversation, "main-turn-2")
      assert :ok = OperatorStop.check(@conversation, @turn)
    end

    test "holds nothing for a conversation that was never stopped" do
      OperatorStop.record({"cli", "other", :root}, @turn)
      assert :ok = OperatorStop.check(@conversation, @turn)
    end

    # A hold the person's next message cannot lift is worse than none, so a stop
    # with no turn to key on records nothing and says so in the log.
    test "a stop with no turn identity records nothing" do
      OperatorStop.record(@conversation, nil)
      assert :ok = OperatorStop.check(@conversation, @turn)
      assert :ok = OperatorStop.check(@conversation, nil)
    end

    test "no computer-use tree means nothing was open to stop" do
      :ok = stop_supervised(CuSupervisor)
      assert :ok = OperatorStop.check(@conversation, @turn)
    end
  end

  describe "a stop with an action in flight" do
    test "answers the waiting caller itself, telling it to stop rather than carry on" do
      {:ok, session} =
        SessionManager.ensure(Config.normalize(enabled: true), context(@turn),
          driver: {BlockingDriver, [test_pid: self()]}
        )

      {:ok, :auto, request} =
        Session.classify(session, %{
          "action" => "left_click",
          "observation_id" => ComputerUseObservations.id(),
          "x" => 1,
          "y" => 2
        })

      caller = Task.async(fn -> Session.execute(session, request) end)
      assert_receive {:driver_entered, %{"action" => "left_click"}}, 1_000

      send(session, {:operator_control, :stop})

      assert {:error, {:operator_stopped, :unknown}} = Task.await(caller, 5_000)
    end

    test "and the model reads a sentence that forbids the next action" do
      result =
        ComputerUse.execute(%{"action" => "screenshot"}, %{
          conversation_key: @conversation,
          computer_use_origin: :interactive,
          session_id: @turn,
          computer_use_config: Config.normalize(enabled: true)
        })

      # Nothing is held yet, so this one runs (and starts a driver).
      assert {:ok, %{success: _}} = result

      OperatorStop.record(@conversation, @turn)

      assert {:ok, refused} =
               ComputerUse.execute(%{"action" => "screenshot"}, %{
                 conversation_key: @conversation,
                 computer_use_origin: :interactive,
                 session_id: @turn,
                 computer_use_config: Config.normalize(enabled: true)
               })

      assert refused.success == false
      assert refused.error =~ "pressed Stop on the on-screen computer-use controls"
      assert refused.error =~ "Do NOT take another computer-use action"
      assert refused.error =~ "ask before going any further"
    end
  end

  # The notice to the person is a courtesy; the reply to the caller is the thing
  # that stops the model. A channel that is slow must never hold up the second,
  # which is why the notice is spawned unlinked after the reply rather than run
  # in the session with a watchdog in front of it.
  describe "the notice never delays the reply" do
    defmodule SlowAdapter do
      @moduledoc false

      def send_message(_destination, _text, _opts) do
        send(:operator_stop_sink, :notice_started)

        receive do
          :release -> :ok
        after
          5_000 -> {:error, :never_released}
        end
      end
    end

    test "the interrupted caller is answered while the channel is still blocked" do
      Process.register(self(), :operator_stop_sink)
      previous_jobs = Application.get_env(:fermix_core, :jobs, [])

      Application.put_env(
        :fermix_core,
        :jobs,
        Keyword.put(previous_jobs, :delivery_channels, %{"telegram" => SlowAdapter})
      )

      on_exit(fn -> Application.put_env(:fermix_core, :jobs, previous_jobs) end)

      conversation = {"telegram", "4242", :root}
      ctx = %{context(@turn) | conversation_key: conversation}

      {:ok, session} =
        SessionManager.ensure(Config.normalize(enabled: true), ctx,
          driver: {BlockingDriver, [test_pid: self()]}
        )

      {:ok, :auto, request} =
        Session.classify(session, %{
          "action" => "left_click",
          "observation_id" => ComputerUseObservations.id(),
          "x" => 1,
          "y" => 2
        })

      caller = Task.async(fn -> Session.execute(session, request) end)
      assert_receive {:driver_entered, %{"action" => "left_click"}}, 1_000

      send(session, {:operator_control, :stop})

      # Well inside the notice's own 3 s watchdog: run inline, this reply could
      # not arrive until that watchdog had expired.
      assert {:error, {:operator_stopped, :unknown}} = Task.await(caller, 1_000)
      assert_receive :notice_started, 1_000
    end
  end

  describe "the door a session is opened through" do
    test "refuses a fresh session for the stopped turn, and starts no driver", %{config: config} do
      OperatorStop.record(@conversation, @turn)

      assert {:error, :operator_stopped} =
               SessionManager.ensure(config, context(@turn),
                 driver: {BlockingDriver, [test_pid: self()]}
               )

      refute_received {:driver_entered, _request}
      assert :error = SessionManager.lookup(context(@turn))
    end

    test "opens one again for the next turn", %{config: config} do
      OperatorStop.record(@conversation, @turn)

      assert {:ok, pid} =
               SessionManager.ensure(config, context("main-turn-2"),
                 driver: {BlockingDriver, [test_pid: self()]}
               )

      assert is_pid(pid)
    end
  end

  describe "the surface the flag adds" do
    test "a stop records against the session's own turn" do
      previous = Application.get_env(:fermix_core, :computer_use, [])
      Application.put_env(:fermix_core, :computer_use, enabled: true, background: true)
      on_exit(fn -> Application.put_env(:fermix_core, :computer_use, previous) end)

      {:ok, session} =
        SessionManager.ensure(Config.current(), context(@turn),
          driver: {BlockingDriver, [test_pid: self()]}
        )

      ref = Process.monitor(session)
      send(session, {:operator_control, :stop})
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2_000

      assert {:error, :operator_stopped} = OperatorStop.check(@conversation, @turn)
    end
  end
end
