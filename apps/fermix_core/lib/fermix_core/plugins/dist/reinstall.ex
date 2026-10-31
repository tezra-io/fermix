defmodule FermixCore.Plugins.Dist.Reinstall do
  @moduledoc """
  Installs again, for this computer, the plugins a move brought from a
  computer of another system or architecture (M75 L19), right after the move
  made this home the primary.

  A move's staging (`FermixCore.Home.Candidate.Activation.stage/5`) names
  them (`request/2`): the installed plugins of a home restored from another
  host (`Archive.install/5`'s `plugins_to_reinstall`), in
  `<plugins>/reinstall.json` (`0600`, device-local), which moves into place
  with the staged home. The new primary's first boot starts this task
  (`run/1`), which installs each again at the version its lockfile entry
  names, through the plugin installer (`Installer.run_install/2`: the
  catalog's build for this computer, its checksum and its cosign signature).
  A plugin built for any system is already in place, and the installer says
  so without fetching anything.

  Each plugin is recorded as not installed before it is tried, and the record
  is cleared once the installer installs it, so a crash part-way leaves the
  plugin it was installing recorded, never unsaid, and the next boot carries
  on with the rest. A plugin that fails is tried at most #{3} times, 10 s
  apart, then stays recorded as `install`; one the
  catalog has no build of for this computer (`:no_build_for_target`, which
  the move's review named) as `no_build`, without another try. Each outcome
  is logged. `outcome/2` reads the record back for `Plugins.Status`, while the
  lockfile still names the build the move brought: an install the owner runs
  afterwards records another build, and the record then no longer counts.

  The task is `:temporary`: under the core tree's `:rest_for_one` a crash
  restarts nothing after it, and the record says what it left.

  `run/1` options (tests): `:root` (the plugin store, default the home's
  `plugins/`), `:install` (in place of `Installer.run_install/2`), `:sleep`.
  """

  use Task, restart: :temporary

  require Logger

  alias FermixCore.Plugins.Dist.Installer
  alias FermixCore.Plugins.Dist.Store
  alias FermixCore.Setup.ConfigStore

  @filename "reinstall.json"
  @version 1
  @file_mode 0o600
  @max_attempts 3
  @retry_pause_ms 10_000

  @type outcome :: :no_build | :failed | :error | nil

  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts \\ []) when is_list(opts), do: Task.start_link(__MODULE__, :run, [opts])

  @doc "Where the record lives in the plugin store at `root`."
  @spec path(Path.t()) :: Path.t()
  def path(root) when is_binary(root) and root != "", do: Path.join(root, @filename)

  @doc """
  Names `names`, the plugins a move brought from another system, to be
  installed again at the first boot of the primary whose plugin store is
  `root`. Writes nothing for none.
  """
  @spec request(Path.t(), [String.t()]) :: :ok | {:error, term()}
  def request(_root, []), do: :ok

  def request(root, names) when is_binary(root) and is_list(names) do
    true = Enum.all?(names, &(is_binary(&1) and &1 != ""))

    with :ok <- mkdir(root) do
      write(root, %{"pending" => Enum.sort(names), "failed" => %{}})
    end
  end

  @doc "Installs again every plugin `request/2` named and none was tried for yet."
  @spec run(keyword()) :: :ok
  def run(opts \\ []) when is_list(opts) do
    root = Keyword.get_lazy(opts, :root, fn -> ConfigStore.workspace_paths().plugins end)

    case read(root) do
      {:ok, record} -> each(root, record, opts)
      :absent -> :ok
      {:error, reason} -> unreadable(root, reason)
    end
  end

  @doc """
  What the move left of plugin `name` in the store at `root`: `:no_build` (no
  build for this computer), `:failed` (installing it again failed), `nil`
  (nothing, or a later install replaced the build the move brought), or
  `:error` when the record cannot be read.
  """
  @spec outcome(Path.t(), String.t()) :: outcome()
  def outcome(root, name) when is_binary(root) and is_binary(name) do
    case read(root) do
      {:ok, %{"failed" => failed}} -> left(root, name, Map.get(failed, name))
      :absent -> nil
      {:error, _reason} -> :error
    end
  end

  defp left(_root, _name, nil), do: nil

  defp left(root, name, %{"sha256" => sha, "reason" => reason}) do
    case Map.get(Store.installed(root), name) do
      %{"sha256" => ^sha} -> reason_atom(reason)
      _replaced_or_gone -> nil
    end
  end

  defp reason_atom("no_build"), do: :no_build
  defp reason_atom("install"), do: :failed

  # -- run --------------------------------------------------------------------

  # The pending list shrinks by one each step, so this ends.
  defp each(_root, %{"pending" => []}, _opts), do: :ok

  defp each(root, %{"pending" => [name | rest]} = record, opts) do
    record = %{record | "pending" => rest}

    record =
      case Map.get(Store.installed(root), name) do
        %{"version" => version, "sha256" => sha} when is_binary(version) and is_binary(sha) ->
          :ok = write(root, put_failed(record, name, sha, "install"))
          settle(record, name, sha, attempt(root, name, version, opts, 1))

        _not_locked ->
          Logger.warning(
            "plugins: #{name} is no longer installed, so the move has nothing to install again"
          )

          record
      end

    :ok = write(root, record)
    each(root, record, opts)
  end

  defp attempt(root, name, version, opts, try) do
    install = Keyword.get(opts, :install, &Installer.run_install/2)

    case install.(name, root: root, version: version) do
      {:ok, _installed_or_present} ->
        Logger.info(
          "plugins: installed #{name} #{version} again for this computer after the move"
        )

        :installed

      {:error, {:no_build_for_target, target}} ->
        Logger.warning(
          "plugins: #{name} #{version} has no build for #{target}; the move's review named " <>
            "it, and Plugins says it cannot run here"
        )

        :no_build

      {:error, reason} when try < @max_attempts ->
        Logger.warning(
          "plugins: installing #{name} #{version} again failed (#{inspect(reason)}); " <>
            "trying again"
        )

        Keyword.get(opts, :sleep, &Process.sleep/1).(@retry_pause_ms)
        attempt(root, name, version, opts, try + 1)

      {:error, reason} ->
        Logger.error(
          "plugins: #{name} #{version} could not be installed again after the move " <>
            "(#{inspect(reason)}); Plugins says so, and installing it there tries again"
        )

        :failed
    end
  end

  defp settle(record, name, _sha, :installed),
    do: %{record | "failed" => Map.delete(record["failed"], name)}

  defp settle(record, name, sha, :no_build), do: put_failed(record, name, sha, "no_build")
  defp settle(record, name, sha, :failed), do: put_failed(record, name, sha, "install")

  defp put_failed(record, name, sha, reason),
    do: put_in(record, ["failed", name], %{"sha256" => sha, "reason" => reason})

  defp unreadable(root, reason) do
    Logger.error(
      "plugins: #{path(root)} could not be read (#{inspect(reason)}), so no plugin the move " <>
        "brought was installed again"
    )

    :ok
  end

  # -- the record -------------------------------------------------------------

  defp read(root) do
    file = path(root)

    with {:ok, contents} <- File.read(file),
         {:ok, %{"v" => @version, "pending" => pending, "failed" => %{}} = record}
         when is_list(pending) <- Jason.decode(contents) do
      {:ok, record}
    else
      {:error, :enoent} -> :absent
      {:error, reason} when is_atom(reason) -> {:error, {:file, file, reason}}
      _invalid -> {:error, {:invalid_record, file}}
    end
  end

  defp write(root, record) do
    file = path(root)
    tmp = file <> ".tmp"
    contents = Jason.encode!(Map.put(record, "v", @version))

    with :ok <- file_op(File.write(tmp, contents), tmp),
         :ok <- file_op(File.chmod(tmp, @file_mode), tmp),
         :ok <- file_op(File.rename(tmp, file), file) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  defp file_op(:ok, _path), do: :ok
  defp file_op({:error, reason}, path), do: {:error, {:file, path, reason}}
end
