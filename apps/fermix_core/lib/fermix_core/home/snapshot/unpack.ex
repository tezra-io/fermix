defmodule FermixCore.Home.Snapshot.Unpack do
  @moduledoc """
  Reads a snapshot's plaintext, as it is decrypted a chunk at a time, into a
  private staging directory (`FermixCore.Home.Snapshot.restore/4`).

  The plaintext is `manifest length (4, big-endian) || manifest JSON` (the
  stage-1 manifest, `Archive.Manifest`, with no byte bound), then each listed
  file's bytes in the manifest's order. Each file is appended to its staged
  copy and hashed as it arrives, and checked against its entry when its last
  byte lands: `{:corrupt_entry, path}` for a hash that differs. Bytes after the
  last file are `{:invalid_snapshot, :trailing_bytes}`, a stream that ends
  before it is `{:invalid_snapshot, :incomplete}`. No file is held open between
  chunks, so a stream that fails part-way leaves nothing open behind it.
  """

  alias FermixCore.Home.Archive.Manifest

  @max_manifest_bytes 67_108_864

  @typedoc "Where the plaintext stands: the length, the manifest, a file, or done."
  @type state :: %{
          phase: :length | {:manifest, pos_integer()} | :files | :done,
          buffer: binary(),
          staging: Path.t(),
          manifest: Manifest.t() | nil,
          pending: [Manifest.entry()],
          file: nil | %{entry: Manifest.entry(), left: non_neg_integer(), digest: term()}
        }

  @doc "The state a stream starts in, writing under `staging`."
  @spec new(Path.t()) :: state()
  def new(staging) when is_binary(staging) do
    %{phase: :length, buffer: <<>>, staging: staging, manifest: nil, pending: [], file: nil}
  end

  @doc "Takes one piece of plaintext."
  @spec feed(binary(), state()) :: {:ok, state()} | {:error, term()}
  def feed(data, %{buffer: buffer} = state) when is_binary(data) do
    step(%{state | buffer: buffer <> data})
  end

  @doc "The manifest once the stream is whole; an error for one that stopped short."
  @spec finish(state()) :: {:ok, Manifest.t()} | {:error, term()}
  def finish(%{phase: :done, manifest: manifest}), do: {:ok, manifest}
  def finish(_state), do: {:error, {:invalid_snapshot, :incomplete}}

  defp step(%{phase: :length, buffer: <<length::32, rest::binary>>} = state) do
    if length in 1..@max_manifest_bytes,
      do: step(%{state | phase: {:manifest, length}, buffer: rest}),
      else: {:error, {:invalid_manifest, {:length, length}}}
  end

  defp step(%{phase: :length} = state), do: {:ok, state}

  defp step(%{phase: {:manifest, length}, buffer: buffer} = state)
       when byte_size(buffer) >= length do
    <<json::binary-size(length), rest::binary>> = buffer

    with {:ok, manifest} <- Manifest.decode(json, :infinity),
         :ok <- clear_of_staging(manifest, state.staging) do
      next_file(%{state | manifest: manifest, pending: manifest.files, buffer: rest})
    end
  end

  defp step(%{phase: {:manifest, _length}} = state), do: {:ok, state}

  defp step(%{phase: :files, buffer: <<>>} = state), do: {:ok, state}

  defp step(%{phase: :files, file: file, buffer: buffer} = state) do
    take = min(file.left, byte_size(buffer))
    <<piece::binary-size(take), rest::binary>> = buffer

    with :ok <- append(state.staging, file.entry.path, piece) do
      file = %{file | left: file.left - take, digest: :crypto.hash_update(file.digest, piece)}
      state = %{state | file: file, buffer: rest}
      if file.left == 0, do: close_file(state), else: {:ok, state}
    end
  end

  defp step(%{phase: :done, buffer: <<>>} = state), do: {:ok, state}
  defp step(%{phase: :done}), do: {:error, {:invalid_snapshot, :trailing_bytes}}

  defp next_file(%{pending: []} = state), do: step(%{state | phase: :done, file: nil})

  defp next_file(%{pending: [entry | pending]} = state) do
    with :ok <- create(state.staging, entry.path) do
      file = %{entry: entry, left: entry.bytes, digest: :crypto.hash_init(:sha256)}
      state = %{state | phase: :files, pending: pending, file: file}
      if entry.bytes == 0, do: close_file(state), else: step(state)
    end
  end

  defp close_file(%{file: %{entry: entry, digest: digest}} = state) do
    if Base.encode16(:crypto.hash_final(digest), case: :lower) == entry.sha256,
      do: next_file(%{state | file: nil}),
      else: {:error, {:corrupt_entry, entry.path}}
  end

  # The staging directory sits in the root it restores into, so no entry may
  # name it.
  defp clear_of_staging(manifest, staging) do
    name = Path.basename(staging)
    paths = Enum.map(manifest.files, & &1.path) ++ Enum.map(manifest.links, & &1.path)

    case Enum.find(paths, &(hd(String.split(&1, "/")) == name)) do
      nil -> :ok
      path -> {:error, {:unsafe_path, path}}
    end
  end

  defp create(staging, rel) do
    path = Path.join(staging, rel)

    with :ok <- mkdir_p(Path.dirname(path)) do
      case File.open(path, [:write, :exclusive, :binary]) do
        {:ok, io} -> close(io, path)
        {:error, reason} -> {:error, {:file, path, reason}}
      end
    end
  end

  defp append(staging, rel, piece) do
    path = Path.join(staging, rel)

    case File.write(path, piece, [:append, :binary]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file, path, reason}}
    end
  end

  defp close(io, path) do
    case File.close(io) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file, path, reason}}
    end
  end

  defp mkdir_p(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end
end
