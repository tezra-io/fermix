defmodule FermixChannels.Companion.OutputTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Companion.Output

  # An event header is capped, so the text a failure or a tool's result
  # becomes is cut to a bound, and never inside a code point.
  test "a turn's error message is bounded in bytes on a UTF-8 boundary" do
    event = Output.turn_error("turn-1", {:provider_error, String.duplicate("é", 2_000)})

    assert event["code"] == "turn_failed"
    assert byte_size(event["message"]) <= 512
    assert String.valid?(event["message"])
    assert Output.turn_error("turn-1", :cancelled)["message"] == "cancelled"
  end

  test "a tool event's detail is bounded in bytes on a UTF-8 boundary" do
    stop = Output.tool_event("turn-1", {:tool_finish, "shell", String.duplicate("日本", 1_000)})
    assert byte_size(stop["detail"]) <= 512
    assert String.valid?(stop["detail"])

    other = Output.tool_event("turn-1", {:tool_progress, String.duplicate("x", 5_000)})
    assert byte_size(other["detail"]) <= 512
  end

  # One message for a failure reason on every error path, the Mac's and the
  # phone's `error` and both wires' `turn_error`: a shallow inspection, cut to
  # the 512 bytes each wire allows (R4-3).
  test "a failure reason becomes one shallow, bounded message on every error path" do
    many = Enum.to_list(1..100)
    assert Output.error_message(many) == "[1, 2, 3, 4, 5, ...]"
    assert Output.turn_error("turn-1", many)["message"] == Output.error_message(many)

    long = {:provider_error, String.duplicate("é", 2_000)}
    assert byte_size(Output.error_message(long)) <= 512
    assert String.valid?(Output.error_message(long))
    assert Output.error_message(:disk_io) == ":disk_io"
  end

  # One builder for the `row` event, in the phone's shape; `Companion.Fanout`
  # projects it to the Mac's fields (R4-4).
  test "a row is announced as the history message a phone renders" do
    row = %{
      server_seq: 8,
      role: "assistant",
      content: "the answer",
      kind: "text",
      client_msg_id: nil,
      in_reply_to: "phone-1",
      media_refs: [],
      metadata: %{"turn_id" => "turn-1", "stale" => nil},
      link_previews: [],
      created_at: ~U[2026-09-27 09:00:00Z]
    }

    assert Output.row("main", row) == %{
             "t" => "row",
             "profile_id" => "main",
             "server_seq" => 8,
             "role" => "assistant",
             "text" => "the answer",
             "ts" => "2026-09-27T09:00:00Z",
             "kind" => "text",
             "media_refs" => [],
             "in_reply_to" => "phone-1",
             "metadata" => %{"turn_id" => "turn-1"}
           }
  end

  defmodule AppendStore do
    def append(profile_id, attrs, _opts) do
      send(self(), {:append, profile_id, attrs})
      {:ok, Map.put(attrs, :server_seq, 1)}
    end
  end

  # FEAT-4: an absent value is an absent key, in a stored row's metadata too,
  # or history ships it as an explicit null.
  test "a reply that belongs to no turn stores no turn_id" do
    assert {:ok, {:created, _row}} = Output.persist_text(AppendStore, "main", "hello", %{})
    assert_received {:append, "main", attrs}
    assert attrs.metadata == nil

    assert {:ok, {:created, _row}} =
             Output.persist_text(AppendStore, "main", "hello", %{turn_id: "turn-1"})

    assert_received {:append, "main", %{metadata: %{"turn_id" => "turn-1"}}}
  end
end
