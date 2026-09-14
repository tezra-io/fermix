defmodule Fermix.CLI.DiagnosticsCommand do
  @moduledoc """
  `fermix diagnostics export --offline [--json]` (M38 §4.6, §11.2).

  Tree-less, like `doctor` and `service status`: it runs before daemon
  configuration can abort a boot, which is the whole point — the bundle has to
  be collectable on a host where the daemon will not start.

  **Offline is an explicit mode, never a retry.** A live export is
  `diagnostics.build` over the control socket and belongs to a client that has a
  daemon to ask; this verb refuses without `--offline` rather than quietly
  producing a different, smaller bundle under the same name.

  `--json` prints the shared envelope and nothing else on stdout, which is what
  the graphical client writes to the file a person chose. Human mode prints one
  line per source, so an operator can see which evidence the bundle carries
  before they send it anywhere.
  """

  alias Fermix.CLI.MachineOutput
  alias FermixCore.Management.Diagnostics.Offline

  @switches [offline: :boolean, json: :boolean]

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv), do: run(argv, [])

  @doc false
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run([], deps) when is_list(deps), do: usage(2)
  def run(["export" | rest], deps) when is_list(deps), do: export(rest, deps)
  def run([unknown | _rest], deps) when is_list(deps), do: unknown_subcommand(unknown)

  defp export(argv, deps) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} -> mode(opts, deps)
      {_opts, [extra | _rest], []} -> usage_error("unexpected argument: #{extra}")
      {_opts, _argv, invalid} -> usage_error("invalid options: #{inspect(invalid)}")
    end
  end

  defp mode(opts, deps) do
    if Keyword.get(opts, :offline, false) do
      collect(Keyword.get(opts, :json, false), deps)
    else
      usage_error(
        "a live export is collected by the Fermix application from a running daemon. " <>
          "Pass --offline to collect what this machine can answer without one."
      )
    end
  end

  defp collect(json?, deps) do
    builder = Keyword.get(deps, :builder, &Offline.build/1)

    case builder.(Keyword.get(deps, :builder_opts, [])) do
      {:ok, report} -> report(report, json?)
      {:error, reason} -> refuse(reason, json?)
    end
  end

  defp report(report, true) do
    IO.puts(MachineOutput.ok(report))
    0
  end

  defp report(report, false) do
    Enum.each(source_lines(report), fn {name, line} ->
      IO.puts(String.pad_trailing(name <> ":", 18) <> line)
    end)

    0
  end

  defp source_lines(report) do
    report
    |> Map.get("sources", %{})
    |> Enum.sort_by(fn {name, _source} -> name end)
    |> Enum.map(fn {name, source} -> {name, source_line(source)} end)
  end

  defp source_line(%{"status" => "available"}), do: "available"
  defp source_line(%{"status" => status, "reason" => reason}), do: "#{status} (#{reason})"
  defp source_line(%{"status" => status}), do: status

  # A bundle that could not be collected is an error, never a partial file with
  # a reassuring name: the one thing worse than no diagnostic is a diagnostic
  # that is missing the half explaining the fault.
  defp refuse(reason, true) do
    IO.puts(MachineOutput.error(:diagnostics_unavailable, output: describe(reason)))
    1
  end

  defp refuse(reason, false) do
    IO.puts(
      :stderr,
      "fermix diagnostics: " <>
        MachineOutput.sentence(:diagnostics_unavailable, output: describe(reason))
    )

    1
  end

  defp describe(:deadline_exceeded), do: "collecting it took too long"
  defp describe(:too_large), do: "it grew past the size a bundle may be"
  defp describe({:invalid_encoding, _reason}), do: "it could not be encoded"
  defp describe(other), do: inspect(other)

  defp unknown_subcommand(name) do
    IO.puts(:stderr, "fermix diagnostics: unknown subcommand: #{name}")
    usage(2)
  end

  defp usage_error(message) do
    IO.puts(:stderr, "fermix diagnostics: #{message}")
    usage(2)
  end

  defp usage(exit_status) do
    out = if exit_status == 0, do: :stdio, else: :stderr

    IO.puts(out, """
    Usage:
      fermix diagnostics export --offline [--json]
    """)

    exit_status
  end
end
