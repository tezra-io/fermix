defmodule FermixCore.Accessories.ControlTest do
  # The closed control-message set of the accessory link (PROTOCOL.md,
  # *Control messages*, *Message reference*): what a decoded message looks
  # like to the daemon, and what the encoder refuses to send.
  use ExUnit.Case, async: true

  alias FermixCore.Accessories.Control

  @id String.duplicate("ab", 32)
  @nonce :binary.copy(<<7>>, 32)

  test "a decoded message has atom keys, binary hex fields and string IDs" do
    json =
      Jason.encode!(%{
        "type" => "hello_ack",
        "gen" => 3,
        "wire" => 1,
        "kind" => "stackchan",
        "accessory_id" => @id,
        "firmware" => "0.1.0",
        "pack" => nil,
        "caps" => 127,
        "accessory_nonce" => Base.encode16(@nonce, case: :lower),
        "sig" => String.duplicate("01", 64),
        "battery_note" => "ignored"
      })

    assert {:ok, message} = Control.decode(:accessory, 0, json)

    assert message == %{
             type: "hello_ack",
             gen: 3,
             wire: 1,
             kind: "stackchan",
             accessory_id: @id,
             firmware: "0.1.0",
             pack: nil,
             caps: 127,
             accessory_nonce: @nonce,
             sig: :binary.copy(<<1>>, 64)
           }
  end

  test "the encoder writes what the decoder reads, and refuses what it would refuse" do
    message = %{type: "credit", gen: 9, stream: 2, bytes: 4_096}

    assert {:ok, json} = Control.encode(:accessory, message)
    assert Control.decode(:accessory, 2, json) == {:ok, message}
    assert Control.stream(message) == 2

    assert {:error, {:invalid_message, "credit", "bytes"}} =
             Control.encode(:accessory, %{message | bytes: 8_193})

    assert {:error, {:unknown_message, "credit"}} = Control.encode(:host, message)

    assert {:error, {:invalid_message, "credit", "gen"}} =
             Control.encode(:accessory, Map.delete(message, :gen))
  end

  test "an optional field may be absent, and is then absent from the decoded message" do
    assert {:ok, %{type: "call.end", gen: 1, stream: 4} = message} =
             Control.decode(:host, 4, ~s({"type":"call.end","gen":1,"stream":4}))

    refute Map.has_key?(message, :reason)
  end

  test "a nested object is validated field by field" do
    state = %{
      "battery" => nil,
      "power" => "usb",
      "brownout" => false,
      "volume" => 60,
      "brightness" => 80,
      "motion" => "ready",
      "calibration" => "valid"
    }

    json = &Jason.encode!(%{"type" => "attached", "gen" => 2, "state" => &1})

    assert {:ok, %{state: %{battery: nil, power: "usb", motion: "ready"}}} =
             Control.decode(:accessory, 0, json.(state))

    assert {:error, {:invalid_message, "attached", "state.volume"}} =
             Control.decode(:accessory, 0, json.(%{state | "volume" => 101}))

    assert {:error, {:invalid_message, "attached", "state.power"}} =
             Control.decode(:accessory, 0, json.(Map.delete(state, "power")))
  end

  test "a payload over the 8,192-byte cap, not UTF-8, or not one object is invalid_json" do
    sized = fn bytes ->
      prefix = ~s({"type":"pong","gen":1,"uptime_ms":1,"p":")
      prefix <> String.duplicate("a", bytes - byte_size(prefix) - 2) <> ~s("})
    end

    assert {:ok, %{type: "pong"}} = Control.decode(:accessory, 0, sized.(8_192))
    assert {:error, :invalid_json} = Control.decode(:accessory, 0, sized.(8_193))

    assert {:error, :invalid_json} =
             Control.decode(:accessory, 0, ~s({"type":"pong","x":") <> <<0xFF>> <> ~s("}))

    assert {:error, :invalid_json} = Control.decode(:accessory, 0, "")
    assert {:error, :invalid_json} = Control.decode(:accessory, 0, ~s({"a":{"a":1,"a":2}}))
  end

  test "each message names the capability it needs, and most need none" do
    assert Control.capability("check.tone") == :speaker
    assert Control.capability("spk.begin") == :speaker
    assert Control.capability("check.mic") == :mic
    assert Control.capability("mute.set") == :mic
    assert Control.capability("check.face") == :screen
    assert Control.capability("accessory.calibrate") == :motion
    assert Control.capability("check.motion") == :motion
    assert Control.capability("ping") == nil
    assert Control.capability("task.event") == nil
  end

  test "the sender sets are closed, and a type may belong to both" do
    assert "hello" in Control.messages(:host)
    refute "hello" in Control.messages(:accessory)
    assert "hello_ack" in Control.messages(:accessory)

    for shared <- ~w(refuse error enroll.cancel) do
      assert shared in Control.messages(:host) and shared in Control.messages(:accessory)
    end
  end
end
