defmodule FermixCore.Browser.ProfileManagerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.ProfileManager

  # A stand-in for ProfileServer that registers itself in the manager's
  # registry exactly like the real one, but never launches Chrome.
  defmodule FakeProfileServer do
    use GenServer

    def start_link(opts) do
      registry = Keyword.fetch!(opts, :registry)
      key = Keyword.fetch!(opts, :key)
      now = System.monotonic_time(:millisecond)
      GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {registry, key, now}})
    end

    @impl true
    def init(opts), do: {:ok, %{opts: opts}}

    @impl true
    def handle_call(:status, _from, state),
      do: {:reply, %{"ok" => true, "running" => true}, state}

    def handle_call({:request, req}, _from, state),
      do: {:reply, {:ok, %{"ok" => true, "echo" => req}}, state}
  end

  setup context do
    original = Application.get_env(:fermix_core, :browser)
    suffix = System.unique_integer([:positive])
    registry = Module.concat(__MODULE__, "Registry#{suffix}")
    dynamic = Module.concat(__MODULE__, "Dyn#{suffix}")
    manager = Module.concat(__MODULE__, "Mgr#{suffix}")

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: dynamic})

    start_supervised!(
      {ProfileManager,
       name: manager,
       registry: registry,
       dynamic_supervisor: dynamic,
       child_module: FakeProfileServer}
    )

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fermix_core, :browser)
        value -> Application.put_env(:fermix_core, :browser, value)
      end
    end)

    {:ok, config} = Config.current(Map.get(context, :browser_config, []))
    %{registry: registry, manager: manager, config: config}
  end

  defp start(manager, owner, profile_name, config) do
    GenServer.call(manager, {:start, {owner, profile_name}, %{mode: :managed}, config})
  end

  defp live_keys(registry) do
    registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_key, pid} -> Process.alive?(pid) end)
    |> Enum.map(&elem(&1, 0))
  end

  test "starts a profile and reuses the same process on the next lookup", ctx do
    assert {:ok, pid} = start(ctx.manager, "owner-a", "fermix", ctx.config)
    assert Process.alive?(pid)
    assert {:ok, ^pid} = start(ctx.manager, "owner-a", "fermix", ctx.config)
    assert live_keys(ctx.registry) == [{"owner-a", "fermix"}]
  end

  @tag browser_config: [max_live_profiles: 2]
  test "evicts the least-recently-used profile when at the cap", ctx do
    assert {:ok, pid1} = start(ctx.manager, "owner-1", "fermix", ctx.config)
    Process.sleep(2)
    assert {:ok, pid2} = start(ctx.manager, "owner-2", "fermix", ctx.config)
    Process.sleep(2)

    # At the cap of 2 — starting a third evicts the oldest (owner-1).
    assert {:ok, pid3} = start(ctx.manager, "owner-3", "fermix", ctx.config)

    refute Process.alive?(pid1)
    assert Process.alive?(pid2)
    assert Process.alive?(pid3)

    keys = MapSet.new(live_keys(ctx.registry))
    assert MapSet.equal?(keys, MapSet.new([{"owner-2", "fermix"}, {"owner-3", "fermix"}]))
  end

  @tag browser_config: [idle_profile_ttl_ms: 1, idle_sweep_interval_ms: 3_600_000]
  test "idle sweep reclaims profiles past their ttl", ctx do
    Application.put_env(:fermix_core, :browser,
      idle_profile_ttl_ms: 1,
      idle_sweep_interval_ms: 3_600_000
    )

    assert {:ok, pid} = start(ctx.manager, "owner-idle", "fermix", ctx.config)
    ref = Process.monitor(pid)
    Process.sleep(5)

    # Sweep tears down asynchronously, so wait for the process to actually die.
    send(ctx.manager, :sweep)
    :sys.get_state(ctx.manager)

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    refute Process.alive?(pid)
    assert live_keys(ctx.registry) == []
  end

  test "stop_owner tears down every profile for that owner, leaving others alive", ctx do
    assert {:ok, pid_a1} = start(ctx.manager, "owner-a", "fermix", ctx.config)
    Process.sleep(2)
    assert {:ok, pid_a2} = start(ctx.manager, "owner-a", "fermix_visible", ctx.config)
    Process.sleep(2)
    assert {:ok, pid_b} = start(ctx.manager, "owner-b", "fermix", ctx.config)

    ref_a1 = Process.monitor(pid_a1)
    ref_a2 = Process.monitor(pid_a2)

    assert :ok = ProfileManager.stop_owner("owner-a", server: ctx.manager)

    # Both of owner-a's profiles are reaped; owner-b is untouched.
    assert_receive {:DOWN, ^ref_a1, :process, ^pid_a1, _reason}, 2_000
    assert_receive {:DOWN, ^ref_a2, :process, ^pid_a2, _reason}, 2_000
    assert Process.alive?(pid_b)
    assert live_keys(ctx.registry) == [{"owner-b", "fermix"}]
  end

  test "reap_conversation stops the browser for that conversation's owner only", ctx do
    keep = {"telegram", "chat-keep", :root}
    reap = {"cli", "sess-reap", :root}
    {:ok, keep_owner} = FermixCore.Browser.Scope.owner_key(%{conversation_key: keep})
    {:ok, reap_owner} = FermixCore.Browser.Scope.owner_key(%{conversation_key: reap})

    assert {:ok, keep_pid} = start(ctx.manager, keep_owner, "fermix", ctx.config)
    assert {:ok, reap_pid} = start(ctx.manager, reap_owner, "fermix", ctx.config)
    ref = Process.monitor(reap_pid)

    assert :ok = FermixCore.Browser.reap_conversation(reap, server: ctx.manager)

    assert_receive {:DOWN, ^ref, :process, ^reap_pid, _reason}, 2_000
    assert Process.alive?(keep_pid)
    assert live_keys(ctx.registry) == [{keep_owner, "fermix"}]
  end

  test "dispatch reaches the profile server directly and reuses it", ctx do
    opts = [registry: ctx.registry, server: ctx.manager]

    assert {:ok, %{"ok" => true, "echo" => %{action: "snapshot"}}} =
             ProfileManager.dispatch(
               "owner-d",
               "fermix",
               %{mode: :managed},
               ctx.config,
               %{action: "snapshot"},
               opts
             )

    # Second dispatch reuses the same server (no duplicate registration).
    assert {:ok, %{"ok" => true}} =
             ProfileManager.dispatch(
               "owner-d",
               "fermix",
               %{mode: :managed},
               ctx.config,
               %{action: "status"},
               opts
             )

    assert live_keys(ctx.registry) == [{"owner-d", "fermix"}]
    assert %{"running" => true} = ProfileManager.status("owner-d", "fermix", opts)
  end
end
