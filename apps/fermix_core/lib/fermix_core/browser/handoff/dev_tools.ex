defmodule FermixCore.Browser.Handoff.DevTools do
  @moduledoc """
  The owner profile's Chrome, reached through the DevTools protocol for a
  browser hand-off (M75 D18, B10): its cookies read on the desktop
  (`Storage.getCookies`), stored and deleted on the primary
  (`Storage.setCookies`), and the headed window the owner signs in with.

  **The profile.** The owner's (`Browser.Scope`'s `"owner"` key) in the
  configured default browser profile, the one tasks run in. It must be a
  managed Chrome profile; another kind (a granted tab, a remote endpoint) has
  no profile Fermix owns, and is refused (`:profile_not_managed`).

  **Which Chrome.** `run/3` uses the Chrome already running on that profile
  when there is one (`ChromeLauncher.attach/4`) and leaves it running. With
  none, `:launch_headless` starts one headless for the session and stops it
  after; `:running_only` answers `:not_running` instead (the sweeper's mode:
  a Chrome that is not running deletes the expired cookies at its next launch).
  The session runs in a task of its own that traps exits, so a Chrome it
  started is stopped on every path, a dropped DevTools connection included.

  **Written to disk.** Chrome keeps its cookies in memory and writes them to
  its profile within about 30 s, or as it shuts down in order; a Chrome that is
  killed before then loses what changed (seen with a real Chrome: a cookie set
  just before a `SIGTERM` was gone at the next start about half the time). So
  a Chrome a session started is closed with `Browser.close`, which writes
  every change, and stopped by signal only when it does not exit in time. A
  Chrome that was already running is left running, and writes on its own
  schedule (`Browser.Handoff` deletes again at its next start what it deleted
  there).

  **Signing in.** `open_headed/2` opens the url in a new tab of the running
  Chrome, or starts a headed one on the profile. A Chrome it starts is held by
  a process of its own for as long as the owner keeps it open, at most an
  hour, and stopped with the engine.
  """

  alias FermixCore.Browser.CDP.Connection
  alias FermixCore.Browser.ChromeLauncher
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error

  require Logger

  @owner_key "owner"
  @run_timeout_ms 120_000
  @signin_max_ms 3_600_000

  @typedoc "Runs one DevTools command on the browser endpoint."
  @type command :: (String.t(), map() -> {:ok, map() | nil} | {:error, term()})

  @typedoc "Whether a session may start a headless Chrome when none runs."
  @type mode :: :launch_headless | :running_only

  @doc """
  Runs `fun` with a command function on the owner profile's Chrome, and
  answers what it answers. `opts`: `:launcher` and `:connection` (the
  launcher and transport modules), `:browser_config` (the `[fermix_core.browser]`
  section), `:task_supervisor`.
  """
  @spec run(mode(), (command() -> result), keyword()) :: result | {:error, term()}
        when result: term()
  def run(mode, fun, opts \\ [])
      when mode in [:launch_headless, :running_only] and is_function(fun, 1) and is_list(opts) do
    supervisor = Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor)
    task = Task.Supervisor.async_nolink(supervisor, fn -> session(mode, fun, opts) end)

    case Task.yield(task, @run_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:devtools_failed, reason}}

      nil ->
        Logger.error("browser hand-off: a DevTools session did not finish in time; stopped")
        {:error, :devtools_timeout}
    end
  end

  @doc """
  Opens `url` for the owner to sign in: in a new tab of the Chrome running on
  the owner profile, or in a headed Chrome started on it. `opts` as `run/3`.
  """
  @spec open_headed(String.t(), keyword()) :: :ok | {:error, term()}
  def open_headed(url, opts \\ []) when is_binary(url) and is_list(opts) do
    with {:ok, config, profile, name} <- owner_profile(opts) do
      launcher = Keyword.get(opts, :launcher, ChromeLauncher)

      case launcher.attach(config, profile, @owner_key, name) do
        {:ok, runtime} -> new_tab(runtime, url, config, opts)
        :none -> hold_headed(config, profile, name, url, opts)
      end
    end
  end

  @doc """
  The owner profile the hand-off uses: the browser configuration, the
  profile and its name, or `:profile_not_managed`.
  """
  @spec owner_profile(keyword()) ::
          {:ok, Config.t(), map(), String.t()} | {:error, :profile_not_managed | Error.t()}
  def owner_profile(opts \\ []) when is_list(opts) do
    raw = Keyword.get_lazy(opts, :browser_config, &browser_section/0)

    with {:ok, config} <- Config.current(raw),
         {:ok, profile, name} <- Config.profile(config, nil) do
      if Map.get(profile, :mode) == :managed,
        do: {:ok, config, profile, name},
        else: {:error, :profile_not_managed}
    end
  end

  defp browser_section, do: Application.get_env(:fermix_core, :browser, [])

  defp session(mode, fun, opts) do
    Process.flag(:trap_exit, true)
    launcher = Keyword.get(opts, :launcher, ChromeLauncher)

    with {:ok, config, profile, name} <- owner_profile(opts),
         {:ok, runtime, started?} <- browser(mode, launcher, config, profile, name) do
      try do
        connected(runtime, config, fun, started?, opts)
      after
        if started? and Port.info(runtime.port_ref) != nil, do: launcher.stop(runtime, config)
      end
    end
  end

  defp browser(mode, launcher, config, profile, name) do
    case {launcher.attach(config, profile, @owner_key, name), mode} do
      {{:ok, runtime}, _mode} ->
        {:ok, runtime, false}

      {:none, :running_only} ->
        {:error, :not_running}

      {:none, :launch_headless} ->
        with {:ok, runtime} <-
               launcher.start(config, %{profile | headless: true}, @owner_key, name),
             do: {:ok, runtime, true}
    end
  end

  defp connected(runtime, config, fun, started?, opts) do
    connection = Keyword.get(opts, :connection, Connection)

    case connection.start_link(runtime.ws_url, keepalive_ms: config.cdp_keepalive_ms) do
      {:ok, conn} ->
        command = command(connection, conn, config)

        try do
          result = fun.(command)
          if started?, do: close_in_order(command, runtime, config)
          result
        after
          connection.close(conn)
        end

      {:error, reason} ->
        {:error, {:devtools_connect_failed, reason}}
    end
  end

  # Chrome writes every change as it closes in order. Its own output is
  # drained while it does; one that does not exit in time is stopped by the
  # caller.
  defp close_in_order(command, %{port_ref: port}, config) do
    case command.("Browser.close", %{}) do
      {:ok, _closing} ->
        await_exit(port, System.monotonic_time(:millisecond) + config.launch_timeout_ms)

      {:error, reason} ->
        Logger.warning("browser hand-off: Chrome did not close: #{inspect(reason)}")
    end
  end

  defp await_exit(port, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, _output}} -> await_exit(port, deadline)
      {^port, {:exit_status, _status}} -> :ok
    after
      remaining -> Logger.warning("browser hand-off: Chrome did not exit after closing")
    end
  end

  defp command(connection, conn, config) do
    fn method, params ->
      connection.command(
        conn,
        method,
        params,
        nil,
        config.action_timeout_ms,
        config.cdp_response_grace_ms
      )
    end
  end

  defp new_tab(runtime, url, config, opts) do
    connected(runtime, config, &create_target(&1, url), false, opts)
  end

  defp create_target(command, url) do
    case command.("Target.createTarget", %{"url" => url}) do
      {:ok, _target} -> :ok
      {:error, reason} -> {:error, {:devtools_failed, reason}}
    end
  end

  # The headed Chrome belongs to the process that started it: its port closes
  # with that process. So a holder starts it, opens the url, answers, and keeps
  # it until the owner quits Chrome, the hour passes or the engine stops.
  defp hold_headed(config, profile, name, url, opts) do
    supervisor = Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor)
    reply_to = {self(), make_ref()}

    {:ok, holder} =
      Task.Supervisor.start_child(supervisor, fn ->
        hold(reply_to, config, %{profile | headless: false}, name, url, opts)
      end)

    monitor = Process.monitor(holder)
    await_holder(reply_to, monitor, config)
  end

  defp await_holder({_pid, ref}, monitor, config) do
    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, _holder, reason} ->
        {:error, {:devtools_failed, reason}}
    after
      config.launch_timeout_ms + config.action_timeout_ms * 2 ->
        Process.demonitor(monitor, [:flush])
        {:error, :devtools_timeout}
    end
  end

  defp hold({parent, ref}, config, profile, name, url, opts) do
    Process.flag(:trap_exit, true)
    launcher = Keyword.get(opts, :launcher, ChromeLauncher)

    case launcher.start(config, profile, @owner_key, name) do
      {:ok, runtime} ->
        result = connected(runtime, config, &create_target(&1, url), false, opts)
        send(parent, {ref, result})
        keep_open(runtime, System.monotonic_time(:millisecond) + @signin_max_ms)
        launcher.stop(runtime, config)

      {:error, error} ->
        send(parent, {ref, {:error, error}})
    end
  end

  # Chrome's own output is drained, and so is the closed DevTools connection's
  # normal exit; Chrome's exit, the engine's shutdown, or the hour ends the wait.
  defp keep_open(%{port_ref: port} = runtime, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, _output}} -> keep_open(runtime, deadline)
      {^port, {:exit_status, _status}} -> :ok
      {:EXIT, _from, :normal} -> keep_open(runtime, deadline)
      {:EXIT, _from, _reason} -> :ok
    after
      remaining -> :ok
    end
  end
end
