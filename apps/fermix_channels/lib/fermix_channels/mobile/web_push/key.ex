defmodule FermixChannels.Mobile.WebPush.Key do
  @moduledoc """
  The home's one Web Push signing key pair (VAPID, RFC 8292).

  It lives in `webpush_key`, in the phone channel's identity directory
  (`FermixChannels.Mobile.Identity.paths/1`, `<home>/mobile/`), so the home
  archive carries it with the pairing keys and a moved or restored home keeps
  the key its phones subscribed with. An interrupted write of it
  (`webpush_key.tmp.*`) is device-local and stays behind
  (`FermixCore.Home.DeviceLocal`, `mobile/*.tmp*`).

  **Encoding.** The file is the 32-byte big-endian P-256 private scalar and
  nothing else, as `gateway_key` beside it holds its X25519 key: no header, no
  newline, mode `0600` in a `0700` directory. The public point is derived from
  it on every load, and a scalar outside 1..n-1 is refused.

  **Created once.** `ensure/1` loads the key, or creates it when there is none:
  the scalar is written to a temp file opened exclusively, made `0600` before
  any byte of it is written, synced, and then hard-linked into place. A link,
  unlike a rename, never replaces a file already there, so when two callers
  race, one link wins, the other finds `:eexist` and both return the key on
  disk. A file that exists and is not a key, has another mode, or is not a
  regular file is an error and is never replaced.

  `:root` names the home as `Identity` takes it; `:link` replaces the publish
  step in tests.
  """

  require Logger

  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.WebPush.Vapid

  @derive {Inspect, only: [:public]}
  @enforce_keys [:private, :public]
  defstruct @enforce_keys

  @type t :: %__MODULE__{private: <<_::256>>, public: <<_::520>>}

  @filename "webpush_key"
  @file_mode 0o600
  @dir_mode 0o700
  @options [:root, :link]

  @doc "Loads the home's key, creating it on first use."
  @spec ensure(keyword()) :: {:ok, t()} | {:error, term()}
  def ensure(opts \\ []) when is_list(opts) do
    with {:ok, paths} <- resolve(opts) do
      case read(paths) do
        {:error, :absent} -> create(paths, Keyword.get(opts, :link, &File.ln/2))
        loaded -> loaded
      end
    end
  end

  @doc "Loads the home's key; `{:error, :absent}` when it has none. Never creates one."
  @spec load(keyword()) :: {:ok, t()} | {:error, :absent | term()}
  def load(opts \\ []) when is_list(opts) do
    with {:ok, paths} <- resolve(opts), do: read(paths)
  end

  @doc """
  The public point in base64url without padding: the sender key a phone hands
  to Google Play services when it subscribes, and what `hello_ack` carries.
  """
  @spec public_text(t()) :: String.t()
  def public_text(%__MODULE__{public: <<4, _point::binary-64>> = public}),
    do: Base.url_encode64(public, padding: false)

  defp resolve(opts) do
    with :ok <- valid_options(opts),
         {:ok, %{dir: dir}} <- Identity.paths(Keyword.take(opts, [:root])) do
      {:ok, %{dir: dir, key: Path.join(dir, @filename)}}
    end
  end

  defp valid_options(opts) do
    case {Keyword.keys(opts) -- @options, Keyword.get(opts, :link, &File.ln/2)} do
      {[], link} when is_function(link, 2) -> :ok
      {[], _link} -> {:error, {:invalid_option, :link}}
      {unknown, _link} -> {:error, {:unknown_options, unknown}}
    end
  end

  defp read(paths) do
    case File.lstat(paths.key) do
      {:error, :enoent} -> {:error, :absent}
      {:ok, %File.Stat{type: :regular}} -> read_present(paths)
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_file_type, paths.key, type}}
      {:error, reason} -> {:error, {:webpush_key_unreadable, paths.key, reason}}
    end
  end

  defp read_present(paths) do
    with :ok <- validate_entry(paths.dir, :directory, @dir_mode),
         :ok <- validate_entry(paths.key, :regular, @file_mode),
         {:ok, private} <- read_file(paths.key) do
      from_private(private, paths.key)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:webpush_key_unreadable, path, reason}}
    end
  end

  defp from_private(<<_::256>> = private, path) do
    case Vapid.public_key(private) do
      {:ok, public} -> {:ok, %__MODULE__{private: private, public: public}}
      {:error, :invalid_private_key} -> {:error, {:invalid_webpush_key, path, :out_of_range}}
    end
  end

  defp from_private(_contents, path), do: {:error, {:invalid_webpush_key, path, :invalid_length}}

  defp create(paths, link) do
    with :ok <- ensure_dir(paths.dir),
         {:ok, key} <- from_private(new_private(), paths.key),
         {:ok, temp} <- write_temp(paths.key, key.private) do
      publish(paths, temp, link)
    end
  end

  defp new_private do
    {_public, private} = :crypto.generate_key(:ecdh, :secp256r1)
    private
  end

  # Whichever caller's link landed, the file on disk is the one key.
  defp publish(paths, temp, link) do
    linked = link.(temp, paths.key)
    remove_temp(temp)

    case linked do
      :ok -> read(paths)
      {:error, :eexist} -> read(paths)
      {:error, reason} -> {:error, {:webpush_key_write_failed, paths.key, reason}}
    end
  end

  defp write_temp(path, private) do
    temp = "#{path}.tmp.#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"

    case File.open(temp, [:write, :binary, :exclusive]) do
      {:ok, io} -> fill_temp(io, temp, private)
      {:error, reason} -> {:error, {:webpush_key_write_failed, temp, reason}}
    end
  end

  # The handle is closed on every path, and the temp file removed on every
  # path that does not return it.
  defp fill_temp(io, temp, private) do
    written =
      with :ok <- File.chmod(temp, @file_mode),
           :ok <- IO.binwrite(io, private) do
        :file.sync(io)
      end

    case {written, File.close(io)} do
      {:ok, :ok} ->
        {:ok, temp}

      {:ok, {:error, reason}} ->
        remove_temp(temp)
        {:error, {:webpush_key_write_failed, temp, reason}}

      {{:error, reason}, _closed} ->
        remove_temp(temp)
        {:error, {:webpush_key_write_failed, temp, reason}}
    end
  end

  # A temp file that cannot be removed is logged, not returned: the reason the
  # caller gets is the one that explains the call, and the leftover is
  # device-local, so no archive carries it.
  defp remove_temp(temp) do
    case File.rm(temp) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.warning("Could not remove #{temp}: #{inspect(reason)}")
    end
  end

  defp ensure_dir(dir) do
    case File.lstat(dir) do
      {:error, :enoent} -> create_dir(dir)
      {:ok, _stat} -> validate_entry(dir, :directory, @dir_mode)
      {:error, reason} -> {:error, {:webpush_key_unreadable, dir, reason}}
    end
  end

  defp create_dir(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, @dir_mode) do
      :ok
    else
      {:error, reason} -> {:error, {:webpush_key_write_failed, dir, reason}}
    end
  end

  defp validate_entry(path, type, mode) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: ^type, mode: actual}} -> validate_mode(path, actual, mode)
      {:ok, %File.Stat{type: other}} -> {:error, {:unsafe_file_type, path, other}}
      {:error, reason} -> {:error, {:webpush_key_unreadable, path, reason}}
    end
  end

  defp validate_mode(path, actual, expected) do
    case Bitwise.band(actual, 0o777) do
      ^expected -> :ok
      other -> {:error, {:unsafe_permissions, path, other, expected}}
    end
  end
end
