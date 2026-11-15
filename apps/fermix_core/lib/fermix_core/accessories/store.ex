defmodule FermixCore.Accessories.Store do
  @moduledoc """
  The accessory pairing store of one Fermix home (M91 §07, D7, D14):

    * `<home>/accessories/` — mode `0700`;
    * `host_key` — the host key's 32-byte private scalar, mode `0600`, made
      once (`ensure_host_key/1`) and never replaced: an accessory stores its
      public key at enrollment, so a new one would unpair every accessory;
    * `accessories.json` — the enrolled accessories' records, mode `0600`:
      `{"v": 1, "accessories": [{accessory_id, accessory_pk, kind, name,
      port_hint, enrolled_at}]}`, sorted by ID, at most `max_records/0`;
    * `voice_device.json` — the voice device the owner chose, mode `0600`:
      `{"v": 1, "device": "desktop" | "accessory:<accessory_id>"}`; absent is
      this Mac's own audio. Only an enrolled accessory can be chosen, and
      forgetting the chosen one makes this Mac the voice device again first.

  Every write goes to a temporary file in the same directory, is synced, and
  is then published in one step, so a reader sees the old file or the new one,
  never half of one; a failed write removes its temporary file. The host key
  is published with a hard link, which refuses to replace one that appeared
  meanwhile. Reads hold every file and the directory to their type and mode,
  never follow a symlink, and never create anything. The files travel with
  the home (archives and Always On moves); `Home.DeviceLocal` drops only an
  interrupted write's temporary file.

  Every function takes the home explicitly and never reads `FERMIX_HOME`.
  Callers serialize writes to one home (the accessory link's own process
  will); the files hold no secret but the host key.
  """

  alias FermixCore.Accessories.HostKey
  alias FermixCore.Accessories.P256
  alias FermixCore.Accessories.Record

  @dir "accessories"
  @host_key_file "host_key"
  @records_file "accessories.json"
  @voice_device_file "voice_device.json"
  @version 1
  @max_records 8
  @dir_mode 0o700
  @file_mode 0o600
  @kind ~r/\A[a-z][a-z0-9_]{0,15}\z/
  @max_name_bytes 64
  @max_hint_bytes 64

  @type home :: Path.t()
  @type error :: term()
  @type voice_device :: :desktop | {:accessory, String.t()}

  @doc "How many accessories one home may enroll."
  @spec max_records() :: pos_integer()
  def max_records, do: @max_records

  @doc "The store's directory."
  @spec dir(home()) :: Path.t()
  def dir(home) when is_binary(home) and home != "", do: Path.join(home, @dir)

  @doc "The host key's file."
  @spec host_key_path(home()) :: Path.t()
  def host_key_path(home) when is_binary(home) and home != "",
    do: Path.join(dir(home), @host_key_file)

  @doc "The records' file."
  @spec records_path(home()) :: Path.t()
  def records_path(home) when is_binary(home) and home != "",
    do: Path.join(dir(home), @records_file)

  @doc "The voice device's file."
  @spec voice_device_path(home()) :: Path.t()
  def voice_device_path(home) when is_binary(home) and home != "",
    do: Path.join(dir(home), @voice_device_file)

  # -- the host key ----------------------------------------------------------------

  @doc "This home's host key, `:absent` before the first pairing made it."
  @spec load_host_key(home()) :: {:ok, HostKey.t()} | :absent | {:error, error()}
  def load_host_key(home) when is_binary(home) and home != "" do
    with :ok <- dir_state(home) |> present_or(:absent),
         :ok <- entry(host_key_path(home), :regular, @file_mode) |> present_or(:absent) do
      read_host_key(host_key_path(home))
    end
  end

  @doc """
  This home's host key, made on first use. Refused, never replaced, when the
  file is unsafe or not a key, and when accessories are enrolled without one:
  they hold the old key, so a new one would leave every one of them unpaired.
  `opts` takes `:link` (default `File.ln/2`), the test seam for another writer
  publishing first.
  """
  @spec ensure_host_key(home(), keyword()) :: {:ok, HostKey.t()} | {:error, error()}
  def ensure_host_key(home, opts \\ []) when is_binary(home) and home != "" and is_list(opts) do
    link = Keyword.get(opts, :link, &File.ln/2)

    case load_host_key(home) do
      :absent -> create_host_key(home, link)
      loaded -> loaded
    end
  end

  defp read_host_key(path) do
    with {:ok, private} <- read(path) do
      case HostKey.from_private(private) do
        {:ok, key} -> {:ok, key}
        {:error, :invalid_host_key} -> {:error, {:invalid_host_key, path}}
      end
    end
  end

  defp create_host_key(home, link) do
    with :ok <- no_records(home),
         :ok <- ensure_dir(home) do
      {_public, private} = P256.generate()
      publish_exclusive(host_key_path(home), private, link)
    end
  end

  defp no_records(home) do
    case entry(records_path(home), :regular, @file_mode) do
      {:error, {:missing, _path}} -> :ok
      _present_or_broken -> {:error, {:host_key_missing, host_key_path(home)}}
    end
  end

  defp publish_exclusive(path, private, link) do
    temp = temp_path(path)

    case write_synced(temp, private) do
      :ok -> link_published(temp, path, link)
      {:error, reason} -> discard(temp, {:write_failed, path, reason})
    end
  end

  # The temporary file goes whatever the link did; a key the link published
  # stays the home's even if that removal fails, which is said beside it.
  defp link_published(temp, path, link) do
    linked = link.(temp, path)

    case remove(temp) do
      :ok -> after_link(linked, path)
      {:error, reason} -> {:error, {:cleanup_failed, after_link(linked, path), temp, reason}}
    end
  end

  # Another writer's key published first is the home's key: load it.
  defp after_link(:ok, path), do: read_host_key(path)
  defp after_link({:error, :eexist}, path), do: read_host_key(path)
  defp after_link({:error, reason}, path), do: {:error, {:write_failed, path, reason}}

  # -- the records -------------------------------------------------------------------

  @doc "The enrolled accessories, sorted by ID; none before the first."
  @spec list(home()) :: {:ok, [Record.t()]} | {:error, error()}
  def list(home) when is_binary(home) and home != "" do
    path = records_path(home)

    with :ok <- dir_state(home) |> present_or(:none),
         :ok <- entry(path, :regular, @file_mode) |> present_or(:none),
         {:ok, contents} <- read(path) do
      decode_records(path, contents)
    else
      :none -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  @doc "One enrolled accessory."
  @spec fetch(home(), String.t()) :: {:ok, Record.t()} | {:error, :unknown_accessory | error()}
  def fetch(home, accessory_id) when is_binary(accessory_id) do
    with {:ok, records} <- list(home) do
      case Enum.find(records, &(&1.accessory_id == accessory_id)) do
        %Record{} = record -> {:ok, record}
        nil -> {:error, :unknown_accessory}
      end
    end
  end

  @doc """
  Records an enrolled accessory, replacing its earlier record. Needs the host
  key, and refuses a record of the host's own key or one whose ID is not its
  key's digest. `opts` takes `:rename` (default `File.rename/2`), the test
  seam for a failed publish.
  """
  @spec put(home(), Record.t(), keyword()) :: :ok | {:error, error()}
  def put(home, %Record{} = record, opts \\ []) when is_list(opts) do
    with {:ok, host} <- host_key_for_records(home),
         :ok <- valid_record(record, host),
         {:ok, records} <- list(home),
         {:ok, records} <- upsert(records, record) do
      write_records(home, records, opts)
    end
  end

  @doc """
  Erases one accessory's record. When it is the voice device, this Mac becomes
  the voice device first, so a failed erase leaves a record that is no longer
  chosen and never a choice of one that is gone. `opts` as `put/3`.
  """
  @spec forget(home(), String.t(), keyword()) :: :ok | {:error, :unknown_accessory | error()}
  def forget(home, accessory_id, opts \\ []) when is_binary(accessory_id) and is_list(opts) do
    with {:ok, records} <- list(home),
         {[_forgotten], kept} <- Enum.split_with(records, &(&1.accessory_id == accessory_id)),
         :ok <- unchoose(home, accessory_id) do
      write_records(home, kept, opts)
    else
      {[], _kept} -> {:error, :unknown_accessory}
      {:error, _reason} = error -> error
    end
  end

  defp unchoose(home, accessory_id) do
    case load_voice_device(home) do
      {:ok, {:accessory, ^accessory_id}} -> write_voice_device(home, :desktop)
      {:ok, _other} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # -- the voice device ----------------------------------------------------------------

  @doc "The voice device the owner chose: `:desktop` until an accessory is."
  @spec load_voice_device(home()) :: {:ok, voice_device()} | {:error, error()}
  def load_voice_device(home) when is_binary(home) and home != "" do
    path = voice_device_path(home)

    with :ok <- dir_state(home) |> present_or(:none),
         :ok <- entry(path, :regular, @file_mode) |> present_or(:none),
         {:ok, contents} <- read(path) do
      decode_voice_device(path, contents)
    else
      :none -> {:ok, :desktop}
      {:error, _reason} = error -> error
    end
  end

  @doc "Chooses the voice device: `:desktop`, or an enrolled accessory."
  @spec put_voice_device(home(), voice_device()) :: :ok | {:error, :unknown_accessory | error()}
  def put_voice_device(home, :desktop) when is_binary(home) and home != "",
    do: write_voice_device(home, :desktop)

  def put_voice_device(home, {:accessory, accessory_id} = device) when is_binary(accessory_id) do
    with {:ok, _record} <- fetch(home, accessory_id), do: write_voice_device(home, device)
  end

  defp write_voice_device(home, device) do
    path = voice_device_path(home)
    temp = temp_path(path)
    contents = Jason.encode!(%{"v" => @version, "device" => device_name(device)})

    with :ok <- ensure_dir(home),
         :ok <- write_synced(temp, contents),
         :ok <- File.rename(temp, path) do
      :ok
    else
      {:error, {:write_failed, _path, _reason}} = error -> error
      {:error, reason} -> discard(temp, {:write_failed, path, reason})
    end
  end

  defp device_name(:desktop), do: "desktop"
  defp device_name({:accessory, accessory_id}), do: "accessory:" <> accessory_id

  defp decode_voice_device(path, contents) do
    case Jason.decode(contents) do
      {:ok, %{"v" => @version, "device" => "desktop"}} -> {:ok, :desktop}
      {:ok, %{"v" => @version, "device" => "accessory:" <> id}} -> accessory_device(path, id)
      _other -> {:error, {:invalid_voice_device, path}}
    end
  end

  defp accessory_device(path, id) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, id),
      do: {:ok, {:accessory, id}},
      else: {:error, {:invalid_voice_device, path}}
  end

  defp host_key_for_records(home) do
    case load_host_key(home) do
      {:ok, host} -> {:ok, host}
      :absent -> {:error, :no_host_key}
      {:error, _reason} = error -> error
    end
  end

  defp valid_record(%Record{accessory_pk: pk}, %HostKey{public: pk}),
    do: {:error, :host_key_reuse}

  defp valid_record(%Record{} = record, _host) do
    case record_problem(record) do
      nil -> :ok
      field -> {:error, {:invalid_record, field}}
    end
  end

  defp upsert(records, record) do
    others = Enum.reject(records, &(&1.accessory_id == record.accessory_id))

    if length(others) >= @max_records,
      do: {:error, :records_full},
      else: {:ok, Enum.sort_by([record | others], & &1.accessory_id)}
  end

  defp write_records(home, records, opts) do
    path = records_path(home)
    rename = Keyword.get(opts, :rename, &File.rename/2)
    temp = temp_path(path)

    with :ok <- ensure_dir(home),
         :ok <- write_synced(temp, encode_records(records)),
         :ok <- rename.(temp, path) do
      :ok
    else
      {:error, reason} -> discard(temp, {:write_failed, path, reason})
    end
  end

  # -- the records' file ---------------------------------------------------------------

  defp encode_records(records) do
    Jason.encode!(%{"v" => @version, "accessories" => Enum.map(records, &encode_record/1)})
  end

  defp encode_record(%Record{} = record) do
    %{
      "accessory_id" => record.accessory_id,
      "accessory_pk" => Base.encode16(record.accessory_pk, case: :lower),
      "kind" => record.kind,
      "name" => record.name,
      "port_hint" => record.port_hint,
      "enrolled_at" => DateTime.to_iso8601(record.enrolled_at)
    }
  end

  # A store is never zero bytes once written, so an empty one is a lost write,
  # not "no accessories".
  defp decode_records(path, ""), do: {:error, {:records_empty, path}}

  defp decode_records(path, contents) do
    case Jason.decode(contents) do
      {:ok, %{"v" => @version, "accessories" => rows}}
      when is_list(rows) and length(rows) <= @max_records ->
        decode_rows(path, rows)

      {:ok, %{"v" => @version}} ->
        {:error, {:invalid_records, path, :accessories}}

      {:ok, _other} ->
        {:error, {:invalid_records, path, :v}}

      {:error, _reason} ->
        {:error, {:invalid_records, path, :json}}
    end
  end

  defp decode_rows(path, rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case decode_row(row) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        {:error, field} -> {:halt, {:error, {:invalid_records, path, field}}}
      end
    end)
    |> then(fn
      {:ok, records} -> {:ok, Enum.sort_by(records, & &1.accessory_id)}
      error -> error
    end)
  end

  defp decode_row(%{} = row) do
    with {:ok, pk} <- hex_field(row, "accessory_pk"),
         {:ok, enrolled_at} <- time_field(row, "enrolled_at") do
      record = %Record{
        accessory_id: row["accessory_id"],
        accessory_pk: pk,
        kind: row["kind"],
        name: row["name"],
        port_hint: row["port_hint"],
        enrolled_at: enrolled_at
      }

      case record_problem(record) do
        nil -> {:ok, record}
        field -> {:error, field}
      end
    end
  end

  defp decode_row(_row), do: {:error, :row}

  defp hex_field(row, key) do
    with value when is_binary(value) <- row[key],
         {:ok, raw} <- Base.decode16(value, case: :lower) do
      {:ok, raw}
    else
      _invalid -> {:error, String.to_existing_atom(key)}
    end
  end

  defp time_field(row, key) do
    with value when is_binary(value) <- row[key],
         {:ok, time, _offset} <- DateTime.from_iso8601(value) do
      {:ok, time}
    else
      _invalid -> {:error, String.to_existing_atom(key)}
    end
  end

  # The first field of a record that is not one the store writes, or nil. The
  # checks run in order, so the ID is compared only with a key that is a point.
  defp record_problem(%Record{} = record) do
    Enum.find_value(record_checks(), fn {field, valid?} ->
      if valid?.(record), do: nil, else: field
    end)
  end

  defp record_checks do
    [
      accessory_pk: &P256.valid_public_key?(&1.accessory_pk),
      accessory_id: &(&1.accessory_id == P256.id(&1.accessory_pk)),
      kind: &(is_binary(&1.kind) and Regex.match?(@kind, &1.kind)),
      name: &text?(&1.name, @max_name_bytes),
      port_hint: &(is_nil(&1.port_hint) or text?(&1.port_hint, @max_hint_bytes)),
      enrolled_at: &match?(%DateTime{}, &1.enrolled_at)
    ]
  end

  defp text?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max//1 and String.printable?(value)

  # -- files ---------------------------------------------------------------------------

  defp dir_state(home), do: entry(dir(home), :directory, @dir_mode)

  # A missing file or directory becomes `absent`; anything else passes through.
  defp present_or({:error, {:missing, _path}}, absent), do: absent
  defp present_or(result, _absent), do: result

  defp entry(path, type, mode) do
    case File.lstat(path) do
      {:ok, %{type: ^type, mode: actual}} -> mode(path, Bitwise.band(actual, 0o777), mode)
      {:ok, %{type: other}} -> {:error, {:unsafe_file_type, path, other, type}}
      {:error, :enoent} -> {:error, {:missing, path}}
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  defp mode(_path, mode, mode), do: :ok
  defp mode(path, actual, expected), do: {:error, {:unsafe_permissions, path, actual, expected}}

  defp ensure_dir(home) do
    path = dir(home)

    case dir_state(home) do
      {:error, {:missing, ^path}} -> make_dir(path)
      result -> result
    end
  end

  defp make_dir(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.mkdir(path),
         :ok <- File.chmod(path, @dir_mode) do
      :ok
    else
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  # The bytes are synced before the publish: a publish that reaches the disk
  # ahead of its data is how a power loss leaves an empty file.
  defp write_synced(temp, contents) do
    case File.open(temp, [:write, :binary, :exclusive, :raw]) do
      {:ok, io} -> fill(io, temp, contents)
      {:error, reason} -> {:error, reason}
    end
  end

  defp fill(io, temp, contents) do
    result =
      with :ok <- File.chmod(temp, @file_mode),
           :ok <- :file.write(io, contents) do
        :file.sync(io)
      end

    case {result, File.close(io)} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _close} -> {:error, reason}
      {:ok, {:error, reason}} -> {:error, reason}
    end
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # A failed write's temporary file goes with it; failing to remove it is said
  # beside the write's own failure, never instead of it.
  defp discard(temp, error) do
    case remove(temp) do
      :ok -> {:error, error}
      {:error, reason} -> {:error, {:cleanup_failed, error, temp, reason}}
    end
  end

  defp temp_path(path), do: "#{path}.tmp.#{System.unique_integer([:positive, :monotonic])}"
end
