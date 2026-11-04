defmodule FermixCore.Home.EngineCeiling do
  @moduledoc """
  The newest Fermix a server may run (Always On's move back, design §6): a
  server always runs exactly the engine version of the computers it serves
  as primary for, from its first install and every night after, so the home
  can always move back to one of them (a home a newer engine wrote is refused
  by an older one's restore, `FermixCore.Home.Archive`).

  The primary records each desktop's engine version from that desktop's
  `hello` (`app_version`, which a desktop engine fills with its own version;
  `FermixChannels.Mobile.Session`), one file per desktop under
  `<home>/device/engine_ceiling/`, named by its device id:

      {"v": 1, "version": "0.17.0", "seen_at": "2031-06-01T09:00:00Z"}

  `device/` stays on this machine and through a move back
  (`FermixCore.Home.DeviceLocal`), so a home never carries another machine's
  record; one left from an earlier tenure is written again by the next
  desktop's `hello`. Each file is `0600` under a `0700` directory, written
  whole to a temporary file of its own and renamed, so two desktops saying
  `hello` at once never lose each other's.

  The ceiling (`ceiling/2`) is the oldest version among the desktops seen in
  the last #{30} days: a desktop unseen longer drops out, and its file goes
  at the next record. `nil` when none was seen. `home.status` answers it as
  `update_ceiling`, and the server's nightly update installs exactly that
  version (`packaging/cloud/first-boot.sh`'s `fermix-update`).
  """

  @dir "engine_ceiling"
  @version 1
  @window_s 30 * 86_400
  @dir_mode 0o700
  @file_mode 0o600
  # Desktops seen within the window, at most; the schema's bound on a
  # primary's desktops.
  @max_entries 64
  @device_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @type error ::
          {:invalid_device_id, term()}
          | {:invalid_version, term()}
          | {:invalid_entry, Path.t()}
          | {:too_many, pos_integer()}
          | {:file, Path.t(), File.posix()}

  @doc "Where the desktops' versions live under `home`."
  @spec dir(Path.t()) :: Path.t()
  def dir(home) when is_binary(home) and home != "", do: Path.join([home, "device", @dir])

  @doc """
  Records that the desktop `device_id` runs Fermix `version`, seen at `now`,
  and removes the entries of desktops unseen for longer than the window.
  """
  @spec record(Path.t(), term(), term(), DateTime.t()) :: :ok | {:error, error()}
  def record(home, device_id, version, %DateTime{} = now) when is_binary(home) and home != "" do
    with :ok <- valid_device_id(device_id),
         :ok <- valid_version(version),
         :ok <- make_dirs(home),
         :ok <- write_entry(home, device_id, version, now),
         {:ok, entries} <- entries(home) do
      drop_stale(entries, now)
    end
  end

  @doc """
  The oldest version among the desktops seen in the window before `now`:
  `{:ok, nil}` when none was. An entry Fermix did not write is named, never
  read as a version.
  """
  @spec ceiling(Path.t(), DateTime.t()) :: {:ok, String.t() | nil} | {:error, error()}
  def ceiling(home, %DateTime{} = now) when is_binary(home) and home != "" do
    with {:ok, entries} <- entries(home) do
      entries
      |> Enum.filter(&seen_within?(&1, now))
      |> Enum.map(& &1.version)
      |> Enum.min_by(&Version.parse!/1, Version, fn -> nil end)
      |> then(&{:ok, &1})
    end
  end

  # -- entries ----------------------------------------------------------------

  defp entries(home) do
    dir = dir(home)

    case File.ls(dir) do
      {:ok, names} when length(names) > @max_entries -> {:error, {:too_many, length(names)}}
      {:ok, names} -> read_entries(dir, Enum.sort(names))
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  # A temporary file a write left behind is no entry.
  defp read_entries(dir, names) do
    names
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case read_entry(Path.join(dir, name)) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp read_entry(file) do
    with {:ok, contents} <- read_file(file),
         {:ok, %{"v" => @version, "version" => version, "seen_at" => seen}} <-
           Jason.decode(contents),
         :ok <- valid_version(version),
         {:ok, seen_at, _offset} <- DateTime.from_iso8601(seen) do
      {:ok, %{file: file, version: version, seen_at: seen_at}}
    else
      {:error, {:file, _path, _reason}} = error -> error
      _not_ours -> {:error, {:invalid_entry, file}}
    end
  end

  defp seen_within?(%{seen_at: seen_at}, now), do: DateTime.diff(now, seen_at) <= @window_s

  defp drop_stale(entries, now) do
    entries
    |> Enum.reject(&seen_within?(&1, now))
    |> Enum.reduce_while(:ok, fn %{file: file}, :ok ->
      case File.rm(file) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:file, file, reason}}}
      end
    end)
  end

  defp write_entry(home, device_id, version, now) do
    file = Path.join(dir(home), "#{String.downcase(device_id)}.json")
    tmp = "#{file}.#{System.unique_integer([:positive])}.tmp"

    contents =
      Jason.encode!(%{
        "v" => @version,
        "version" => version,
        "seen_at" => now |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })

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

  # -- shape and files --------------------------------------------------------

  defp valid_device_id(id) when is_binary(id) do
    if Regex.match?(@device_id, id), do: :ok, else: {:error, {:invalid_device_id, id}}
  end

  defp valid_device_id(id), do: {:error, {:invalid_device_id, id}}

  defp valid_version(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, _parsed} -> :ok
      :error -> {:error, {:invalid_version, version}}
    end
  end

  defp valid_version(version), do: {:error, {:invalid_version, version}}

  defp make_dirs(home) do
    with :ok <- make_dir(Path.join(home, "device")), do: make_dir(dir(home))
  end

  defp make_dir(dir) do
    case File.mkdir(dir) do
      :ok -> file_op(File.chmod(dir, @dir_mode), dir)
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  defp read_file(file) do
    case File.read(file) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp file_op(:ok, _path), do: :ok
  defp file_op({:error, reason}, path), do: {:error, {:file, path, reason}}
end
