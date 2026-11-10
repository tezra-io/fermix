defmodule FermixChannels.Desktop.Relay.OutboxTest do
  @moduledoc """
  The desktop's outbound lanes (M97 §5.1): strict priority one frame at a
  time, an event's frames in together and in order, and each lane's bound
  refusing, said once when it starts and once when it ends.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.Relay.Outbox

  @mib 1_024 * 1_024

  test "a live frame goes before interactive ones, and both before bulk, each lane in order" do
    {:ok, outbox} = Outbox.put(Outbox.new(), :bulk, [frame("snapshot_stored", "b1")], :b1)
    {:ok, outbox} = Outbox.put(outbox, :bulk, [frame("snapshot_refused", "b2")], :b2)
    {:ok, outbox} = Outbox.put(outbox, :interactive, [frame("manage", "i1")], :i1)
    {:ok, outbox} = Outbox.put(outbox, :live, [frame("call_audio", "l1")], :l1)
    {:ok, outbox} = Outbox.put(outbox, :interactive, [frame("companion_line", "i2")], :i2)

    assert drain(outbox) == [
             {"call_audio", :l1, :live},
             {"manage", :i1, :interactive},
             {"companion_line", :i2, :interactive},
             {"snapshot_stored", :b1, :bulk},
             {"snapshot_refused", :b2, :bulk}
           ]
  end

  test "a bulk stream yields between its frames to what arrives meanwhile" do
    {:ok, outbox} = Outbox.put(Outbox.new(), :bulk, [frame("media_fetch", "b1")], nil)
    {:ok, outbox} = Outbox.put(outbox, :bulk, [frame("media_fetch", "b2")], nil)
    {:ok, {"media_fetch", %{"n" => "b1"}, _tail}, nil, :bulk, outbox} = Outbox.take(outbox)

    {:ok, outbox} = Outbox.put(outbox, :interactive, [frame("manage", "i1")], nil)
    assert {:ok, {"manage", _fields, _tail}, nil, :interactive, outbox} = Outbox.take(outbox)
    assert {:ok, {"media_fetch", %{"n" => "b2"}, _tail}, nil, :bulk, outbox} = Outbox.take(outbox)
    assert Outbox.take(outbox) == :empty
  end

  test "an event's frames go in together and in order, its tag on the last" do
    frames = for n <- 0..2, do: frame("companion_line", "part #{n}")
    {:ok, outbox} = Outbox.put(Outbox.new(), :interactive, frames, {:reply, :caller})
    {:ok, outbox} = Outbox.put(outbox, :live, [frame("call_line", "live")], nil)

    assert drain(outbox) == [
             {"call_line", nil, :live},
             {"companion_line", nil, :interactive},
             {"companion_line", nil, :interactive},
             {"companion_line", {:reply, :caller}, :interactive}
           ]

    assert Outbox.size(outbox) == 4
  end

  test "a lane past its bytes refuses the whole event, counts it, and says once it drained" do
    line = :binary.copy("l", @mib)
    outbox = Enum.reduce(1..16, Outbox.new(), &put!(&2, :interactive, line, &1))

    assert {:error, :busy, outbox} = Outbox.put(outbox, :interactive, [frame_of(line)], :late)
    assert {:error, :busy, outbox} = Outbox.put(outbox, :interactive, [frame_of("x")], :later)
    assert Outbox.refused(outbox, :interactive) == 2
    assert Outbox.size(outbox) == 16

    # Other lanes take their own; a frame with no tail still fits the full lane.
    assert {:ok, outbox} = Outbox.put(outbox, :bulk, [frame_of(line)], nil)
    assert {:ok, outbox} = Outbox.put(outbox, :interactive, [frame_of(<<>>)], :close)

    # Not drained until half of it went.
    outbox = take_n(outbox, 7)
    assert {[], outbox} = Outbox.drained(outbox)
    outbox = take_n(outbox, 1)
    assert {[{:interactive, 2}], outbox} = Outbox.drained(outbox)
    assert {[], _outbox} = Outbox.drained(outbox)
  end

  test "each lane has its own bounds, the live lane the smallest" do
    bounds = Outbox.bounds()
    assert bounds.live == {256 * 1_024, 4_096}
    assert bounds.interactive == {16 * @mib, 4_096}
    assert bounds.bulk == {4 * @mib, 4_096}

    {:ok, outbox} =
      Outbox.put(Outbox.new(), :live, [frame_of(:binary.copy("a", 256 * 1_024))], nil)

    assert {:error, :busy, _outbox} = Outbox.put(outbox, :live, [frame_of("a")], nil)
  end

  test "a lane past its frame count refuses even frames with no tail" do
    outbox =
      Enum.reduce(1..4_096, Outbox.new(), fn _n, outbox -> put!(outbox, :bulk, <<>>, nil) end)

    assert {:error, :busy, outbox} = Outbox.put(outbox, :bulk, [frame_of(<<>>)], nil)
    assert Outbox.refused(outbox, :bulk) == 1
  end

  test "clearing answers every tag still queued, and the lanes start empty" do
    {:ok, outbox} = Outbox.put(Outbox.new(), :bulk, [frame("snapshot_stored", "b")], {:reply, :b})
    {:ok, outbox} = Outbox.put(outbox, :interactive, [frame("manage", "i")], nil)
    {:ok, outbox} = Outbox.put(outbox, :interactive, [frame("hello", "h")], {:reply, :h})

    assert {[{:reply, :h}, {:reply, :b}], outbox} = Outbox.clear(outbox)
    assert Outbox.take(outbox) == :empty
    assert Outbox.size(outbox) == 0
  end

  defp frame(type, n), do: {type, %{"n" => n}, n}
  defp frame_of(tail), do: {"companion_line", %{"channel" => 1}, tail}

  defp put!(outbox, lane, tail, tag) do
    {:ok, outbox} = Outbox.put(outbox, lane, [frame_of(tail)], tag)
    outbox
  end

  defp take_n(outbox, 0), do: outbox

  defp take_n(outbox, n) do
    {:ok, _frame, _tag, _lane, outbox} = Outbox.take(outbox)
    take_n(outbox, n - 1)
  end

  defp drain(outbox) do
    case Outbox.take(outbox) do
      {:ok, {type, _fields, _tail}, tag, lane, outbox} -> [{type, tag, lane} | drain(outbox)]
      :empty -> []
    end
  end
end
