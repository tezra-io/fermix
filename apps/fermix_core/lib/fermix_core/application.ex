defmodule FermixCore.Application do
  @moduledoc false

  use Application
  require Logger

  alias Burrito.Util, as: BurritoUtil
  alias Burrito.Util.Args, as: BurritoArgs
  alias Fermix.CLI.Daemon
  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Agents.MainAgent
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Capabilities.Builtin, as: BuiltinCapability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.ExtractionDebouncer
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Scheduler
  alias FermixCore.Memory.Store
  alias FermixCore.Setup.BootReport
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Tools.Registry
  alias FermixCore.Trace

  @impl true
  def start(_type, _args) do
    if BurritoUtil.running_standalone?() do
      cli_dispatch(BurritoArgs.argv())
    else
      # Dev (mix test, iex -S mix phx.server) or plain release
      # (`bin/fermix start`). All sibling apps are `:permanent`, so OTP
      # auto-starts them after this returns; whether the Phoenix endpoint
      # binds is governed by the existing PHX_SERVER convention in
      # `config/runtime.exs`.
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

    with {:ok, pid} <- start_supervision_tree() do
      spawn(fn -> run_cli(argv) end)
      {:ok, pid}
    end
  end

  # `setup`: build the supervision tree (needed for `Memory.Repo` during
  # `SetupSeeder`), run the wizard synchronously, then halt before OTP
  # proceeds to start fermix_channels/fermix_web. Setup never binds a
  # network port.
  defp cli_dispatch(["setup" | _] = argv) do
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

  defp start_supervision_tree do
    setup_file_logger()
    Trace.TelemetryHandler.attach()

    children =
      [
        {Task.Supervisor, name: FermixCore.TaskSupervisor},
        {Trace, trace_opts()},
        maybe_token_manager(),
        Registry,
        CapabilityRegistry,
        {SkillRegistry, capability_registry: CapabilityRegistry},
        Repo,
        ConversationStore,
        Store,
        ExtractionDebouncer,
        Scheduler,
        BootReport,
        AgentSupervisor,
        MainAgent,
        maybe_daemon_socket()
      ]
      |> List.flatten()

    opts = [strategy: :rest_for_one, name: FermixCore.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      register_tools()
      register_builtin_capabilities()
      {:ok, pid}
    end
  end

  defp run_cli(argv) do
    Fermix.CLI.main(argv)
  rescue
    error ->
      IO.puts(:stderr, "fermix: unexpected error — #{Exception.message(error)}")
      IO.puts(:stderr, Exception.format_stacktrace(__STACKTRACE__))
      1
  end

  defp register_tools do
    tools = [
      FermixCore.Tools.Shell,
      FermixCore.Tools.FileRead,
      FermixCore.Tools.FileWrite,
      FermixCore.Tools.MemoryStore,
      FermixCore.Tools.MemoryRecall,
      FermixCore.Tools.Browser,
      FermixCore.Tools.InvokeSkill
    ]

    Enum.each(tools, fn tool ->
      case Registry.register(tool) do
        :ok -> :ok
        {:error, :already_registered} -> :ok
      end
    end)
  end

  defp register_builtin_capabilities do
    Registry.all_tools()
    |> Enum.each(fn tool_module ->
      capability = BuiltinCapability.from_tool_module(tool_module)

      case CapabilityRegistry.register(capability) do
        :ok -> :ok
        {:error, {:duplicate_name, _}} -> :ok
      end
    end)
  end

  defp maybe_token_manager do
    providers = Application.get_env(:fermix_core, :providers, [])
    openai = Keyword.get(providers, :openai, [])

    if Keyword.get(openai, :auth_mode) == :oauth do
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

  defp trace_opts do
    trace_config = Application.get_env(:fermix_core, :trace, [])
    [base_dir: Keyword.get(trace_config, :base_dir, default_trace_dir())]
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
end
