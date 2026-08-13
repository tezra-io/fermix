defmodule FermixChannels.Mobile.DeviceStore do
  @moduledoc """
  Serialized custody for paired mobile devices.

  Runtime callers use the supervised GenServer facade. Explicit `root:` calls
  are the hermetic test/one-shot seam and never consult the host's real
  `FERMIX_HOME`.
  """

  use GenServer

  defmodule Device do
    @moduledoc "A paired device authenticated by its Noise static public key."

    @enforce_keys [:device_id, :name, :model, :noise_pk, :created_at, :apns_key_salt]
    defstruct @enforce_keys ++ [push_token: nil, last_seen: nil]

    @type t :: %__MODULE__{
            device_id: String.t(),
            name: String.t(),
            model: String.t(),
            noise_pk: <<_::256>>,
            push_token: String.t() | nil,
            created_at: DateTime.t(),
            last_seen: DateTime.t() | nil,
            apns_key_salt: <<_::256>>
          }
  end

  @type server :: GenServer.server()
  @type result(value) :: {:ok, value} | {:error, term()}

  @file_mode 0o600
  @dir_mode 0o700
  @required_fields [:device_id, :name, :model, :noise_pk, :created_at, :apns_key_salt]
  @optional_fields [:push_token, :last_seen]
  @update_fields [:name, :model, :push_token, :last_seen]
  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

  @doc "Start the serialized store for one Fermix home."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "List all paired devices in stable device-id order."
  @spec list() :: result([Device.t()])
  def list, do: list(__MODULE__)

  @spec list(server() | keyword()) :: result([Device.t()])
  def list(opts) when is_list(opts), do: with_root(opts, &read_devices/1)
  def list(server), do: GenServer.call(server, :list)

  @doc "Fetch one device by UUID."
  @spec fetch(String.t()) :: result(Device.t())
  def fetch(device_id) when is_binary(device_id), do: fetch(__MODULE__, device_id)

  @spec fetch(String.t(), keyword()) :: result(Device.t())
  def fetch(device_id, opts) when is_binary(device_id) and is_list(opts) do
    with_root(opts, &fetch_from_root(&1, device_id))
  end

  @spec fetch(server(), String.t()) :: result(Device.t())
  def fetch(server, device_id) when is_binary(device_id),
    do: GenServer.call(server, {:fetch, device_id})

  @doc "Add a new identity, rejecting duplicate UUIDs and Noise keys."
  @spec add(map()) :: result(Device.t())
  def add(attrs) when is_map(attrs), do: add(__MODULE__, attrs)

  @spec add(map(), keyword()) :: result(Device.t())
  def add(attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, device} <- validate_new(attrs),
         {:ok, result} <- with_root(opts, &add_to_root(&1, device)) do
      {:ok, result}
    end
  end

  @spec add(server(), map()) :: result(Device.t())
  def add(server, attrs) when is_map(attrs), do: GenServer.call(server, {:add, attrs})

  @doc "Update mutable device metadata. Identity and creation time are immutable."
  @spec update(String.t(), map()) :: result(Device.t())
  def update(device_id, attrs) when is_binary(device_id) and is_map(attrs) do
    update(__MODULE__, device_id, attrs)
  end

  @spec update(String.t(), map(), keyword()) :: result(Device.t())
  def update(device_id, attrs, opts)
      when is_binary(device_id) and is_map(attrs) and is_list(opts) do
    with_root(opts, &update_at_root(&1, device_id, attrs))
  end

  @spec update(server(), String.t(), map()) :: result(Device.t())
  def update(server, device_id, attrs) when is_binary(device_id) and is_map(attrs) do
    GenServer.call(server, {:update, device_id, attrs})
  end

  @doc "Delete one paired device."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(device_id) when is_binary(device_id), do: delete(__MODULE__, device_id)

  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(device_id, opts) when is_binary(device_id) and is_list(opts) do
    with_root(opts, &delete_at_root(&1, device_id))
  end

  @spec delete(server(), String.t()) :: :ok | {:error, term()}
  def delete(server, device_id) when is_binary(device_id),
    do: GenServer.call(server, {:delete, device_id})

  @doc "Resolve the device authenticated by a raw 32-byte Noise public key."
  @spec find_by_noise_pk(binary()) :: result(Device.t())
  def find_by_noise_pk(noise_pk) when is_binary(noise_pk),
    do: find_by_noise_pk(__MODULE__, noise_pk)

  @spec find_by_noise_pk(binary(), keyword()) :: result(Device.t())
  def find_by_noise_pk(noise_pk, opts) when is_binary(noise_pk) and is_list(opts) do
    with_root(opts, &find_noise_at_root(&1, noise_pk))
  end

  @spec find_by_noise_pk(server(), binary()) :: result(Device.t())
  def find_by_noise_pk(server, noise_pk) when is_binary(noise_pk) do
    GenServer.call(server, {:find_by_noise_pk, noise_pk})
  end

  @impl true
  def init(opts) do
    with {:ok, root} <- resolve_root(opts),
         {:ok, _devices} <- read_devices(root) do
      {:ok, root}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:list, _from, root), do: {:reply, read_devices(root), root}

  def handle_call({:fetch, id}, _from, root),
    do: {:reply, fetch_from_root(root, id), root}

  def handle_call({:add, attrs}, _from, root),
    do: {:reply, add_validated(root, attrs), root}

  def handle_call({:update, id, attrs}, _from, root),
    do: {:reply, update_at_root(root, id, attrs), root}

  def handle_call({:delete, id}, _from, root),
    do: {:reply, delete_at_root(root, id), root}

  def handle_call({:find_by_noise_pk, key}, _from, root),
    do: {:reply, find_noise_at_root(root, key), root}

  defp add_validated(root, attrs) do
    with {:ok, device} <- validate_new(attrs) do
      add_to_root(root, device)
    end
  end

  defp add_to_root(root, device) do
    with {:ok, devices} <- read_devices(root),
         :ok <- reject_duplicate_id(devices, device),
         :ok <- reject_duplicate_noise(devices, device),
         :ok <- write_devices(root, [device | devices]) do
      {:ok, device}
    end
  end

  defp update_at_root(root, device_id, attrs) do
    with :ok <- validate_device_id(device_id),
         {:ok, updates} <- validate_updates(attrs),
         {:ok, devices} <- read_devices(root),
         {:ok, existing} <- find_device(devices, device_id),
         {:ok, updated} <- apply_updates(existing, updates),
         :ok <- write_devices(root, replace_device(devices, updated)) do
      {:ok, updated}
    end
  end

  defp delete_at_root(root, device_id) do
    with :ok <- validate_device_id(device_id),
         {:ok, devices} <- read_devices(root),
         {:ok, _device} <- find_device(devices, device_id),
         :ok <- write_devices(root, Enum.reject(devices, &(&1.device_id == device_id))) do
      :ok
    end
  end

  defp fetch_from_root(root, device_id) do
    with :ok <- validate_device_id(device_id),
         {:ok, devices} <- read_devices(root) do
      find_device(devices, device_id)
    end
  end

  defp find_noise_at_root(root, noise_pk) do
    with :ok <- validate_binary32(:noise_pk, noise_pk),
         {:ok, devices} <- read_devices(root) do
      case Enum.find(devices, &(&1.noise_pk == noise_pk)) do
        %Device{} = device -> {:ok, device}
        nil -> {:error, {:noise_identity_not_found, Base.encode64(noise_pk)}}
      end
    end
  end

  defp read_devices(root) do
    with :ok <- ensure_mobile_dir(root) do
      read_store(store_path(root))
    end
  end

  defp read_store(path) do
    case File.lstat(path) do
      {:error, :enoent} -> {:ok, []}
      {:ok, %{type: :regular, mode: mode}} -> decode_store(path, mode)
      {:ok, %{type: type}} -> {:error, {:unsafe_file_type, path, type, :regular}}
      {:error, reason} -> {:error, {:devices_unreadable, path, reason}}
    end
  end

  defp decode_store(path, mode) do
    with :ok <- validate_mode(path, mode, @file_mode),
         {:ok, contents} <- read_file(path),
         {:ok, document} <- decode_toml(path, contents),
         {:ok, devices} <- decode_rows(path, document) do
      validate_loaded_uniqueness(path, devices)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:devices_unreadable, path, reason}}
    end
  end

  defp decode_toml(path, contents) do
    case TomlElixir.decode(contents) do
      {:ok, document} -> {:ok, document}
      {:error, reason} -> {:error, {:devices_decode_failed, path, reason}}
    end
  end

  defp decode_rows(path, %{"devices" => rows}) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, devices} ->
      case decode_device(row) do
        {:ok, device} -> {:cont, {:ok, [device | devices]}}
        {:error, reason} -> {:halt, {:error, {:invalid_device_row, path, index, reason}}}
      end
    end)
    |> then(fn
      {:ok, devices} -> {:ok, Enum.reverse(devices)}
      {:error, _reason} = error -> error
    end)
  end

  defp decode_rows(_path, %{} = document) when map_size(document) == 0, do: {:ok, []}
  defp decode_rows(path, document), do: {:error, {:invalid_devices_document, path, document}}

  defp decode_device(row) when is_map(row) do
    attrs = %{
      device_id: row["device_id"],
      name: row["name"],
      model: row["model"],
      noise_pk: decode_base64(row["noise_pk"]),
      push_token: row["push_token"],
      created_at: decode_datetime(row["created_at"]),
      last_seen: decode_optional_datetime(row["last_seen"]),
      apns_key_salt: decode_base64(row["apns_key_salt"])
    }

    validate_decoded(attrs)
  end

  defp decode_device(row), do: {:error, {:invalid_row_type, row}}

  defp validate_decoded(attrs) do
    case Enum.find(attrs, fn {_key, value} -> match?({:decode_error, _}, value) end) do
      {field, {:decode_error, reason}} -> {:error, {:invalid_device, field, reason}}
      nil -> validate_new(attrs)
    end
  end

  defp decode_base64(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> decoded
      :error -> {:decode_error, :invalid_base64}
    end
  end

  defp decode_base64(value), do: {:decode_error, {:invalid_base64_value, value}}

  defp decode_datetime(%DateTime{} = value), do: value

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> datetime
      _other -> {:decode_error, :invalid_datetime}
    end
  end

  defp decode_datetime(value), do: {:decode_error, {:invalid_datetime_value, value}}
  defp decode_optional_datetime(nil), do: nil
  defp decode_optional_datetime(value), do: decode_datetime(value)

  defp validate_new(attrs) do
    with :ok <- validate_keys(attrs, @required_fields, @optional_fields),
         :ok <- validate_device_id(attrs[:device_id]),
         :ok <- validate_text(:name, attrs[:name]),
         :ok <- validate_text(:model, attrs[:model]),
         :ok <- validate_binary32(:noise_pk, attrs[:noise_pk]),
         :ok <- validate_optional_text(:push_token, attrs[:push_token]),
         :ok <- validate_datetime(:created_at, attrs[:created_at]),
         :ok <- validate_optional_datetime(:last_seen, attrs[:last_seen]),
         :ok <- validate_binary32(:apns_key_salt, attrs[:apns_key_salt]) do
      {:ok, struct!(Device, Map.take(attrs, @required_fields ++ @optional_fields))}
    end
  end

  defp validate_updates(attrs) do
    unknown = Map.keys(attrs) -- @update_fields

    with true <- map_size(attrs) > 0 or {:error, {:invalid_device_update, :empty}},
         true <- unknown == [] or {:error, {:invalid_device_update_fields, unknown}},
         :ok <- validate_present(attrs, :name, &validate_text/2),
         :ok <- validate_present(attrs, :model, &validate_text/2),
         :ok <- validate_present(attrs, :push_token, &validate_optional_text/2),
         :ok <- validate_present(attrs, :last_seen, &validate_optional_datetime/2) do
      {:ok, attrs}
    end
  end

  defp validate_present(attrs, key, validator) do
    if Map.has_key?(attrs, key), do: validator.(key, attrs[key]), else: :ok
  end

  defp validate_keys(attrs, required, optional) do
    keys = Map.keys(attrs)
    missing = required -- keys
    unknown = keys -- (required ++ optional)

    cond do
      missing != [] -> {:error, {:invalid_device, :missing_fields, missing}}
      unknown != [] -> {:error, {:invalid_device, :unknown_fields, unknown}}
      true -> :ok
    end
  end

  defp validate_device_id(id) when is_binary(id) do
    if Regex.match?(@uuid_regex, id),
      do: :ok,
      else: {:error, {:invalid_device, :device_id, :invalid_uuid}}
  end

  defp validate_device_id(_id), do: {:error, {:invalid_device, :device_id, :invalid_uuid}}

  defp validate_text(_field, value) when is_binary(value) and byte_size(value) in 1..255, do: :ok
  defp validate_text(field, _value), do: {:error, {:invalid_device, field, :invalid_text}}

  defp validate_optional_text(_field, nil), do: :ok
  defp validate_optional_text(field, value), do: validate_text(field, value)

  defp validate_binary32(_field, value) when is_binary(value) and byte_size(value) == 32, do: :ok
  defp validate_binary32(field, _value), do: {:error, {:invalid_device, field, :invalid_length}}

  defp validate_datetime(_field, %DateTime{}), do: :ok
  defp validate_datetime(field, _value), do: {:error, {:invalid_device, field, :invalid_datetime}}

  defp validate_optional_datetime(_field, nil), do: :ok
  defp validate_optional_datetime(field, value), do: validate_datetime(field, value)

  defp apply_updates(device, updates) do
    with :ok <- validate_last_seen_progress(device.last_seen, updates),
         updated = struct!(device, updates),
         :ok <- validate_text(:name, updated.name),
         :ok <- validate_text(:model, updated.model),
         :ok <- validate_optional_text(:push_token, updated.push_token),
         :ok <- validate_optional_datetime(:last_seen, updated.last_seen) do
      {:ok, updated}
    end
  end

  defp validate_last_seen_progress(_existing, updates) when not is_map_key(updates, :last_seen),
    do: :ok

  defp validate_last_seen_progress(nil, _updates), do: :ok

  defp validate_last_seen_progress(%DateTime{} = existing, %{last_seen: %DateTime{} = attempted}) do
    if DateTime.compare(attempted, existing) in [:eq, :gt],
      do: :ok,
      else: {:error, {:last_seen_regression, existing, attempted}}
  end

  defp validate_last_seen_progress(%DateTime{} = existing, %{last_seen: attempted}),
    do: {:error, {:last_seen_regression, existing, attempted}}

  defp reject_duplicate_id(devices, device) do
    if Enum.any?(devices, &(&1.device_id == device.device_id)),
      do: {:error, {:duplicate_device_id, device.device_id}},
      else: :ok
  end

  defp reject_duplicate_noise(devices, device) do
    if Enum.any?(devices, &(&1.noise_pk == device.noise_pk)),
      do: {:error, {:duplicate_noise_identity, Base.encode64(device.noise_pk)}},
      else: :ok
  end

  defp validate_loaded_uniqueness(path, devices) do
    ids = Enum.map(devices, & &1.device_id)
    keys = Enum.map(devices, & &1.noise_pk)

    cond do
      length(Enum.uniq(ids)) != length(ids) ->
        {:error, {:duplicate_device_ids_on_disk, path}}

      length(Enum.uniq(keys)) != length(keys) ->
        {:error, {:duplicate_noise_identities_on_disk, path}}

      true ->
        {:ok, Enum.sort_by(devices, & &1.device_id)}
    end
  end

  defp find_device(devices, device_id) do
    case Enum.find(devices, &(&1.device_id == device_id)) do
      %Device{} = device -> {:ok, device}
      nil -> {:error, {:device_not_found, device_id}}
    end
  end

  defp replace_device(devices, updated) do
    Enum.map(devices, fn device ->
      if device.device_id == updated.device_id, do: updated, else: device
    end)
  end

  defp write_devices(root, devices) do
    path = store_path(root)
    temp = temp_path(path)

    with :ok <- ensure_mobile_dir(root),
         {:ok, encoded} <- encode_devices(path, devices),
         :ok <- write_temp(path, temp, encoded),
         :ok <- rename_temp(path, temp) do
      :ok
    else
      {:error, reason} -> cleanup_temp(temp, reason)
    end
  end

  defp encode_devices(path, devices) do
    document = %{
      "devices" => devices |> Enum.sort_by(& &1.device_id) |> Enum.map(&encode_device/1)
    }

    case TomlElixir.encode(document) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, {:devices_encode_failed, path, reason}}
    end
  end

  defp encode_device(device) do
    %{
      "device_id" => device.device_id,
      "name" => device.name,
      "model" => device.model,
      "noise_pk" => Base.encode64(device.noise_pk),
      "created_at" => DateTime.to_iso8601(device.created_at),
      "apns_key_salt" => Base.encode64(device.apns_key_salt)
    }
    |> maybe_put("push_token", device.push_token)
    |> maybe_put("last_seen", encode_datetime(device.last_seen))
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp write_temp(path, temp, encoded) do
    with :ok <- File.write(temp, encoded, [:binary, :exclusive]),
         :ok <- File.chmod(temp, @file_mode) do
      :ok
    else
      {:error, reason} -> {:error, {:devices_write_failed, path, reason}}
    end
  end

  defp rename_temp(path, temp) do
    case File.rename(temp, path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:devices_write_failed, path, reason}}
    end
  end

  defp cleanup_temp(temp, original_reason) do
    case File.rm(temp) do
      :ok ->
        {:error, original_reason}

      {:error, :enoent} ->
        {:error, original_reason}

      {:error, cleanup_reason} ->
        {:error, {:devices_cleanup_failed, original_reason, temp, cleanup_reason}}
    end
  end

  defp ensure_mobile_dir(root) do
    dir = mobile_dir(root)

    case File.lstat(dir) do
      {:error, :enoent} -> create_mobile_dir(dir)
      {:ok, %{type: :directory, mode: mode}} -> validate_mode(dir, mode, @dir_mode)
      {:ok, %{type: type}} -> {:error, {:unsafe_file_type, dir, type, :directory}}
      {:error, reason} -> {:error, {:devices_dir_unwritable, dir, reason}}
    end
  end

  defp create_mobile_dir(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, @dir_mode) do
      :ok
    else
      {:error, reason} -> {:error, {:devices_dir_unwritable, dir, reason}}
    end
  end

  defp validate_mode(path, mode, expected) do
    actual = Bitwise.band(mode, 0o777)
    if actual == expected, do: :ok, else: {:error, {:unsafe_permissions, path, actual, expected}}
  end

  defp with_root(opts, callback) do
    with {:ok, root} <- resolve_root(opts), do: callback.(root)
  end

  defp resolve_root(opts) do
    unknown = Keyword.keys(opts) -- [:root, :name]
    root = Keyword.get(opts, :root) || default_root()

    cond do
      unknown != [] -> {:error, {:invalid_device_store_options, unknown}}
      not is_binary(root) or root == "" -> {:error, {:invalid_device_store_root, root}}
      true -> {:ok, Path.expand(root)}
    end
  end

  defp default_root do
    System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
  end

  defp mobile_dir(root), do: Path.join(root, "mobile")
  defp store_path(root), do: Path.join(mobile_dir(root), "devices.toml")

  defp temp_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    "#{path}.tmp.#{suffix}"
  end
end
