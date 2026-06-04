defmodule FermixCore.Application do
  @moduledoc false

  use Application
  require Logger

  alias Burrito.Util, as: BurritoUtil
  alias Burrito.Util.Args, as: BurritoArgs
  alias Fermix.CLI.Daemon
  alias Fermix.CLI.Setup
  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Agents.MainAgent
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Auth.Store, as: AuthStore
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Config, as: CoreConfig
  alias FermixCore.Jobs.RunnerSupervisor, as: JobRunnerSupervisor
  alias FermixCore.Jobs.Scheduler, as: JobScheduler
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Scheduler, as: MemoryScheduler
  alias FermixCore.Memory.Store
  alias FermixCore.Plugins.CapabilitySeeder, as: PluginCapabilitySeeder
  alias FermixCore.Prompt.BootstrapRename
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Realtime.Supervisor, as: RealtimeSupervisor
  alias FermixCore.Sandbox.CommandCapabilities
  alias FermixCore.Sandbox.DecisionTelemetry
  alias FermixCore.Setup.BootReport
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Trace

  @impl true
  def start(_type, _args) do
    if BurritoUtil.running_standalone?() do
      cli_dispatch(BurritoArgs.argv())
    else
      # Dev (mix test, mix fermix.dev, iex -S mix phx.server) or plain
      # release (`bin/fermix start`). All sibling apps are `:permanent`,
      # so OTP auto-starts them after this returns; whether the Phoenix
      # endpoint binds is governed by the existing PHX_SERVER convention
      # in `config/runtime.exs`. `mix fermix.dev` sets the gating env
      # flags before calling `Application.ensure_all_started/1`, so the
      # daemon socket and Realtime supervisor start without going
      # through `cli_dispatch/1`.
      start_supervision_tree()
    end
  end

  # `run`: enable the endpoint server now (before OTP proceeds to start
  # fermix_web), build the supervision tree, then spawn `Fermix.CLI.Run`
  # for log + block. The BEAM stays alive because all sibling apps are
  # `:permanent` — we do not call `System.halt`.
  defp cli_dispatch(["run" | _] = argv) do
    enable_endpoint_server()
    enable_daemon_socket()
    enable_realtime_socket()

    with {:ok, pid} <- start_supervision_tree() do
      spawn(fn -> run_cli(argv) end)
      {:ok, pid}
    end
  end

  # `setup`: the service-first web path avoids the local tree and starts
  # the real daemon instead. Terminal setup still builds the tree needed
  # for `SetupSeeder`, then halts before sibling OTP apps start.
  defp cli_dispatch(["setup" | _] = argv) do
    if Setup.supervision_required?(tl(argv)) do
      {:ok, _pid} = start_supervision_tree()
    end

    System.halt(run_cli(argv))
  end

  defp cli_dispatch(["memory" | _] = argv) do
    {:ok, _pid} = start_supervision_tree()
    System.halt(run_cli(argv))
  end

  # version / help / start / stop / unknown — strictly read-only, no side
  # effects. Halt before any sibling app starts so there is no file
  # logger, no `Memory.Repo`, no `TokenManager`, no port bind.
  defp cli_dispatch(argv) do
    System.halt(run_cli(argv))
  end

  defp enable_endpoint_server do
    existing = Application.get_env(:fermix_web, FermixWebWeb.Endpoint, [])
    Application.put_env(:fermix_web, FermixWebWeb.Endpoint, Keyword.put(existing, :server, true))
  end

  defp enable_daemon_socket do
    Application.put_env(:fermix_core, :daemon_socket_enabled, true)
  end

  defp enable_realtime_socket do
    Application.put_env(:fermix_core, :realtime_socket_enabled, true)
  end

  defp start_supervision_tree do
    remember_launch_cwd()
    :ok = ConfigStore.ensure_workspace()
    :ok = BootstrapRename.run()
    :ok = AuthStore.validate_permissions!()
    setup_file_logger()
    Trace.TelemetryHandler.attach()
    DecisionTelemetry.attach()

    children =
      [
        {Task.Supervisor, name: FermixCore.TaskSupervisor},
        {Finch, name: FermixCore.Finch, pools: finch_pools()},
        {Trace, trace_opts()},
        TokenSupervisor,
        maybe_token_manager(),
        FermixCore.Browser.Supervisor,
        CapabilityRegistry,
        BuiltinSeeder,
        {CommandCapabilities, capability_registry: CapabilityRegistry},
        {PluginCapabilitySeeder, capability_registry: CapabilityRegistry},
        {SkillRegistry, capability_registry: CapabilityRegistry},
        {McpSupervisor, capability_registry: CapabilityRegistry},
        Repo,
        ConversationStore,
        Store,
        MemoryScheduler,
        BootReport,
        AgentSupervisor,
        MainAgent,
        JobRunnerSupervisor,
        {JobScheduler, jobs_scheduler_opts()},
        maybe_daemon_socket(),
        maybe_realtime_supervisor()
      ]
      |> List.flatten()

    opts = [strategy: :rest_for_one, name: FermixCore.Supervisor]

    Supervisor.start_link(children, opts)
  end

  # Shared outbound HTTP pool for `FermixCore.Net.HttpClient`. Finch's
  # default `conn_max_idle_time` is `:infinity`, so a long-lived daemon
  # reuses keep-alive sockets that cloud LBs silently RST'd while the host
  # slept or sat idle — the next request then fails with a `:closed`
  # transport error before any byte arrives. Capping idle age means
  # checkout discards stale connections and handshakes fresh ones (a few
  # hundred ms of TLS, noise next to an LLM call). chatgpt.com keeps the
  # Codex adapter's 5s connect timeout, moved here because Req forbids
  # combining `:finch` with `:connect_options`.
  @http_conn_max_idle_ms 15_000

  # Public (@doc false) because Finch has no API to read pool config back,
  # so tests pin these literals here — a regression to the :infinity
  # default would otherwise be invisible to the suite.
  @doc false
  @spec finch_pools() :: %{(atom() | String.t()) => keyword()}
  def finch_pools do
    %{
      :default => [conn_max_idle_time: @http_conn_max_idle_ms],
      "https://chatgpt.com" => [
        conn_max_idle_time: @http_conn_max_idle_ms,
        conn_opts: [transport_opts: [timeout: 5_000]]
      ]
    }
  end

  defp run_cli(argv) do
    Fermix.CLI.main(argv)
  rescue
    error ->
      IO.puts(:stderr, "fermix: unexpected error — #{Exception.message(error)}")
      IO.puts(:stderr, Exception.format_stacktrace(__STACKTRACE__))
      1
  end

  defp maybe_token_manager do
    provider =
      Application.get_env(:fermix_core, :agent, [])
      |> Keyword.get(:provider, :openai)

    if provider == :openai_codex do
      [TokenManager]
    else
      []
    end
  end

  defp maybe_daemon_socket do
    if Application.get_env(:fermix_core, :daemon_socket_enabled, false) do
      [Daemon]
    else
      []
    end
  end

  defp maybe_realtime_supervisor do
    if realtime_socket_enabled?() and realtime_ready?() do
      [RealtimeSupervisor]
    else
      []
    end
  end

  defp realtime_socket_enabled? do
    Application.get_env(:fermix_core, :realtime_socket_enabled, false)
  end

  defp realtime_ready? do
    config = RealtimeConfig.current()

    config.enabled? and config.provider == "openai" and
      match?({:ok, _api_key}, CoreConfig.provider_api_key(:openai))
  end

  defp trace_opts do
    trace_config = Application.get_env(:fermix_core, :trace, [])
    [base_dir: Keyword.get(trace_config, :base_dir, default_trace_dir())]
  end

  defp jobs_scheduler_opts do
    Application.get_env(:fermix_core, :jobs, [])
  end

  defp setup_file_logger do
    log_config = Application.get_env(:fermix_core, :log, [])

    if Keyword.get(log_config, :enabled, true) do
      log_file = Keyword.get(log_config, :file, default_log_file())
      max_bytes = Keyword.get(log_config, :max_no_bytes, 10_485_760)
      max_files = Keyword.get(log_config, :max_no_files, 10)

      File.mkdir_p!(Path.dirname(log_file))

      case :logger.add_handler(:fermix_file, :logger_std_h, %{
             config: %{
               file: String.to_charlist(log_file),
               max_no_bytes: max_bytes,
               max_no_files: max_files
             },
             formatter: {:logger_formatter, %{template: [:time, ~c" ", :level, ~c" ", :msg, ~c"
"]}}
           }) do
        :ok -> :ok
        {:error, {:already_exist, _}} -> :ok
        {:error, reason} -> Logger.warning("Failed to add file logger: #{inspect(reason)}")
      end
    end
  end

  defp default_trace_dir, do: ConfigStore.workspace_paths().traces
  defp default_log_file, do: Path.join(ConfigStore.workspace_paths().logs, "fermix.log")

  defp remember_launch_cwd do
    Application.put_env(:fermix_core, :sandbox_launch_cwd, File.cwd!())
  end
end
