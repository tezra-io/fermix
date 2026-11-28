defmodule FermixChannels.Gateway.IngressLanesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias FermixChannels.Gateway.IngressLanes, as: Lanes

  defp lanes(max_active, max_waiting),
    do: Lanes.new(max_active: max_active, max_waiting: max_waiting)

  # Pushes that must all be taken, returning the lanes after the last one.
  defp push_all(lanes, pushes) do
    Enum.reduce(pushes, lanes, fn {key, item, expected}, lanes ->
      case {expected, Lanes.push(lanes, key, item)} do
        {:start, {:start, ^item, lanes}} ->
          lanes

        {:queued, {:queued, lanes}} ->
          lanes

        {expected, got} ->
          flunk("push #{inspect(item)}: expected #{expected}, got #{inspect(got)}")
      end
    end)
  end

  describe "new/1" do
    test "takes both bounds as positive integers" do
      lanes = lanes(8, 200)
      assert %Lanes{max_active: 8, max_waiting: 200} = lanes
    end

    test "refuses a missing, zero, negative or non-integer bound" do
      for opts <- [
            [max_waiting: 1],
            [max_active: 1],
            [max_active: 0, max_waiting: 1],
            [max_active: 1, max_waiting: -1],
            [max_active: 1.5, max_waiting: 1],
            [max_active: 1, max_waiting: :many]
          ] do
        assert_raise ArgumentError, ~r/positive integer/, fn -> Lanes.new(opts) end
      end
    end
  end

  describe "one conversation" do
    test "its first item starts and the next waits until the first finishes" do
      lanes = push_all(lanes(4, 10), [{:a, 1, :start}, {:a, 2, :queued}])

      assert {:start, :a, 2, lanes} = Lanes.finish(lanes, :a)
      assert {:idle, _lanes} = Lanes.finish(lanes, :a)
    end

    test "its items start in the order they were pushed" do
      lanes = push_all(lanes(4, 10), [{:a, 1, :start}, {:a, 2, :queued}, {:a, 3, :queued}])

      assert {:start, :a, 2, lanes} = Lanes.finish(lanes, :a)
      assert {:start, :a, 3, lanes} = Lanes.finish(lanes, :a)
      assert {:idle, _lanes} = Lanes.finish(lanes, :a)
    end

    test "an item never overtakes its own conversation's waiting items, even with a free slot" do
      # :a's second item waits behind :a's first; :b frees a slot, and :a's
      # third push still queues behind its second.
      lanes = push_all(lanes(2, 10), [{:a, 1, :start}, {:b, 2, :start}, {:a, 3, :queued}])
      assert {:idle, lanes} = Lanes.finish(lanes, :b)
      lanes = push_all(lanes, [{:a, 4, :queued}])

      assert {:start, :a, 3, lanes} = Lanes.finish(lanes, :a)
      assert {:start, :a, 4, _lanes} = Lanes.finish(lanes, :a)
    end
  end

  describe "across conversations" do
    test "different conversations run side by side up to max_active" do
      lanes = push_all(lanes(2, 10), [{:a, 1, :start}, {:b, 2, :start}, {:c, 3, :queued}])

      assert {:start, :c, 3, _lanes} = Lanes.finish(lanes, :b)
    end

    test "conversations waiting for a slot are served in the order they became ready" do
      lanes =
        push_all(lanes(1, 10), [
          {:a, 1, :start},
          {:c, 2, :queued},
          {:b, 3, :queued},
          {:c, 4, :queued}
        ])

      assert {:start, :c, 2, lanes} = Lanes.finish(lanes, :a)
      assert {:start, :b, 3, lanes} = Lanes.finish(lanes, :c)
      assert {:start, :c, 4, lanes} = Lanes.finish(lanes, :b)
      assert {:idle, _lanes} = Lanes.finish(lanes, :c)
    end

    test "a conversation whose item just finished goes behind those already waiting" do
      # :a is busy with three items; :b waits for the one slot. When :a's first
      # finishes, :b runs before :a's second, and :a's third waits behind :b's.
      lanes =
        push_all(lanes(1, 10), [
          {:a, 1, :start},
          {:a, 2, :queued},
          {:b, 3, :queued},
          {:a, 4, :queued},
          {:b, 5, :queued}
        ])

      assert {:start, :b, 3, lanes} = Lanes.finish(lanes, :a)
      assert {:start, :a, 2, lanes} = Lanes.finish(lanes, :b)
      assert {:start, :b, 5, lanes} = Lanes.finish(lanes, :a)
      assert {:start, :a, 4, lanes} = Lanes.finish(lanes, :b)
      assert {:idle, _lanes} = Lanes.finish(lanes, :a)
    end
  end

  describe "capacity" do
    test "a push beyond max_waiting is :full and keeps nothing" do
      lanes = push_all(lanes(1, 2), [{:a, 1, :start}, {:a, 2, :queued}, {:b, 3, :queued}])

      assert {:full, ^lanes} = Lanes.push(lanes, :c, 4)
      assert {:full, ^lanes} = Lanes.push(lanes, :a, 5)

      assert {:start, :b, 3, lanes} = Lanes.finish(lanes, :a)
      assert {:start, :a, 2, lanes} = Lanes.finish(lanes, :b)
      assert {:idle, _lanes} = Lanes.finish(lanes, :a)
    end

    test "a place freed by a start takes a push again" do
      lanes = push_all(lanes(1, 1), [{:a, 1, :start}, {:b, 2, :queued}])
      assert {:full, ^lanes} = Lanes.push(lanes, :c, 3)

      assert {:start, :b, 2, lanes} = Lanes.finish(lanes, :a)
      assert {:queued, _lanes} = Lanes.push(lanes, :c, 3)
    end

    test "an item that can start now is never refused, whatever waits" do
      lanes = push_all(lanes(2, 1), [{:a, 1, :start}, {:a, 2, :queued}])

      assert {:start, 3, _lanes} = Lanes.push(lanes, :b, 3)
    end
  end

  describe "guards" do
    test "finishing a conversation with nothing running raises" do
      lanes = push_all(lanes(1, 10), [{:a, 1, :start}, {:b, 2, :queued}])

      assert_raise ArgumentError, ~r/nothing is running under :b/, fn ->
        Lanes.finish(lanes, :b)
      end

      assert_raise ArgumentError, ~r/nothing is running under :z/, fn ->
        Lanes.finish(lanes, :z)
      end
    end
  end

  # The rule as a model the lanes must match step for step: which keys run,
  # each key's waiting items (oldest first), and the order keys became ready.
  # A random run of pushes and finishes is checked at every step, then drained:
  # every accepted item must start exactly once, in its key's push order.
  property "every push and finish follows the rule, and every accepted item starts once" do
    check all(
            max_active <- integer(1..3),
            max_waiting <- integer(1..5),
            ops <- list_of(op(), max_length: 80)
          ) do
      model = %{
        max_active: max_active,
        max_waiting: max_waiting,
        running: MapSet.new(),
        waiting: %{},
        ready: [],
        accepted: %{},
        started: %{}
      }

      {lanes, model} =
        ops
        |> Enum.with_index()
        |> Enum.reduce({lanes(max_active, max_waiting), model}, &step/2)

      {_lanes, model} = drain(lanes, model, length(ops) + 1)

      assert model.waiting == %{}
      assert model.started == model.accepted
    end
  end

  defp op do
    one_of([
      tuple({constant(:push), member_of([:a, :b, :c, :d])}),
      tuple({constant(:finish), integer(0..3)})
    ])
  end

  defp step({{:push, key}, item}, {lanes, model}) do
    may_start? =
      not busy?(model, key) and MapSet.size(model.running) < model.max_active

    result = Lanes.push(lanes, key, item)
    model = check_push(result, may_start?, model, lanes, key, item)
    {elem(result, tuple_size(result) - 1), checked(model)}
  end

  defp step({{:finish, pick}, _index}, {lanes, model}) do
    case model.running |> MapSet.to_list() |> Enum.sort() do
      [] -> {lanes, model}
      keys -> finish(lanes, model, Enum.at(keys, rem(pick, length(keys))))
    end
  end

  defp check_push({:start, item, _lanes}, true, model, _lanes_before, key, item),
    do: model |> accept(key, item) |> run(key, item)

  defp check_push({:queued, _lanes}, false, model, _lanes_before, key, item) do
    assert waiting_total(model) < model.max_waiting
    ready = if busy?(model, key), do: model.ready, else: model.ready ++ [key]
    waiting = Map.update(model.waiting, key, [item], &(&1 ++ [item]))
    accept(%{model | waiting: waiting, ready: ready}, key, item)
  end

  defp check_push({:full, lanes}, false, model, lanes_before, _key, _item) do
    assert waiting_total(model) == model.max_waiting
    assert lanes == lanes_before
    model
  end

  defp check_push(result, may_start?, _model, _lanes_before, key, item) do
    flunk(
      "push #{inspect(item)} under #{inspect(key)} (may start: #{may_start?}) " <>
        "returned #{inspect(result)}"
    )
  end

  # A finished key with waiting items becomes ready behind the keys already
  # ready; the freed slot then goes to the first ready key's oldest item.
  defp finish(lanes, model, key) do
    model = %{model | running: MapSet.delete(model.running, key)}

    model =
      if Map.has_key?(model.waiting, key), do: %{model | ready: model.ready ++ [key]}, else: model

    case {Lanes.finish(lanes, key), model.ready} do
      {{:idle, lanes}, []} ->
        {lanes, checked(model)}

      {{:start, next, item, lanes}, [next | ready]} ->
        [^item | rest] = Map.fetch!(model.waiting, next)

        waiting =
          if rest == [],
            do: Map.delete(model.waiting, next),
            else: Map.put(model.waiting, next, rest)

        {lanes, checked(run(%{model | waiting: waiting, ready: ready}, next, item))}

      {got, ready} ->
        flunk(
          "finish #{inspect(key)} returned #{inspect(got)}; ready keys were #{inspect(ready)}"
        )
    end
  end

  defp drain(_lanes, _model, 0), do: flunk("the lanes did not drain")

  defp drain(lanes, model, budget) do
    case model.running |> MapSet.to_list() |> Enum.sort() do
      [] ->
        {lanes, model}

      [key | _] ->
        {lanes, model} = finish(lanes, model, key)
        drain(lanes, model, budget - 1)
    end
  end

  # The invariants that hold between any two steps.
  defp checked(model) do
    assert MapSet.size(model.running) <= model.max_active
    assert waiting_total(model) <= model.max_waiting
    # No slot stays free while a conversation waits for one.
    if model.ready != [], do: assert(MapSet.size(model.running) == model.max_active)
    model
  end

  defp busy?(model, key),
    do: MapSet.member?(model.running, key) or Map.has_key?(model.waiting, key)

  defp run(model, key, item) do
    refute MapSet.member?(model.running, key), "two items of #{inspect(key)} running at once"

    %{
      model
      | running: MapSet.put(model.running, key),
        started: Map.update(model.started, key, [item], &(&1 ++ [item]))
    }
  end

  defp accept(model, key, item),
    do: %{model | accepted: Map.update(model.accepted, key, [item], &(&1 ++ [item]))}

  defp waiting_total(model),
    do: model.waiting |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
end
