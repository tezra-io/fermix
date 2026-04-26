defmodule Fermix.CLI do
  @moduledoc """
  Top-level CLI dispatcher invoked by the Burrito-wrapped binary.

  Routes argv to the subcommand modules under `Fermix.CLI.*` and returns
  an integer exit status. Subcommands listed in the milestone but not yet
  implemented (`start`, `stop`) print a Stage-4 deferral message and exit
  non-zero — they do not silently delegate to `run`. Subcommands deferred
  beyond Stage 4 (`status`, `logs`, `service`, `upgrade`, `doctor`,
  `uninstall`) are not registered here; unknown commands fall through to
  `usage/0` with a non-zero exit so users get a clear error rather than a
  silent stub.
  """

  alias Fermix.CLI.Run
  alias Fermix.CLI.Setup
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
  defp dispatch("run", rest), do: Run.run(rest)
  defp dispatch("start", _rest), do: stage4_pending("start")
  defp dispatch("stop", _rest), do: stage4_pending("stop")
  defp dispatch(unknown, _rest), do: unknown_command(unknown)

  @spec usage(non_neg_integer()) :: non_neg_integer()
  defp usage(exit_status) do
    out = if exit_status == 0, do: :stdio, else: :stderr

    IO.puts(out, """
    fermix — Elixir-native multi-agent platform

    Usage:
      fermix setup [--print-state] [--openai-api-key VALUE] ...
      fermix run                  Start the daemon in the foreground
      fermix start                (Stage 4) Start the installed OS service
      fermix stop                 (Stage 4) Stop the installed OS service
      fermix version              Print version
      fermix help                 Show this message
    """)

    exit_status
  end

  @spec unknown_command(String.t()) :: non_neg_integer()
  defp unknown_command(cmd) do
    IO.puts(:stderr, "fermix: unknown command: #{cmd}")
    usage(2)
  end

  @spec stage4_pending(String.t()) :: non_neg_integer()
  defp stage4_pending(cmd) do
    IO.puts(
      :stderr,
      "fermix #{cmd}: not implemented — Stage 4 will add launchd/systemd " <>
        "service control. Use `fermix run` to run the daemon in the foreground."
    )

    2
  end
end
