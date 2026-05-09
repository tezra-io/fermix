defmodule Fermix.CLI do
  @moduledoc """
  Top-level CLI dispatcher invoked by the Burrito-wrapped binary.

  Routes argv to the subcommand modules under `Fermix.CLI.*` and returns
  an integer exit status. Subcommands deferred beyond Stage 4
  (`upgrade`, `doctor`) are not registered here; unknown commands fall
  through to `usage/0` with a non-zero exit so users get a clear error
  rather than a silent stub.
  """

  alias Fermix.CLI.AgentsCommand
  alias Fermix.CLI.AuthCommand
  alias Fermix.CLI.CapabilitiesCommand
  alias Fermix.CLI.ChatCommand
  alias Fermix.CLI.Doctor
  alias Fermix.CLI.HealthCommand
  alias Fermix.CLI.LogsCommand
  alias Fermix.CLI.RestartCommand
  alias Fermix.CLI.Run
  alias Fermix.CLI.ServiceCommand
  alias Fermix.CLI.Setup
  alias Fermix.CLI.StartCommand
  alias Fermix.CLI.StatusCommand
  alias Fermix.CLI.StopCommand
  alias Fermix.CLI.UpgradeCommand
  alias Fermix.CLI.Version

  @doc """
  Dispatch entry point.

  Returns the integer exit status. The Burrito entry point in
  `FermixCore.Application` is responsible for calling `System.halt/1`
  with this value once the CLI returns.
  """
  @help_flags ~w(help --help -h)
  @version_flags ~w(version --version)

  @spec main([String.t()]) :: non_neg_integer()
  def main(argv) when is_list(argv) do
    case argv do
      [] -> usage(2)
      [cmd | rest] -> dispatch(cmd, rest)
    end
  end

  defp dispatch(cmd, _rest) when cmd in @help_flags, do: usage(0)
  defp dispatch(cmd, _rest) when cmd in @version_flags, do: Version.run()
  defp dispatch("setup", rest), do: Setup.run(rest)
  defp dispatch("auth", rest), do: AuthCommand.run(rest)
  defp dispatch("ask", rest), do: ChatCommand.run(rest)
  defp dispatch("chat", rest), do: ChatCommand.run(rest)
  defp dispatch("run", rest), do: Run.run(rest)
  defp dispatch("service", rest), do: ServiceCommand.run(rest)
  defp dispatch("start", rest), do: StartCommand.run(rest)
  defp dispatch("stop", rest), do: StopCommand.run(rest)
  defp dispatch("restart", rest), do: RestartCommand.run(rest)
  defp dispatch("status", rest), do: StatusCommand.run(rest)
  defp dispatch("health", rest), do: HealthCommand.run(rest)
  defp dispatch("agents", rest), do: AgentsCommand.run(rest)
  defp dispatch("capabilities", rest), do: CapabilitiesCommand.run(rest)
  defp dispatch("logs", rest), do: LogsCommand.run(rest)
  defp dispatch("upgrade", rest), do: UpgradeCommand.run(rest)
  defp dispatch("doctor", rest), do: Doctor.run(rest)
  defp dispatch(unknown, _rest), do: unknown_command(unknown)

  @spec usage(non_neg_integer()) :: non_neg_integer()
  defp usage(exit_status) do
    out = if exit_status == 0, do: :stdio, else: :stderr

    IO.puts(out, """
    fermix — Elixir-native multi-agent platform

    Usage:
      fermix setup [--print-state] [--reconfigure] [--import-codex] [--openai-api-key VALUE]
                   [--provider openai|openai_codex|anthropic]
                   [--default-model VALUE] [--reasoning-effort none|minimal|low|medium|high|xhigh]
                   [--telegram-bot-token VALUE] ...
      fermix auth   login   [--no-browser] [--port N] [--timeout SECONDS]
      fermix auth   status
      fermix auth   logout
      fermix ask    [--stdin] [--session ID] [--timeout MS] [--json] MESSAGE...
      fermix chat   [--stdin] [--session ID] [--timeout MS] [--json] MESSAGE...
      fermix run                        Start the daemon in the foreground
      fermix service install   [--user|--system]   Install OS service unit
      fermix service uninstall [--user|--system]   Remove OS service unit
      fermix start             [--user|--system]   Start the installed OS service
      fermix stop              [--user|--system]   Stop the installed OS service
      fermix restart           [--user|--system]   Restart the installed OS service
      fermix status [--full] [--json]             Show daemon and overview status
      fermix health [--json]                      Show daemon-evaluated health
      fermix agents [--json]                      Show main-agent and worker status
      fermix capabilities [--kind KIND] [--json]  Show registered capabilities
      fermix logs   [-f] [-n LINES]                Show daemon log file
      fermix upgrade [--check]                     Self-update from signed releases
      fermix doctor  [--full]                      Run post-install diagnostics
      fermix version                               Print version
      fermix help                                  Show this message
    """)

    exit_status
  end

  @spec unknown_command(String.t()) :: non_neg_integer()
  defp unknown_command(cmd) do
    IO.puts(:stderr, "fermix: unknown command: #{cmd}")
    usage(2)
  end
end
