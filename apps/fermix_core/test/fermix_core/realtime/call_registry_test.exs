defmodule FermixCore.Realtime.CallRegistryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.CallRegistry

  @first_uuid "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b"
  @second_uuid "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab"
  @started_at ~U[2026-10-03 14:05:00Z]

  setup do
    registry = :"call_registry_#{System.unique_integer([:positive])}"
    start_supervised!({CallRegistry, name: registry})
    %{registry: registry}
  end

  test "a claim names the call in progress and registers its UUID", %{registry: registry} do
    holder = claim_in_process(registry, @first_uuid)

    assert CallRegistry.active(registry) ==
             {:ok,
              %{
                call_uuid: @first_uuid,
                conversation: "chat",
                started_at: @started_at,
                session: holder
              }}

    assert CallRegistry.lookup(registry, @first_uuid) == {:ok, holder}
  end

  # M56 §4.4: a private call is not the chat's, and whoever reads the call in
  # progress can tell without asking its session.
  test "the claim says which conversation the call is in", %{registry: registry} do
    assert :ok = CallRegistry.claim(registry, call(@first_uuid, "private"))
    assert {:ok, %{conversation: "private", session: session}} = CallRegistry.active(registry)
    assert session == self()
  end

  # The registry runs only while voice does (`Realtime.Supervisor`), and a
  # typed chat message asks it for a call on every turn (M56 §4.3).
  test "with voice off, no registry runs and no call is in progress" do
    assert CallRegistry.active(:"call_registry_not_started_#{System.unique_integer()}") == :none
  end

  test "a second claim is refused while the first holder lives", %{registry: registry} do
    holder = claim_in_process(registry, @first_uuid)

    assert {:error, :call_in_progress} = CallRegistry.claim(registry, call(@second_uuid))
    assert CallRegistry.lookup(registry, @second_uuid) == :none
    assert {:ok, %{session: ^holder}} = CallRegistry.active(registry)
  end

  # Two connections starting a call at once: the claim is one `insert_new`, so
  # exactly one of them wins however their starts interleave.
  test "of many claims racing, exactly one wins", %{registry: registry} do
    test_pid = self()

    for index <- 1..20 do
      spawn(fn ->
        uuid = "00000000-0000-4000-8000-#{String.pad_leading(Integer.to_string(index), 12, "0")}"
        send(test_pid, {:claimed, CallRegistry.claim(registry, call(uuid))})

        hold_claim()
      end)
    end

    results = for _index <- 1..20, do: receive_claim()

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :call_in_progress})) == 19
  end

  test "the claim and the UUID go with the holder, however it ends", %{registry: registry} do
    holder = claim_in_process(registry, @first_uuid)
    ref = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}

    assert CallRegistry.active(registry) == :none
    assert CallRegistry.lookup(registry, @first_uuid) == :none

    assert :ok = CallRegistry.claim(registry, call(@second_uuid))
    assert {:ok, %{call_uuid: @second_uuid, session: session}} = CallRegistry.active(registry)
    assert session == self()
  end

  # A holder process that claims and then waits, so the claim outlives the call
  # that took it.
  defp claim_in_process(registry, uuid) do
    test_pid = self()

    holder =
      spawn(fn ->
        send(test_pid, {:claimed, CallRegistry.claim(registry, call(uuid))})

        hold_claim()
      end)

    assert receive_claim() == :ok
    holder
  end

  defp call(uuid, conversation \\ "chat"),
    do: %{call_uuid: uuid, conversation: conversation, started_at: @started_at}

  # Bounded, so a holder never outlives its test by more than a moment.
  defp hold_claim do
    receive do
      :release -> :ok
    after
      5_000 -> :ok
    end
  end

  defp receive_claim do
    receive do
      {:claimed, result} -> result
    after
      1_000 -> flunk("a claim never answered")
    end
  end
end
