defmodule FermixCore.Management.LifecycleTest do
  use ExUnit.Case, async: true

  alias FermixCore.Management.Lifecycle

  setup context do
    parent = self()

    server =
      start_supervised!(
        {Lifecycle,
         name: :"lifecycle_#{:erlang.phash2(context.test)}",
         lease_ttl_ms: Map.get(context, :lease_ttl_ms, 5_000),
         shutdown: fn -> send(parent, :shutdown_invoked) end}
      )

    %{server: server}
  end

  # The expiry timer runs on Erlang monotonic time, which is frozen across
  # sleep on Darwin and never stepped by NTP. Publishing a wall-clock deadline
  # against it makes the client believe the lease died while the server still
  # holds it — every later `prepare` answers `busy` for the residual TTL. The
  # lease therefore publishes the relative TTL the timer was armed with, and
  # the client measures it against its own clock.
  test "prepare mints one lease carrying the relative ttl its timer was armed with", %{
    server: server
  } do
    assert {:ok, lease} = Lifecycle.prepare(server: server)

    assert is_binary(lease.lease_id)
    assert String.starts_with?(lease.lease_id, "lease_")
    assert lease.ttl_ms == 5_000
    refute Map.has_key?(lease, :expires_at_ms)
    assert Lifecycle.prepared?(server: server)
  end

  test "a second prepare while a lease is held is refused as busy", %{server: server} do
    assert {:ok, _lease} = Lifecycle.prepare(server: server)
    assert {:error, :busy} = Lifecycle.prepare(server: server)
  end

  test "commit runs the daemon shutdown path exactly once", %{server: server} do
    assert {:ok, %{lease_id: lease_id}} = Lifecycle.prepare(server: server)

    assert {:ok, %{lease_id: ^lease_id, status: :committed}} =
             Lifecycle.commit(lease_id, server: server)

    assert_receive :shutdown_invoked, 500
    refute Lifecycle.prepared?(server: server)

    assert {:error, :unknown_lease} = Lifecycle.commit(lease_id, server: server)
    refute_receive :shutdown_invoked, 100
  end

  test "cancel releases the lease without shutting the daemon down", %{server: server} do
    assert {:ok, %{lease_id: lease_id}} = Lifecycle.prepare(server: server)

    assert {:ok, %{lease_id: ^lease_id, status: :cancelled}} =
             Lifecycle.cancel(lease_id, server: server)

    refute Lifecycle.prepared?(server: server)
    refute_receive :shutdown_invoked, 100

    assert {:error, :unknown_lease} = Lifecycle.commit(lease_id, server: server)
    assert {:ok, _new_lease} = Lifecycle.prepare(server: server)
  end

  @tag lease_ttl_ms: 40
  test "a prepared daemon auto-resumes when the lease expires without commit", %{server: server} do
    assert {:ok, %{lease_id: lease_id}} = Lifecycle.prepare(server: server)

    wait_until(fn -> not Lifecycle.prepared?(server: server) end)

    refute_receive :shutdown_invoked, 100
    assert {:error, :lease_expired} = Lifecycle.commit(lease_id, server: server)
    assert {:error, :lease_expired} = Lifecycle.cancel(lease_id, server: server)
    assert {:ok, _new_lease} = Lifecycle.prepare(server: server)
  end

  test "an unissued lease id is refused as unknown", %{server: server} do
    assert {:error, :unknown_lease} = Lifecycle.commit("lease_never_issued", server: server)
    assert {:error, :unknown_lease} = Lifecycle.cancel("lease_never_issued", server: server)
  end

  test "the expired-lease memory is bounded", %{server: server} do
    ids =
      for _ <- 1..(Lifecycle.max_remembered_leases() + 3) do
        {:ok, %{lease_id: lease_id}} = Lifecycle.prepare(server: server)
        send(server, {:lease_expired, lease_id})
        wait_until(fn -> not Lifecycle.prepared?(server: server) end)
        lease_id
      end

    [oldest | _rest] = ids
    newest = List.last(ids)

    assert {:error, :unknown_lease} = Lifecycle.commit(oldest, server: server)
    assert {:error, :lease_expired} = Lifecycle.commit(newest, server: server)
  end

  defp wait_until(predicate, attempts \\ 50)

  defp wait_until(_predicate, 0), do: flunk("condition never became true")

  defp wait_until(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      wait_until(predicate, attempts - 1)
    end
  end
end
