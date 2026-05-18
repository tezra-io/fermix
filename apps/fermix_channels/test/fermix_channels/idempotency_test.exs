defmodule FermixChannels.IdempotencyTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Idempotency

  setup do
    table = :"idempotency_table_#{System.unique_integer([:positive])}"
    name = :"idempotency_#{System.unique_integer([:positive])}"
    start_supervised!({Idempotency, name: name, table: table})
    %{table: table}
  end

  test "returns :fresh once and :duplicate thereafter for the same key", %{table: table} do
    assert :fresh = Idempotency.check_and_record(:telegram, "evt-1", table: table)
    assert :duplicate = Idempotency.check_and_record(:telegram, "evt-1", table: table)
    assert :duplicate = Idempotency.check_and_record(:telegram, "evt-1", table: table)
  end

  test "keys are scoped by channel", %{table: table} do
    assert :fresh = Idempotency.check_and_record(:telegram, "shared-id", table: table)
    assert :fresh = Idempotency.check_and_record(:slack, "shared-id", table: table)
    assert :duplicate = Idempotency.check_and_record(:telegram, "shared-id", table: table)
  end

  test "expired entries are treated as fresh again", %{table: table} do
    assert :fresh =
             Idempotency.check_and_record(:telegram, "evt-ttl", ttl_ms: 1, table: table)

    Process.sleep(5)

    assert :fresh =
             Idempotency.check_and_record(:telegram, "evt-ttl", ttl_ms: 1, table: table)
  end
end
