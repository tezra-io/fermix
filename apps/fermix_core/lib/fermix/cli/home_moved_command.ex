defmodule Fermix.CLI.HomeMovedCommand do
  @moduledoc """
  `fermix home mark-moved --to TEXT [--json]` (M75 step 1): retires this home as
  the primary once its archive has left for another host.

  **Entry point.** `run/1` takes the arguments after `mark-moved` and returns
  the exit status; `Fermix.CLI` dispatches `fermix home mark-moved ARGS...` to
  `run(ARGS)`. `run/2` is the same with injected dependencies, for tests.

  It writes `FermixCore.Home.Moved`'s marker under the home this command runs
  against (`FERMIX_HOME`, default `~/.fermix`): the home's current primary
  epoch (`FermixCore.Home.Epoch`), the time now, and `--to`, which names the
  new primary for a person reading a refusal (1 to 128 bytes of printable
  text). From then on the home refuses to boot as the primary
  (`FermixCore.Home.Role`) and runs only in the device role.

  Refused, by name and before anything is written: a running engine
  (`daemon_running`, read through the control socket's `hello`, the probe
  `fermix status` and `fermix home export` use), a probe that cannot tell
  (`mark_moved_failed`), a home with no primary epoch (`epoch_absent`) and a
  home already marked (`already_moved`: the first move stands). A `--to` the
  marker cannot hold is a usage error.

  `--json` prints the CLI envelope (`priv/cli/CONTRACT.md`, "The moved
  result"); without it the result is a few lines on stdout and a refusal one
  sentence on stderr. Exit status: `0` marked, `1` refused, `2` usage error.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.MachineOutput
  alias FermixCore.Home.DaemonProbe
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Moved
  alias FermixCore.Setup.ConfigStore

  @switches [to: :string, json: :boolean]
  @usage "Usage:\n  fermix home mark-moved --to TEXT [--json]"

  @doc "Runs `fermix home mark-moved` against the real home, clock and daemon probe."
  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) when is_list(argv), do: run(argv, [])

  @doc """
  Runs the verb with injected dependencies: `:home` (the home to mark), `:now`
  (a 0-arity clock) and `:hello` (the daemon probe, a 0-arity function
  answering as `Fermix.CLI.Daemon.Client.request_v1/3` does).
  """
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, deps) when is_list(argv) and is_list(deps) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} -> with_destination(opts, deps)
      {_opts, [extra | _rest], []} -> usage_error("unexpected argument: #{extra}")
      {_opts, _argv, invalid} -> usage_error("invalid options: #{inspect(invalid)}")
    end
  end

  @doc "The moved result the envelope carries: the marker as it was written."
  @spec result(Moved.marker()) :: map()
  def result(%{epoch: epoch, moved_at: %DateTime{} = moved_at, to: to})
      when is_integer(epoch) and is_binary(to) do
    %{"epoch" => epoch, "moved_at" => DateTime.to_iso8601(moved_at), "to" => to}
  end

  defp with_destination(opts, deps) do
    case Keyword.fetch(opts, :to) do
      {:ok, to} -> mark(to, Keyword.get(opts, :json, false), deps)
      :error -> usage_error("--to is required")
    end
  end

  defp mark(to, json?, deps) do
    home = Path.expand(Keyword.get_lazy(deps, :home, &ConfigStore.fermix_home/0))

    with :ok <- daemon_stopped(home, deps),
         {:ok, epoch} <- primary_epoch(home),
         marker = %{epoch: epoch, moved_at: now(deps), to: to},
         :ok <- Moved.write(home, marker) do
      report(home, marker, json?)
    else
      # The marker refuses this `--to` before it reads the one on disk, whose
      # own `to` is never this one unless both are unusable.
      {:error, {:invalid_marker, _file, {:to, ^to}}} ->
        usage_error("--to must be 1 to 128 bytes of printable text")

      {:error, reason} ->
        refuse(reason, json?)
    end
  end

  defp daemon_stopped(home, deps),
    do: DaemonProbe.stopped(home, Keyword.take(deps, [:hello]))

  defp primary_epoch(home) do
    case Epoch.read(home) do
      {:ok, epoch} -> {:ok, epoch}
      :absent -> {:error, :epoch_absent}
      {:error, reason} -> {:error, reason}
    end
  end

  # Whole seconds: the marker is read by people, and a second is the finest
  # moment a move is told apart by.
  defp now(deps) do
    clock = Keyword.get(deps, :now, &DateTime.utc_now/0)
    DateTime.truncate(clock.(), :second)
  end

  defp report(_home, marker, true) do
    IO.puts(MachineOutput.ok(result(marker)))
    0
  end

  defp report(home, marker, false) do
    %{"moved_at" => moved_at} = result(marker)
    IO.puts("Marked #{home} moved to #{marker.to} at epoch #{marker.epoch} (#{moved_at}).")

    IO.puts(
      "It no longer starts as the primary; run it in the device role " <>
        "([fermix_core.engine] role = \"device\") or restore a snapshot into an empty home."
    )

    0
  end

  defp refuse(reason, json?) do
    {code, details} = code(reason)
    print_refusal(code, details, json?)
    1
  end

  defp print_refusal(code, details, true), do: IO.puts(MachineOutput.error(code, details))

  defp print_refusal(code, details, false),
    do: IO.puts(:stderr, "fermix home mark-moved: " <> MachineOutput.sentence(code, details))

  defp code(:daemon_running), do: {:daemon_running, []}
  defp code(:epoch_absent), do: {:epoch_absent, []}

  defp code({:already_moved, %{to: to, moved_at: %DateTime{} = at, epoch: epoch}}),
    do: {:already_moved, to: to, date: Date.to_iso8601(DateTime.to_date(at)), epoch: epoch}

  defp code(reason), do: {:mark_moved_failed, output: describe(reason)}

  defp describe({:daemon_probe_failed, reason}),
    do: "could not tell whether Fermix is running (#{probe_error(reason)})"

  defp describe({:invalid_epoch, file, _excerpt}),
    do: "the primary epoch at #{file} is not one Fermix wrote"

  defp describe({:invalid_marker, file, _detail}),
    do: "the moved marker at #{file} is not one Fermix wrote"

  defp describe({:file, path, posix}), do: "#{path}: #{:file.format_error(posix)}"

  defp probe_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp probe_error(reason), do: Client.describe_error(reason)

  defp usage_error(message) do
    IO.puts(:stderr, "fermix home mark-moved: #{message}")
    IO.puts(:stderr, @usage)
    2
  end
end
