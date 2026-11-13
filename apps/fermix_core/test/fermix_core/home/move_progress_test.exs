defmodule FermixCore.Home.MoveProgressTest do
  @moduledoc """
  What the move in hand counted so far (Always On pane §3.13, P2 and P4): one
  record per engine in memory, the watch told at each change with the record
  already in place, a record that lives no longer than the process that put
  it, and nothing at all where the store does not run.

  Each store is the test's own, and tells the test, from inside the store, the
  record it holds at each change: the order is exact and nothing is timed.
  """
  use ExUnit.Case, async: true

  alias FermixCore.Application, as: CoreApplication
  alias FermixCore.Home.MoveProgress
  alias FermixCore.Home.Role

  @move "2031-05-04T10-00-00Z-4c7e"
  @capture %{move_id: @move, step: :capture, bytes: 0, size: nil}
  @send %{move_id: @move, step: :send, bytes: 0, size: 4_718_592}
  @chunk 60 * 1_024

  setup do
    test = self()
    store = :"move_progress_#{System.unique_integer([:positive])}"

    told = fn ->
      send(test, {:told, MoveProgress.read(store)})
      :ok
    end

    start_supervised!({MoveProgress, name: store, status_changed: told})
    %{store: store}
  end

  test "a put replaces the one record, which is in place when the watch is told", %{store: store} do
    assert MoveProgress.read(store) == nil

    assert :ok = MoveProgress.put(store, @capture)
    assert_received {:told, @capture}

    sent = %{@send | bytes: 235_929}
    assert :ok = MoveProgress.put(store, @send)
    assert :ok = MoveProgress.put(store, sent)
    assert_received {:told, @send}
    assert_received {:told, ^sent}
    assert MoveProgress.read(store) == sent
  end

  test "clear forgets the record only when it names that move", %{store: store} do
    :ok = MoveProgress.put(store, @send)
    assert_received {:told, @send}

    # The store tells from inside the call, before it answers: a tell would be
    # here by now.
    assert :ok = MoveProgress.clear(store, "2031-05-04T09-12-00Z-0b9d")
    refute_received {:told, _record}
    assert MoveProgress.read(store) == @send

    assert :ok = MoveProgress.clear(store, @move)
    assert_received {:told, nil}
    assert MoveProgress.read(store) == nil

    assert :ok = MoveProgress.clear(store, @move)
    refute_received {:told, _record}
  end

  test "a record lives no longer than the process that put it", %{store: store} do
    writer =
      Task.async(fn ->
        :ok = MoveProgress.put(store, @send)

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {:told, @send}
    send(writer.pid, :exit)
    :ok = Task.await(writer)

    assert_receive {:told, nil}
    assert MoveProgress.read(store) == nil
  end

  test "where the store does not run, a read is nil and a put or clear does nothing" do
    absent = :"move_progress_absent_#{System.unique_integer([:positive])}"

    assert MoveProgress.read(absent) == nil
    assert :ok = MoveProgress.put(absent, @send)
    assert :ok = MoveProgress.clear(absent, @move)
    assert MoveProgress.read(absent) == nil
    refute_received {:told, _record}
  end

  test "a record whose count does not fit its step is refused", %{store: store} do
    for wrong <- [
          %{@send | size: nil},
          %{@send | bytes: 4_718_593},
          %{@capture | bytes: 61_440},
          %{@capture | bytes: 0.0},
          %{@capture | size: 4_718_592},
          %{@capture | step: :unpack},
          %{@capture | move_id: ""},
          Map.put(@capture, :sentence, "an invented sentence")
        ] do
      assert_raise FunctionClauseError, fn -> MoveProgress.put(store, wrong) end
    end

    assert MoveProgress.read(store) == nil
  end

  describe "crossed?/3, the one 5% rule both writers put by" do
    test "a count crosses when it reaches a whole twentieth it had not reached" do
      refute MoveProgress.crossed?(0, 4, 100)
      assert MoveProgress.crossed?(0, 5, 100)
      refute MoveProgress.crossed?(5, 9, 100)
      assert MoveProgress.crossed?(9, 10, 100)
    end

    test "a chunk that jumps several twentieths crosses once" do
      assert MoveProgress.crossed?(3, 61, 100)
    end

    test "the last chunk always crosses into the whole, and nothing crosses past it" do
      assert MoveProgress.crossed?(99, 100, 100)
      refute MoveProgress.crossed?(96, 99, 100)
      refute MoveProgress.crossed?(100, 100, 100)
    end

    test "a size of one byte crosses once, at its byte; a size of none never crosses" do
      refute MoveProgress.crossed?(0, 0, 1)
      assert MoveProgress.crossed?(0, 1, 1)
      refute MoveProgress.crossed?(0, 0, 0)
    end

    test "a whole transfer of any size crosses at most twenty times, its last chunk always" do
      for size <- [1, 7, 100, @chunk - 1, @chunk, @chunk + 1, 20 * @chunk, 5_000_003] do
        crossings = crossings(size)
        assert length(crossings) <= 20
        assert List.last(crossings) == size

        # Under 5% a chunk, each twentieth is crossed on its own.
        if size >= 20 * @chunk, do: assert(length(crossings) == 20)
      end
    end

    test "a count that runs backwards or past its size is refused" do
      assert_raise FunctionClauseError, fn -> MoveProgress.crossed?(0, 101, 100) end
      assert_raise FunctionClauseError, fn -> MoveProgress.crossed?(50, 40, 100) end
      assert_raise FunctionClauseError, fn -> MoveProgress.crossed?(-1, 0, 100) end
    end
  end

  describe "where the store runs" do
    test "an engine's tree has it in every role but a candidate's; a test VM's never" do
      assert CoreApplication.maybe_move_progress(:prod) == [MoveProgress]
      assert CoreApplication.maybe_move_progress(:test) == []

      children = CoreApplication.maybe_move_progress(:prod)
      assert Role.children(children, :primary) == [MoveProgress]
      assert Role.children(children, :device) == [MoveProgress]
      assert Role.children(children, :candidate) == []
    end
  end

  # The counts a transfer of `size` bytes puts at, handed in 60 KiB chunks.
  defp crossings(size) do
    0
    |> Stream.unfold(fn
      sent when sent >= size -> nil
      sent -> {min(sent + @chunk, size), min(sent + @chunk, size)}
    end)
    |> Enum.reduce({0, []}, fn now, {before, crossed} ->
      if MoveProgress.crossed?(before, now, size),
        do: {now, [now | crossed]},
        else: {now, crossed}
    end)
    |> elem(1)
    |> Enum.reverse()
  end
end
