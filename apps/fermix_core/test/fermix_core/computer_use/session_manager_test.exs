defmodule FermixCore.ComputerUse.SessionManagerTest do
  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Session
  alias FermixCore.ComputerUse.SessionManager
  alias FermixCore.ComputerUse.Supervisor, as: CuSupervisor

  defmodule StubDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def execute(_state, _request), do: {:ok, %{"ok" => true}}

    @impl true
    def stop(_state), do: :ok
  end

  # Blocks inside the ACTION, and answers a control at once from a separate call —
  # which is the shape the real wire has: the helper's control reader is not its
  # action worker. The ack names the request still under way, which is the fact
  # `/pause` has to tell the human, so the double tracks it in an Agent.
  defmodule BlockingDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts) do
      {:ok, in_flight} = Agent.start_link(fn -> nil end)
      {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid), in_flight: in_flight}}
    end

    @impl true
    def execute(_state, %{"action" => "probe"}), do: {:ok, %{"input_control" => true}}

    def execute(%{test_pid: pid, in_flight: in_flight}, request) do
      send(pid, {:driver_entered, request, self()})
      Agent.update(in_flight, fn _ -> "r-" <> request["action"] end)

      receive do
        :driver_release ->
          Agent.update(in_flight, fn _ -> nil end)
          {:ok, %{"ok" => true}}
      after
        5_000 -> {:error, :test_driver_never_released}
      end
    end

    @impl true
    def control(%{in_flight: in_flight}, action) do
      {:ok,
       %{
         action: action,
         ok: true,
         authorization_generation: 2,
         in_flight_request_id: Agent.get(in_flight, & &1)
       }}
    end

    @impl true
    def stop(_state), do: :ok
  end

  setup do
    start_supervised!(CuSupervisor)
    %{config: Config.normalize(enabled: true)}
  end

  defp stub_driver, do: {StubDriver, [test_pid: self()]}

  defp context(extra \\ %{}) do
    Map.merge(%{agent_name: "main", conversation_key: {"cli", "c1", :root}}, extra)
  end

  test "ensure starts a session and reuses it for the same conversation", %{config: config} do
    ctx = context(%{computer_use_origin: :interactive})

    assert {:ok, pid} = SessionManager.ensure(config, ctx, driver: stub_driver())
    assert is_pid(pid)
    assert {:ok, ^pid} = SessionManager.ensure(config, ctx, driver: stub_driver())
    assert {:ok, ^pid} = SessionManager.lookup(ctx)
  end

  test "different conversations get different sessions", %{config: config} do
    {:ok, p1} =
      SessionManager.ensure(
        config,
        context(%{conversation_key: {"cli", "a", :root}, computer_use_origin: :interactive}),
        driver: stub_driver()
      )

    {:ok, p2} =
      SessionManager.ensure(
        config,
        context(%{conversation_key: {"cli", "b", :root}, computer_use_origin: :interactive}),
        driver: stub_driver()
      )

    refute p1 == p2
  end

  test "host mode fails closed for an unattended origin and starts no session" do
    config = Config.normalize(enabled: true)
    ctx = context(%{computer_use_origin: :scheduled})

    assert {:error, {:host_start_refused, :scheduled}} =
             SessionManager.ensure(config, ctx, driver: stub_driver())

    assert :error = SessionManager.lookup(ctx)
  end

  test "host mode fails closed when no origin is set (unattended is the safe default)" do
    config = Config.normalize(enabled: true)
    # A context that never declared an origin (e.g. a scheduled job) must NOT inherit
    # an attended origin — it defaults to :unattended and is refused.
    ctx = context()

    assert {:error, {:host_start_refused, :unattended}} =
             SessionManager.ensure(config, ctx, driver: stub_driver())

    assert :error = SessionManager.lookup(ctx)
  end

  test "host mode starts a session from an attended origin" do
    config = Config.normalize(enabled: true)
    ctx = context(%{computer_use_origin: :voice})

    assert {:ok, pid} = SessionManager.ensure(config, ctx, driver: stub_driver())
    assert is_pid(pid)
  end

  test "lookup returns :error when no session exists for the conversation" do
    assert :error = SessionManager.lookup(context())
  end

  test "abort tears down a running session and it does NOT restart", %{config: config} do
    ctx = context(%{computer_use_origin: :voice})
    {:ok, pid} = SessionManager.ensure(config, ctx, driver: stub_driver())
    ref = Process.monitor(pid)

    assert :ok = SessionManager.abort(ctx)

    # The contract boundary is `abort/1` RETURNING, not the `:DOWN` landing, so
    # this asserts before awaiting the monitor deliberately. `Registry` sweeps a
    # dead pid from its OWN monitor, a separate message with no ordering
    # guarantee against the caller's; waiting on `:DOWN` first would assert an
    # ordering no caller can rely on. It matters beyond tidiness because
    # `ensure/3` hands back whatever the registry holds, so a surviving entry
    # resumes a dead pid instead of starting a fresh session.
    assert :error = SessionManager.lookup(ctx)
    assert [] = DynamicSupervisor.which_children(CuSupervisor.session_supervisor())

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    # A :permanent child would be RESTARTED by the supervisor here, re-registering
    # under the same key — the teardown-defeating blocker. Asserted on the child
    # spec rather than by sleeping and re-reading the registry: the restart
    # strategy is the thing that must not regress, and it is knowable without
    # waiting for a restart that should never come.
    assert %{restart: :temporary} = Session.child_spec([])
    assert :error = SessionManager.lookup(ctx)
  end

  test "abort is a no-op when no session exists for the conversation" do
    assert :ok = SessionManager.abort(context(%{conversation_key: {"cli", "nope", :root}}))
  end

  test "abort is a no-op when the context carries no conversation key" do
    assert :ok = SessionManager.abort(%{agent_name: "realtime"})
  end

  test "abort is a clean no-op when the registry is not running (CU disabled)" do
    # Its whole supervisor is gated on ComputerUse.ready?/0, so when CU is
    # disabled the registry does not exist — the voice teardown backstop that
    # calls abort on EVERY call end must not crash there.
    :ok = stop_supervised(CuSupervisor)
    refute is_pid(Process.whereis(CuSupervisor.registry()))

    assert :ok = SessionManager.abort(context(%{computer_use_origin: :voice}))
  end

  test "pause/resume flip a running session's guard without tearing it down", %{config: config} do
    ctx = context(%{computer_use_origin: :interactive})
    {:ok, pid} = SessionManager.ensure(config, ctx, driver: stub_driver())

    assert :paused = SessionManager.pause(ctx)
    # unlike abort, the session stays alive and registered
    assert Process.alive?(pid)
    assert {:ok, ^pid} = SessionManager.lookup(ctx)
    assert Session.paused?(pid)

    assert :resumed = SessionManager.resume(ctx)
    refute Session.paused?(pid)
    assert {:ok, ^pid} = SessionManager.lookup(ctx)
  end

  # A session too wedged to answer a control at all. Every surface renders
  # `:unconfirmed` as "the helper was shut down", so that has to be TRUE on this
  # branch too — reporting it while leaving the session alive and paused is exactly
  # the lie the verdict exists to avoid.
  defmodule DeafSession do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_call(_message, _from, state) do
      # Longer than any control budget, and bounded so the suite cannot hang.
      Process.sleep(60_000)
      {:reply, :paused, state}
    end
  end

  test "a session that never answers a control is ended, so :unconfirmed stays true" do
    ctx = context(%{computer_use_origin: :interactive})
    key = ctx.conversation_key

    {:ok, pid} =
      DynamicSupervisor.start_child(CuSupervisor.session_supervisor(), %{
        id: DeafSession,
        start:
          {DeafSession, :start_link, [[name: {:via, Registry, {CuSupervisor.registry(), key}}]]},
        restart: :temporary,
        shutdown: 1_000
      })

    ref = Process.monitor(pid)

    assert :unconfirmed = SessionManager.pause(ctx)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
  end

  # `/pause` must tell the human the truth about an action already inside the
  # helper. The fact now comes from the helper's own acknowledgement, which names
  # the request it is still running — no Registry flag, no window between reading
  # one and the action starting. The driver lives in the session's `ActionWorker`,
  # so `self()` inside the double is that worker.
  test "pause reports an action already in flight, from the helper's own ack", %{config: config} do
    ctx = context(%{computer_use_origin: :interactive})
    {:ok, pid} = SessionManager.ensure(config, ctx, driver: {BlockingDriver, [test_pid: self()]})

    assert :paused = SessionManager.pause(ctx)
    assert :resumed = SessionManager.resume(ctx)

    action =
      Task.async(fn ->
        {:ok, :auto, request} = Session.classify(pid, %{"action" => "screenshot"})
        Session.execute(pid, request)
      end)

    assert_receive {:driver_entered, %{"action" => "screenshot"}, worker}, 1_000
    assert worker != pid

    assert :paused_in_flight = SessionManager.pause(ctx)

    send(worker, :driver_release)
    assert {:ok, _result} = Task.await(action)

    # The flag is set before the control goes out, so the guard is armed the moment
    # the in-flight action finishes — not only once its reply has been delivered.
    assert Session.paused?(pid)

    # Nothing is under way any more, so the next `/pause` is the idle sentence.
    :resumed = SessionManager.resume(ctx)
    assert :paused = SessionManager.pause(ctx)
  end

  test "session_id answers nil for anything that is not a live registered session" do
    # A tool context may carry any `GenServer.server()`; raising here would lose the
    # exec event for an action that already ran.
    assert SessionManager.session_id(:not_a_session) == nil
    assert SessionManager.session_id(make_ref()) == nil
    assert SessionManager.session_id({:via, Registry, {CuSupervisor.registry(), :nope}}) == nil
  end

  test "a running session publishes its lifecycle id where a tool exec can read it", %{
    config: config
  } do
    ctx = context(%{computer_use_origin: :interactive})
    {:ok, pid} = SessionManager.ensure(config, ctx, driver: stub_driver())

    assert "cua_" <> _ = SessionManager.session_id(pid)
  end

  test "session_id is nil for a session started outside the registry" do
    session =
      start_supervised!(
        {Session,
         [
           config: Config.normalize(enabled: true),
           driver: stub_driver(),
           origin: :interactive,
           session_id: "cua_unregistered"
         ]}
      )

    assert SessionManager.session_id(session) == nil
  end

  test "pause/resume are :no_session no-ops when nothing is running" do
    assert :no_session = SessionManager.pause(context(%{conversation_key: {"cli", "x", :root}}))
    assert :no_session = SessionManager.resume(context(%{conversation_key: {"cli", "x", :root}}))
    assert :no_session = SessionManager.pause(%{agent_name: "realtime"})
  end

  test "pause is a clean :no_session when the registry is not running (CU disabled)" do
    :ok = stop_supervised(CuSupervisor)
    refute is_pid(Process.whereis(CuSupervisor.registry()))
    assert :no_session = SessionManager.pause(context(%{computer_use_origin: :voice}))
  end
end
