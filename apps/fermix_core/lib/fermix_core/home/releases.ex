defmodule FermixCore.Home.Releases do
  @moduledoc """
  The release table fermix.ai serves at `https://fermix.ai/install/releases`,
  read, and the release an Always On server may install from it (M97, design
  §3.4: the server leads). Pure: text in, answers out; nothing here fetches.

  The site writes the table (`src/lib/engine-releases.ts` and its pin
  scripts in tezra-io/fermix-site), one row a line:

      format 1
      latest <version>
      <version> <sha256> <file>
      app <engine_version> <system> <app_version>

  A digest row pins one file of an engine release; an `app` row says that
  release of the macOS or Linux app is published and carries that engine
  release, which the table pins.

  A row is known by its first word: `latest`, `app`, or a MAJOR.MINOR.PATCH
  version for a digest row. A row known otherwise is ignored, as
  `scripts/install.sh` reads only its two- and three-field rows, and so is an
  `app` row for a system other than macOS and Linux: a table that gains a
  kind of row never stops a server that does not know it. Ignoring a row can
  only withhold a release, never make one eligible. A known row that is
  malformed refuses the whole table, by name, as does a table that does not
  end with a newline (one cut short), lists no release, or names a `latest`
  that is not its highest release. The site refuses all of these too, and
  every row it does not know: the two readers are held to the same tables,
  `test/fixtures/release_tables` here and `tests/fixtures/release-tables`
  there, byte copies of each other.

  `eligible/3`: a release is eligible once, for each system of the computers
  that keep the home's backup copies, an `app` row carries exactly that
  engine release, since a computer restores a backup with the engine its app
  carries. The newest such release at or above the running one is the one
  to install; with no backup systems, the latest. A server never installs a
  release below the one it runs. A computer whose system is not known
  (`:unknown`) could need either app, so it holds every release above the
  running one.
  """

  # In the order `waits_for` lists them.
  @backup_systems [:macos, :linux, :unknown]
  @systems %{"macos" => :macos, "linux" => :linux}

  defstruct latest: nil, releases: %{}, apps: []

  @type system :: :macos | :linux
  @type app :: %{engine: String.t(), system: system(), version: String.t()}
  @typedoc "Each pinned release's files, mapped to their SHA-256."
  @type files :: %{optional(String.t()) => String.t()}
  @type t :: %__MODULE__{
          latest: String.t() | nil,
          releases: %{optional(String.t()) => files()},
          apps: [app()]
        }
  @type table :: t()
  @typedoc "The system of a computer that keeps backup copies, `:unknown` when it has not said."
  @type backup_system :: system() | :unknown
  @type held :: %{version: String.t(), waits_for: [backup_system()]}
  @type eligibility :: %{eligible: String.t() | nil, held: held() | nil, ahead_of_apps: boolean()}

  @doc """
  Reads the table. `{:error, {:invalid_table, reason}}` names the row or
  line that refused it.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, {:invalid_table, String.t()}}
  def parse(text) when is_binary(text) do
    case read(text) do
      {:ok, table} -> {:ok, table}
      {:error, reason} -> {:error, {:invalid_table, reason}}
    end
  end

  @doc """
  What a server running `running` may install, given the systems of the
  computers that keep backup copies:

    * `eligible`: the newest release, at or above `running`, that every
      listed system has an app for that carries exactly it; `nil` if none.
      With `:unknown` listed, `running` itself when the table lists it, else
      `nil`.
    * `held`: the newest release above that (or above `running` when none
      is eligible), which is not eligible yet, and the systems whose app it
      waits for (`:unknown` among them when listed); `nil` when there is none.
    * `ahead_of_apps`: `running` is above the newest engine some listed
      system's app carries (it was installed past the gate). A listed system
      no `app` row names, `:unknown` included, counts as behind it, unless the
      table has no `app` rows at all: such a table predates them and says
      nothing about the apps.
  """
  @spec eligible(t(), String.t(), [backup_system()]) :: eligibility()
  def eligible(%__MODULE__{} = table, running, backup_systems)
      when is_binary(running) and is_list(backup_systems) do
    floor = version_key!(running)
    systems = systems!(backup_systems)
    newest_first = table.releases |> Map.keys() |> Enum.sort_by(&version_key/1, :desc)

    eligible =
      if :unknown in systems,
        do: listed(table, running),
        else:
          Enum.find(
            newest_first,
            &(version_key(&1) >= floor and waits_for(table, &1, systems) == [])
          )

    %{
      eligible: eligible,
      held: held(table, List.first(newest_first), eligible || running, systems),
      ahead_of_apps: ahead_of_apps?(table, floor, systems)
    }
  end

  defp read(text) do
    with {:ok, lines} <- lines(text),
         {:ok, latest, rows} <- header(lines),
         {:ok, table} <- read_rows(rows, %__MODULE__{latest: latest}),
         :ok <- check_releases(table) do
      check_apps(table)
    end
  end

  defp lines(text) do
    if String.ends_with?(text, "\n") do
      {:ok, text |> binary_part(0, byte_size(text) - 1) |> String.split("\n")}
    else
      {:error, "does not end with a newline"}
    end
  end

  defp header(["format 1", "latest " <> latest | rows]) do
    if version?(latest),
      do: {:ok, latest, rows},
      else: {:error, ~s(the second line is not "latest <version>")}
  end

  defp header(["format 1" | _rows]), do: {:error, ~s(the second line is not "latest <version>")}
  defp header(_lines), do: {:error, ~s(the first line is not "format 1")}

  defp read_rows(rows, table) do
    rows
    |> Enum.reduce_while({:ok, table}, fn row, {:ok, acc} ->
      case read_row(String.split(row, " "), row, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> in_file_order()
  end

  defp in_file_order({:ok, table}), do: {:ok, %{table | apps: Enum.reverse(table.apps)}}
  defp in_file_order(error), do: error

  defp read_row(["app" | fields], row, table), do: app_row(fields, row, table)

  defp read_row(["latest" | _fields], row, _table),
    do: {:error, ~s("#{row}" repeats the latest line)}

  defp read_row(["format" | _fields], row, _table),
    do: {:error, ~s("#{row}" repeats the format line)}

  defp read_row([first | fields], row, table) do
    if version?(first), do: digest_row(first, fields, row, table), else: {:ok, table}
  end

  defp digest_row(version, [digest, file], row, table) do
    files = Map.get(table.releases, version, %{})

    cond do
      not sha256?(digest) or file == "" ->
        malformed_digest(row)

      Map.has_key?(files, file) ->
        {:error, "#{file} of #{version} is listed twice"}

      true ->
        {:ok, %{table | releases: Map.put(table.releases, version, Map.put(files, file, digest))}}
    end
  end

  defp digest_row(_version, _fields, row, _table), do: malformed_digest(row)

  defp malformed_digest(row), do: {:error, ~s("#{row}" is not "<version> <sha256> <file>")}

  defp app_row([engine, system, version], row, table) do
    cond do
      not version?(engine) or not version?(version) or system == "" ->
        malformed_app(row)

      not Map.has_key?(@systems, system) ->
        {:ok, table}

      true ->
        add_app(table, %{engine: engine, system: Map.fetch!(@systems, system), version: version})
    end
  end

  defp app_row(_fields, row, _table), do: malformed_app(row)

  defp malformed_app(row),
    do: {:error, ~s("#{row}" is not "app <engine_version> <system> <app_version>")}

  # An app release carries one engine release, so it is listed once.
  defp add_app(table, %{system: system, version: version} = app) do
    if Enum.any?(table.apps, &(&1.system == system and &1.version == version)) do
      {:error, "#{system} app #{version} is listed twice"}
    else
      {:ok, %{table | apps: [app | table.apps]}}
    end
  end

  defp check_releases(%__MODULE__{releases: releases}) when map_size(releases) == 0,
    do: {:error, "lists no release"}

  defp check_releases(%__MODULE__{latest: latest, releases: releases}) do
    highest = releases |> Map.keys() |> Enum.max_by(&version_key/1)

    if latest == highest,
      do: :ok,
      else: {:error, "latest is #{latest}, not the highest listed release #{highest}"}
  end

  defp check_apps(%__MODULE__{apps: apps, releases: releases} = table) do
    case Enum.find(apps, &(not Map.has_key?(releases, &1.engine))) do
      nil ->
        {:ok, table}

      app ->
        {:error,
         "#{app.system} app #{app.version} carries engine #{app.engine}, which the table does not pin"}
    end
  end

  # The newest release is held when it is above what the server would run
  # after this update; being above the newest eligible release (or above
  # `running`, when none is), it is not eligible, so it waits for some system.
  defp held(_table, nil, _floor, _systems), do: nil

  defp held(table, newest, floor, systems) do
    if version_key(newest) > version_key(floor),
      do: %{version: newest, waits_for: waits_for(table, newest, systems)},
      else: nil
  end

  # No `app` row names `:unknown`, so it waits for every release.
  defp waits_for(table, engine, systems) do
    Enum.reject(systems, fn system ->
      Enum.any?(table.apps, &(&1.engine == engine and &1.system == system))
    end)
  end

  # With `:unknown` listed nothing above `running` is eligible; staying on it is.
  defp listed(table, running),
    do: if(Map.has_key?(table.releases, running), do: running, else: nil)

  defp ahead_of_apps?(%__MODULE__{apps: []}, _floor, _systems), do: false
  defp ahead_of_apps?(table, floor, systems), do: Enum.any?(systems, &ahead_of?(table, floor, &1))

  defp ahead_of?(table, floor, system) do
    case for(%{system: ^system, engine: engine} <- table.apps, do: version_key(engine)) do
      [] -> true
      carried -> floor > Enum.max(carried)
    end
  end

  defp systems!(backup_systems) do
    case Enum.reject(backup_systems, &(&1 in @backup_systems)) do
      [] ->
        Enum.filter(@backup_systems, &(&1 in backup_systems))

      other ->
        raise ArgumentError,
              "backup systems are :macos, :linux or :unknown, got: #{inspect(other)}"
    end
  end

  defp version_key!(version) do
    if version?(version),
      do: version_key(version),
      else:
        raise(ArgumentError, "running is not a MAJOR.MINOR.PATCH version: #{inspect(version)}")
  end

  # Compared as numbers, so 0.10.0 is above 0.9.0.
  defp version_key(version),
    do: version |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()

  defp version?(text), do: Regex.match?(~r/\A\d+\.\d+\.\d+\z/, text)
  defp sha256?(text), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, text)
end
