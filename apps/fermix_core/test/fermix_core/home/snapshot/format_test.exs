defmodule FermixCore.Home.Snapshot.FormatTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.Snapshot.Format
  alias FermixCore.Home.Snapshot.Recipient

  @created_at ~U[2026-10-27 09:30:00Z]
  @chunk 1_048_576
  @framing 4 + 16

  setup do
    %{pair: Recipient.generate()}
  end

  describe "a round trip" do
    test "a small stream, a whole chunk, several chunks and nothing at all", %{pair: pair} do
      for plaintext <- [
            "one invented line\n",
            :binary.copy(<<7>>, @chunk),
            :crypto.strong_rand_bytes(2 * @chunk + 12_345),
            ""
          ] do
        stream = seal(pair, plaintext, epoch: 5)

        assert {:ok, header, ^plaintext} = open(stream, pair)
        assert header.epoch == 5
        assert header.created_at == @created_at
        assert header.salt == pair.salt
        assert header.key_id == Recipient.key_id(pair.public_key)
        assert header.chunk_bytes == @chunk
      end
    end

    test "the writer reports the digest and length of every byte it emitted", %{pair: pair} do
      plaintext = :crypto.strong_rand_bytes(@chunk + 99)
      {stream, written} = seal_with_stats(pair, plaintext)

      assert written.size == byte_size(stream)
      assert written.sha256 == Base.encode16(:crypto.hash(:sha256, stream), case: :lower)
      # Header, then two chunks, each with its length and tag.
      assert byte_size(stream) == Format.header_bytes() + byte_size(plaintext) + 2 * @framing
    end

    test "a reader that answers a few bytes at a time reads the same stream", %{pair: pair} do
      plaintext = :crypto.strong_rand_bytes(@chunk + 3)
      stream = seal(pair, plaintext)

      assert {:ok, _header, ^plaintext} = open(stream, pair, trickle: 7)
    end

    test "writes of any size make the same plaintext", %{pair: pair} do
      plaintext = :crypto.strong_rand_bytes(3 * @chunk)
      pieces = for <<piece::binary-size(65_536) <- plaintext>>, do: piece

      stream = seal(pair, pieces)

      assert {:ok, _header, ^plaintext} = open(stream, pair)
    end
  end

  describe "what is refused" do
    setup %{pair: pair} do
      %{stream: seal(pair, :crypto.strong_rand_bytes(2 * @chunk + 500))}
    end

    test "one flipped bit anywhere in a chunk", %{pair: pair, stream: stream} do
      for offset <- [
            Format.header_bytes() + 4,
            Format.header_bytes() + @chunk,
            byte_size(stream) - 1
          ] do
        assert open(flip(stream, offset), pair) == {:error, :snapshot_rejected},
               "offset #{offset}"
      end
    end

    test "one flipped bit in the clear header", %{pair: pair, stream: stream} do
      # created_at: covered by every chunk's tag.
      assert open(flip(stream, 12), pair) == {:error, :snapshot_rejected}
      # The ephemeral key: another shared secret, another key.
      assert open(flip(stream, 50), pair) == {:error, :snapshot_rejected}
      # The key id: a snapshot for another recipient.
      assert open(flip(stream, 40), pair) == {:error, :wrong_key}
      # The magic.
      assert open(flip(stream, 0), pair) == {:error, :not_a_snapshot}
    end

    test "a stream cut inside a chunk", %{pair: pair, stream: stream} do
      for keep <- [Format.header_bytes() + 2, Format.header_bytes() + 1000, byte_size(stream) - 1] do
        assert open(binary_part(stream, 0, keep), pair) == {:error, :snapshot_truncated},
               "kept #{keep}"
      end
    end

    test "a stream cut at a chunk boundary", %{pair: pair, stream: stream} do
      [header, first, second, _last] = split(stream)

      assert open(header <> first <> second, pair) == {:error, :snapshot_rejected}
      assert open(header <> first, pair) == {:error, :snapshot_rejected}
      assert open(header, pair) == {:error, :snapshot_truncated}
    end

    test "chunks in another order, or one repeated", %{pair: pair, stream: stream} do
      [header, first, second, last] = split(stream)

      assert open(header <> second <> first <> last, pair) == {:error, :snapshot_rejected}
      assert open(header <> first <> first <> last, pair) == {:error, :snapshot_rejected}
    end

    test "anything appended after the last chunk", %{pair: pair, stream: stream} do
      [_header, _first, _second, last] = split(stream)

      assert open(stream <> last, pair) == {:error, :snapshot_rejected}
      assert open(stream <> "x", pair) == {:error, :snapshot_rejected}
    end

    test "another recipient's key", %{stream: stream} do
      assert open(stream, Recipient.generate()) == {:error, :wrong_key}
    end

    test "a file that is not a snapshot", %{pair: pair} do
      assert open("FXHOME1\n" <> :binary.copy("x", 200), pair) == {:error, :not_a_snapshot}
      assert open("", pair) == {:error, :not_a_snapshot}
    end

    test "a function stopping the stream stops it", %{pair: pair, stream: stream} do
      read = reader(stream, :all)
      stop = fn _plaintext, _acc -> {:error, :stopped_here} end

      assert Format.decrypt(read, pair, stop, nil) == {:error, :stopped_here}
    end
  end

  test "a sink that refuses stops the writer", %{pair: pair} do
    emit = fn _iodata -> {:error, :disk_full} end

    assert Format.open_writer(pair, %{created_at: @created_at, epoch: 1}, emit) ==
             {:error, :disk_full}
  end

  defp seal(pair, plaintext, opts \\ []) do
    {stream, _written} = seal_with_stats(pair, plaintext, opts)
    stream
  end

  defp seal_with_stats(pair, plaintext, opts \\ []) do
    test = self()
    ref = make_ref()
    emit = fn iodata -> send(test, {ref, IO.iodata_to_binary(iodata)}) && :ok end
    facts = %{created_at: @created_at, epoch: Keyword.get(opts, :epoch, 1)}

    {:ok, writer} = Format.open_writer(Recipient.public(pair), facts, emit)

    writer =
      plaintext
      |> List.wrap()
      |> Enum.reduce(writer, fn piece, writer ->
        {:ok, writer} = Format.write(writer, piece)
        writer
      end)

    {:ok, written} = Format.finish(writer)
    {collect(ref, []), written}
  end

  defp collect(ref, acc) do
    receive do
      {^ref, piece} -> collect(ref, [acc | piece])
    after
      0 -> IO.iodata_to_binary(acc)
    end
  end

  defp open(stream, pair, opts \\ []) do
    read = reader(stream, Keyword.get(opts, :trickle, :all))

    case Format.decrypt(read, pair, fn piece, acc -> {:ok, [acc | piece]} end, []) do
      {:ok, header, acc} -> {:ok, header, IO.iodata_to_binary(acc)}
      {:error, _reason} = error -> error
    end
  end

  # A reader over a binary held by a process of its own, answering at most
  # `trickle` bytes per call.
  defp reader(stream, trickle) do
    {:ok, holder} = Agent.start_link(fn -> stream end)

    fn n ->
      take = if trickle == :all, do: n, else: min(n, trickle)

      Agent.get_and_update(holder, fn
        <<>> ->
          {:eof, <<>>}

        rest when byte_size(rest) <= take ->
          {{:ok, rest}, <<>>}

        rest ->
          {{:ok, binary_part(rest, 0, take)}, binary_part(rest, take, byte_size(rest) - take)}
      end)
    end
  end

  defp flip(stream, offset) do
    <<before::binary-size(offset), byte, rest::binary>> = stream
    <<before::binary, Bitwise.bxor(byte, 1), rest::binary>>
  end

  # The header and each framed chunk.
  defp split(stream) do
    <<header::binary-size(81), rest::binary>> = stream
    [header | chunks(rest)]
  end

  defp chunks(<<>>), do: []

  defp chunks(<<length::32, _rest::binary>> = data) do
    size = 4 + length + 16
    <<chunk::binary-size(size), rest::binary>> = data
    [chunk | chunks(rest)]
  end
end
