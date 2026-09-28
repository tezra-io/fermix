defmodule FermixCore.Capabilities.AccessGate.PendingTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.AccessGate.Pending

  setup do
    clock = start_supervised!({Agent, fn -> 1_000 end}, id: :clock)
    name = :"access_pending_#{System.unique_integer([:positive])}"
    now = fn -> Agent.get(clock, & &1) end
    start_supervised!({Pending, name: name, clock: now})
    %{server: name, clock: clock}
  end

  defp advance(clock, ms), do: Agent.update(clock, &(&1 + ms))

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        tool: "tesla_unlock_doors",
        args: %{"vin" => "5YJ"},
        digest: "digest-a",
        plugin: "tesla",
        auth_profile: "tesla:default",
        binding: {:conversation, {"telegram", "1", :root}},
        sources: ["web_fetch"],
        snapshot: %{session_id: "s1"}
      },
      overrides
    )
  end

  test "a take is single use and returns the recorded call", %{server: server} do
    assert {:ok, id, :new} = Pending.park(attrs(), server)
    assert {:ok, record} = Pending.take(id, server)
    assert record.id == id
    assert record.args == %{"vin" => "5YJ"}
    assert record.tool == "tesla_unlock_doors"
    assert :error = Pending.take(id, server)
  end

  # A voice call names the command in a warning when its outcome goes unspoken.
  test "tool names a live record's command, whatever its status, until it expires", %{
    server: server,
    clock: clock
  } do
    assert :error = Pending.tool("missing", server)
    assert {:ok, id, :new} = Pending.park(attrs(), server)
    assert {:ok, "tesla_unlock_doors"} = Pending.tool(id, server)
    assert {:ok, record} = Pending.take(id, server)
    assert {:ok, "tesla_unlock_doors"} = Pending.tool(id, server)
    assert :ok = Pending.finish(record, "tesla_unlock_doors ran.", server)
    assert {:ok, "tesla_unlock_doors"} = Pending.tool(id, server)
    advance(clock, Pending.ttl_ms() + 1)
    assert :error = Pending.tool(id, server)
  end

  test "a record expires after the confirmation window", %{server: server, clock: clock} do
    assert {:ok, id, :new} = Pending.park(attrs(), server)
    advance(clock, Pending.ttl_ms() + 1)
    assert :error = Pending.take(id, server)
  end

  # A re-park may have sent the owner a fresh token (the last was denied or
  # expired), so the record's window restarts with it.
  test "an identical park answers :existing and restarts the window", %{
    server: server,
    clock: clock
  } do
    assert {:ok, id, :new} = Pending.park(attrs(), server)
    advance(clock, Pending.ttl_ms() - 10)
    assert {:ok, ^id, :existing} = Pending.park(attrs(), server)
    advance(clock, 20)
    assert {:ok, %{id: ^id}} = Pending.take(id, server)
  end

  test "an expired record parks afresh under a new id", %{server: server, clock: clock} do
    assert {:ok, id, :new} = Pending.park(attrs(), server)
    advance(clock, Pending.ttl_ms() + 1)
    assert {:ok, fresh, :new} = Pending.park(attrs(), server)
    refute fresh == id
  end

  test "a different binding or different arguments park separately", %{server: server} do
    assert {:ok, a, :new} = Pending.park(attrs(), server)
    assert {:ok, b, :new} = Pending.park(attrs(%{digest: "digest-b"}), server)
    assert {:ok, c, :new} = Pending.park(attrs(%{binding: {:voice_call, "call-1"}}), server)
    assert Enum.uniq([a, b, c]) == [a, b, c]
  end

  test "a running record answers :running, and a finished one answers with its outcome", %{
    server: server
  } do
    assert {:ok, id, :new} = Pending.park(attrs(), server)
    assert {:ok, record} = Pending.take(id, server)
    assert {:ok, ^id, :running} = Pending.park(attrs(), server)
    assert :ok = Pending.finish(record, "tesla_unlock_doors ran.", server)
    assert {:ok, ^id, {:done, "tesla_unlock_doors ran."}} = Pending.park(attrs(), server)
    assert :error = Pending.take(id, server)
  end

  test "discard drops a pending record", %{server: server} do
    assert {:ok, id, :new} = Pending.park(attrs(), server)
    assert :ok = Pending.discard(id, server)
    assert :error = Pending.take(id, server)
  end

  test "the store holds a bounded number of live records", %{server: server, clock: clock} do
    for n <- 1..Pending.max_live() do
      assert {:ok, _id, :new} = Pending.park(attrs(%{digest: "d#{n}"}), server)
    end

    assert {:error, :too_many_pending} = Pending.park(attrs(%{digest: "one-more"}), server)
    advance(clock, Pending.ttl_ms() + 1)
    assert {:ok, _id, :new} = Pending.park(attrs(%{digest: "one-more"}), server)
  end

  test "voice_pending answers the newest pending record for that call only", %{
    server: server,
    clock: clock
  } do
    call = {:voice_call, "call-1"}
    assert :none = Pending.voice_pending("call-1", server)
    assert {:ok, older, :new} = Pending.park(attrs(%{binding: call, digest: "a"}), server)
    advance(clock, 5)
    assert {:ok, newer, :new} = Pending.park(attrs(%{binding: call, digest: "b"}), server)
    assert {:ok, _other, :new} = Pending.park(attrs(%{binding: {:voice_call, "call-2"}}), server)

    assert {:ok, ^newer} = Pending.voice_pending("call-1", server)
    assert {:ok, _record} = Pending.take(newer, server)
    assert {:ok, ^older} = Pending.voice_pending("call-1", server)
  end

  # What a turn (or a call) parked and is still waiting on: the one question
  # "may this session act again yet", and which command a Live delegation's own
  # reply asked the owner about.
  test "pending_from answers the newest record that session parked, only while it waits", %{
    server: server,
    clock: clock
  } do
    assert :none = Pending.pending_from("s1", server)
    assert {:ok, older, :new} = Pending.park(attrs(%{digest: "a"}), server)
    advance(clock, 5)
    assert {:ok, newer, :new} = Pending.park(attrs(%{digest: "b"}), server)
    assert {:ok, _other, :new} = Pending.park(attrs(%{snapshot: %{session_id: "s2"}}), server)

    assert {:ok, ^newer} = Pending.pending_from("s1", server)
    assert {:ok, record} = Pending.take(newer, server)
    assert {:ok, ^older} = Pending.pending_from("s1", server)
    assert :ok = Pending.discard(older, server)
    assert :none = Pending.pending_from("s1", server)

    assert :ok = Pending.finish(record, "tesla_unlock_doors ran.", server)
    assert :none = Pending.pending_from("s1", server)
  end

  # `finish/3` is only ever handed the record `take/2` returned; anything else
  # is refused at the caller instead of crashing the store every later child of
  # the application's supervisor restarts with.
  test "finish accepts only a taken record", %{server: server} do
    assert {:ok, id, :new} = Pending.park(attrs(), server)
    assert {:ok, record} = Pending.take(id, server)
    untaken = Map.put(record, :status, :pending)

    assert_raise FunctionClauseError, fn -> Pending.finish(untaken, "ran", server) end
    assert :ok = Pending.finish(record, "ran", server)
  end
end
