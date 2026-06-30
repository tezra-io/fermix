defmodule FermixCore.ComputerUse.SessionManagerTest do
  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.SessionManager
  alias FermixCore.ComputerUse.Supervisor, as: CuSupervisor

  defmodule StubDriver do
    @behaviour FermixCore.ComputerUse.Driver

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
end
