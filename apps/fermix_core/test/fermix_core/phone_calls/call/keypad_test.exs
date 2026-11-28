defmodule FermixCore.PhoneCalls.Call.KeypadTest do
  use ExUnit.Case, async: true

  alias FermixCore.PhoneCalls.Call.Keypad

  # A caller as `GenServer.reply/2` takes one; nothing is sent to it here.
  @from {:caller, :tag}

  defp acked(event_id), do: {:dtmf_sent, %{client_event_id: event_id}}

  test "one key at a time: each waits for its own acknowledgement" do
    keypad = Keypad.new(@from, "del_1", "12#")
    assert {:press, "1"} = Keypad.next(keypad)

    keypad = Keypad.pressing(keypad, "1", "evt_1")
    # In flight until its own acknowledgement comes.
    assert Keypad.printable(keypad).in_flight
    assert :unrelated = Keypad.acknowledge(keypad, acked("evt_other"))

    assert {:confirmed, keypad} = Keypad.acknowledge(keypad, acked("evt_1"))
    assert {:press, "2"} = Keypad.next(keypad)

    {:confirmed, keypad} =
      keypad |> Keypad.pressing("2", "evt_2") |> Keypad.acknowledge(acked("evt_2"))

    {:confirmed, keypad} =
      keypad |> Keypad.pressing("#", "evt_3") |> Keypad.acknowledge(acked("evt_3"))

    assert :done = Keypad.next(keypad)

    assert {@from, {:ok, %{confirmed: "12#", unconfirmed: "", stopped: nil}}} =
             Keypad.answer(keypad, nil)
  end

  test "a refused key stops the sequence; it and every key after it are unconfirmed" do
    keypad = Keypad.new(@from, "del_1", "123")

    {:confirmed, keypad} =
      keypad |> Keypad.pressing("1", "evt_1") |> Keypad.acknowledge(acked("evt_1"))

    keypad = Keypad.pressing(keypad, "2", "evt_2")

    assert :refused =
             Keypad.acknowledge(keypad, {:vendor_error, %{client_event_id: "evt_2", code: "x"}})

    assert {@from, {:ok, %{confirmed: "1", unconfirmed: "23", stopped: :refused}}} =
             Keypad.answer(keypad, :refused)
  end

  test "a key that never went out says why, and nothing is sent again" do
    assert Keypad.send_stopped({:not_sent, :closed}) == :not_sent
    assert Keypad.send_stopped({:unknown, :timeout}) == :send_unknown
    assert Keypad.send_stopped(:invalid_dtmf_key) == :invalid_key
  end

  test "the key cap before any key is a refusal; after one, a partial sequence" do
    cap = {:cap_reached, :dtmf_keys}
    keypad = Keypad.new(@from, "del_1", "12")
    assert {@from, {:error, ^cap}} = Keypad.answer(keypad, cap)

    {:confirmed, keypad} =
      keypad |> Keypad.pressing("1", "evt_1") |> Keypad.acknowledge(acked("evt_1"))

    assert {@from, {:ok, %{confirmed: "1", unconfirmed: "2", stopped: ^cap}}} =
             Keypad.answer(keypad, cap)
  end

  test "belongs to the turn that asked" do
    keypad = Keypad.new(@from, "del_1", "1")
    assert Keypad.asked_by?(keypad, "del_1")
    refute Keypad.asked_by?(keypad, "del_2")
  end

  test "prints counts, never the keys" do
    keypad = "del_1" |> then(&Keypad.new(@from, &1, "4417")) |> Keypad.pressing("4", "evt_1")
    printed = Keypad.printable(keypad)

    assert printed == %{turn: "del_1", pending: 4, confirmed: 0, in_flight: true}
    refute inspect(printed) =~ "4417"
    assert Keypad.printable(nil) == nil
  end
end
