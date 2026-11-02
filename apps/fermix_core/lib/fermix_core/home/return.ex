defmodule FermixCore.Home.Return do
  @moduledoc """
  The one record of a return (Always On's move back to this computer):
  `<home>/device/return.json`, for a server Fermix created and an owner's own
  server alike. `device/` stays on this machine and is kept through the
  return's activation (`FermixCore.Home.DeviceLocal`), so the record is still
  here once this computer is the primary again. The provider ledger
  (`FermixCore.Home.Provision.Ledger`) is never touched by a return.

  Mode `0600` under a `0700` `device/`, written whole to a temporary file and
  renamed, so a reader never sees half of one:

      {
        "v": 1,
        "from": "orchard-server",
        "provider_server": "srv-7f3a",
        "primary_epoch": 5,
        "started_at": "2031-06-01T09:00:00Z",
        "move_started_at": "2031-06-01T09:05:00Z",
        "candidate_id": "c-91",
        "move_id": "m-12",
        "moved_at": "2031-06-01T09:20:00Z",
        "epoch": 7
      }

  - `from` (required): the server's name, as the candidate's `primary.name`
    holds it, so the screen can name it afterwards; 1 to 128 bytes of
    printable text.
  - `started_at` (required): when the owner asked to move back.
  - `provider_server`: the ledger's server, absent for an owner's own server.
  - `primary_epoch`: the epoch the link had seen when the return was asked for.
  - `move_started_at`, `candidate_id`, `move_id`: once the server started the
    move.
  - `moved_at`, `epoch`: once this computer booted as the primary again
    (`done/2`, which the primary's boot runs before anything reads the home;
    one it could not write is remembered, `remember_unrecorded/0`, and each
    `home.status` read of that engine tries it again).

  A record left without its `candidate/` by a crash, or the other way round, is
  harmless: the next return writes both again.
  """

  alias FermixCore.Home.Epoch

  @dir "device"
  @filename "return.json"
  @version 1
  @dir_mode 0o700
  @file_mode 0o600
  @max_text_bytes 128
  @times [:started_at, :move_started_at, :moved_at]
  @texts [:from, :provider_server, :candidate_id, :move_id]
  @epochs [:primary_epoch, :epoch]
  @keys @times ++ @texts ++ @epochs
  @required [:from, :started_at]
  @boot_key {__MODULE__, :boot}

  @type record :: %{
          required(:from) => String.t(),
          required(:started_at) => DateTime.t(),
          optional(:provider_server) => String.t(),
          optional(:primary_epoch) => pos_integer(),
          optional(:move_started_at) => DateTime.t(),
          optional(:candidate_id) => String.t(),
          optional(:move_id) => String.t(),
          optional(:moved_at) => DateTime.t(),
          optional(:epoch) => pos_integer()
        }
  @type error ::
          {:invalid_record, Path.t(), term()} | {:file, Path.t(), File.posix()} | :no_epoch

  @doc "Where the record lives under `home`."
  @spec path(Path.t()) :: Path.t()
  def path(home) when is_binary(home) and home != "", do: Path.join([home, @dir, @filename])

  @doc "The record under `home`: `:absent` when this computer never asked to move back."
  @spec read(Path.t()) :: {:ok, record()} | :absent | {:error, error()}
  def read(home) when is_binary(home) and home != "" do
    file = path(home)

    case File.read(file) do
      {:ok, contents} -> decode(contents, file)
      {:error, :enoent} -> :absent
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  @doc "Writes `record` whole under `home`, refusing one that is not the documented shape."
  @spec write(Path.t(), record()) :: :ok | {:error, error()}
  def write(home, record) when is_binary(home) and home != "" and is_map(record) do
    file = path(home)

    with :ok <- valid(record, file),
         :ok <- make_dir(Path.dirname(file)) do
      write_private(file, encode(record))
    end
  end

  @doc """
  At the primary's boot: the record gains when this computer became the
  primary again (`now`) and the epoch its home holds. A record that has one
  already keeps it, and a computer with no record has nothing to say.
  """
  @spec done(Path.t(), DateTime.t()) :: :ok | {:error, error()}
  def done(home, %DateTime{} = now) when is_binary(home) and home != "" do
    case read(home) do
      {:ok, %{moved_at: _at}} -> :ok
      {:ok, record} -> record_done(home, record, now)
      :absent -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp record_done(home, record, now) do
    case Epoch.read(home) do
      {:ok, epoch} -> write(home, Map.merge(record, %{moved_at: now, epoch: epoch}))
      :absent -> {:error, :no_epoch}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  At boot, once `done/2` could not write: records that this engine's boot
  left the return unrecorded, for the reads after it. Written once, before
  any child starts, like the engine role (`FermixCore.Home.Role`).
  """
  @spec remember_unrecorded() :: :ok
  def remember_unrecorded, do: :persistent_term.put(@boot_key, :unrecorded)

  @doc """
  Whether this engine's boot left the return unrecorded (`:unrecorded`), or
  recorded it or had none to record (`:recorded`, also in a process that
  booted no engine, which so never writes it).
  """
  @spec boot_done() :: :recorded | :unrecorded
  def boot_done, do: :persistent_term.get(@boot_key, :recorded)

  @doc "Removes the record; an absent one is already removed."
  @spec remove(Path.t()) :: :ok | {:error, error()}
  def remove(home) when is_binary(home) and home != "" do
    file = path(home)

    case File.rm(file) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  # -- shape ------------------------------------------------------------------

  defp valid(record, file) do
    cond do
      Enum.any?(@required, &(not Map.has_key?(record, &1))) -> invalid(file, :missing)
      Enum.any?(Map.keys(record), &(&1 not in @keys)) -> invalid(file, :unknown_key)
      true -> valid_values(record, file)
    end
  end

  defp valid_values(record, file) do
    case Enum.find(record, fn {key, value} -> not value?(key, value) end) do
      nil -> :ok
      {key, _value} -> invalid(file, key)
    end
  end

  defp value?(key, %DateTime{}) when key in @times, do: true
  defp value?(key, value) when key in @texts, do: text?(value)
  defp value?(key, value) when key in @epochs, do: is_integer(value) and value >= 1
  defp value?(_key, _value), do: false

  defp text?(value) when is_binary(value),
    do:
      String.valid?(value) and byte_size(value) in 1..@max_text_bytes and
        not Regex.match?(~r/[\p{Cc}]/u, value)

  defp text?(_value), do: false

  defp invalid(file, detail), do: {:error, {:invalid_record, file, detail}}

  defp encode(record) do
    record
    |> Map.new(fn
      {key, %DateTime{} = at} -> {Atom.to_string(key), DateTime.to_iso8601(at)}
      {key, value} -> {Atom.to_string(key), value}
    end)
    |> Map.put("v", @version)
    |> Jason.encode!()
  end

  defp decode(contents, file) do
    with {:ok, %{"v" => @version} = map} <- Jason.decode(contents),
         {:ok, record} <- fields(Map.delete(map, "v")),
         :ok <- valid(record, file) do
      {:ok, record}
    else
      {:error, {:invalid_record, _file, _detail}} = error -> error
      other -> invalid(file, other)
    end
  end

  defp fields(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case field(name, value) do
        {:ok, key, decoded} -> {:cont, {:ok, Map.put(acc, key, decoded)}}
        :error -> {:halt, {:bad_field, name}}
      end
    end)
  end

  defp field(name, value) do
    case Enum.find(@keys, &(Atom.to_string(&1) == name)) do
      nil -> :error
      key when key in @times -> time(key, value)
      key -> {:ok, key, value}
    end
  end

  defp time(key, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, key, at}
      {:error, _reason} -> :error
    end
  end

  defp time(_key, _value), do: :error

  defp make_dir(dir) do
    case File.mkdir(dir) do
      :ok -> file_op(File.chmod(dir, @dir_mode), dir)
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  defp write_private(file, contents) do
    tmp = file <> ".tmp"

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

  defp file_op(:ok, _path), do: :ok
  defp file_op({:error, reason}, path), do: {:error, {:file, path, reason}}
end
