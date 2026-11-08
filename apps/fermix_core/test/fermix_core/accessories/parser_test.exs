defmodule FermixCore.Accessories.ParserTest do
  # The receive side of the accessory link: serial reads are fragments of a
  # byte stream, so the parser must give the same frames however the bytes
  # arrive, find its way back after noise, and never deliver a frame its CRC
  # does not vouch for (PROTOCOL.md, *Receiving*).
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias FermixCore.Accessories.Frame
  alias FermixCore.Accessories.Parser
  alias FermixCore.Accessories.Reassembler

  @max_frame 4_116

  defp accessory_frame do
    gen all(
          kind <- member_of([:control, :mic, :diagnostics]),
          seq <- integer(0..4_294_967_295),
          frame <- accessory_frame(kind, seq)
        ) do
      frame
    end
  end

  defp accessory_frame(:control, seq) do
    gen all(
          payload <- binary(min_length: 1, max_length: 300),
          flags <- member_of([1, 2, 3, 0, 7]),
          stream <- integer(0..3)
        ) do
      %Frame{type: :control, flags: flags, stream: stream, seq: seq, payload: payload}
    end
  end

  defp accessory_frame(:mic, seq) do
    gen all(payload <- binary(length: 960), stream <- integer(1..65_535)) do
      %Frame{type: :mic, stream: stream, seq: seq, payload: payload}
    end
  end

  defp accessory_frame(:diagnostics, seq) do
    gen all(payload <- binary(min_length: 1, max_length: 200)) do
      %Frame{type: :diagnostics, seq: seq, payload: payload}
    end
  end

  # Split one binary at the given cut points (each taken modulo its length).
  defp split(binary, cuts) do
    points = cuts |> Enum.map(&rem(&1, byte_size(binary) + 1)) |> Enum.sort() |> Enum.uniq()

    {chunks, last, rest} =
      Enum.reduce(points, {[], 0, binary}, fn point, {chunks, at, rest} ->
        size = point - at
        <<chunk::binary-size(size), tail::binary>> = rest
        {[chunk | chunks], point, tail}
      end)

    _ = last
    Enum.reverse([rest | chunks])
  end

  defp feed_all(parser, chunks) do
    Enum.reduce(chunks, {[], parser}, fn chunk, {events, parser} ->
      {new, parser} = Parser.feed(parser, chunk, 0)
      {events ++ new, parser}
    end)
  end

  defp frames(events), do: for({:frame, frame} <- events, do: frame)
  defp faults(events), do: for({:fault, reason} <- events, do: reason)

  # Bytes with no "F" in them can never hold a magic.
  defp noise do
    gen all(bytes <- list_of(integer(0..255), min_length: 1, max_length: 300)) do
      bytes |> Enum.reject(&(&1 == ?F)) |> Enum.map(&<<&1>>) |> IO.iodata_to_binary()
    end
    |> filter(&(&1 != ""))
  end

  property "valid frames split anywhere come out whole, in order, with nothing left" do
    check all(
            frames <- list_of(accessory_frame(), min_length: 1, max_length: 8),
            cuts <- list_of(integer(0..40_000), max_length: 30)
          ) do
      stream = frames |> Enum.map(&Frame.encode/1) |> IO.iodata_to_binary()
      {events, parser} = feed_all(Parser.new(:accessory), split(stream, cuts))

      assert events == Enum.map(frames, &{:frame, &1})
      assert Parser.pending_bytes(parser) == 0
      assert Parser.resync_bytes(parser) == 0
    end
  end

  property "noise before the first frame is discarded silently and counted" do
    check all(
            banner <- noise(),
            frames <- list_of(accessory_frame(), min_length: 1, max_length: 4),
            cuts <- list_of(integer(0..20_000), max_length: 10)
          ) do
      stream = IO.iodata_to_binary([banner | Enum.map(frames, &Frame.encode/1)])
      {events, parser} = feed_all(Parser.new(:accessory), split(stream, cuts))

      assert events == Enum.map(frames, &{:frame, &1})
      assert Parser.resync_bytes(parser) == byte_size(banner)
    end
  end

  property "noise between frames once synced is one bad_magic, and the next frame is found" do
    check all(
            [first, second] <- list_of(accessory_frame(), length: 2),
            junk <- noise(),
            cuts <- list_of(integer(0..20_000), max_length: 10)
          ) do
      stream = IO.iodata_to_binary([Frame.encode(first), junk, Frame.encode(second)])
      {events, parser} = feed_all(Parser.new(:accessory), split(stream, cuts))

      assert events == [{:frame, first}, {:fault, :bad_magic}, {:frame, second}]
      assert Parser.resync_bytes(parser) == byte_size(junk)
    end
  end

  property "a flipped bit never yields a frame, is reported, and what follows is found again" do
    check all(
            frames <- list_of(accessory_frame(), min_length: 3, max_length: 5),
            index <- integer(1..(length(frames) - 1)),
            bit <- integer(0..10_000_000)
          ) do
      encoded = Enum.map(frames, &Frame.encode/1)
      target = Enum.at(encoded, index)
      broken = flip(target, rem(bit, bit_size(target)))
      # Enough trailing bytes that a corrupted length is always waited out.
      tail = :binary.copy(<<0>>, @max_frame + 1)
      stream = IO.iodata_to_binary([List.replace_at(encoded, index, broken), tail])

      {events, _parser} = Parser.feed(Parser.new(:accessory), stream, 0)

      assert frames(events) == List.delete_at(frames, index)
      assert faults(events) != []
    end
  end

  property "random bytes never crash the parser, never pass a bad CRC, and stay bounded" do
    check all(
            bytes <- binary(max_length: 20_000),
            cuts <- list_of(integer(0..20_000), max_length: 20)
          ) do
      {events, parser} = feed_all(Parser.new(:accessory), split(bytes, cuts))

      for {:frame, frame} <- events do
        assert :binary.match(bytes, Frame.encode(frame)) != :nomatch
      end

      assert Parser.pending_bytes(parser) < @max_frame
      consumed = events |> frames() |> Enum.map(&byte_size(Frame.encode(&1))) |> Enum.sum()

      assert consumed + Parser.resync_bytes(parser) + Parser.pending_bytes(parser) ==
               byte_size(bytes)
    end
  end

  test "an over-cap length after sync is refused at once, without waiting for its bytes" do
    good = Frame.encode(%Frame{type: :control, flags: 3, payload: "{}"})
    over = <<"FX", 1, 1, 3, 0, 0::16, 1::32-little, 4_097::32-little>>

    {events, parser} = Parser.feed(Parser.new(:accessory), good <> over, 0)

    assert events == [
             {:frame, %Frame{type: :control, flags: 3, payload: "{}"}},
             {:fault, :over_cap}
           ]

    assert Parser.pending_bytes(parser) < 16
  end

  test "faults are counted by reason, with the frames delivered" do
    good = Frame.encode(%Frame{type: :control, flags: 3, payload: "{}"})
    <<body::binary-size(18), crc::32-little>> = good
    bad_crc = body <> <<Bitwise.bxor(crc, 1)::32-little>>

    {_events, parser} =
      Parser.feed(Parser.new(:accessory), good <> bad_crc <> good <> bad_crc <> good, 0)

    assert %{frames: 3, faults: %{crc_mismatch: 2}} = Parser.counters(parser)
  end

  test "the parser reads one peer's frames: the host's speaker PCM, the accessory's microphone" do
    speaker = %Frame{type: :speaker, stream: 1, payload: <<0, 0>>}
    mic = %Frame{type: :mic, stream: 1, payload: :binary.copy(<<1>>, 960)}

    assert {[{:frame, ^speaker}], _} = Parser.feed(Parser.new(:host), Frame.encode(speaker), 0)

    assert {[{:fault, :wrong_direction}], _} =
             Parser.feed(Parser.new(:accessory), Frame.encode(speaker), 0)

    assert {[{:frame, ^mic}], _} = Parser.feed(Parser.new(:accessory), Frame.encode(mic), 0)

    assert {[{:fault, :wrong_direction}], _} =
             Parser.feed(Parser.new(:host), Frame.encode(mic), 0)
  end

  test "a frame that stops arriving is a fault after a second, and what follows is read again" do
    good = Frame.encode(%Frame{type: :control, flags: 3, payload: "{}"})
    false_length = <<"FX", 1, 1, 3, 0, 0::16, 1::32-little, 2_000::32-little, "{}">>

    {events, parser} = Parser.feed(Parser.new(:accessory), good <> false_length, 0)
    assert events == [{:frame, %Frame{type: :control, flags: 3, payload: "{}"}}]
    assert {[], parser} = Parser.feed(parser, "", 999)
    assert {[{:fault, :frame_timeout}], parser} = Parser.feed(parser, "", 1_000)
    assert Parser.pending_bytes(parser) == 0
    assert Parser.resync_bytes(parser) == byte_size(false_length)

    {events, _parser} = Parser.feed(parser, good, 1_001)
    assert events == [{:frame, %Frame{type: :control, flags: 3, payload: "{}"}}]
  end

  test "a frame's own bytes may take the whole second" do
    mic = Frame.encode(%Frame{type: :mic, stream: 1, payload: :binary.copy(<<1>>, 960)})
    <<head::binary-size(500), tail::binary>> = mic

    {[], parser} = Parser.feed(Parser.new(:accessory), head, 0)
    {[], parser} = Parser.feed(parser, "", 999)
    assert {[{:frame, %Frame{type: :mic}}], _parser} = Parser.feed(parser, tail, 1_000)
  end

  test "a reset drops the bytes held for a frame, counts them, and keeps every counter" do
    good = Frame.encode(%Frame{type: :control, flags: 3, payload: "{}"})
    {_events, parser} = Parser.feed(Parser.new(:accessory), good <> binary_part(good, 0, 7), 0)

    reset = Parser.reset(parser)

    assert Parser.pending_bytes(reset) == 0
    assert Parser.resync_bytes(reset) == 7
    assert Parser.counters(reset).frames == 1
    # Hunting again: noise after a reset is not a fault.
    assert {[{:frame, _frame}], _} = Parser.feed(reset, "noise" <> good, 5)
  end

  describe "Frame" do
    test "encode refuses a frame no peer may send" do
      for frame <- [
            %Frame{type: :control, payload: ""},
            %Frame{type: :control, flags: 8, payload: "{}"},
            %Frame{type: :control, payload: :binary.copy("x", 4_097)},
            %Frame{type: :mic, stream: 1, payload: <<0>>},
            %Frame{type: :mic, stream: 0, payload: :binary.copy(<<0>>, 960)},
            %Frame{type: :speaker, stream: 1, payload: <<0, 0, 0>>},
            %Frame{type: :speaker, stream: 1, flags: 4, payload: <<0, 0>>},
            %Frame{type: :diagnostics, stream: 2, payload: "x"},
            %Frame{type: :control, stream: 65_536, payload: "{}"},
            %Frame{type: :control, seq: 4_294_967_296, payload: "{}"}
          ] do
        assert_raise ArgumentError, fn -> Frame.encode(frame) end
      end
    end

    test "a control payload splits into START and END fragments of at most 4,096 bytes" do
      payload = :binary.copy("y", 8_192)

      assert [{1, first}, {2, last}] = Frame.control_fragments(payload, urgent: false)
      assert byte_size(first) == 4_096 and byte_size(last) == 4_096
      assert first <> last == payload

      assert [{1, _}, {2, tail}] =
               Frame.control_fragments(:binary.copy("y", 5_000), urgent: false)

      assert byte_size(tail) == 904
      assert [{3, "{}"}] = Frame.control_fragments("{}", urgent: false)
      assert [{7, "{}"}] = Frame.control_fragments("{}", urgent: true)
    end

    test "a control payload over the 8,192-byte message cap is never split" do
      assert_raise FunctionClauseError, fn ->
        Frame.control_fragments(:binary.copy("y", 8_193), urgent: false)
      end
    end
  end

  property "a control message cut into fragments reassembles to itself" do
    check all(
            payload <- binary(min_length: 1, max_length: 8_192),
            stream <- integer(0..65_535),
            base <- integer(0..4_294_967_295)
          ) do
      frames =
        payload
        |> Frame.control_fragments(urgent: false)
        |> Enum.with_index()
        |> Enum.map(fn {{flags, chunk}, i} ->
          %Frame{
            type: :control,
            flags: flags,
            stream: stream,
            seq: rem(base + i, 4_294_967_296),
            payload: chunk
          }
        end)

      {last, _reassembler} =
        Enum.reduce(frames, {nil, Reassembler.new()}, fn frame, {_last, reassembler} ->
          case Reassembler.feed(reassembler, frame) do
            {:more, next} -> {:more, next}
            {:message, ^stream, message, next} -> {{:message, message}, next}
          end
        end)

      assert last == {:message, payload}
    end
  end

  defp flip(binary, bit) do
    <<before::bitstring-size(bit), b::1, rest::bitstring>> = binary
    <<before::bitstring, Bitwise.bxor(b, 1)::1, rest::bitstring>>
  end
end
