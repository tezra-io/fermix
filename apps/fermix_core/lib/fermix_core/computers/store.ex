defmodule FermixCore.Computers.Store do
  @moduledoc """
  What the home last heard from each of its computers (M97 §3.2, §17), kept
  on the primary so a computer that is away is still listed with its last
  offers and engine version: one file per computer under
  `<home>/device/computers/`, named by its device id:

      {"v": 1, "engine_version": "0.19.0", "seen_at": "2031-06-01T09:00:00Z",
       "offers_rev": "0f1e2d3c4b5a6978", "offers": [{"id": "files", "state": "on"}]}

  Each field is written by the one place that hears it: the engine version
  and when it was seen by the session's `hello` (`FermixChannels.Mobile.Session`),
  the offers and their revision by `Computers.Registry` when an `offers`
  event arrives, and `seen_at` again by the Registry when the session ends,
  so an away computer's last-seen time is when the home last heard it. A
  record merges its fields into the file and keeps the rest.

  `device/` stays on this machine and through a move back
  (`FermixCore.Home.DeviceLocal`). Each file is `0600` under a `0700`
  directory, written whole to a temporary file of its own and renamed, so
  two computers written at once never lose each other's. At most #{64}
  files: the schema's bound on a primary's computers. A file Fermix did not
  write is named, never read as a record.

  It supersedes `device/engine_ceiling/`. Each computer's engine version is
  what it stands by against this server (`Computers.Versions`, M97 §3.4).
  """

  alias FermixCore.Computers.Offers

  @dir "computers"
  @version 1
  @dir_mode 0o700
  @file_mode 0o600
  @max_entries 64
  @device_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  @fields [:engine_version, :seen_at, :offers_rev, :offers]

  @typedoc "One computer's record."
  @type entry :: %{
          engine_version: String.t() | nil,
          seen_at: DateTime.t() | nil,
          offers_rev: String.t() | nil,
          offers: [Offers.offer()]
        }

  @type error ::
          {:invalid_device_id, term()}
          | {:invalid_field, atom(), term()}
          | {:invalid_entry, Path.t()}
          | {:too_many, pos_integer()}
          | {:file, Path.t(), File.posix()}

  @doc "Where the computers' records live under `home`."
  @spec dir(Path.t()) :: Path.t()
  def dir(home) when is_binary(home) and home != "", do: Path.join([home, "device", @dir])

  @doc """
  Merges `fields` (`engine_version`, `seen_at`, `offers_rev`, `offers`) into
  the record of computer `device_id`, keeping every field it does not name.
  """
  @spec record(Path.t(), String.t(), map()) :: :ok | {:error, error()}
  def record(home, device_id, fields)
      when is_binary(home) and home != "" and is_map(fields) do
    with :ok <- valid_device_id(device_id),
         :ok <- valid_fields(fields),
         :ok <- make_dirs(home),
         {:ok, current} <- current(home, device_id) do
      write_entry(home, device_id, Map.merge(current, Map.take(fields, @fields)))
    end
  end

  @doc "Every computer's record, by device id."
  @spec read_all(Path.t()) :: {:ok, %{String.t() => entry()}} | {:error, error()}
  def read_all(home) when is_binary(home) and home != "" do
    dir = dir(home)

    case File.ls(dir) do
      {:ok, names} -> read_entries(dir, names)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  @doc "Drops the record of computer `device_id`; one that has none has nothing to drop."
  @spec forget(Path.t(), String.t()) :: :ok | {:error, error()}
  def forget(home, device_id) when is_binary(home) and home != "" do
    with :ok <- valid_device_id(device_id) do
      file = file(home, device_id)

      case File.rm(file) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, {:file, file, reason}}
      end
    end
  end

  # -- entries ----------------------------------------------------------------

  defp current(home, device_id) do
    file = file(home, device_id)

    case File.read(file) do
      {:ok, contents} -> decode(file, contents)
      {:error, :enoent} -> new_entry(home)
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  # A computer not yet recorded fits within the bound, or is refused.
  defp new_entry(home) do
    case File.ls(dir(home)) do
      {:ok, names} ->
        if Enum.count(names, &String.ends_with?(&1, ".json")) >= @max_entries,
          do: {:error, {:too_many, @max_entries}},
          else: {:ok, empty()}

      {:error, reason} ->
        {:error, {:file, dir(home), reason}}
    end
  end

  defp empty, do: %{engine_version: nil, seen_at: nil, offers_rev: nil, offers: []}

  # A temporary file a write left behind is no entry.
  defp read_entries(dir, names) do
    entries = names |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.sort()

    if length(entries) > @max_entries,
      do: {:error, {:too_many, @max_entries}},
      else: Enum.reduce_while(entries, {:ok, %{}}, &read_entry(dir, &1, &2))
  end

  defp read_entry(dir, name, {:ok, acc}) do
    file = Path.join(dir, name)

    with {:ok, contents} <- read_file(file),
         {:ok, entry} <- decode(file, contents) do
      {:cont, {:ok, Map.put(acc, Path.rootname(name), entry)}}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp decode(file, contents) do
    with {:ok, %{"v" => @version} = map} <- Jason.decode(contents),
         {:ok, version} <- optional_version(map["engine_version"]),
         {:ok, seen_at} <- optional_time(map["seen_at"]),
         {:ok, rev} <- optional_rev(map["offers_rev"]),
         {:ok, offers} <- stored_offers(Map.get(map, "offers", [])) do
      {:ok, %{engine_version: version, seen_at: seen_at, offers_rev: rev, offers: offers}}
    else
      _not_ours -> {:error, {:invalid_entry, file}}
    end
  end

  defp optional_version(nil), do: {:ok, nil}

  defp optional_version(version) do
    if valid_version?(version), do: {:ok, version}, else: :error
  end

  defp optional_time(nil), do: {:ok, nil}

  defp optional_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> :error
    end
  end

  defp optional_time(_other), do: :error

  defp optional_rev(nil), do: {:ok, nil}
  defp optional_rev(rev), do: if(Offers.rev?(rev), do: {:ok, rev}, else: :error)

  defp stored_offers(list) when is_list(list),
    do: Offers.decode(Jason.encode!(%{"v" => 1, "offers" => list}))

  defp stored_offers(_other), do: :error

  defp write_entry(home, device_id, entry) do
    file = file(home, device_id)
    tmp = "#{file}.#{System.unique_integer([:positive])}.tmp"

    contents =
      Jason.encode!(%{
        "v" => @version,
        "engine_version" => entry.engine_version,
        "seen_at" => entry.seen_at && iso(entry.seen_at),
        "offers_rev" => entry.offers_rev,
        "offers" => Enum.map(entry.offers, &wire/1)
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

  # As the wire carries an offer: its absent fields left out.
  defp wire(offer) do
    offer
    |> Offers.view()
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # -- shape and files --------------------------------------------------------

  defp file(home, device_id), do: Path.join(dir(home), "#{String.downcase(device_id)}.json")

  defp valid_device_id(id) when is_binary(id) do
    if Regex.match?(@device_id, id), do: :ok, else: {:error, {:invalid_device_id, id}}
  end

  defp valid_device_id(id), do: {:error, {:invalid_device_id, id}}

  defp valid_fields(fields) do
    case Enum.find(fields, fn {key, value} -> not valid_field?(key, value) end) do
      nil -> :ok
      {key, value} -> {:error, {:invalid_field, key, value}}
    end
  end

  defp valid_field?(:engine_version, version), do: valid_version?(version)
  defp valid_field?(:seen_at, at), do: match?(%DateTime{}, at)
  defp valid_field?(:offers_rev, rev), do: is_nil(rev) or Offers.rev?(rev)

  defp valid_field?(:offers, offers),
    do: is_list(offers) and length(offers) <= Offers.max_offers()

  defp valid_field?(_key, _value), do: false

  defp valid_version?(version) when is_binary(version),
    do: match?({:ok, _}, Version.parse(version))

  defp valid_version?(_version), do: false

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
