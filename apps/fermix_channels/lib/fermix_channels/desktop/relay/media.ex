defmodule FermixChannels.Desktop.Relay.Media do
  @moduledoc """
  The blobs a desktop fetches from its primary for its own app (M75 §6).

  The app's `media_fetch` on `companion.sock` asks for a managed local file.
  After a move the bytes live on the primary, so the relay fetches them with
  the phone wire's `media_fetch` (`media_begin`, `media_chunk`s,
  `media_end`) into a staging directory of its own, `<home>/device/media-fetch`
  (`0700`), checking the size the primary announced and that the bytes hash to
  the ref, and only then names the staged blob by its ref. The companion
  socket's `Companion.MediaGrants` then makes the managed file from it as it
  makes one from the phone store's blob (`staged_blob/2` is its blob source),
  and the tunnel removes the staged blob (`discard/2`).

  One transfer at a time, as the primary streams them; a part file never
  outlives its transfer, and the directory is cleared when the relay starts.
  """

  @dir_mode 0o700
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @typedoc "One blob arriving."
  @type transfer :: %{
          ref: String.t(),
          kind: String.t(),
          mime: String.t(),
          size: non_neg_integer(),
          io: :file.io_device(),
          part: Path.t(),
          next: non_neg_integer(),
          received: non_neg_integer(),
          hash: term()
        }

  @typedoc "What a finished transfer staged, as `Companion.MediaGrants.grant/3` takes it."
  @type media :: %{
          ref: String.t(),
          kind: String.t(),
          mime: String.t(),
          size_bytes: non_neg_integer()
        }

  @doc "Where the relay stages fetched blobs under `home`."
  @spec staging_dir(Path.t()) :: Path.t()
  def staging_dir(home) when is_binary(home) and home != "",
    do: Path.join([home, "device", "media-fetch"])

  @doc "Creates the staging directory (`0700`) and removes every file a previous run left."
  @spec prepare(Path.t()) :: :ok | {:error, term()}
  def prepare(staging) when is_binary(staging) do
    with :ok <- File.mkdir_p(staging),
         :ok <- File.chmod(staging, @dir_mode),
         {:ok, names} <- File.ls(staging) do
      Enum.reduce_while(names, :ok, fn name, :ok -> clear(Path.join(staging, name)) end)
    else
      {:error, reason} -> {:error, {:staging, staging, reason}}
    end
  end

  defp clear(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> remove(path)
      {:ok, _other} -> {:cont, :ok}
      {:error, :enoent} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:staging, path, reason}}}
    end
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> {:cont, :ok}
      {:error, :enoent} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:staging, path, reason}}}
    end
  end

  @doc """
  The staged blob of `ref`, as `Companion.MediaGrants` asks a blob source:
  its path and size, or `:media_gone`.
  """
  @spec staged_blob(Path.t(), String.t()) ::
          {:ok, %{path: Path.t(), size_bytes: non_neg_integer()}} | {:error, :media_gone}
  def staged_blob(staging, ref) when is_binary(staging) and is_binary(ref) do
    with true <- Regex.match?(@sha256, ref),
         path = Path.join(staging, ref),
         {:ok, %{type: :regular, size: size}} <- File.stat(path) do
      {:ok, %{path: path, size_bytes: size}}
    else
      _missing -> {:error, :media_gone}
    end
  end

  @doc "Removes the staged blob of `ref`; one already gone changes nothing."
  @spec discard(Path.t(), String.t()) :: :ok
  def discard(staging, ref) when is_binary(staging) and is_binary(ref) do
    if Regex.match?(@sha256, ref), do: _ = File.rm(Path.join(staging, ref))
    :ok
  end

  @doc """
  Starts a transfer from its `media_begin`: refused past `max_bytes`, and
  for a ref that is not a SHA-256.
  """
  @spec begin(Path.t(), map(), pos_integer()) :: {:ok, transfer()} | {:error, term()}
  def begin(staging, %{"ref" => ref, "kind" => kind, "mime" => mime, "size_bytes" => size}, max)
      when is_binary(ref) and is_binary(kind) and is_binary(mime) and is_integer(size) do
    part = Path.join(staging, ref <> ".part")

    cond do
      not Regex.match?(@sha256, ref) -> {:error, :invalid_ref}
      size > max -> {:error, {:too_large, size, max}}
      true -> open_part(part, %{ref: ref, kind: kind, mime: mime, size: size})
    end
  end

  def begin(_staging, _fields, _max), do: {:error, :invalid_media_begin}

  defp open_part(part, facts) do
    _ = File.rm(part)

    case File.open(part, [:write, :binary, :exclusive, :raw]) do
      {:ok, io} ->
        {:ok,
         Map.merge(facts, %{
           io: io,
           part: part,
           next: 0,
           received: 0,
           hash: :crypto.hash_init(:sha256)
         })}

      {:error, reason} ->
        {:error, {:staging, part, reason}}
    end
  end

  @doc "Appends one `media_chunk`: in order, and never past the announced size."
  @spec chunk(transfer(), non_neg_integer(), binary()) :: {:ok, transfer()} | {:error, term()}
  def chunk(%{next: index} = transfer, index, bytes) when is_binary(bytes) do
    received = transfer.received + byte_size(bytes)

    if received > transfer.size,
      do: {:error, :media_descriptor_mismatch},
      else: write_chunk(transfer, received, bytes)
  end

  def chunk(%{next: next}, index, _bytes), do: {:error, {:media_chunk_order, next, index}}

  defp write_chunk(transfer, received, bytes) do
    case :file.write(transfer.io, bytes) do
      :ok -> {:ok, advance(transfer, received, bytes)}
      {:error, reason} -> {:error, {:staging, transfer.part, reason}}
    end
  end

  defp advance(transfer, received, bytes),
    do: %{
      transfer
      | next: transfer.next + 1,
        received: received,
        hash: :crypto.hash_update(transfer.hash, bytes)
    }

  @doc """
  Ends a transfer at `media_end`: the bytes must be the announced size and
  hash to the ref, and only then is the blob staged under its ref.
  """
  @spec finish(transfer(), Path.t()) :: {:ok, media()} | {:error, term()}
  def finish(transfer, staging) do
    digest = transfer.hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
    closed = File.close(transfer.io)

    cond do
      closed != :ok -> fail(transfer, {:staging, transfer.part, closed})
      transfer.received != transfer.size -> fail(transfer, :media_descriptor_mismatch)
      digest != transfer.ref -> fail(transfer, :media_descriptor_mismatch)
      true -> stage(transfer, Path.join(staging, transfer.ref))
    end
  end

  defp stage(transfer, path) do
    case File.rename(transfer.part, path) do
      :ok ->
        {:ok,
         %{ref: transfer.ref, kind: transfer.kind, mime: transfer.mime, size_bytes: transfer.size}}

      {:error, reason} ->
        fail(transfer, {:staging, path, reason})
    end
  end

  defp fail(transfer, reason) do
    _ = File.rm(transfer.part)
    {:error, reason}
  end

  @doc "Abandons a transfer: its part file goes."
  @spec abort(transfer() | nil) :: :ok
  def abort(nil), do: :ok

  def abort(transfer) do
    _ = File.close(transfer.io)
    _ = File.rm(transfer.part)
    :ok
  end
end
