defmodule FermixChannels.X.Pairing do
  @moduledoc """
  This installation's half of its Fermix Connect pairing
  (`priv/connect/PROTOCOL.md` §1): the per-home Ed25519 instance key and the
  pairing record, both under `FERMIX_HOME/x/`.

  The key is a raw 32-byte seed in `instance_key`, created on first use and
  never rotated in place; unpairing deletes it. It is a file and not a
  keychain item because keychain items are named by profile, so two homes on
  one Mac would overwrite each other's key (M63 §2). The record,
  `pairing.json`, is written once Connect accepts the key proof and deleted on
  unpair; nothing replaces it. Neither is a setting: every value in the record
  is checked against Connect's own state on every connection and assignment.

  Both files are `0600` in a `0700` directory, written through a temporary file
  and published only where nothing exists yet, so a crash leaves either the old
  state or the new one. Loading is strict: a file of the wrong type or mode, a
  key of the wrong length or a record that does not match the contract is
  refused with its reason, never repaired.

  Tests pass `root:`; production uses `FERMIX_HOME` (or `~/.fermix`).
  """

  alias FermixCore.Setup.ConfigStore

  @enforce_keys [
    :version,
    :origin,
    :instance_id,
    :tenant_id,
    :handle,
    :key_id,
    :key_generation,
    :tenant_generation,
    :connect_key_id,
    :connect_public_key,
    :paired_at
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          version: 1,
          origin: String.t(),
          instance_id: String.t(),
          tenant_id: String.t(),
          handle: String.t(),
          key_id: String.t(),
          key_generation: pos_integer(),
          tenant_generation: pos_integer(),
          connect_key_id: String.t(),
          connect_public_key: String.t(),
          paired_at: String.t()
        }

  @type public_key :: <<_::256>>

  @dir "x"
  @key_file "instance_key"
  @record_file "pairing.json"
  @file_mode 0o600
  @dir_mode 0o700
  @record_max_bytes 4_096

  # The contract's own patterns (protocol.schema.json `$defs`).
  @origin ~r/\Ahttps:\/\/[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:[0-9]{1,5})?\z/
  @opaque_id ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @x_id ~r/\A[1-9][0-9]{0,19}\z/
  @handle ~r/\A@[A-Za-z0-9_]{1,15}\z/
  @key_id ~r/\Ak[0-9a-f]{16}\z/
  @public_key ~r/\A[A-Za-z0-9_-]{43}\z/
  @timestamp ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?Z\z/

  @fields [
    {"version", :version},
    {"origin", :origin},
    {"instance_id", :instance_id},
    {"tenant_id", :tenant_id},
    {"handle", :handle},
    {"key_id", :key_id},
    {"key_generation", :key_generation},
    {"tenant_generation", :tenant_generation},
    {"connect_key_id", :connect_key_id},
    {"connect_public_key", :connect_public_key},
    {"paired_at", :paired_at}
  ]

  @doc "The home the pairing lives under: `:root`, else `FERMIX_HOME` (or `~/.fermix`)."
  @spec root(keyword()) :: String.t()
  def root(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :root) do
      nil ->
        Path.expand(ConfigStore.fermix_home())

      root when is_binary(root) and root != "" ->
        Path.expand(root)

      other ->
        raise ArgumentError, "X pairing root must be a non-empty path, got #{inspect(other)}"
    end
  end

  @spec key_path(keyword()) :: String.t()
  def key_path(opts \\ []) when is_list(opts), do: Path.join(dir(opts), @key_file)

  @spec record_path(keyword()) :: String.t()
  def record_path(opts \\ []) when is_list(opts), do: Path.join(dir(opts), @record_file)

  @doc """
  Whether `value` is an origin the contract accepts (`protocol.schema.json`,
  `$defs/origin`): `https://`, a lowercase host, an optional port, no path and
  no trailing slash. Every signature names it byte for byte, and a record is
  valid for exactly that string.
  """
  @spec origin?(term()) :: boolean()
  def origin?(value) when is_binary(value), do: Regex.match?(@origin, value)
  def origin?(_value), do: false

  @doc """
  The instance's public key, creating the key on first use. An existing key is
  loaded strictly, never replaced: two callers racing to create it both end
  with the one key that was published first.
  """
  @spec ensure_key(keyword()) :: {:ok, public_key()} | {:error, term()}
  def ensure_key(opts \\ []) when is_list(opts) do
    with :ok <- ensure_dir(dir(opts)) do
      case public_key(opts) do
        {:error, {:missing, _path}} -> create_key(key_path(opts), opts)
        result -> result
      end
    end
  end

  @doc "The instance's public key, loaded strictly; it is never created here."
  @spec public_key(keyword()) :: {:ok, public_key()} | {:error, term()}
  def public_key(opts \\ []) when is_list(opts) do
    with {:ok, seed} <- read_seed(key_path(opts)) do
      {public, ^seed} = :crypto.generate_key(:eddsa, :ed25519, seed)
      {:ok, public}
    end
  end

  @doc "`\"k\"` followed by the first 16 hex characters of SHA-256 of the public key."
  @spec key_id(public_key()) :: String.t()
  def key_id(<<_::256>> = public_key) do
    "k" <> binary_part(sha256_hex(public_key), 0, 16)
  end

  @doc "SHA-256 of the public key as 16 groups of four hex characters, as `mobile.status` shows."
  @spec fingerprint(public_key()) :: String.t()
  def fingerprint(<<_::256>> = public_key) do
    hex = sha256_hex(public_key)
    Enum.join(for(<<group::binary-size(4) <- hex>>, do: group), " ")
  end

  @doc """
  The pairing record. `{:error, :unpaired}` when there is none; a record that
  is unreadable or does not match the contract is `{:invalid_record, reason}`.
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, :unpaired | {:invalid_record, term()}}
  def load(opts \\ []) when is_list(opts) do
    path = record_path(opts)

    with :ok <- record_present(path),
         {:ok, bytes} <- read_strict(path, @record_max_bytes) do
      parse_record(bytes)
    else
      {:error, :unpaired} -> {:error, :unpaired}
      {:error, {:invalid_record, _reason}} = error -> error
      {:error, reason} -> {:error, {:invalid_record, reason}}
    end
  end

  @doc """
  Writes the record once. A record that is already there is not replaced
  (`{:error, :already_paired}`): unpairing deletes it first.
  """
  @spec save(t(), keyword()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = record, opts \\ []) when is_list(opts) do
    with {:ok, record} <- record |> to_document() |> parse_document(),
         :ok <- ensure_dir(dir(opts)) do
      publish(record_path(opts), encode(record), :already_paired)
    end
  end

  @doc "Deletes the record and the key; either already absent is not an error."
  @spec delete(keyword()) :: :ok | {:error, term()}
  def delete(opts \\ []) when is_list(opts) do
    with :ok <- remove(record_path(opts)) do
      remove(key_path(opts))
    end
  end

  @doc "Ed25519 signature of `message` with the instance key, which must exist."
  @spec sign(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def sign(message, opts \\ []) when is_binary(message) and is_list(opts) do
    with {:ok, seed} <- read_seed(key_path(opts)) do
      {:ok, :crypto.sign(:eddsa, :none, message, [seed, :ed25519])}
    end
  end

  @doc "Whether `signature` is `public_key`'s Ed25519 signature of `message`."
  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(message, signature, <<_::256>> = public_key)
      when is_binary(message) and is_binary(signature) do
    byte_size(signature) == 64 and
      :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
  end

  def verify(message, signature, _public_key) when is_binary(message) and is_binary(signature),
    do: false

  # --- the key ---------------------------------------------------------------

  defp create_key(path, opts) do
    {_public, seed} = :crypto.generate_key(:eddsa, :ed25519)

    case publish(path, seed, :exists) do
      :ok -> public_key(opts)
      # Another caller published first: its key is the one.
      {:error, :exists} -> public_key(opts)
      {:error, _reason} = error -> error
    end
  end

  defp read_seed(path) do
    case read_strict(path, 32) do
      {:ok, <<_::256>> = seed} -> {:ok, seed}
      {:ok, _other} -> {:error, {:invalid_key, path, :invalid_length}}
      {:error, :unpaired} -> {:error, {:missing, path}}
      {:error, _reason} = error -> error
    end
  end

  # --- the record ------------------------------------------------------------

  defp record_present(path) do
    case File.lstat(path) do
      {:error, :enoent} -> {:error, :unpaired}
      {:ok, _stat} -> :ok
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  defp parse_record(bytes) do
    case Jason.decode(bytes) do
      {:ok, document} when is_map(document) -> wrap_invalid(parse_document(document))
      {:ok, _other} -> {:error, {:invalid_record, :not_an_object}}
      {:error, _decode_error} -> {:error, {:invalid_record, :not_json}}
    end
  end

  defp wrap_invalid({:ok, record}), do: {:ok, record}
  defp wrap_invalid({:error, reason}), do: {:error, {:invalid_record, reason}}

  defp parse_document(document) do
    known = Enum.map(@fields, &elem(&1, 0))

    case Map.keys(document) -- known do
      [] -> parse_fields(document)
      unknown -> {:error, {:unknown_fields, Enum.sort(unknown)}}
    end
  end

  defp parse_fields(document) do
    Enum.reduce_while(@fields, {:ok, %{}}, fn {name, key}, {:ok, acc} ->
      case field(key, Map.get(document, name)) do
        :ok -> {:cont, {:ok, Map.put(acc, key, Map.fetch!(document, name))}}
        {:error, reason} -> {:halt, {:error, {key, reason}}}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, struct!(__MODULE__, fields)}
      {:error, _reason} = error -> error
    end
  end

  defp field(_key, nil), do: {:error, :missing}
  defp field(:version, 1), do: :ok
  defp field(:version, _other), do: {:error, :unsupported_version}
  defp field(:origin, value), do: match(@origin, value)
  defp field(:instance_id, value), do: match(@opaque_id, value)
  defp field(:tenant_id, value), do: match(@x_id, value)
  defp field(:handle, value), do: match(@handle, value)
  defp field(:key_id, value), do: match(@key_id, value)
  defp field(:connect_key_id, value), do: match(@opaque_id, value)
  defp field(:paired_at, value), do: match(@timestamp, value)

  defp field(key, value) when key in [:key_generation, :tenant_generation] do
    if is_integer(value) and value > 0, do: :ok, else: {:error, :not_a_generation}
  end

  defp field(:connect_public_key, value) do
    with :ok <- match(@public_key, value),
         {:ok, <<_::256>>} <- Base.url_decode64(value, padding: false) do
      :ok
    else
      _invalid -> {:error, :not_a_public_key}
    end
  end

  defp match(pattern, value) when is_binary(value) do
    if Regex.match?(pattern, value), do: :ok, else: {:error, :invalid_format}
  end

  defp match(_pattern, _value), do: {:error, :not_a_string}

  defp to_document(%__MODULE__{} = record) do
    Map.new(@fields, fn {name, key} -> {name, Map.fetch!(record, key)} end)
  end

  defp encode(%__MODULE__{} = record) do
    @fields
    |> Enum.map(fn {name, key} -> {name, Map.fetch!(record, key)} end)
    |> Jason.OrderedObject.new()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  # --- files -----------------------------------------------------------------

  defp dir(opts), do: Path.join(root(opts), @dir)

  defp ensure_dir(dir) do
    case File.lstat(dir) do
      {:error, :enoent} -> create_dir(dir)
      {:ok, %{type: :directory, mode: mode}} -> validate_mode(dir, mode, @dir_mode)
      {:ok, %{type: type}} -> {:error, {:unsafe_file_type, dir, type}}
      {:error, reason} -> {:error, {:unreadable, dir, reason}}
    end
  end

  defp create_dir(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, @dir_mode) do
      :ok
    else
      {:error, reason} -> {:error, {:unwritable, dir, reason}}
    end
  end

  # Reads a regular `0600` file of at most `max` bytes. A missing file is
  # `:unpaired`, which each caller names for itself.
  defp read_strict(path, max) do
    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode, size: size}} when size <= max ->
        with :ok <- validate_mode(path, mode, @file_mode), do: read(path)

      {:ok, %{type: :regular}} ->
        {:error, {:too_large, path}}

      {:ok, %{type: type}} ->
        {:error, {:unsafe_file_type, path, type}}

      {:error, :enoent} ->
        {:error, :unpaired}

      {:error, reason} ->
        {:error, {:unreadable, path, reason}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  defp validate_mode(path, mode, expected) do
    actual = Bitwise.band(mode, 0o777)
    if actual == expected, do: :ok, else: {:error, {:unsafe_permissions, path, actual, expected}}
  end

  # Writes `contents` to a `0600` temporary file and links it into place, which
  # fails when `path` already exists: a published file is never overwritten.
  # The temporary file is removed on every path.
  defp publish(path, contents, exists_error) do
    temp = "#{path}.tmp.#{System.unique_integer([:positive, :monotonic])}"

    result =
      with :ok <- write_temp(temp, contents) do
        link(temp, path, exists_error)
      end

    case {result, remove(temp)} do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, {:temp_cleanup_failed, reason}}
      {error, _cleanup} -> error
    end
  end

  defp write_temp(temp, contents) do
    with :ok <- File.write(temp, contents, [:binary, :exclusive]),
         :ok <- File.chmod(temp, @file_mode) do
      :ok
    else
      {:error, reason} -> {:error, {:unwritable, temp, reason}}
    end
  end

  defp link(temp, path, exists_error) do
    case File.ln(temp, path) do
      :ok -> :ok
      {:error, :eexist} -> {:error, exists_error}
      {:error, reason} -> {:error, {:unwritable, path, reason}}
    end
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:unremovable, path, reason}}
    end
  end

  defp sha256_hex(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
