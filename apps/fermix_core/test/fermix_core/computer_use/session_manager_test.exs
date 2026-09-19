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

  # A Driver whose action blocks until the test releases it, so an action IN FLIGHT
  # can be observed from outside the session — which is, by construction, unable to
  # answer any call while it is blocked in the driver. Bounded: a never-released
  # action gives up rather than hanging the suite.
  defmodule BlockingDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def execute(_state, %{"action" => "probe"}), do: {:ok, %{"input_control" => true}}

    def execute(%{test_pid: pid}, request) do
      send(pid, {:driver_entered, request, self()})

      receive do
        :driver_release -> {:ok, %{"ok" => true}}
      after
        5_000 -> {:error, :test_driver_never_released}
      end
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

  # `/pause` must tell the human the truth about an action already inside the
  # helper, which cannot be recalled over this protocol. The fact is published on
  # the session's registry entry, read without a call: the driver lives in the
  # session's `ActionWorker`, so `self()` inside the double below is that worker.
  test "pause reports an action already in flight, and the flag never sticks", %{config: config} do
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

    # The cast goes out BEFORE the flag is read, so the guard is armed the moment the
    # in-flight action finishes — not only once its reply has been delivered.
    assert Session.paused?(pid)

    # Cleared on the way out, so the next `/pause` is the idle sentence again.
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
