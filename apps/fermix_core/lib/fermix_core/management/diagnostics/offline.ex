defmodule FermixCore.Management.Diagnostics.Offline do
  @moduledoc """
  The offline half of the one diagnostics collector (M38 §11.2, §4.6).

  `FermixCore.Management.Diagnostics` builds the live bundle from a running
  daemon. This module builds the same kind of object with **no daemon at all**,
  which is the state an operator most needs a bundle in: a service that will not
  start, a malformed binding, a listener that cannot bind.

  It is not a second collector. Every field is constructed through
  `Diagnostics.take/2` — the one allowlist — and every free-text leaf goes
  through `Diagnostics.scrub/1` — the one redactor. A source that grows a new
  key does not grow this bundle, because the key is simply never read.

  **Every source answers, including the ones that cannot.** Each is `%{"status",
  "observed_at", "data" | "reason"}` with `available`, `unavailable` or
  `not_applicable`. A stopped daemon, an absent journal, a missing log file and
  the absent graphical session are representable evidence, not reasons to lose
  the whole bundle. Nothing omitted is read as healthy.

  **Bounds are the contract, not a courtesy.** One megabyte encoded, ten seconds
  for the whole collection, five for the journal read, and a result that exceeds
  either is an error rather than a bundle that quietly lost its tail.
  """

  alias Fermix.CLI.Service
  alias Fermix.CLI.Service.Status
  alias Fermix.CLI.ServiceCommand
  alias FermixCore.BuildInfo
  alias FermixCore.Management.Diagnostics
  alias FermixCore.Management.Logs

  @schema_version 1
  @max_bytes 1_048_576
  @deadline_ms 10_000
  @journal_timeout_ms 5_000
  @journal_lines 100
  @log_entries 200
  @engine_manifest "/usr/share/fermix/engine.json"
  @unit "fermix.service"

  # The service facts a bundle may carry. Deliberately not the whole status
  # result: the bound home and the effective unit path name an operator's
  # account and directory layout, which §11.2 excludes, and the state of the
  # binding is the fact a reader needs rather than its path.
  @service_fields ~w(enabled active sub_state pid invocation_id restart_count linger
    path_source alignment binding_state unit_vendor unit_legacy_generated unit_foreign
    unit_need_daemon_reload listener_port listener_source)

  @journal_fields ~w(time level subsystem message source)

  @type report :: %{String.t() => term()}
  @type failure :: :deadline_exceeded | :too_large | {:invalid_encoding, term()}

  @doc "The bundle's own schema version, which is not the management protocol's."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "The encoded ceiling, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Collects the offline bundle.

  The whole collection runs inside one bounded task, so the ten-second deadline
  reaps the journal child with it rather than leaving a subprocess behind. A
  result that cannot be encoded, or that exceeds the ceiling, is an error: a
  claimed bundle nobody can read is worse than a refusal that says why.
  """
  @spec build(keyword()) :: {:ok, report()} | {:error, failure()}
  def build(opts \\ []) when is_list(opts) do
    task = Task.async(fn -> collect(opts, clock(opts)) end)

    case Task.yield(task, Keyword.get(opts, :deadline_ms, @deadline_ms)) do
      {:ok, report} -> bounded(report)
      nil -> shutdown(task)
    end
  end

  defp shutdown(task) do
    _ = Task.shutdown(task, :brutal_kill)
    {:error, :deadline_exceeded}
  end

  defp bounded(report) do
    case Jason.encode(report) do
      {:ok, encoded} when byte_size(encoded) <= @max_bytes -> {:ok, report}
      {:ok, _oversized} -> {:error, :too_large}
      {:error, reason} -> {:error, {:invalid_encoding, reason}}
    end
  end

  defp collect(opts, now) do
    %{
      "schema_version" => @schema_version,
      "generated_at" => now.(),
      "mode" => "offline",
      "sources" => %{
        "engine" => engine(opts, now),
        "service" => service(opts, now),
        "doctor" => doctor(now),
        "logs" => logs(opts, now),
        "secret_backend" => secret_backend(opts, now),
        "desktop_session" => desktop_session(now)
      }
    }
  end

  # ── sources ────────────────────────────────────────────────────────────────

  # The compiled identity plus the verdict on the manifest the package installed
  # beside it. The running identity is what an offline export cannot have, and
  # it is named as unavailable rather than left out.
  defp engine(opts, now) do
    build_info = Keyword.get(opts, :build_info, BuildInfo)
    installed = Status.installed(build_info.public_identity(), manifest(opts))

    available(
      %{
        "installed" => Diagnostics.take(installed, Diagnostics.engine_fields() ++ ["integrity"]),
        "running" => nil,
        "running_status" => "unavailable"
      },
      now
    )
  end

  defp manifest(opts) do
    path = Keyword.get(opts, :engine_manifest_path, @engine_manifest)

    with {:ok, contents} <- File.read(path), do: Jason.decode(contents)
  end

  # The shared service inspector, projected onto the allowlist. Only a packaged
  # engine has a packaged service, and every other distribution says so rather
  # than reporting a unit it does not own.
  defp service(opts, now) do
    service = Keyword.get(opts, :service, Service)

    case service.status(Keyword.get(opts, :service_opts, [])) do
      {:ok, status} ->
        available(Diagnostics.take(service_facts(status), @service_fields), now)

      {:error, :foreign_distribution} ->
        not_applicable("this engine is not a packaged install", now)

      {:error, reason} ->
        unavailable(Diagnostics.scrub(service_reason(reason)), now)
    end
  end

  # The published sentence, not the atom behind it: whoever reads this bundle
  # reads the same words the CLI printed to the operator who sent it.
  defp service_reason(reason), do: ServiceCommand.format_reason(reason)

  defp service_facts(status) do
    binding = Map.get(status, "binding", %{})
    unit = Map.get(status, "unit", %{})
    listener = Map.get(status, "listener", %{})

    status
    |> Map.take(~w(enabled active sub_state pid invocation_id restart_count linger
         path_source alignment))
    |> Map.merge(%{
      "binding_state" => Map.get(binding, "state"),
      "unit_vendor" => Map.get(unit, "vendor"),
      "unit_legacy_generated" => Map.get(unit, "legacy_generated"),
      "unit_foreign" => Map.get(unit, "foreign"),
      "unit_need_daemon_reload" => Map.get(unit, "need_daemon_reload"),
      "listener_port" => Map.get(listener, "port"),
      "listener_source" => Map.get(listener, "source")
    })
  end

  # Doctor's own checks reach the daemon, so an offline run would report a
  # broken engine as a broken host. The absence is the honest answer.
  defp doctor(now) do
    unavailable("Doctor runs against the daemon, which is not being contacted", now)
  end

  # Both named log places (§11.1): the rotating file the daemon owns, and the
  # journal the unit's own streams go to. Each entry carries which one it came
  # from, and each reader carries its own outcome, so a readable file plus an
  # unreadable journal is reported as exactly that.
  defp logs(opts, now) do
    {file_status, entries} = file_entries(opts)
    {journal_status, journal, journal_reason} = journal_entries(opts)

    available(
      %{
        "file_status" => file_status,
        "journal_status" => journal_status,
        "journal_reason" => journal_reason,
        "count" => length(entries) + length(journal),
        "entries" => entries ++ journal
      },
      now
    )
  end

  defp file_entries(opts) do
    reader = Keyword.get(opts, :logs_reader, &Logs.query/1)

    case reader.(%{"limit" => @log_entries}) do
      {:ok, result} -> {"available", labelled(Map.get(result, "entries", []), "file")}
      {:error, _reason} -> {"unavailable", []}
    end
  end

  defp labelled(entries, source) do
    Enum.map(entries, fn entry ->
      entry
      |> Diagnostics.take(Diagnostics.entry_fields())
      |> Map.put("source", source)
    end)
  end

  defp journal_entries(opts) do
    case journal_runner(opts).("journalctl", journal_args()) do
      {output, 0} -> {"available", journal_lines(output), nil}
      :absent -> {"unavailable", [], "journalctl is not installed"}
      :timeout -> {"unavailable", [], "journalctl did not answer in time"}
      {output, _status} -> {"unavailable", [], Diagnostics.scrub(String.trim(output))}
    end
  end

  defp journal_args do
    [
      "--user",
      "-u",
      @unit,
      "-n",
      Integer.to_string(@journal_lines),
      "--no-pager",
      "-o",
      "short-iso"
    ]
  end

  # `short-iso` puts the timestamp first and the rest of the line is the unit's
  # own output, which is operator text and goes through the shared scrubber.
  defp journal_lines(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.take(-@journal_lines)
    |> Enum.map(&journal_entry/1)
  end

  defp journal_entry(line) do
    {time, message} =
      case String.split(line, " ", parts: 2) do
        [time, rest] -> {time, rest}
        [only] -> {nil, only}
      end

    Diagnostics.take(
      %{
        "time" => time,
        "level" => nil,
        "subsystem" => nil,
        "message" => message,
        "source" => "journal"
      },
      @journal_fields
    )
  end

  # Presence only, and never a lookup: an export must not prompt for a keyring
  # or unlock a collection (§11.2). The tool's name is the fact; its path would
  # be a filesystem detail this bundle has no business carrying.
  defp secret_backend(opts, now) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)
    tool = secret_tool(Keyword.get(opts, :os, :os.type()))

    available(%{"tool" => tool, "present" => not is_nil(find.(tool))}, now)
  end

  defp secret_tool({:unix, :darwin}), do: "security"
  defp secret_tool(_other), do: "secret-tool"

  # Supplied by the graphical client, which is the only process inside the
  # session. A lingering daemon's environment is not that session and must never
  # be reconstructed into one (§11.2).
  defp desktop_session(now) do
    unavailable("session facts are supplied by the graphical client", now)
  end

  # ── shapes ─────────────────────────────────────────────────────────────────

  defp available(data, now),
    do: %{"status" => "available", "observed_at" => now.(), "data" => data}

  defp unavailable(reason, now),
    do: %{"status" => "unavailable", "observed_at" => now.(), "reason" => reason}

  defp not_applicable(reason, now),
    do: %{"status" => "not_applicable", "observed_at" => now.(), "reason" => reason}

  # One seam for the clock, so a golden fixture pins the bundle's SHAPE without
  # pinning the second it was collected in.
  defp clock(opts), do: Keyword.get(opts, :now, &default_now/0)

  defp default_now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp journal_runner(opts), do: Keyword.get(opts, :cmd, &default_cmd/2)

  # The child is owned here on every path: it is reaped at the five-second
  # bound, and the port dies with the task the whole collection runs in.
  defp default_cmd(executable, args) do
    case System.find_executable(executable) do
      nil -> :absent
      path -> bounded_cmd(path, args)
    end
  end

  defp bounded_cmd(path, args) do
    task = Task.async(fn -> System.cmd(path, args, stderr_to_stdout: true) end)

    case Task.yield(task, @journal_timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        :timeout
    end
  end
end
