defmodule FermixCore.Browser.ProfileManager do
  @moduledoc """
  Registry-backed manager for per-`{owner, profile}` `ProfileServer` processes.

  This is a manager, not a supervisor — the actual lifecycle owner is the
  sibling `DynamicSupervisor`. The hot path never touches this GenServer: a
  caller looks the profile up in the `Registry` (a lock-free ETS read) and calls
  the `ProfileServer` directly, so browser work for one conversation never
  blocks another. This GenServer is consulted only on the rare paths — starting
  a new profile (enforcing the live-instance cap with LRU eviction) and the
  periodic idle sweep that reclaims unused Chrome instances.
  """

  use GenServer

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.ProfileServer

  require Logger

  @registry FermixCore.Browser.Registry

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Run a request against the profile's `ProfileServer`, starting it if needed.

  Executes in the caller's process: the lookup is a lock-free `Registry` read
  and the `ProfileServer.request/2` call is direct. Only a cold start consults
  the manager GenServer. Retries (bounded by `config.start_retries`) if the
  server stops between lookup and call (idle sweep / eviction race).

  `opts` may carry `:registry` and `:server` to target a non-default
  registry/manager (used by isolated tests); both default to the production
  singletons so the lookup table and the manager process always agree.
  """
  @spec dispatch(String.t(), String.t(), map(), Config.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def dispatch(owner, profile_name, profile, config, request, opts \\ []) do
    registry = Keyword.get(opts, :registry, @registry)
    server = Keyword.get(opts, :server, __MODULE__)

    do_dispatch(
      owner,
      profile_name,
      profile,
      config,
      request,
      registry,
      server,
      config.start_retries
    )
  end

  @doc """
  Asynchronously tear down every live `ProfileServer` for `owner` (all of its
  profiles), killing the Chrome process(es).

  Reaps a finished one-shot conversation's browser at turn end so a completed
  CLI/`ask` turn does not pin a Chrome window for the full idle TTL. Async (a
  cast) so it never blocks the caller's reply path; a no-op when the owner has
  no running profile.
  """
  @spec stop_owner(String.t(), keyword()) :: :ok
  def stop_owner(owner, opts \\ []) when is_binary(owner) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.cast(server, {:stop_owner, owner})
  end

  @spec status(String.t(), String.t(), keyword()) :: map()
  def status(owner, profile_name, opts \\ []) do
    registry = Keyword.get(opts, :registry, @registry)

    case live_pid(registry, {owner, profile_name}) do
      {:ok, pid} -> ProfileServer.status(pid)
      :error -> %{"ok" => true, "profile" => profile_name, "running" => false}
    end
  end

  @impl true
  def init(opts) do
    config = fetch_config()

    state = %{
      dynamic_supervisor: Keyword.fetch!(opts, :dynamic_supervisor),
      registry: Keyword.fetch!(opts, :registry),
      child_module: Keyword.get(opts, :child_module, ProfileServer),
      child_opts: Keyword.get(opts, :child_opts, [])
    }

    schedule_sweep(config)
    {:ok, state}
  end

  @impl true
  def handle_call({:start, key, profile, config}, _from, state) do
    {:reply, ensure_started(key, profile, config, state, config.start_retries), state}
  end

  @impl true
  def handle_cast({:stop_owner, owner}, state) do
    config = fetch_config()

    state.registry
    |> entries()
    |> Enum.each(fn {{entry_owner, _profile_name}, pid, _last_used} ->
      if entry_owner == owner and Process.alive?(pid), do: async_stop(pid, config)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    config = fetch_config()
    sweep_idle(config, state)
    schedule_sweep(config)
    {:noreply, state}
  end

  defp do_dispatch(owner, profile_name, profile, config, request, registry, server, retries) do
    with {:ok, pid} <- ensure(owner, profile_name, profile, config, registry, server) do
      case safe_request(pid, request) do
        {:error, :server_gone} when retries > 0 ->
          do_dispatch(
            owner,
            profile_name,
            profile,
            config,
            request,
            registry,
            server,
            retries - 1
          )

        {:error, :server_gone} ->
          {:error, Error.new("browser_unavailable", "Browser profile became unavailable")}

        other ->
          other
      end
    end
  end

  defp ensure(owner, profile_name, profile, config, registry, server) do
    case live_pid(registry, {owner, profile_name}) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        GenServer.call(server, {:start, {owner, profile_name}, profile, config}, :infinity)
    end
  end

  defp safe_request(pid, request) do
    ProfileServer.request(pid, request)
  catch
    :exit, _reason -> {:error, :server_gone}
  end

  defp ensure_started(_key, _profile, _config, _state, 0) do
    {:error, Error.new("browser_unavailable", "Browser profile could not be started")}
  end

  defp ensure_started(key, profile, config, state, retries) do
    case live_pid(state.registry, key) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        with :ok <- enforce_cap(config, state),
             {:ok, pid} <- start_child(key, profile, config, state, retries) do
          {:ok, pid}
        end
    end
  end

  defp enforce_cap(config, state) do
    if live_count(state.registry) < config.max_live_profiles do
      :ok
    else
      evict_lru(config, state)
    end
  end

  defp evict_lru(config, state) do
    case lru_pid(state.registry) do
      nil ->
        {:error, Error.new("browser_busy", "No idle browser profile is available to evict")}

      pid ->
        stop_child(pid, config)
        :ok
    end
  end

  defp start_child(key, profile, config, state, retries) do
    case DynamicSupervisor.start_child(
           state.dynamic_supervisor,
           child_spec(key, profile, config, state)
         ) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        reuse_or_retry(pid, key, profile, config, state, retries)

      {:error, reason} ->
        {:error,
         Error.new("browser_start_failed", "Could not start browser profile: #{inspect(reason)}")}
    end
  end

  # A lingering dead registration (idle sweep / eviction that has not cleared
  # yet) surfaces as :already_started. If it is genuinely live, reuse it;
  # otherwise wait one poll interval for the Registry to drop it and retry.
  defp reuse_or_retry(pid, key, profile, config, state, retries) do
    if Process.alive?(pid) do
      {:ok, pid}
    else
      Process.sleep(config.wait_poll_interval_ms)
      ensure_started(key, profile, config, state, retries - 1)
    end
  end

  defp child_spec(key, profile, config, state) do
    opts =
      Keyword.merge(state.child_opts,
        owner_key: elem(key, 0),
        profile_name: elem(key, 1),
        profile: profile,
        config: config,
        registry: state.registry,
        key: key
      )

    %{
      id: key,
      start: {state.child_module, :start_link, [opts]},
      restart: :transient,
      shutdown: shutdown_timeout(config),
      type: :worker
    }
  end

  # Synchronous teardown: used only for at-cap eviction (rare, keeps the cap a
  # hard ceiling). The idle sweep uses async_stop so a routine sweep cannot
  # block cold starts for up to N x grace.
  defp stop_child(pid, config) do
    ProfileServer.stop(pid, shutdown_timeout(config))
  end

  defp async_stop(pid, config) do
    Task.Supervisor.start_child(FermixCore.TaskSupervisor, fn ->
      ProfileServer.stop(pid, shutdown_timeout(config))
    end)
  end

  defp shutdown_timeout(config) do
    config.stop_grace_ms + config.kill_grace_ms + config.shutdown_slack_ms
  end

  defp sweep_idle(config, state) do
    now = System.monotonic_time(:millisecond)

    state.registry
    |> entries()
    |> Enum.filter(fn {_key, pid, last_used} ->
      Process.alive?(pid) and now - last_used >= config.idle_profile_ttl_ms
    end)
    |> Enum.each(fn {key, pid, _last_used} ->
      Logger.debug("browser: reclaiming idle profile #{inspect(key)}")
      async_stop(pid, config)
    end)
  end

  defp schedule_sweep(%Config{idle_sweep_interval_ms: interval}) do
    Process.send_after(self(), :sweep, interval)
  end

  defp fetch_config do
    case Config.current() do
      {:ok, config} -> config
      {:error, _reason} -> %Config{}
    end
  end

  defp live_pid(registry, key) do
    case Registry.lookup(registry, key) do
      [{pid, _value}] -> if Process.alive?(pid), do: {:ok, pid}, else: :error
      [] -> :error
    end
  end

  defp live_count(registry) do
    registry |> entries() |> Enum.count(fn {_key, pid, _value} -> Process.alive?(pid) end)
  end

  defp lru_pid(registry) do
    registry
    |> entries()
    |> Enum.filter(fn {_key, pid, _value} -> Process.alive?(pid) end)
    |> Enum.min_by(fn {_key, _pid, last_used} -> last_used end, fn -> nil end)
    |> case do
      nil -> nil
      {_key, pid, _last_used} -> pid
    end
  end

  defp entries(registry) do
    Registry.select(registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
  end
end
