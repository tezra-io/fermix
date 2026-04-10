defmodule FermixCore.Application do
  @moduledoc false

  use Application
  require Logger

  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Agents.MainAgent
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Store
  alias FermixCore.Setup.BootReport
  alias FermixCore.Tools.Registry
  alias FermixCore.Trace

  @impl true
  def start(_type, _args) do
    setup_file_logger()
    Trace.TelemetryHandler.attach()

    children =
      [
        {Task.Supervisor, name: FermixCore.TaskSupervisor},
        {Trace, trace_opts()},
        maybe_token_manager(),
        SkillRegistry,
        Registry,
        ConversationStore,
        Store,
        BootReport,
        AgentSupervisor,
        MainAgent
      ]
      |> List.flatten()

    opts = [strategy: :rest_for_one, name: FermixCore.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      register_tools()
      {:ok, pid}
    end
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

  defp maybe_token_manager do
    providers = Application.get_env(:fermix_core, :providers, [])
    openai = Keyword.get(providers, :openai, [])

    if Keyword.get(openai, :auth_mode) == :oauth do
      [TokenManager]
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
      max_files = Keyword.get(log_config, :max_no_files, 5)

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

  defp default_trace_dir, do: Path.join(System.user_home!(), ".fermix/traces")
  defp default_log_file, do: Path.join(System.user_home!(), ".fermix/logs/fermix.log")
end
