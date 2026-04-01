defmodule FermixCore.Application do
  @moduledoc false

  use Application
  require Logger

  alias FermixCore.Trace

  @impl true
  def start(_type, _args) do
    setup_file_logger()

    children = [
      {Trace, trace_opts()}
    ]

    opts = [strategy: :one_for_one, name: FermixCore.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      Trace.TelemetryHandler.attach()
      {:ok, pid}
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
             formatter:
               {:logger_formatter, %{template: [:time, ~c" ", :level, ~c" ", :msg, ~c"\n"]}}
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
