defmodule FermixCore.Tools.PlaceSearch.Brave.PacerTest do
  # The door a home's Brave place searches go through (`Brave.Pacer`): one
  # request at a time, each sent when Brave's last answer allows it, none sent
  # into a spent window. Every test starts a pacer of its own on a clock it
  # moves by hand, so nothing here waits on the wall clock or shares the
  # application's pacer.
  use ExUnit.Case, async: true

  alias FermixCore.Tools.PlaceSearch.Brave.Pacer

  @within_ms 45_000

  describe "pacing/2: what an answer says of the next request" do
    test "a spent per-second window holds the next request for its reset" do
      assert Pacer.pacing(200, rate("1, 15000", "0, 14999", "1, 1419704")) == {:hold_ms, 1_000}
      assert Pacer.pacing(200, rate("1, 15000", "0, 14999", "2, 1419704")) == {:hold_ms, 2_000}
    end

    test "a spent window that resets in under a second still holds 1 s" do
      assert Pacer.pacing(200, rate("1, 15000", "0, 14999", "0, 1419704")) == {:hold_ms, 1_000}
    end

    test "a spent window whose reset cannot be read holds 1 s" do
      assert Pacer.pacing(200, rate(nil, "0, 14999", nil)) == {:hold_ms, 1_000}
      assert Pacer.pacing(200, rate(nil, "0, 14999", "soon")) == {:hold_ms, 1_000}
    end

    test "windows with requests left in every one hold nothing" do
      assert Pacer.pacing(200, rate("1, 15000", "1, 14999", "1, 1419704")) == {:hold_ms, 0}
      assert Pacer.pacing(200, rate(nil, "3, 14999", nil)) == {:hold_ms, 0}
    end

    test "a spent window that resets after 2 s spends the key until then" do
      assert Pacer.pacing(200, rate("1, 15000", "0, 14999", "30, 1419704")) == {:spent_ms, 30_000}

      assert Pacer.pacing(200, rate("1, 15000", "1, 0", "1, 1419704")) ==
               {:spent_ms, 1_419_704_000}
    end

    test "a 200 with no window, or one that cannot be read, carries no pacing information" do
      assert {:unread, why} = Pacer.pacing(200, %{})
      assert why =~ "x-ratelimit-remaining"

      assert {:unread, _why} = Pacer.pacing(200, rate(nil, "none, 14999", nil))
      assert {:unread, _why} = Pacer.pacing(200, rate(nil, "-1, 14999", nil))
    end

    test "a refusal with no window holds nothing and says nothing" do
      assert Pacer.pacing(400, %{}) == {:hold_ms, 0}
      assert Pacer.pacing(503, rate(nil, "soon", nil)) == {:hold_ms, 0}
    end

    test "a 429 holds for the spent window's reset, at least 1 s, and 1 s when it gives none" do
      assert Pacer.pacing(429, rate("1, 15000", "0, 14999", "1, 1419704")) == {:hold_ms, 1_000}
      assert Pacer.pacing(429, rate("1, 15000", "0, 14999", "0, 1419704")) == {:hold_ms, 1_000}
      assert Pacer.pacing(429, rate(nil, nil, "2, 1419704")) == {:hold_ms, 2_000}
      assert Pacer.pacing(429, %{}) == {:hold_ms, 1_000}
      assert Pacer.pacing(429, rate(nil, nil, "later")) == {:hold_ms, 1_000}
      assert Pacer.pacing(429, rate("1, 15000", "1, 14999", "1, 1419704")) == {:hold_ms, 1_000}
    end

    test "a 429 whose reset comes after 2 s spends the key until then" do
      assert Pacer.pacing(429, rate("1, 15000", "0, 14999", "9, 1419704")) == {:spent_ms, 9_000}
      assert Pacer.pacing(429, rate(nil, nil, "5, 1419704")) == {:spent_ms, 5_000}

      assert Pacer.pacing(429, rate("1, 15000", "0, 0", "1, 1419704")) ==
               {:spent_ms, 1_419_704_000}
    end

    test "windows given on several header lines are read in order" do
      headers = %{"x-ratelimit-remaining" => ["1", "0"], "x-ratelimit-reset" => ["1", "9"]}
      assert Pacer.pacing(200, headers) == {:spent_ms, 9_000}
    end
  end

  describe "turns" do
    setup :start_pacer

    test "a turn with nothing ahead of it sends at once", %{pacer: pacer} do
      assert {:ok, turn, 0} = Pacer.turn(pacer, @within_ms)
      finish(pacer, turn, {:hold_ms, 0})
      assert {:ok, _turn, 0} = Pacer.turn(pacer, @within_ms)
    end

    test "the turn after a spent window waits out its reset, less the time gone", ctx do
      %{pacer: pacer, clock: clock} = ctx
      {:ok, turn, 0} = Pacer.turn(pacer, @within_ms)
      finish(pacer, turn, {:hold_ms, 1_000})

      advance(clock, 400)
      assert {:ok, turn, 600} = Pacer.turn(pacer, @within_ms)
      finish(pacer, turn, {:hold_ms, 0})

      assert {:ok, _turn, 0} = Pacer.turn(pacer, @within_ms)
    end

    test "an answer with no pacing information lets the next turn go at once", %{pacer: pacer} do
      {:ok, turn, 0} = Pacer.turn(pacer, @within_ms)
      finish(pacer, turn, {:hold_ms, 1_000})
      {:ok, turn, 1_000} = Pacer.turn(pacer, @within_ms)
      finish(pacer, turn, {:unread, "no x-ratelimit-remaining header"})

      assert {:ok, _turn, 0} = Pacer.turn(pacer, @within_ms)
    end

    test "after an answer that spent the key, every turn is refused until its reset", ctx do
      %{pacer: pacer, clock: clock} = ctx
      {:ok, turn, 0} = Pacer.turn(pacer, @within_ms)
      finish(pacer, turn, {:spent_ms, 60_000})

      assert {:error, {:spent, 60_000}} = Pacer.turn(pacer, @within_ms)
      advance(clock, 59_000)
      assert {:error, {:spent, 1_000}} = Pacer.turn(pacer, @within_ms)
      advance(clock, 1_000)
      assert {:ok, _turn, 0} = Pacer.turn(pacer, @within_ms)
    end

    # M89 D13 B: the trip placer wakes at the reset the pacer last read.
    test "how long the key stays spent, asked without a turn: none once it resets", ctx do
      %{pacer: pacer, clock: clock} = ctx
      assert Pacer.spent_ms(pacer) == nil

      {:ok, turn, 0} = Pacer.turn(pacer, @within_ms)
      finish(pacer, turn, {:spent_ms, 60_000})
      assert Pacer.spent_ms(pacer) == 60_000
      advance(clock, 45_000)
      assert Pacer.spent_ms(pacer) == 15_000
      advance(clock, 15_000)
      assert Pacer.spent_ms(pacer) == nil

      # A short hold spends nothing.
      {:ok, turn, 0} = Pacer.turn(pacer, @within_ms)
      finish(pacer, turn, {:hold_ms, 1_000})
      assert Pacer.spent_ms(pacer) == nil
    end

    test "a turn that would send after its caller's wait ends is refused and holds nothing",
         %{pacer: pacer} do
      {:ok, turn, 0} = Pacer.turn(pacer, @within_ms)
      finish(pacer, turn, {:hold_ms, 1_000})

      assert {:error, :deadline} = Pacer.turn(pacer, 999)
      assert {:ok, _turn, 1_000} = Pacer.turn(pacer, 1_000)
    end

    test "again waits out the held turn's answer and keeps the turn", %{pacer: pacer} do
      {:ok, turn, 0} = Pacer.turn(pacer, @within_ms)
      :ok = Pacer.answered(pacer, turn, {:hold_ms, 1_000})

      assert {:ok, 1_000} = Pacer.again(pacer, turn)
      assert :ok = Pacer.done(pacer, turn)
    end

    test "again past the caller's wait, or into a spent key, is refused", %{pacer: pacer} do
      {:ok, turn, 0} = Pacer.turn(pacer, 500)
      :ok = Pacer.answered(pacer, turn, {:hold_ms, 1_000})
      assert {:error, :deadline} = Pacer.again(pacer, turn)

      :ok = Pacer.answered(pacer, turn, {:spent_ms, 9_000})
      assert {:error, {:spent, 9_000}} = Pacer.again(pacer, turn)
      :ok = Pacer.done(pacer, turn)
    end

    test "only the held turn's answer and end count; any other is answered and ignored",
         %{pacer: pacer} do
      {:ok, turn, 0} = Pacer.turn(pacer, @within_ms)

      assert :ok = Pacer.answered(pacer, make_ref(), {:hold_ms, 5_000})
      assert :ok = Pacer.done(pacer, make_ref())
      assert {:error, :not_holder} = Pacer.again(pacer, make_ref())

      # Still held: a caller with no time to wait is refused when its wait ends.
      assert {:error, :deadline} = Pacer.turn(pacer, 0)

      :ok = Pacer.done(pacer, turn)
      assert {:ok, _turn, 0} = Pacer.turn(pacer, @within_ms)
    end

    test "a turn held past its bound is taken back; its late answer and end change nothing",
         %{pacer: pacer} do
      {:ok, late, 0} = Pacer.turn(pacer, @within_ms)

      # The bound's timer, delivered by hand.
      send(pacer, {:overran, late})
      assert {:ok, turn, 0} = Pacer.turn(pacer, @within_ms)

      assert :ok = Pacer.answered(pacer, late, {:hold_ms, 5_000})
      assert :ok = Pacer.done(pacer, late)
      assert {:error, :not_holder} = Pacer.again(pacer, late)

      :ok = Pacer.done(pacer, turn)
      assert {:ok, _turn, 0} = Pacer.turn(pacer, @within_ms)
    end

    test "a wait longer than any caller's is refused before it reaches the pacer", ctx do
      assert_raise FunctionClauseError, fn -> Pacer.turn(ctx.pacer, 120_001) end
    end
  end

  describe "callers wait in their own process, one after another" do
    setup :start_pacer

    test "a caller asking while a turn is held is answered when that turn ends, with the wait",
         %{pacer: pacer} do
      {:ok, first, 0} = Pacer.turn(pacer, @within_ms)
      second = Task.async(fn -> Pacer.turn(pacer, @within_ms) end)
      await_monitored_by(second.pid, pacer)

      finish(pacer, first, {:hold_ms, 1_000})

      assert {:ok, _turn, 1_000} = Task.await(second)

      # The second caller ended without ending its turn: its end frees it.
      assert {:ok, _turn, 1_000} = Pacer.turn(pacer, @within_ms)
    end

    test "a queued caller whose turn would come after its wait ends is refused at its turn",
         %{pacer: pacer} do
      {:ok, first, 0} = Pacer.turn(pacer, @within_ms)
      second = Task.async(fn -> Pacer.turn(pacer, 30_000) end)
      await_monitored_by(second.pid, pacer)

      # Its wait is measured from its asking: 30 s on the pacer's clock.
      finish(pacer, first, {:hold_ms, 30_001})

      assert {:error, :deadline} = Task.await(second)
    end

    test "a queued caller is refused at its turn when the answer before it spent the key",
         %{pacer: pacer} do
      {:ok, first, 0} = Pacer.turn(pacer, @within_ms)
      second = Task.async(fn -> Pacer.turn(pacer, @within_ms) end)
      await_monitored_by(second.pid, pacer)

      finish(pacer, first, {:spent_ms, 1_419_704_000})

      assert {:error, {:spent, 1_419_704_000}} = Task.await(second)
    end

    test "a queued caller whose wait ends in the queue is refused then", %{pacer: pacer} do
      {:ok, _first, 0} = Pacer.turn(pacer, @within_ms)

      # Nothing ends the held turn, so only the queued caller's own wait,
      # of nothing, can answer it.
      assert {:error, :deadline} = Pacer.turn(pacer, 0)
    end

    test "a holder that dies gives its turn to the next caller", %{pacer: pacer} do
      test_pid = self()

      holder =
        spawn(fn ->
          send(test_pid, {:held, Pacer.turn(pacer, @within_ms)})

          receive do
            :never -> :ok
          end
        end)

      assert_receive {:held, {:ok, _turn, 0}}
      watch = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^watch, :process, ^holder, :killed}

      assert {:ok, _turn, 0} = Pacer.turn(pacer, @within_ms)
    end
  end

  defp start_pacer(_context) do
    clock = start_supervised!({Agent, fn -> 0 end})
    now_ms = fn -> Agent.get(clock, & &1) end
    pacer = start_supervised!({Pacer, name: nil, now_ms: now_ms})
    %{pacer: pacer, clock: clock}
  end

  defp advance(clock, ms), do: Agent.update(clock, &(&1 + ms))

  defp finish(pacer, turn, pacing) do
    :ok = Pacer.answered(pacer, turn, pacing)
    :ok = Pacer.done(pacer, turn)
  end

  # Brave's rate headers as Req hands them over: lower-case names, each a list
  # of the values its header lines carried.
  defp rate(limit, remaining, reset) do
    [
      {"x-ratelimit-limit", limit},
      {"x-ratelimit-remaining", remaining},
      {"x-ratelimit-reset", reset}
    ]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Map.new(fn {name, value} -> {name, [value]} end)
  end

  # The pacer monitors each caller it holds a place for, and says nothing else
  # until that caller's turn comes.
  defp await_monitored_by(pid, pacer, attempts \\ 10_000) do
    {:monitored_by, watchers} = Process.info(pid, :monitored_by)

    cond do
      pacer in watchers ->
        :ok

      attempts == 0 ->
        flunk("the pacer never took the caller's place in its queue")

      true ->
        # sleep: polls the caller's monitors, which announce nothing
        Process.sleep(1)
        await_monitored_by(pid, pacer, attempts - 1)
    end
  end
end
