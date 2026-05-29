defmodule FermixChannels.Gateway.IdempotencyTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.Idempotency

  setup do
    table = :"idempotency_table_#{System.unique_integer([:positive])}"
    name = :"idempotency_#{System.unique_integer([:positive])}"
    start_supervised!({Idempotency, name: name, table: table})
    %{table: table, server: name}
  end

  test "returns :fresh once and :duplicate thereafter for the same key", %{server: server} do
    test_pid = self()
    handler_id = "test-idempotency-check-#{System.unique_integer()}"

    :telemetry.attach(
      handler_id,
      [:fermix, :idempotency, :check],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :fresh = Idempotency.check_and_record(:telegram, "evt-1", server: server)
    assert :duplicate = Idempotency.check_and_record(:telegram, "evt-1", server: server)
    assert :duplicate = Idempotency.check_and_record(:telegram, "evt-1", server: server)

    assert_receive {:telemetry, [:fermix, :idempotency, :check], measurements, metadata}
    assert measurements.duration_us >= 0
    assert metadata.channel == :telegram
    assert metadata.result == :fresh
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

  test "outbound media claims include file contents and suppress later duplicates", %{
    server: server
  } do
    test_pid = self()
    handler_id = "test-idempotency-outbound-media-#{System.unique_integer()}"

    :telemetry.attach(
      handler_id,
      [:fermix, :idempotency, :outbound_media_claim],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    dir = FermixTestSupport.SafeRm.make_tmp_dir!("outbound-media-idempotency")

    try do
      path = Path.join(dir, "report.txt")
      File.write!(path, "one")
      media_part = %{kind: :document, path: path, filename: "report.txt"}

      assert {:ok, {:fresh, _claim}} =
               Idempotency.claim_outbound_media(:telegram, "chat-1", media_part, server: server)

      assert {:ok, :duplicate} =
               Idempotency.claim_outbound_media(:telegram, "chat-1", media_part, server: server)

      assert_receive {:telemetry, [:fermix, :idempotency, :outbound_media_claim], measurements,
                      metadata}

      assert measurements.duration_us >= 0
      assert metadata.channel == :telegram
      assert metadata.result == :fresh

      File.write!(path, "two")

      assert {:ok, {:fresh, _claim}} =
               Idempotency.claim_outbound_media(:telegram, "chat-1", media_part, server: server)
    after
      FermixTestSupport.SafeRm.rm_rf!(dir)
    end
  end

  test "concurrent outbound media claims for the same key see exactly one fresh claim", %{
    server: server
  } do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("outbound-media-claim-race")

    try do
      path = Path.join(dir, "report.txt")
      File.write!(path, "one")
      media_part = %{kind: :document, path: path, filename: "report.txt"}
      parent = self()

      tasks =
        for _i <- 1..50 do
          Task.async(fn ->
            result =
              Idempotency.claim_outbound_media(:telegram, "chat-1", media_part, server: server)

            send(parent, {:result, result})
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

      assert results |> Enum.filter(&match?({:ok, {:fresh, _claim}}, &1)) |> length() == 1
      assert Enum.count(results, &(&1 == {:ok, :duplicate})) == 49
    after
      FermixTestSupport.SafeRm.rm_rf!(dir)
    end
  end

  test "releasing an outbound media claim allows a later retry", %{server: server} do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("outbound-media-release")

    try do
      path = Path.join(dir, "report.txt")
      File.write!(path, "one")
      media_part = %{kind: :document, path: path, filename: "report.txt"}

      assert {:ok, {:fresh, claim}} =
               Idempotency.claim_outbound_media(:telegram, "chat-1", media_part, server: server)

      assert :ok = Idempotency.release_outbound_media_claim(claim, server: server)

      assert {:ok, {:fresh, _claim}} =
               Idempotency.claim_outbound_media(:telegram, "chat-1", media_part, server: server)
    after
      FermixTestSupport.SafeRm.rm_rf!(dir)
    end
  end
end
