defmodule FermixCore.Home.DesktopLink do
  @moduledoc """
  The file that makes a device-role engine a desktop of its primary (M75 §3,
  §6): `<home>/device/desktop.json`, what the desktop relay needs to reach
  the primary, and which secret store holds the desktop's own Noise static
  key (`FermixCore.Home.ComputerKey`, M97 §7.5). It stays on this machine
  (`device/` is device-local).

  The move worker writes it on the source of a move (`write/2`); the
  desktop relay (`FermixChannels.Desktop.Relay`) reads it and raises what the
  file remembers as it learns more (`record_epoch/3`, `record_route/3`). One
  engine boot decides whether the home is linked (`linked?/2`): the device
  role with `desktop.json` present.

  ## `device/desktop.json`

  Mode `0600`, written whole to a temporary file and renamed, so a reader
  never sees half of one:

      {
        "v": 2,
        "device_id": "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e",
        "key": "@keyring",
        "primary": {
          "name": "fermix-vm",
          "gateway_pk": "<32 bytes, standard base64 with padding>",
          "node_id": "<64 lowercase hex digits>",
          "relays": [{"url": "https://relay.example/", "quic_port": 7842}],
          "relays_rev": "<16 lowercase hex digits>",
          "addrs": ["100.101.102.103:4033"]
        },
        "primary_epoch": 5
      }

  - `device_id` is the desktop's row in the primary's `devices.toml` (a UUID).
  - `key` is the secret store that holds the desktop's key: `@keyring` or
    `@file`, `SecretWriter`'s sentinels. Every write names it. A version 1
    file, which an engine before it wrote, has none: its key is the raw file
    `device/desktop_key`, which `ComputerKey.migrate/2` moves into the store
    and records here (`key: nil` until then).
  - `primary.name` is the name a person knows the primary by, at most 128
    bytes of printable text: the server the move went to. `gateway_pk` is the primary's X25519 gateway key
    (the Noise responder's static key) and `node_id` its iroh endpoint id; both
    are the source's own, because the identity bundle moves with the home.
    `relays` (1 to 8) and `relays_rev` are the route the primary last gave,
    in the mobile wire's shape. `addrs` (0 to 8, `hint?/1`) are the direct
    address hints it last gave (`FermixChannels.Mobile.Iroh.Hints`): an
    Always On server's tailnet addresses at its fixed port, which every dial
    to it names. A file without them holds none, and so does a link written
    without them.
  - `primary_epoch` is the highest primary epoch this desktop has seen. It
    never goes down.
  """

  alias FermixCore.Home.Role
  alias FermixCore.Setup.SecretWriter

  @version 2
  # The link an engine before the key moved wrote: no `key`.
  @version_before_key 1
  @dir "device"
  @link_file "desktop.json"
  @file_mode 0o600
  @dir_mode 0o700
  @max_name_bytes 128
  @max_relays 8
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @node_id ~r/\A[0-9a-f]{64}\z/
  @relays_rev ~r/\A[0-9a-f]{16}\z/
  @max_hints 8

  @typedoc "A relay on the route, in the mobile wire's shape."
  @type relay :: %{required(String.t()) => String.t() | pos_integer()}

  @typedoc """
  What `desktop.json` holds. `key` is nil only in a link read from a version
  1 file; a write needs a store.
  """
  @type t :: %{
          device_id: String.t(),
          key: SecretWriter.store() | nil,
          primary: %{
            required(:name) => String.t(),
            required(:gateway_pk) => <<_::256>>,
            required(:node_id) => String.t(),
            required(:relays) => [relay(), ...],
            required(:relays_rev) => String.t(),
            optional(:addrs) => [String.t()]
          },
          epoch: pos_integer()
        }

  @typedoc "The desktop's Noise static keypair."
  @type keypair :: %{private: <<_::256>>, public: <<_::256>>}

  @type error :: {:file, Path.t(), File.posix()} | {:invalid_link, Path.t(), atom()}

  @doc "Where `desktop.json` lives under `home`."
  @spec path(Path.t()) :: Path.t()
  def path(home) when is_binary(home) and home != "", do: Path.join([home, @dir, @link_file])

  @doc """
  Whether an engine that booted as `record` serves `home` as a desktop of its
  primary: the device role, with `desktop.json` present. Decided once per
  boot by each reader (the daemon's management dispatch, the companion socket,
  the device-role tree), so no request takes both paths in one boot.
  """
  @spec linked?(Role.record(), Path.t()) :: boolean()
  def linked?(%{role: :device}, home) when is_binary(home) and home != "",
    do: File.regular?(path(home))

  def linked?(%{role: role}, home) when is_atom(role) and is_binary(home) and home != "",
    do: false

  @doc "Reads and checks `desktop.json`."
  @spec read(Path.t()) :: {:ok, t()} | {:error, error()}
  def read(home) when is_binary(home) and home != "" do
    file = path(home)

    with {:ok, contents} <- read_file(file),
         {:ok, decoded} <- decode_json(contents, file) do
      decode(decoded, file)
    end
  end

  @doc """
  Writes `desktop.json` whole, mode `0600`, creating `device/` (`0700`). A
  link that names no key store is refused (`{:invalid_link, path, :key}`).
  """
  @spec write(Path.t(), t()) :: :ok | {:error, error()}
  def write(home, %{device_id: _id, primary: _primary, epoch: _epoch} = link)
      when is_binary(home) and home != "" do
    file = path(home)

    with {:ok, encoded} <- encode(link, file),
         :ok <- ensure_dir(Path.dirname(file)) do
      atomic_write(file, encoded)
    end
  end

  @doc """
  Raises the highest primary epoch seen to `epoch` and writes it; an epoch at
  or below the one held changes nothing.
  """
  @spec record_epoch(Path.t(), t(), pos_integer()) :: {:ok, t()} | {:error, error()}
  def record_epoch(home, %{epoch: held} = link, epoch)
      when is_binary(home) and is_integer(epoch) and epoch > 0 do
    if epoch > held, do: rewrite(home, %{link | epoch: epoch}), else: {:ok, link}
  end

  @doc """
  Keeps the route the primary last gave: its relays, their revision and its
  address hints (none when it gave none).
  """
  @spec record_route(Path.t(), t(), {[relay()], String.t(), [String.t()]}) ::
          {:ok, t()} | {:error, error()}
  def record_route(home, %{primary: primary} = link, {relays, rev, addrs})
      when is_binary(home) and is_list(relays) and is_binary(rev) and is_list(addrs) do
    route = %{relays: relays, relays_rev: rev, addrs: addrs}

    if Map.take(primary, [:relays, :relays_rev, :addrs]) == route,
      do: {:ok, link},
      else: rewrite(home, %{link | primary: Map.merge(primary, route)})
  end

  @doc """
  Whether `value` is a direct address hint: `ip:port`, an IPv6 address in
  brackets, the port 1 to 65535. A name is none: the helper dials addresses.
  """
  @spec hint?(term()) :: boolean()
  def hint?(value) when is_binary(value) do
    case Regex.run(~r/\A(?:\[([0-9a-fA-F:.]+)\]|([0-9.]+)):([0-9]{1,5})\z/, value) do
      [_all, ipv6, "", port] -> address?(ipv6, 8) and port?(port)
      [_all, "", ipv4, port] -> address?(ipv4, 4) and port?(port)
      nil -> false
    end
  end

  def hint?(_value), do: false

  defp address?(text, size) do
    case :inet.parse_strict_address(String.to_charlist(text)) do
      {:ok, address} -> tuple_size(address) == size
      {:error, _reason} -> false
    end
  end

  defp port?(text), do: String.to_integer(text) in 1..65_535

  defp rewrite(home, link) do
    with :ok <- write(home, link), do: {:ok, link}
  end

  @doc "The sentence a person is shown for an error of this module."
  @spec error_sentence(error()) :: String.t()
  def error_sentence({:file, path, :enoent}),
    do: "Fermix found no #{Path.basename(path)} in this home's device folder."

  def error_sentence({:file, path, reason}),
    do: "Fermix could not read #{Path.basename(path)} (#{:file.format_error(reason)})."

  def error_sentence({:invalid_link, _path, field}),
    do: "The desktop link file is not one Fermix wrote: its #{field} is not valid."

  # -- reading -----------------------------------------------------------------

  defp read_file(file) do
    case File.read(file) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp decode_json(contents, file) do
    case Jason.decode(contents) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _not_an_object -> {:error, {:invalid_link, file, :json}}
    end
  end

  defp decode(%{"v" => @version} = decoded, file) do
    with {:ok, sentinel} <- field(decoded, :key, &SecretWriter.sentinel?/1, file),
         {:ok, store} <- SecretWriter.store_of_sentinel(sentinel),
         {:ok, link} <- decode_link(decoded, file) do
      {:ok, Map.put(link, :key, store)}
    end
  end

  # Its key is still the file `ComputerKey.migrate/2` moves.
  defp decode(%{"v" => @version_before_key} = decoded, file) do
    with {:ok, link} <- decode_link(decoded, file), do: {:ok, Map.put(link, :key, nil)}
  end

  defp decode(_decoded, file), do: {:error, {:invalid_link, file, :v}}

  defp decode_link(decoded, file) do
    with {:ok, device_id} <- field(decoded, :device_id, &uuid?/1, file),
         {:ok, primary} <- primary(decoded["primary"], file),
         {:ok, epoch} <- field(decoded, :primary_epoch, &epoch?/1, file) do
      {:ok, %{device_id: device_id, primary: primary, epoch: epoch}}
    end
  end

  defp primary(%{} = primary, file) do
    with {:ok, name} <- field(primary, :name, &name?/1, file),
         {:ok, key} <- field(primary, :gateway_pk, &base64_key?/1, file),
         {:ok, node_id} <- field(primary, :node_id, &matches?(@node_id, &1), file),
         {:ok, relays} <- field(primary, :relays, &relays?/1, file),
         {:ok, rev} <- field(primary, :relays_rev, &matches?(@relays_rev, &1), file),
         {:ok, addrs} <- hints(primary, file) do
      {:ok,
       %{
         name: name,
         gateway_pk: Base.decode64!(key),
         node_id: node_id,
         relays: relays,
         relays_rev: rev,
         addrs: addrs
       }}
    end
  end

  defp primary(_absent, file), do: {:error, {:invalid_link, file, :primary}}

  # Absent is none: a link from before hints were kept, or a primary with none.
  defp hints(primary, file) do
    if Map.has_key?(primary, "addrs"),
      do: field(primary, :addrs, &hints?/1, file),
      else: {:ok, []}
  end

  @doc "Whether `value` is a link's `addrs`: a list of at most 8 hints (`hint?/1`)."
  @spec hints?(term()) :: boolean()
  def hints?(addrs) when is_list(addrs) and length(addrs) <= @max_hints,
    do: Enum.all?(addrs, &hint?/1)

  def hints?(_addrs), do: false

  defp field(map, key, valid?, file) when is_atom(key) do
    value = Map.get(map, Atom.to_string(key))

    if not is_nil(value) and valid?.(value),
      do: {:ok, value},
      else: {:error, {:invalid_link, file, key}}
  end

  defp uuid?(value), do: matches?(@uuid, value)
  defp matches?(pattern, value), do: is_binary(value) and Regex.match?(pattern, value)
  defp epoch?(value), do: is_integer(value) and value > 0

  defp name?(value) do
    is_binary(value) and byte_size(value) in 1..@max_name_bytes and String.printable?(value) and
      not String.match?(value, ~r/[\x00-\x1f\x7f]/)
  end

  defp base64_key?(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, <<_::256>>} -> true
      _other -> false
    end
  end

  defp base64_key?(_value), do: false

  defp relays?(relays) when is_list(relays) and length(relays) in 1..@max_relays,
    do: Enum.all?(relays, &relay?/1)

  defp relays?(_relays), do: false

  defp relay?(%{"url" => "https://" <> _host, "quic_port" => port} = relay)
       when is_integer(port) and port in 1..65_535 and map_size(relay) == 2,
       do: true

  defp relay?(_relay), do: false

  # -- writing -----------------------------------------------------------------

  defp encode(%{device_id: device_id, primary: primary, epoch: epoch} = link, file) do
    decoded = %{
      "v" => @version,
      "device_id" => device_id,
      "key" => key_sentinel(Map.get(link, :key)),
      "primary" => %{
        "name" => primary.name,
        "gateway_pk" => Base.encode64(primary.gateway_pk),
        "node_id" => primary.node_id,
        "relays" => primary.relays,
        "relays_rev" => primary.relays_rev,
        "addrs" => Map.get(primary, :addrs, [])
      },
      "primary_epoch" => epoch
    }

    # What is written must read back: the same checks hold both ways.
    with {:ok, _link} <- decode(decoded, file), do: {:ok, Jason.encode!(decoded)}
  end

  # No store, no sentinel: the read-back check refuses it by name.
  defp key_sentinel(store) when store in [:keyring, :file], do: SecretWriter.sentinel_for(store)
  defp key_sentinel(_none), do: nil

  defp ensure_dir(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, @dir_mode) do
      :ok
    else
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  defp atomic_write(file, contents) do
    temp = file <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    with :ok <- write_new(temp, contents),
         :ok <- rename(temp, file) do
      :ok
    end
  end

  defp write_new(temp, contents) do
    case File.open(temp, [:write, :binary, :exclusive, :raw]) do
      {:ok, io} -> fill(io, temp, contents)
      {:error, reason} -> {:error, {:file, temp, reason}}
    end
  end

  defp fill(io, temp, contents) do
    result =
      with :ok <- File.chmod(temp, @file_mode),
           :ok <- :file.write(io, contents) do
        :file.sync(io)
      end

    close = File.close(io)

    case {result, close} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _close} -> discard(temp, reason)
      {:ok, {:error, reason}} -> discard(temp, reason)
    end
  end

  defp rename(temp, file) do
    case File.rename(temp, file) do
      :ok -> :ok
      {:error, reason} -> discard(temp, reason, file)
    end
  end

  defp discard(temp, reason, file \\ nil) do
    _ = File.rm(temp)
    {:error, {:file, file || temp, reason}}
  end
end
