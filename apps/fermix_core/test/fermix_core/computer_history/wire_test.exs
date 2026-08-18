defmodule FermixCore.ComputerHistory.WireTest do
  @moduledoc "MILESTONE_32 §8.4a — the capture-mode wire decoder (Fermix side)."
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Wire

  defp line(map), do: Jason.encode!(map)

  describe "event frames" do
    test "a full field.value event decodes onto the event columns" do
      frame =
        line(%{
          "type" => "event",
          "v" => 1,
          "ts" => 1_700,
          "seq" => 5,
          "boot_id" => "boot-abc",
          "app" => %{"bundle_id" => "com.apple.Safari", "name" => "Safari", "pid" => 42},
          "kind" => "field.value",
          "window_title" => "Inbox",
          "url" => "https://github.com/x",
          "host" => "github.com",
          "field_label" => "To",
          "text" => "hi there",
          "content_withheld" => false,
          "char_len" => 8
        })

      assert {:event, event} = Wire.decode(frame)
      assert event.boot_id == "boot-abc"
      assert event.source_seq == 5
      assert event.ts == 1_700
      assert event.type == "field.value"
      assert event.bundle_id == "com.apple.Safari"
      assert event.window_title == "Inbox"
      assert event.host == "github.com"
      assert event.text == "hi there"
      assert event.char_len == 8
      assert event.content_withheld == false
      # scan_flag is never on the wire — Ingest computes it.
      refute Map.has_key?(event, :scan_flag)
    end

    test "content_withheld true is carried; a private-unknown withhold round-trips" do
      frame =
        line(%{
          "type" => "event",
          "ts" => 1,
          "seq" => 1,
          "boot_id" => "b",
          "kind" => "browser.navigated",
          "content_withheld" => true,
          "private_state" => "unknown"
        })

      assert {:event, event} = Wire.decode(frame)
      assert event.content_withheld == true
      assert event.private_state == "unknown"
    end

    test "a system/gap event with no app decodes with a nil bundle_id" do
      frame =
        line(%{
          "type" => "event",
          "ts" => 1,
          "seq" => 2,
          "boot_id" => "b",
          "kind" => "observer.gap",
          "gap_reason" => "sleep"
        })

      assert {:event, event} = Wire.decode(frame)
      assert event.bundle_id == nil
      assert event.type == "observer.gap"
      assert event.gap_reason == "sleep"
    end

    test "an event missing a required field is an error (a gap, not a crash)" do
      assert {:error, {:missing_field, "kind"}} =
               Wire.decode(line(%{"type" => "event", "ts" => 1, "seq" => 1, "boot_id" => "b"}))

      assert {:error, {:missing_field, "seq"}} =
               Wire.decode(line(%{"type" => "event", "ts" => 1, "boot_id" => "b", "kind" => "x"}))
    end

    test "wrong-typed required fields are rejected" do
      # seq as a string, ts as a float — both invalid.
      assert {:error, {:missing_field, "seq"}} =
               Wire.decode(
                 line(%{
                   "type" => "event",
                   "ts" => 1,
                   "seq" => "5",
                   "boot_id" => "b",
                   "kind" => "x"
                 })
               )
    end

    test "a non-binary content field is ignored, not coerced" do
      frame =
        line(%{
          "type" => "event",
          "ts" => 1,
          "seq" => 1,
          "boot_id" => "b",
          "kind" => "x",
          "text" => 12_345
        })

      assert {:event, event} = Wire.decode(frame)
      refute Map.has_key?(event, :text)
    end
  end

  describe "ack frames" do
    test "an observe_start ack carries action + protocol_version" do
      frame =
        line(%{
          "type" => "ack",
          "action" => "observe_start",
          "ok" => true,
          "protocol_version" => 6
        })

      assert {:ack, ack} = Wire.decode(frame)
      assert ack.action == "observe_start"
      assert ack.ok == true
      assert ack.protocol_version == 6
    end

    test "ok defaults to false when absent or non-true" do
      assert {:ack, %{ok: false}} =
               Wire.decode(line(%{"type" => "ack", "action" => "observe_stop"}))
    end
  end

  describe "malformed frames" do
    test "bad JSON is an error" do
      assert {:error, {:bad_json, _}} = Wire.decode("{not json")
    end

    test "an unknown or missing type is an error" do
      assert {:error, {:unknown_frame_type, "heartbeat"}} =
               Wire.decode(line(%{"type" => "heartbeat"}))

      assert {:error, :missing_frame_type} = Wire.decode(line(%{"foo" => "bar"}))
    end
  end
end
