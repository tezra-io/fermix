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
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    # A :permanent child would be RESTARTED by the :one_for_one supervisor here,
    # re-registering under the same key — the teardown-defeating blocker. Session
    # is :temporary and abort goes through terminate_child, so it stays down.
    assert :error = SessionManager.lookup(ctx)
    Process.sleep(150)
    assert :error = SessionManager.lookup(ctx)
    assert [] = DynamicSupervisor.which_children(CuSupervisor.session_supervisor())
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
