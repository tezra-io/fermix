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

  # The latest microphone opening's levels ride `diag.counters` beside its
  # `counters`, all six or none (PROTOCOL.md (accessory), *Diagnostics*).
  describe "diag.counters' levels" do
    @counters %{
      "uptime_s" => 75,
      "frames_rx" => 31,
      "frames_tx" => 1_204,
      "crc_errors" => 0,
      "resync_bytes" => 0,
      "pcm_seq_gaps" => 0,
      "mic_overflows" => 0,
      "spk_underflows" => 0
    }
    @levels %{
      "mic_rms" => 238,
      "mic_peak" => 911,
      "ref_rms" => 4,
      "ref_peak" => 17,
      "out_rms" => 702,
      "out_peak" => 2_655
    }

    defp counters_json(fields) do
      %{"type" => "diag.counters", "gen" => 4, "counters" => @counters}
      |> Map.merge(fields)
      |> Jason.encode!()
    end

    test "all six decode beside the counters and encode back" do
      assert {:ok, message} = Control.decode(:accessory, 0, counters_json(@levels))

      assert %{
               counters: %{uptime_s: 75, frames_tx: 1_204},
               mic_rms: 238,
               mic_peak: 911,
               ref_rms: 4,
               ref_peak: 17,
               out_rms: 702,
               out_peak: 2_655
             } = message

      assert {:ok, json} = Control.encode(:accessory, message)
      assert Jason.decode!(json) == Map.merge(Jason.decode!(counters_json(%{})), @levels)
    end

    test "none is a message without them" do
      assert {:ok, message} = Control.decode(:accessory, 0, counters_json(%{}))
      assert Map.keys(message) |> Enum.sort() == [:counters, :gen, :type]
    end

    test "some but not all is invalid, named by the first missing level" do
      partial = Map.take(@levels, ["mic_rms", "mic_peak", "out_peak"])

      assert {:error, {:invalid_message, "diag.counters", "ref_rms"}} =
               Control.decode(:accessory, 0, counters_json(partial))

      assert {:error, {:invalid_message, "diag.counters", "mic_rms"}} =
               Control.decode(:accessory, 0, counters_json(Map.delete(@levels, "mic_rms")))

      assert {:error, {:invalid_message, "diag.counters", "out_peak"}} =
               Control.encode(:accessory, %{
                 type: "diag.counters",
                 gen: 4,
                 counters: Map.new(@counters, fn {k, v} -> {String.to_existing_atom(k), v} end),
                 mic_rms: 1,
                 mic_peak: 2,
                 ref_rms: 3,
                 ref_peak: 4,
                 out_rms: 5
               })
    end

    test "a level is an int16 magnitude, 0 to 32,767" do
      assert {:ok, %{mic_peak: 32_767}} =
               Control.decode(:accessory, 0, counters_json(%{@levels | "mic_peak" => 32_767}))

      assert {:error, {:invalid_message, "diag.counters", "mic_peak"}} =
               Control.decode(:accessory, 0, counters_json(%{@levels | "mic_peak" => 32_768}))

      assert {:error, {:invalid_message, "diag.counters", "ref_rms"}} =
               Control.decode(:accessory, 0, counters_json(%{@levels | "ref_rms" => -1}))
    end
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
