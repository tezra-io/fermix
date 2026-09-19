defmodule FermixCore.ComputerUse.InputOwnerTest do
  @moduledoc """
  One native input owner across conversations (M42 slice 2 §6). There is exactly
  one cursor and one focused window on the machine, so two conversations driving
  them at once is not concurrency — it is two agents fighting over the same seat,
  each reading a screen the other is changing. The seat is taken, not queued: a
  second conversation is told so at once rather than having a click land minutes
  later on a screen that has moved on.
  """

  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.InputOwner

  defp start_owner(opts \\ []) do
    name = :"input_owner_#{System.unique_integer([:positive])}"
    start_supervised!({InputOwner, Keyword.merge([name: name], opts)}, id: name)
    name
  end

  # A process that lives until the test releases it, standing in for a session
  # holding the seat.
  defp holder do
    pid = spawn(fn -> receive do: (:done -> :ok) end)
    on_exit(fn -> send(pid, :done) end)
    pid
  end

  test "the first conversation takes the seat and a second is refused, not queued" do
    owner = start_owner()
    a = holder()
    b = holder()

    assert :ok = InputOwner.acquire(a, owner)
    assert {:error, :input_busy} = InputOwner.acquire(b, owner)
  end

  test "the holder re-acquires its own seat freely" do
    owner = start_owner()
    a = holder()

    assert :ok = InputOwner.acquire(a, owner)
    assert :ok = InputOwner.acquire(a, owner)
    assert :ok = InputOwner.acquire(a, owner)
  end

  # A session is `:temporary` and dies on a poison reset, an abort, or the end of
  # its conversation. Without the monitor the seat would be held by a corpse and
  # no other conversation could ever act.
  test "the seat is released when its holder dies" do
    owner = start_owner()
    a = holder()
    b = holder()

    assert :ok = InputOwner.acquire(a, owner)

    ref = Process.monitor(a)
    send(a, :done)
    assert_receive {:DOWN, ^ref, :process, ^a, _reason}

    assert :ok = InputOwner.acquire(b, owner)
  end

  # `idle_lapse_ms: 0` means "any gap at all has lapsed", which makes the rule
  # observable without a sleep: a holder that has dispatched nothing since its
  # last acquire cannot hold the seat against another conversation forever.
  test "ownership lapses once the holder has dispatched nothing for the idle period" do
    owner = start_owner(idle_lapse_ms: 0)
    a = holder()
    b = holder()

    assert :ok = InputOwner.acquire(a, owner)
    assert :ok = InputOwner.acquire(b, owner)
    # …and the new holder now owns it against the old one, which must ask again.
    assert :ok = InputOwner.acquire(b, owner)
  end

  # No arbiter running (computer-use disabled, so no CU tree) means there is
  # nothing to arbitrate BETWEEN — the same shape `CaptureHealth.status/0` uses.
  # It must not raise: a teardown backstop and every direct-started session in the
  # suite reach it.
  test "acquiring against an absent owner is a clean grant, never a crash" do
    assert :ok = InputOwner.acquire(self(), :input_owner_that_is_not_running)
  end
end
