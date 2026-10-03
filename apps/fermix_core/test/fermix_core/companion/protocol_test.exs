defmodule FermixCore.Companion.ProtocolTest do
  use ExUnit.Case, async: true

  alias FermixCore.Companion.Protocol

  test "publishes the version window, the line cap and the ordered catalogs" do
    assert Protocol.protocol_version() == 2
    assert Protocol.supported_version_range() == {1, 2}
    assert Protocol.max_line_bytes() == 65_536

    assert Protocol.client_events() ==
             ~w(client_hello msg command cancel history_pull history_search read_state)

    assert Protocol.server_events() ==
             ~w(server_hello accepted turn_started text_delta tool_event text_done turn_error
                turn_done row approval approval_resolved read_state history_page search_results
                error)
  end

  # M56 §6: a turn that ends with no reply needs a frame an older client would
  # not survive, so it goes only to a connection that declared version 2.
  test "every server event names the version that brought it, turn_done version 2" do
    assert Protocol.server_event_version("turn_done") == 2

    for type <- Protocol.server_events() -- ["turn_done"] do
      assert Protocol.server_event_version(type) == 1, "#{type} is not a version 1 event"
    end

    refute "turn_done" in Protocol.shared_server_events()
  end

  test "turn_done names the turn it ends and nothing else" do
    assert {:ok, line} = Protocol.encode_server_event("turn_done", %{"turn_id" => "turn-mac-1"})
    assert Jason.decode!(line) == %{"type" => "turn_done", "turn_id" => "turn-mac-1"}

    assert {:error, {:missing_field, "turn_id"}} =
             Protocol.encode_server_event("turn_done", %{})

    assert {:error, {:invalid_field, "turn_id"}} =
             Protocol.encode_server_event("turn_done", %{"turn_id" => ""})
  end

  test "the shared chat events are a subset of both catalogs" do
    assert Protocol.shared_client_events() -- Protocol.client_events() == []
    assert Protocol.shared_server_events() -- Protocol.server_events() == []
    refute "history_pull" in Protocol.shared_client_events()
    refute "history_page" in Protocol.shared_server_events()
    assert "cancel" in Protocol.shared_client_events()
    assert "row" in Protocol.shared_server_events()
  end

  test "negotiates directionally, version 1 and version 2 both accepted" do
    assert :ok = Protocol.negotiate(1)
    assert :ok = Protocol.negotiate(2)
    assert {:error, :client_too_old} = Protocol.negotiate(0)
    assert {:error, :client_too_new} = Protocol.negotiate(3)
  end

  test "client_hello refuses a missing or malformed version with the Realtime reasons" do
    assert {:ok, %{type: "client_hello", payload: %{"protocol_version" => 1}}} =
             decode(%{"type" => "client_hello", "protocol_version" => 1})

    assert {:error, :missing_protocol_version} = decode(%{"type" => "client_hello"})

    assert {:error, :invalid_protocol_version} =
             decode(%{"type" => "client_hello", "protocol_version" => "1"})
  end

  test "a message keeps the mobile shape and carries no attachments on this wire" do
    msg = %{
      "type" => "msg",
      "client_msg_id" => "c-1",
      "profile_id" => "main",
      "text" => "hello",
      "attach_ids" => []
    }

    assert {:ok, %{type: "msg", payload: payload}} = decode(msg)
    refute Map.has_key?(payload, "type")

    assert {:error, {:missing_field, "attach_ids"}} = decode(Map.delete(msg, "attach_ids"))
    assert {:error, {:missing_field, "content"}} = decode(%{msg | "text" => "  "})

    assert {:error, :attachments_unsupported} =
             decode(%{msg | "attach_ids" => ["attach-1"]})
  end

  test "history_pull takes exactly one cursor" do
    base = %{"type" => "history_pull", "profile_id" => "main", "limit" => 50}

    assert {:ok, _event} = decode(Map.put(base, "after_seq", 0))
    assert {:ok, _event} = decode(Map.put(base, "before_seq", 12))
    assert {:error, {:missing_field, "after_seq"}} = decode(base)
    assert {:error, {:invalid_field, "before_seq"}} = decode(Map.put(base, "before_seq", 0))

    assert {:error, {:invalid_field, "before_seq"}} =
             decode(base |> Map.put("after_seq", 0) |> Map.put("before_seq", 3))

    assert {:error, {:invalid_field, "limit"}} =
             decode(base |> Map.put("after_seq", 0) |> Map.put("limit", 201))
  end

  test "history_search bounds its query and page" do
    base = %{"type" => "history_search", "profile_id" => "main", "query" => "plan", "limit" => 20}

    assert {:ok, _event} = decode(base)
    assert {:ok, _event} = decode(Map.put(base, "before_seq", 40))
    assert {:error, {:invalid_field, "query"}} = decode(%{base | "query" => ""})

    assert {:error, {:invalid_field, "query"}} =
             decode(%{base | "query" => String.duplicate("é", 257)})

    assert {:ok, _event} = decode(%{base | "query" => String.duplicate("é", 256)})
    assert {:error, {:invalid_field, "limit"}} = decode(%{base | "limit" => 51})
    assert {:error, {:invalid_field, "before_seq"}} = decode(Map.put(base, "before_seq", 0))
  end

  test "cancel names the request whose turn it stops, and read_state its profile" do
    assert {:ok, _event} =
             decode(%{"type" => "cancel", "profile_id" => "main", "client_msg_id" => "mac-1"})

    assert {:error, {:missing_field, "profile_id"}} = decode(%{"type" => "cancel"})

    assert {:error, {:missing_field, "client_msg_id"}} =
             decode(%{"type" => "cancel", "profile_id" => "main"})

    assert {:ok, _event} =
             decode(%{"type" => "read_state", "profile_id" => "main", "read_up_to_seq" => 4})
  end

  test "malformed and unknown lines fail loudly" do
    assert {:error, :invalid_json} = Protocol.decode_client_event("{")
    assert {:error, :invalid_event} = Protocol.decode_client_event("[1]")
    assert {:error, :missing_type} = Protocol.decode_client_event(~s({"text":"hi"}))
    assert {:error, {:unknown_event, "ping"}} = decode(%{"type" => "ping"})
  end

  test "the encoder writes one newline-terminated object with its type" do
    assert {:ok, line} =
             Protocol.encode_server_event("server_hello", %{min_version: 1, max_version: 2})

    assert String.ends_with?(line, "\n")

    assert Jason.decode!(line) == %{
             "type" => "server_hello",
             "min_version" => 1,
             "max_version" => 2
           }

    assert {:error, {:invalid_field, "version_range"}} =
             Protocol.encode_server_event("server_hello", %{min_version: 1, max_version: 1})
  end

  test "the encoder refuses explicit nulls, a written type and unknown events" do
    assert {:error, {:null_field, "detail"}} =
             Protocol.encode_server_event("tool_event", %{
               "turn_id" => "t",
               "tool" => "shell",
               "phase" => "stop",
               "detail" => nil
             })

    assert {:error, {:reserved_field, "type"}} =
             Protocol.encode_server_event("error", %{"type" => "x", "reason" => "r"})

    assert {:error, {:unknown_event, "pong"}} = Protocol.encode_server_event("pong", %{})
  end

  test "history pages and search results carry their cursors" do
    assert {:ok, _line} =
             Protocol.encode_server_event("history_page", %{
               "profile_id" => "main",
               "messages" => [],
               "history_head_seq" => 0,
               "next_after_seq" => 0
             })

    assert {:error, {:missing_field, "history_head_seq"}} =
             Protocol.encode_server_event("history_page", %{
               "profile_id" => "main",
               "messages" => []
             })

    assert {:ok, _line} =
             Protocol.encode_server_event("search_results", %{
               "profile_id" => "main",
               "query" => "plan",
               "hits" => [],
               "next_before_seq" => 9
             })

    assert {:error, {:invalid_field, "next_before_seq"}} =
             Protocol.encode_server_event("search_results", %{
               "profile_id" => "main",
               "query" => "plan",
               "hits" => [],
               "next_before_seq" => 0
             })
  end

  test "a row announces one timeline row, with the sender's id only on a user's" do
    row = %{
      "profile_id" => "main",
      "server_seq" => 12,
      "role" => "user",
      "text" => "What is on my calendar today?",
      "ts" => "2026-09-25T09:00:00Z"
    }

    assert {:ok, _line} = Protocol.encode_server_event("row", row)

    assert {:ok, _line} =
             Protocol.encode_server_event("row", Map.put(row, "client_msg_id", "mac-1"))

    assert {:ok, _line} = Protocol.encode_server_event("row", %{row | "text" => ""})

    assert {:error, {:invalid_field, "client_msg_id"}} =
             Protocol.encode_server_event("row", Map.put(row, "client_msg_id", ""))

    assert {:error, {:invalid_field, "server_seq"}} =
             Protocol.encode_server_event("row", %{row | "server_seq" => 0})

    assert {:error, {:missing_field, "ts"}} =
             Protocol.encode_server_event("row", Map.delete(row, "ts"))
  end

  # M56 §6: the Mac's row carries a history message's kind and metadata, as
  # the phone's always has.
  test "a row may carry its kind and metadata" do
    row = %{
      "profile_id" => "main",
      "server_seq" => 15,
      "role" => "assistant",
      "text" => "It is at https://x.test/form.",
      "ts" => "2026-10-03T10:00:00Z",
      "kind" => "text",
      "metadata" => %{"call" => shared_call()}
    }

    assert {:ok, _line} = Protocol.encode_server_event("row", row)

    assert {:error, {:invalid_field, "kind"}} =
             Protocol.encode_server_event("row", %{row | "kind" => ""})

    assert {:error, {:invalid_field, "metadata"}} =
             Protocol.encode_server_event("row", %{row | "metadata" => "call"})
  end

  describe "validate_call_metadata/1" do
    test "a result shown in the chat names the call, the event and its task" do
      assert :ok = Protocol.validate_call_metadata(shared_call())
    end

    test "every key of the design's call map is accepted with its type" do
      done =
        Map.merge(shared_call(), %{"event" => "task_done", "state" => "timed_out"})

      assert :ok = Protocol.validate_call_metadata(ended_call())
      assert :ok = Protocol.validate_call_metadata(%{shared_call() | "event" => "task_running"})
      assert :ok = Protocol.validate_call_metadata(done)
    end

    # M56 §4.2: the call's one row when it ends names its engine, its length,
    # its bill's accounting and what became of its gist; the cost is absent
    # when it is unknown.
    test "a call's ended row names its engine, length, accounting and gist" do
      for gist_status <- ~w(written failed none) do
        assert :ok =
                 Protocol.validate_call_metadata(%{ended_call() | "gist_status" => gist_status})
      end

      assert :ok = Protocol.validate_call_metadata(Map.delete(ended_call(), "voice_cost_cents"))

      for key <- ~w(engine duration_s accounting gist_status) do
        assert {:error, {:missing_field, "call." <> ^key}} =
                 Protocol.validate_call_metadata(Map.delete(ended_call(), key))
      end
    end

    test "the call and the event are required, and the event is one of four" do
      assert {:error, {:missing_field, "call.uuid"}} =
               Protocol.validate_call_metadata(Map.delete(shared_call(), "uuid"))

      assert {:error, {:missing_field, "call.event"}} =
               Protocol.validate_call_metadata(Map.delete(shared_call(), "event"))

      assert {:error, {:invalid_field, "call.event"}} =
               Protocol.validate_call_metadata(%{shared_call() | "event" => "spoken"})

      assert {:error, {:invalid_field, "call.uuid"}} =
               Protocol.validate_call_metadata(%{shared_call() | "uuid" => "call-7"})
    end

    test "a task's event names the task and its revision; a task's end names its state" do
      assert {:error, {:missing_field, "call.task_id"}} =
               Protocol.validate_call_metadata(Map.delete(shared_call(), "task_id"))

      assert {:error, {:missing_field, "call.revision"}} =
               Protocol.validate_call_metadata(Map.delete(shared_call(), "revision"))

      assert {:error, {:missing_field, "call.state"}} =
               Protocol.validate_call_metadata(%{shared_call() | "event" => "task_done"})
    end

    test "each field is refused in a shape other than its own" do
      for {key, value} <- [
            {"task_id", ""},
            {"revision", 0},
            {"state", "running"},
            {"duration_s", -1},
            {"voice_cost_cents", "0.5"},
            {"accounting", "running"},
            {"engine", ""},
            {"gist_status", "pending"}
          ] do
        assert {:error, {:invalid_field, "call." <> ^key}} =
                 Protocol.validate_call_metadata(Map.put(shared_call(), key, value))
      end
    end

    test "a key the call map does not have is refused, and so is anything not a map" do
      assert {:error, {:unknown_field, "call.text"}} =
               Protocol.validate_call_metadata(Map.put(shared_call(), "text", "hi"))

      assert {:error, {:invalid_field, "call"}} = Protocol.validate_call_metadata(nil)
    end
  end

  defp ended_call do
    %{
      "uuid" => "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b",
      "event" => "ended",
      "engine" => "openai_live",
      "duration_s" => 360,
      "voice_cost_cents" => 30.125,
      "accounting" => "complete",
      "gist_status" => "written"
    }
  end

  defp shared_call do
    %{
      "uuid" => "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b",
      "event" => "shared",
      "task_id" => "dg_01H9",
      "revision" => 1
    }
  end

  test "payload validation is available to another envelope without the type key" do
    assert :ok =
             Protocol.validate_server_payload("accepted", %{
               "client_msg_id" => "c",
               "duplicate" => true,
               "server_seq" => 3
             })

    assert {:error, {:missing_field, "duplicate"}} =
             Protocol.validate_server_payload("accepted", %{"client_msg_id" => "c"})

    assert {:error, {:unknown_event, "hello"}} = Protocol.validate_client_payload("hello", %{})
  end

  defp decode(map), do: map |> Jason.encode!() |> Protocol.decode_client_event()
end
