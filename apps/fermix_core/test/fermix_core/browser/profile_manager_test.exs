defmodule FermixCore.Browser.ProfileManagerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.ProfileManager
  alias FermixCore.Browser.Scope

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

  # A ProfileServer stand-in whose answer to each request is scripted, so the
  # two deaths that look alike from the caller — one with the request already
  # running, one with it still queued — can be reproduced deterministically.
  #
  # `:exit_after` reports the delivery FIRST and then dies: the work started.
  # `:exit_before` dies without reporting: the stop happened between callbacks
  # and nothing ran. Every count below is read off those reports, so "not
  # re-sent" and "ran exactly once" are assertions, not inferences.
  #
  # The script lives in an Agent outside the process so it survives a restart.
  defmodule ScriptedProfileServer do
    use GenServer

    def start_link(opts) do
      registry = Keyword.fetch!(opts, :registry)
      key = Keyword.fetch!(opts, :key)
      now = System.monotonic_time(:millisecond)
      GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {registry, key, now}})
    end

    @impl true
    def init(opts) do
      {:ok, %{script: Keyword.fetch!(opts, :script), reporter: Keyword.fetch!(opts, :reporter)}}
    end

    @impl true
    def handle_call({:request, request}, _from, state) do
      state.script |> next_directive() |> run(request, state)
    end

    # An exhausted script serves normally — every scenario below is "die once,
    # then behave", so the retry it allows (or refuses) is what is under test.
    defp next_directive(script) do
      Agent.get_and_update(script, fn
        [] -> {:serve, []}
        [directive | rest] -> {directive, rest}
      end)
    end

    defp run({:exit_before, reason}, _request, state), do: {:stop, reason, state}

    defp run(directive, request, state) do
      send(state.reporter, {:delivered, request})
      deliver(directive, request, state)
    end

    defp deliver(:serve, request, state),
      do: {:reply, {:ok, %{"ok" => true, "echo" => request}}, state}

    defp deliver({:exit_after, reason}, _request, state), do: {:stop, reason, state}
  end

  # Answers the manager's `{:start, ...}` call with pids the test chose, so a
  # dispatch can meet a pid that is ALREADY DEAD — the idle-reap/eviction race
  # the `:noproc` branch exists for, which cannot be scheduled for real.
  defmodule FakeManager do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(opts), do: {:ok, %{pids: Keyword.fetch!(opts, :pids)}}

    @impl true
    def handle_call({:start, _key, _profile, _config}, _from, %{pids: [pid | rest]} = state),
      do: {:reply, {:ok, pid}, %{state | pids: rest}}
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
    {:ok, keep_owner} = Scope.owner_key(%{conversation_key: keep})
    {:ok, reap_owner} = Scope.owner_key(%{conversation_key: reap})

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
               %{action: "snapshot", mutating: false},
               opts
             )

    # Second dispatch reuses the same server (no duplicate registration).
    assert {:ok, %{"ok" => true}} =
             ProfileManager.dispatch(
               "owner-d",
               "fermix",
               %{mode: :managed},
               ctx.config,
               %{action: "status", mutating: false},
               opts
             )

    assert live_keys(ctx.registry) == [{"owner-d", "fermix"}]
    assert %{"running" => true} = ProfileManager.status("owner-d", "fermix", opts)
  end

  # ── no blind replay of mutations (M47 §3.4) ────────────────────────────────

  # A re-sent `act click` is a second click, a re-sent `upload` a second upload,
  # a re-sent `webmcp` `call` a second tool invocation. The retry that exists for
  # a profile reaped between lookup and call must not also cover a server that
  # died holding the request.
  test "a mutating request is NOT re-sent when the server dies in flight", ctx do
    opts = scripted_manager([{:exit_after, :killed_mid_request}])
    request = %{action: "act", args: %{"kind" => "click"}, mutating: true}

    {result, _log} = with_log(fn -> scripted_dispatch(opts, request, ctx.config) end)

    assert {:error, %Error{code: "outcome_unknown"} = error} = result
    assert error.message =~ "may or may not have happened"
    assert error.message =~ "Take a snapshot"

    # The click reached the page exactly once, and the refusal is what the
    # caller gets instead of a second one.
    assert_received {:delivered, %{action: "act"}}
    refute_receive {:delivered, _request}, 100
  end

  # The other half: a read repeats nothing, so the existing retry stays.
  test "a read IS retried when the server dies in flight", ctx do
    opts = scripted_manager([{:exit_after, :killed_mid_request}])
    request = %{action: "snapshot", args: %{}, mutating: false}

    {result, _log} = with_log(fn -> scripted_dispatch(opts, request, ctx.config) end)

    assert {:ok, %{"ok" => true}} = result
    assert_received {:delivered, %{action: "snapshot"}}
    assert_received {:delivered, %{action: "snapshot"}}
  end

  # `{:noproc, _}` is what a caller sees when the server was already gone when
  # the call was SENT — an idle-reaped or evicted profile whose registration the
  # lookup won on the way past. Nothing ran, so the mutation is re-ensured and
  # sent to the fresh profile, exactly once in total.
  test "a profile already dead when the call is sent runs the mutation exactly once", ctx do
    live = unregistered_scripted_server([])
    manager = fake_manager([dead_pid(), live])
    opts = [registry: empty_registry(), server: manager]
    request = %{action: "act", args: %{"kind" => "click"}, mutating: true}

    assert {:ok, %{"ok" => true, "echo" => %{action: "act"}}} =
             scripted_dispatch(opts, request, ctx.config)

    assert_received {:delivered, %{action: "act"}}
    refute_receive {:delivered, _request}, 100
  end

  # `stop_owner/2` is a CAST and teardown kills Chrome for up to seconds, so a
  # request sent in that window reaches a server that stops without ever
  # handling it. ProfileServer traps exits, its `handle_call/3` never returns
  # `:stop`, and a nested CDP call blocks in a selective receive — so a
  # `:normal`/`:shutdown` exit can only be observed with the request still
  # queued. Turning that into `outcome_unknown` would refuse the `open` that
  # begins the next turn, which used to succeed on a fresh profile.
  test "a stop BETWEEN callbacks never ran, so the mutation is retried and runs once", ctx do
    for reason <- [:normal, :shutdown, {:shutdown, :reaped}] do
      opts = scripted_manager([{:exit_before, reason}])
      request = %{action: "open", args: %{"url" => "https://example.com"}, mutating: true}

      {result, _log} = with_log(fn -> scripted_dispatch(opts, request, ctx.config) end)

      assert {:ok, %{"ok" => true, "echo" => %{action: "open"}}} = result,
             "a #{inspect(reason)} stop was read as an in-flight death"

      assert_received {:delivered, %{action: "open"}}
      refute_receive {:delivered, _request}, 100
    end
  end

  defp scripted_dispatch(opts, request, config) do
    ProfileManager.dispatch("owner-script", "fermix", %{mode: :managed}, config, request, opts)
  end

  defp scripted_manager(script) do
    suffix = System.unique_integer([:positive])
    registry = Module.concat(__MODULE__, "ScriptRegistry#{suffix}")
    dynamic = Module.concat(__MODULE__, "ScriptDyn#{suffix}")
    manager = Module.concat(__MODULE__, "ScriptMgr#{suffix}")

    start_supervised!({Registry, keys: :unique, name: registry}, id: registry)
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: dynamic}, id: dynamic)

    start_supervised!(
      {ProfileManager,
       name: manager,
       registry: registry,
       dynamic_supervisor: dynamic,
       child_module: ScriptedProfileServer,
       child_opts: [script: script_agent(script, suffix), reporter: self()]},
      id: manager
    )

    [registry: registry, server: manager]
  end

  defp fake_manager(pids) do
    suffix = System.unique_integer([:positive])
    name = Module.concat(__MODULE__, "FakeMgr#{suffix}")
    start_supervised!({FakeManager, name: name, pids: pids}, id: name)
    name
  end

  # Registered under a key the dispatch never looks up, so `ensure/6` always
  # goes through the manager and the test decides which pid it meets.
  defp unregistered_scripted_server(script) do
    suffix = System.unique_integer([:positive])
    registry = Module.concat(__MODULE__, "AsideRegistry#{suffix}")
    start_supervised!({Registry, keys: :unique, name: registry}, id: registry)

    start_supervised!(
      {ScriptedProfileServer,
       registry: registry,
       key: {"aside", "fermix"},
       script: script_agent(script, suffix),
       reporter: self()},
      id: {:aside_server, suffix}
    )
  end

  defp empty_registry do
    suffix = System.unique_integer([:positive])
    registry = Module.concat(__MODULE__, "EmptyRegistry#{suffix}")
    start_supervised!({Registry, keys: :unique, name: registry}, id: registry)
    registry
  end

  defp script_agent(script, suffix),
    do: start_supervised!({Agent, fn -> script end}, id: {:script, suffix})

  defp dead_pid do
    {:ok, pid} = Agent.start(fn -> :gone end)
    ref = Process.monitor(pid)
    Agent.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end
end
