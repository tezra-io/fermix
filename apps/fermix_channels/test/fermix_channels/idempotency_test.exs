defmodule FermixChannels.IdempotencyTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Idempotency

  setup do
    table = :"idempotency_table_#{System.unique_integer([:positive])}"
    name = :"idempotency_#{System.unique_integer([:positive])}"
    start_supervised!({Idempotency, name: name, table: table})
    %{table: table, server: name}
  end

  test "returns :fresh once and :duplicate thereafter for the same key", %{server: server} do
    assert :fresh = Idempotency.check_and_record(:telegram, "evt-1", server: server)
    assert :duplicate = Idempotency.check_and_record(:telegram, "evt-1", server: server)
    assert :duplicate = Idempotency.check_and_record(:telegram, "evt-1", server: server)
  end

  test "keys are scoped by channel", %{server: server} do
    assert :fresh = Idempotency.check_and_record(:telegram, "shared-id", server: server)
    assert :fresh = Idempotency.check_and_record(:slack, "shared-id", server: server)
    assert :duplicate = Idempotency.check_and_record(:telegram, "shared-id", server: server)
  end

  test "expired entries are treated as fresh again", %{server: server} do
    assert :fresh =
             Idempotency.check_and_record(:telegram, "evt-ttl", ttl_ms: 1, server: server)

    Process.sleep(5)

    assert :fresh =
             Idempotency.check_and_record(:telegram, "evt-ttl", ttl_ms: 1, server: server)
  end

  test "concurrent callers for the same missing key see exactly one :fresh", %{server: server} do
    parent = self()

    tasks =
      for _i <- 1..50 do
        Task.async(fn ->
          send(
            parent,
            {:result, Idempotency.check_and_record(:telegram, "race-id", server: server)}
          )
        end)
      end

    Enum.each(tasks, &Task.await/1)

    results =
      for _ <- 1..50 do
        receive do
          {:result, r} -> r
        after
          1_000 -> flunk("missing result")
        end
      end

    assert Enum.count(results, &(&1 == :fresh)) == 1
    assert Enum.count(results, &(&1 == :duplicate)) == 49
  end

  test "concurrent callers replacing an EXPIRED entry see exactly one :fresh", %{
    server: server,
    table: table
  } do
    # Seed an expired entry directly so every caller hits the
    # "missing or expired" branch and races for the in-GenServer CAS.
    key = {:telegram, "expired-race-id"}
    past_deadline = System.monotonic_time(:millisecond) - 100_000
    :ets.insert(table, {key, past_deadline})

    parent = self()

    tasks =
      for _i <- 1..50 do
        Task.async(fn ->
          send(
            parent,
            {:result, Idempotency.check_and_record(:telegram, "expired-race-id", server: server)}
          )
        end)
      end

    Enum.each(tasks, &Task.await/1)

    results =
      for _ <- 1..50 do
        receive do
          {:result, r} -> r
        after
          1_000 -> flunk("missing result")
        end
      end

    assert Enum.count(results, &(&1 == :fresh)) == 1
    assert Enum.count(results, &(&1 == :duplicate)) == 49
  end

  test "forget/3 removes the record so the next call is fresh again", %{server: server} do
    assert :fresh = Idempotency.check_and_record(:slack, "abc", server: server)
    assert :duplicate = Idempotency.check_and_record(:slack, "abc", server: server)

    :ok = Idempotency.forget(:slack, "abc", server: server)

    assert :fresh = Idempotency.check_and_record(:slack, "abc", server: server)
  end
end
