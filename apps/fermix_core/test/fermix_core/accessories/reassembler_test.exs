defmodule FermixCore.Accessories.ReassemblerTest do
  @moduledoc """
  A control frame with seq 0 starts a new sequence (`priv/accessory/PROTOCOL.md`,
  *Reassembly*): a sender that opened the link again (a restarted daemon, a
  new link process, a rebooted accessory) numbers its control frames from 0,
  so the receiver drops any partial message and its base, counts no fault,
  and reads the frame as the first of the new sequence.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Accessories.Frame
  alias FermixCore.Accessories.Reassembler

  defp frame(seq, flags, payload \\ "{}", stream \\ 0),
    do: %Frame{type: :control, flags: flags, stream: stream, seq: seq, payload: payload}

  defp feed_all(frames) do
    {events, _r} =
      Enum.reduce(frames, {[], Reassembler.new()}, fn frame, {acc, r} ->
        case Reassembler.feed(r, frame) do
          {:more, r} -> {acc, r}
          {:message, _stream, payload, r} -> {acc ++ [{:message, payload}], r}
          {:fault, reason, r} -> {acc ++ [{:fault, reason}], r}
        end
      end)

    events
  end

  test "a seq-0 frame mid-stream rebases with no fault: the restarted sender's first message is read" do
    assert feed_all([frame(41, 3), frame(42, 3), frame(0, 3, "[]")]) ==
             [{:message, "{}"}, {:message, "{}"}, {:message, "[]"}]
  end

  test "after the rebase the sequence goes on from 0" do
    assert feed_all([frame(41, 3), frame(0, 3), frame(1, 3), frame(3, 3)]) ==
             [{:message, "{}"}, {:message, "{}"}, {:message, "{}"}, {:fault, :control_seq_gap}]
  end

  test "a seq-0 frame drops a partial message, with no fault" do
    assert feed_all([frame(7, 1, "{\"a\":"), frame(0, 3, "[]")]) == [{:message, "[]"}]
  end

  test "a wrap inside a fragmented message drops that message; its rest is read afresh" do
    assert feed_all([frame(4_294_967_295, 1, "{\"a\":"), frame(0, 2, "1}")]) ==
             [{:fault, :fragment_sequence}]
  end

  test "a wrap between whole messages is no gap" do
    assert feed_all([frame(4_294_967_295, 3), frame(0, 3), frame(1, 3)]) ==
             [{:message, "{}"}, {:message, "{}"}, {:message, "{}"}]
  end
end
