defmodule FermixCore.Home.DesktopLink do
  @moduledoc """
  The two files that make a device-role engine a desktop of its primary
  (M75 §3, §6): `<home>/device/desktop.json`, what the desktop relay needs to
  reach the primary, and `<home>/device/desktop_key`, the desktop's own
  Noise static key. Both stay on this machine (`device/` is device-local).

  The move worker writes both on the source of a move (`write/2`,
  `write_key/2`); the desktop relay (`FermixChannels.Desktop.Relay`) reads
  them and raises what the file remembers as it learns more
  (`record_epoch/2`, `record_route/3`). One engine boot decides whether the
  home is linked (`linked?/2`): the device role with `desktop.json` present.

  ## `device/desktop.json`

  Mode `0600`, written whole to a temporary file and renamed, so a reader
  never sees half of one:

      {
        "v": 1,
        "device_id": "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e",
        "primary": {
          "name": "fermix-vm",
          "gateway_pk": "<32 bytes, standard base64 with padding>",
          "node_id": "<64 lowercase hex digits>",
          "relays": [{"url": "https://relay.example/", "quic_port": 7842}],
          "relays_rev": "<16 lowercase hex digits>"
        },
        "primary_epoch": 5
      }

  - `device_id` is the desktop's row in the primary's `devices.toml` (a UUID).
  - `primary.name` is the name a person knows the primary by, at most 128
    bytes of printable text. `gateway_pk` is the primary's X25519 gateway key
    (the Noise responder's static key) and `node_id` its iroh endpoint id; both
    are the source's own, because the identity bundle moves with the home.
    `relays` (1 to 8) and `relays_rev` are the route the primary last gave,
    in the mobile wire's shape.
  - `primary_epoch` is the highest primary epoch this desktop has seen. It
    never goes down.

  ## `device/desktop_key`

  The desktop's X25519 private key, the raw 32 bytes, mode `0600`, a regular
  file. Any looser mode is refused by name: the key proves this desktop to the
  primary.
  """

  alias FermixCore.Home.Role

  @version 1
  @dir "device"
  @link_file "desktop.json"
  @key_file "desktop_key"
  @file_mode 0o600
  @dir_mode 0o700
  @max_name_bytes 128
  @max_relays 8
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @node_id ~r/\A[0-9a-f]{64}\z/
  @relays_rev ~r/\A[0-9a-f]{16}\z/

  @typedoc "A relay on the route, in the mobile wire's shape."
  @type relay :: %{required(String.t()) => String.t() | pos_integer()}

  @typedoc "What `desktop.json` holds."
  @type t :: %{
          device_id: String.t(),
          primary: %{
            name: String.t(),
            gateway_pk: <<_::256>>,
            node_id: String.t(),
            relays: [relay(), ...],
            relays_rev: String.t()
          },
          epoch: pos_integer()
        }

  @typedoc "The desktop's Noise static keypair."
  @type keypair :: %{private: <<_::256>>, public: <<_::256>>}

  @type error ::
          {:file, Path.t(), File.posix()}
          | {:invalid_link, Path.t(), atom()}
          | {:key_mode, Path.t(), non_neg_integer()}
          | {:invalid_key, Path.t(), atom()}

  @doc "Where `desktop.json` lives under `home`."
  @spec path(Path.t()) :: Path.t()
  def path(home) when is_binary(home) and home != "", do: Path.join([home, @dir, @link_file])

  @doc "Where the desktop's key lives under `home`."
  @spec key_path(Path.t()) :: Path.t()
  def key_path(home) when is_binary(home) and home != "", do: Path.join([home, @dir, @key_file])

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

  @doc "Writes `desktop.json` whole, mode `0600`, creating `device/` (`0700`)."
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

  @doc "Keeps the route the primary last gave (its relays and their revision)."
  @spec record_route(Path.t(), t(), {[relay()], String.t()}) :: {:ok, t()} | {:error, error()}
  def record_route(home, %{primary: primary} = link, {relays, rev})
      when is_binary(home) and is_list(relays) and is_binary(rev) do
    if relays == primary.relays and rev == primary.relays_rev,
      do: {:ok, link},
      else: rewrite(home, %{link | primary: %{primary | relays: relays, relays_rev: rev}})
  end

  defp rewrite(home, link) do
    with :ok <- write(home, link), do: {:ok, link}
  end

  @doc """
  Reads the desktop's key: a regular file of exactly 32 bytes, mode `0600`.
  """
  @spec read_key(Path.t()) :: {:ok, keypair()} | {:error, error()}
  def read_key(home) when is_binary(home) and home != "" do
    file = key_path(home)

    with :ok <- key_entry(file),
         {:ok, private} <- read_file(file),
         :ok <- key_length(private, file) do
      {public, ^private} = :crypto.generate_key(:ecdh, :x25519, private)
      {:ok, %{private: private, public: public}}
    end
  end

  @doc "Writes the desktop's private key, mode `0600`, creating `device/` (`0700`)."
  @spec write_key(Path.t(), <<_::256>>) :: :ok | {:error, error()}
  def write_key(home, <<_::256>> = private) when is_binary(home) and home != "" do
    file = key_path(home)

    with :ok <- ensure_dir(Path.dirname(file)) do
      atomic_write(file, private)
    end
  end

  @doc "The sentence a person is shown for an error of this module."
  @spec error_sentence(error()) :: String.t()
  def error_sentence({:file, path, :enoent}),
    do: "Fermix found no #{Path.basename(path)} in this home's device folder."

  def error_sentence({:file, path, reason}),
    do: "Fermix could not read #{Path.basename(path)} (#{:file.format_error(reason)})."

  def error_sentence({:invalid_link, _path, field}),
    do: "The desktop link file is not one Fermix wrote: its #{field} is not valid."

  def error_sentence({:key_mode, _path, mode}),
    do:
      "The desktop key file is mode #{octal(mode)}, readable by others; " <>
        "Fermix uses it only at 0600."

  def error_sentence({:invalid_key, _path, _detail}),
    do: "The desktop key file is not a key Fermix wrote."

  defp octal(mode),
    do: mode |> Bitwise.band(0o777) |> Integer.to_string(8) |> String.pad_leading(4, "0")

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
    with {:ok, device_id} <- field(decoded, :device_id, &uuid?/1, file),
         {:ok, primary} <- primary(decoded["primary"], file),
         {:ok, epoch} <- field(decoded, :primary_epoch, &epoch?/1, file) do
      {:ok, %{device_id: device_id, primary: primary, epoch: epoch}}
    end
  end

  defp decode(_decoded, file), do: {:error, {:invalid_link, file, :v}}

  defp primary(%{} = primary, file) do
    with {:ok, name} <- field(primary, :name, &name?/1, file),
         {:ok, key} <- field(primary, :gateway_pk, &base64_key?/1, file),
         {:ok, node_id} <- field(primary, :node_id, &matches?(@node_id, &1), file),
         {:ok, relays} <- field(primary, :relays, &relays?/1, file),
         {:ok, rev} <- field(primary, :relays_rev, &matches?(@relays_rev, &1), file) do
      {:ok,
       %{
         name: name,
         gateway_pk: Base.decode64!(key),
         node_id: node_id,
         relays: relays,
         relays_rev: rev
       }}
    end
  end

  defp primary(_absent, file), do: {:error, {:invalid_link, file, :primary}}

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

  defp key_entry(file) do
    case File.lstat(file) do
      {:ok, %{type: :regular, mode: mode}} -> key_mode(Bitwise.band(mode, 0o777), file)
      {:ok, %{type: type}} -> {:error, {:invalid_key, file, type}}
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp key_mode(@file_mode, _file), do: :ok
  defp key_mode(mode, file), do: {:error, {:key_mode, file, mode}}

  defp key_length(<<_::256>>, _file), do: :ok
  defp key_length(_bytes, file), do: {:error, {:invalid_key, file, :length}}

  # -- writing -----------------------------------------------------------------

  defp encode(%{device_id: device_id, primary: primary, epoch: epoch}, file) do
    decoded = %{
      "v" => @version,
      "device_id" => device_id,
      "primary" => %{
        "name" => primary.name,
        "gateway_pk" => Base.encode64(primary.gateway_pk),
        "node_id" => primary.node_id,
        "relays" => primary.relays,
        "relays_rev" => primary.relays_rev
      },
      "primary_epoch" => epoch
    }

    # What is written must read back: the same checks hold both ways.
    with {:ok, _link} <- decode(decoded, file), do: {:ok, Jason.encode!(decoded)}
  end

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
