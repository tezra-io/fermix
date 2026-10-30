defmodule FermixChannels.Mobile.ChunksTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Chunks

  @chunk 60 * 1_024

  describe "split/2" do
    test "cuts a payload into pieces of at most 60 KiB, in order, the last marked" do
      payload = :crypto.strong_rand_bytes(2 * @chunk + 17)
      pieces = Chunks.split(payload)

      assert Enum.map(pieces, fn {index, last, bytes} -> {index, last, byte_size(bytes)} end) ==
               [{0, false, @chunk}, {1, false, @chunk}, {2, true, 17}]

      assert pieces |> Enum.map(&elem(&1, 2)) |> IO.iodata_to_binary() == payload
    end

    test "a payload that fills its chunks exactly ends on a full last chunk" do
      assert [{0, false, first}, {1, true, second}] = Chunks.split(String.duplicate("a", 8), 4)
      assert {first, second} == {"aaaa", "aaaa"}
    end

    test "an empty payload is one empty last piece, so every payload has a last" do
      assert Chunks.split(<<>>) == [{0, true, <<>>}]
    end

    test "a chunk size past 60 KiB is refused" do
      assert_raise FunctionClauseError, fn -> Chunks.split("x", @chunk + 1) end
    end
  end

  describe "the accumulator" do
    test "reassembles what split/2 cut, whatever the chunk size" do
      payload = :crypto.strong_rand_bytes(150_001)

      for size <- [1_000, 4_096, @chunk] do
        assert {:done, ^payload} = reassemble(Chunks.split(payload, size), byte_size(payload))
      end

      assert {:done, <<>>} = reassemble(Chunks.split(<<>>), 0)
    end

    test "refuses a gap" do
      {:more, acc} = Chunks.add(Chunks.new(100), 0, false, "ab")
      assert {:error, {:chunk_gap, 1, 2}} = Chunks.add(acc, 2, true, "cd")
      assert {:error, {:chunk_gap, 0, 1}} = Chunks.add(Chunks.new(100), 1, true, "cd")
    end

    test "refuses a repeat" do
      {:more, acc} = Chunks.add(Chunks.new(100), 0, false, "ab")
      {:more, acc} = Chunks.add(acc, 1, false, "cd")
      assert {:error, {:chunk_repeat, 2, 1}} = Chunks.add(acc, 1, false, "cd")
      assert {:error, {:chunk_repeat, 2, 0}} = Chunks.add(acc, 0, true, "ab")
    end

    test "refuses a payload past its bound, counted across its chunks" do
      {:more, acc} = Chunks.add(Chunks.new(5), 0, false, "abc")
      assert {:error, {:chunk_payload_too_large, 6, 5}} = Chunks.add(acc, 1, true, "def")
      assert {:done, "abcde"} = Chunks.add(acc, 1, true, "de")
    end

    # The accumulator ends at its last frame: a second `last` for the same
    # payload can only come at a later index, which is a gap for whatever
    # accumulator the receiver holds next, and index 0 begins a new payload.
    test "a second last after the payload ended is a gap, not a continuation" do
      assert {:done, "ab"} = Chunks.add(Chunks.new(100), 0, true, "ab")
      assert {:error, {:chunk_gap, 0, 1}} = Chunks.add(Chunks.new(100), 1, true, "cd")
    end
  end

  test "each chunked event names the field its payloads are told apart by, and its bound" do
    for type <- Chunks.chunked_events() do
      assert {:ok, field} = Chunks.key_field(type)
      assert is_binary(field)
      assert {:ok, bound} = Chunks.bound(type, 123)
      assert bound > 0
      assert Chunks.chunked?(type)
    end

    assert Chunks.bound("invoke_blob", 123) == {:ok, 123}
    assert Chunks.bound("manage", 1) == {:ok, 1_048_576}
    assert Chunks.bound("manage_result", 1) == {:ok, 4_194_304}
    assert Chunks.bound("invoke", 1) == {:ok, 65_536}
    assert Chunks.bound("loopback_response", 1) == {:ok, 262_144}
    assert Chunks.key_field("companion_line") == {:ok, "channel"}
    refute Chunks.chunked?("snapshot_chunk")
    assert Chunks.bound("snapshot_chunk", 1) == :error
  end

  defp reassemble(pieces, bound) do
    Enum.reduce_while(pieces, {:more, Chunks.new(bound)}, fn {index, last, bytes}, {:more, acc} ->
      case Chunks.add(acc, index, last, bytes) do
        {:more, acc} -> {:cont, {:more, acc}}
        done_or_error -> {:halt, done_or_error}
      end
    end)
  end
end
