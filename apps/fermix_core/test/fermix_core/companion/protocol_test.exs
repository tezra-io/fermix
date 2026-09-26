defmodule FermixCore.Companion.ProtocolTest do
  use ExUnit.Case, async: true

  alias FermixCore.Companion.Protocol

  test "publishes the version window, the line cap and the ordered catalogs" do
    assert Protocol.protocol_version() == 1
    assert Protocol.supported_version_range() == {1, 1}
    assert Protocol.max_line_bytes() == 65_536

    assert Protocol.client_events() ==
             ~w(client_hello msg command cancel history_pull history_search read_state)

    assert Protocol.server_events() ==
             ~w(server_hello accepted turn_started text_delta tool_event text_done turn_error
                row approval approval_resolved read_state history_page search_results error)
  end

  test "the shared chat events are a subset of both catalogs" do
    assert Protocol.shared_client_events() -- Protocol.client_events() == []
    assert Protocol.shared_server_events() -- Protocol.server_events() == []
    refute "history_pull" in Protocol.shared_client_events()
    refute "history_page" in Protocol.shared_server_events()
    refute "row" in Protocol.shared_server_events()
  end

  test "negotiates directionally" do
    assert :ok = Protocol.negotiate(1)
    assert {:error, :client_too_old} = Protocol.negotiate(0)
    assert {:error, :client_too_new} = Protocol.negotiate(2)
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
             Protocol.encode_server_event("server_hello", %{min_version: 1, max_version: 1})

    assert String.ends_with?(line, "\n")

    assert Jason.decode!(line) == %{
             "type" => "server_hello",
             "min_version" => 1,
             "max_version" => 1
           }

    assert {:error, {:invalid_field, "version_range"}} =
             Protocol.encode_server_event("server_hello", %{min_version: 1, max_version: 2})
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
