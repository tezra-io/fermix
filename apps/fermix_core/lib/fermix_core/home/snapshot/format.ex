defmodule FermixCore.Home.Snapshot.Format do
  @moduledoc """
  `FXSNAP1`, the encrypted snapshot stream (M75 §8): written and read a chunk at
  a time, so no size bound applies but the disk's and memory holds one chunk.

  **Header, in clear (81 bytes).**

      "FXSNAP1\\n"        8   magic
      version            1   1
      created_at         8   Unix seconds, big-endian
      epoch              4   the primary epoch captured, big-endian
      salt              16   the recipient's salt (`Recipient`)
      key id             8   the recipient public key's id (`Recipient.key_id/1`)
      ephemeral key     32   the sender's one-use X25519 public key
      chunk size         4   plaintext bytes per chunk, 1,048,576

  **Key.** `X25519(ephemeral, recipient)`, refused when all zero, through
  HKDF-SHA256 with the header's salt as the extract salt and
  `"fermix-snapshot-v1" || ephemeral key || recipient key` as the expand info,
  into one AES-256 key. The sender's private half is dropped once the key is
  made, so only the recipient's private half opens the stream.

  **Chunks.** Each is `length (4, big-endian) || ciphertext || tag (16)`,
  AES-256-GCM of at most one chunk of plaintext. Every chunk but the last holds
  exactly a chunk's worth; the last holds the rest, possibly nothing. The nonce
  is the chunk index (`<<0::32, index::64>>`, unique under the one-use key) and
  the associated data is the whole header followed by `index (8) || last (1)`,
  so a changed header, a chunk moved to another place, a stream cut at a chunk
  boundary (its new last chunk was sealed as not last) and bytes appended after
  the last chunk all fail to open. A reader decides "last" by finding the end
  of the input right after a chunk, which is the one fact a truncation cannot
  forge.

  **Failures**, each by name: `:not_a_snapshot` (no magic), `{:unsupported_version,
  v}`, `{:invalid_header, field}`, `:wrong_key` (the key id is not the
  recipient's: a wrong passphrase), `:snapshot_truncated` (the input ended inside
  a chunk or before any), and `:snapshot_rejected` (a chunk did not open: the
  file was changed, cut at a chunk boundary, reordered or extended).
  """

  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Snapshot.Recipient

  @magic "FXSNAP1\n"
  @version 1
  @chunk_bytes 1_048_576
  @tag_bytes 16
  @length_bytes 4
  @header_bytes 81
  @label "fermix-snapshot-v1"
  @zero_key <<0::256>>
  @max_unix 253_402_300_799

  @type header :: %{
          version: pos_integer(),
          created_at: DateTime.t(),
          epoch: pos_integer(),
          salt: binary(),
          key_id: binary(),
          ephemeral_public: binary(),
          chunk_bytes: pos_integer()
        }
  @typedoc "Receives each piece of the encrypted stream, in order."
  @type emit :: (iodata() -> :ok | {:error, term()})
  @typedoc "Answers up to `n` more bytes of the input, `:eof` at its end."
  @type read :: (pos_integer() -> {:ok, binary()} | :eof | {:error, term()})
  @type error ::
          :not_a_snapshot
          | {:unsupported_version, non_neg_integer()}
          | {:invalid_header, atom()}
          | :wrong_key
          | :snapshot_truncated
          | :snapshot_rejected
          | {:read, term()}
  @typedoc "What a finished stream amounts to: the SHA-256 (hex) and length of its bytes."
  @type written :: %{sha256: String.t(), size: non_neg_integer()}
  @opaque writer :: %{
            key: binary(),
            header: binary(),
            index: non_neg_integer(),
            buffer: iodata(),
            size: non_neg_integer(),
            emit: emit(),
            digest: term(),
            written: non_neg_integer()
          }

  @doc "The magic every snapshot starts with."
  @spec magic() :: binary()
  def magic, do: @magic

  @doc "Plaintext bytes per chunk."
  @spec chunk_bytes() :: pos_integer()
  def chunk_bytes, do: @chunk_bytes

  @doc "The length of the clear header."
  @spec header_bytes() :: pos_integer()
  def header_bytes, do: @header_bytes

  @doc """
  Starts a stream to `recipient` and emits its header. `facts` names the
  snapshot's `created_at` (whole seconds are kept) and the `epoch` it captured.
  """
  @spec open_writer(Recipient.t(), %{created_at: DateTime.t(), epoch: pos_integer()}, emit()) ::
          {:ok, writer()} | {:error, term()}
  def open_writer(recipient, %{created_at: %DateTime{} = created_at, epoch: epoch}, emit)
      when is_integer(epoch) and epoch >= 1 and is_function(emit, 1) do
    %{salt: salt, public_key: recipient_public} = Recipient.public(recipient)
    {ephemeral_public, ephemeral_secret} = :crypto.generate_key(:ecdh, :x25519)

    with :ok <- epoch_in_range(epoch),
         {:ok, shared} <- shared(ephemeral_secret, recipient_public) do
      header =
        header_binary(%{
          created_at: created_at,
          epoch: epoch,
          salt: salt,
          key_id: Recipient.key_id(recipient_public),
          ephemeral_public: ephemeral_public
        })

      key = key(shared, salt, ephemeral_public, recipient_public)

      out(
        %{
          key: key,
          header: header,
          index: 0,
          buffer: [],
          size: 0,
          emit: emit,
          digest: :crypto.hash_init(:sha256),
          written: 0
        },
        header
      )
    end
  end

  @doc "Adds plaintext, emitting every whole chunk it completes."
  @spec write(writer(), iodata()) :: {:ok, writer()} | {:error, term()}
  def write(%{buffer: buffer, size: size} = writer, data) do
    added = IO.iodata_length(data)
    writer = %{writer | buffer: [buffer | data], size: size + added}

    if writer.size > @chunk_bytes, do: drain(writer), else: {:ok, writer}
  end

  @doc """
  Ends the stream: the rest of the plaintext as the last chunk (empty only
  when nothing was written), answering the SHA-256 and length of every byte
  emitted, header included.
  """
  @spec finish(writer()) :: {:ok, written()} | {:error, term()}
  def finish(%{buffer: buffer} = writer) do
    with {:ok, done} <- emit_chunk(writer, IO.iodata_to_binary(buffer), true) do
      sha256 = done.digest |> :crypto.hash_final() |> Base.encode16(case: :lower)
      {:ok, %{sha256: sha256, size: done.written}}
    end
  end

  # Holds back the last whole chunk while more may follow: whether it is the
  # last is known only at `finish/1`.
  defp drain(writer) do
    <<chunk::binary-size(@chunk_bytes), rest::binary>> = IO.iodata_to_binary(writer.buffer)

    with {:ok, writer} <- emit_chunk(writer, chunk, false) do
      next = %{writer | index: writer.index + 1, buffer: rest, size: byte_size(rest)}
      if next.size > @chunk_bytes, do: drain(next), else: {:ok, next}
    end
  end

  defp emit_chunk(writer, plaintext, last?) do
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        writer.key,
        nonce(writer.index),
        plaintext,
        aad(writer.header, writer.index, last?),
        @tag_bytes,
        true
      )

    out(writer, [<<byte_size(ciphertext)::32>>, ciphertext, tag])
  end

  # Every emitted byte is counted into the stream's digest, so the caller
  # learns what it stored without reading it back.
  defp out(writer, iodata) do
    case writer.emit.(iodata) do
      :ok ->
        {:ok,
         %{
           writer
           | digest: :crypto.hash_update(writer.digest, iodata),
             written: writer.written + IO.iodata_length(iodata)
         }}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Reads and checks the clear header, answering it and its bytes."
  @spec read_header(read()) :: {:ok, header(), binary()} | {:error, error()}
  def read_header(read) when is_function(read, 1) do
    case read_exactly(read, @header_bytes) do
      {:ok, bytes} -> parse_header(bytes)
      :eof -> {:error, :not_a_snapshot}
      {:short, _bytes} -> {:error, :not_a_snapshot}
      {:error, _reason} = error -> error
    end
  end

  @doc "The header of the snapshot at `path`, read without decrypting anything."
  @spec peek_header(Path.t()) :: {:ok, header()} | {:error, error() | {:file, Path.t(), term()}}
  def peek_header(path) when is_binary(path) do
    with_file(path, fn read ->
      case read_header(read) do
        {:ok, header, _bytes} -> {:ok, header}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc "Whether the file at `path` begins with the snapshot magic."
  @spec snapshot?(Path.t()) :: boolean()
  def snapshot?(path) when is_binary(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, byte_size(@magic))) do
      {:ok, @magic} -> true
      _other -> false
    end
  end

  @doc """
  Decrypts the stream `read` answers with `pair`, handing each chunk's
  plaintext to `fun` with the accumulator, in order. Answers the header and the
  final accumulator once the last chunk opened; `fun` may stop the stream with
  `{:error, reason}`. Nothing after a failed chunk reaches `fun`.
  """
  @spec decrypt(read(), Recipient.pair(), (binary(), acc -> {:ok, acc} | {:error, term()}), acc) ::
          {:ok, header(), acc} | {:error, term()}
        when acc: term()
  def decrypt(read, %{secret_key: _secret} = pair, fun, acc)
      when is_function(read, 1) and is_function(fun, 2) do
    with {:ok, header, header_bytes} <- read_header(read),
         :ok <- same_key(header, pair),
         {:ok, shared} <- shared(pair.secret_key, header.ephemeral_public) do
      key = key(shared, header.salt, header.ephemeral_public, pair.public_key)
      state = %{read: read, key: key, header: header_bytes, fun: fun}

      case chunks(state, read_chunk(read), 0, acc) do
        {:ok, acc} -> {:ok, header, acc}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc "A `read/0` function over an open binary file."
  @spec file_reader(IO.device()) :: read()
  def file_reader(io) do
    fn n ->
      case IO.binread(io, n) do
        data when is_binary(data) -> {:ok, data}
        :eof -> :eof
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Runs `fun` with a reader over the file at `path`, closing it on every path."
  @spec with_file(Path.t(), (read() -> result)) :: result | {:error, {:file, Path.t(), term()}}
        when result: term()
  def with_file(path, fun) when is_binary(path) and is_function(fun, 1) do
    case File.open(path, [:read, :binary, {:read_ahead, @chunk_bytes}]) do
      {:ok, io} ->
        try do
          fun.(file_reader(io))
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, {:file, path, reason}}
    end
  end

  # One chunk ahead: a chunk is the last exactly when the input ends right
  # after it.
  defp chunks(_state, {:error, _reason} = error, _index, _acc), do: error
  defp chunks(_state, :eof, _index, _acc), do: {:error, :snapshot_truncated}

  defp chunks(state, {:ok, sealed}, index, acc) do
    next = read_chunk(state.read)
    last? = next == :eof

    with {:ok, plaintext} <- open_chunk(state, sealed, index, last?),
         {:ok, acc} <- state.fun.(plaintext, acc) do
      if last?, do: {:ok, acc}, else: chunks(state, next, index + 1, acc)
    end
  end

  defp open_chunk(state, {length, ciphertext, tag}, index, last?) do
    with :ok <- chunk_length(length, last?) do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             state.key,
             nonce(index),
             ciphertext,
             aad(state.header, index, last?),
             tag,
             false
           ) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :snapshot_rejected}
      end
    end
  end

  # A writer never seals a short chunk before the last, nor a long one.
  defp chunk_length(length, _last?) when length > @chunk_bytes, do: {:error, :snapshot_rejected}
  defp chunk_length(@chunk_bytes, _last?), do: :ok
  defp chunk_length(_length, true), do: :ok
  defp chunk_length(_length, false), do: {:error, :snapshot_rejected}

  defp read_chunk(read) do
    with {:ok, <<length::32>>} <- read_or_end(read, @length_bytes),
         :ok <- length_bounded(length),
         {:ok, body} <- read_body(read, length + @tag_bytes) do
      <<ciphertext::binary-size(length), tag::binary-size(@tag_bytes)>> = body
      {:ok, {length, ciphertext, tag}}
    end
  end

  defp length_bounded(length) when length <= @chunk_bytes, do: :ok
  defp length_bounded(_length), do: {:error, :snapshot_rejected}

  defp read_or_end(read, n) do
    case read_exactly(read, n) do
      {:ok, bytes} -> {:ok, bytes}
      :eof -> :eof
      {:short, _bytes} -> {:error, :snapshot_truncated}
      {:error, _reason} = error -> error
    end
  end

  defp read_body(read, n) do
    case read_exactly(read, n) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} = error -> error
      _short_or_end -> {:error, :snapshot_truncated}
    end
  end

  # A reader may answer fewer bytes than asked before the end; this keeps
  # asking until `n` arrived or the input ended.
  defp read_exactly(read, n), do: read_exactly(read, n, [], 0)

  defp read_exactly(read, n, acc, got) do
    case read.(n - got) do
      {:ok, data} when byte_size(data) + got == n ->
        {:ok, IO.iodata_to_binary([acc | data])}

      {:ok, data} when byte_size(data) > 0 and byte_size(data) + got < n ->
        read_exactly(read, n, [acc | data], got + byte_size(data))

      {:ok, _empty_or_long} ->
        {:error, {:read, :bad_length}}

      :eof when got == 0 ->
        :eof

      :eof ->
        {:short, IO.iodata_to_binary(acc)}

      {:error, reason} ->
        {:error, {:read, reason}}
    end
  end

  defp header_binary(header) do
    <<@magic::binary, @version::8, DateTime.to_unix(header.created_at)::64, header.epoch::32,
      header.salt::binary-size(16), header.key_id::binary-size(8),
      header.ephemeral_public::binary-size(32), @chunk_bytes::32>>
  end

  defp parse_header(
         <<@magic::binary, version::8, created::64, epoch::32, salt::binary-size(16),
           key_id::binary-size(8), ephemeral::binary-size(32), chunk::32>> = bytes
       ) do
    cond do
      version != @version -> {:error, {:unsupported_version, version}}
      chunk != @chunk_bytes -> {:error, {:invalid_header, :chunk_bytes}}
      epoch < 1 or epoch > Epoch.max_epoch() -> {:error, {:invalid_header, :epoch}}
      created > @max_unix -> {:error, {:invalid_header, :created_at}}
      true -> {:ok, header_map(version, created, epoch, salt, key_id, ephemeral), bytes}
    end
  end

  defp parse_header(_bytes), do: {:error, :not_a_snapshot}

  defp header_map(version, created, epoch, salt, key_id, ephemeral) do
    %{
      version: version,
      created_at: DateTime.from_unix!(created),
      epoch: epoch,
      salt: salt,
      key_id: key_id,
      ephemeral_public: ephemeral,
      chunk_bytes: @chunk_bytes
    }
  end

  defp same_key(%{key_id: key_id}, %{public_key: public_key}) do
    if Recipient.key_id(public_key) == key_id, do: :ok, else: {:error, :wrong_key}
  end

  defp epoch_in_range(epoch) do
    if epoch <= Epoch.max_epoch(), do: :ok, else: {:error, {:invalid_header, :epoch}}
  end

  defp shared(secret, public) do
    case :crypto.compute_key(:ecdh, public, secret, :x25519) do
      @zero_key -> {:error, :snapshot_rejected}
      <<shared::binary-size(32)>> -> {:ok, shared}
    end
  rescue
    ErlangError -> {:error, :snapshot_rejected}
  end

  defp key(shared, salt, ephemeral_public, recipient_public) do
    prk = :crypto.mac(:hmac, :sha256, salt, shared)
    info = @label <> ephemeral_public <> recipient_public
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
  end

  defp nonce(index), do: <<0::32, index::64>>

  defp aad(header, index, last?), do: header <> <<index::64, if(last?, do: 1, else: 0)::8>>
end
