defmodule FermixChannels.Mobile.ProtocolTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Protocol

  @client_events ~w(
    hello msg attach_begin attach_chunk attach_end command cancel history_pull media_fetch
    push_register ack read_state pair_request unpair ping
  )
  @server_events ~w(
    hello_ack accepted attach_status turn_started text_delta tool_event text_done
    media_begin media_chunk media_end turn_error row reaction approval approval_resolved
    link_preview read_state history_page notice pair_approved pair_denied error pong event_part
  )

  test "publishes the v1 N/N-1 window and approved event catalogs" do
    assert Protocol.protocol_version() == 1
    assert Protocol.supported_version_range() == {1, 1}
    assert Protocol.client_events() == @client_events
    assert Protocol.server_events() == @server_events
    assert Protocol.max_header_bytes() == 4_096
    assert Protocol.max_raw_chunk_bytes() == 61_440
    assert Protocol.max_plaintext_bytes() == 65_519
    assert Protocol.max_event_bytes() == 1_048_576
  end

  test "negotiates supported, old, and new clients directionally" do
    assert :ok = Protocol.negotiate(1)
    assert {:error, :client_too_old} = Protocol.negotiate(0)
    assert {:error, :client_too_new} = Protocol.negotiate(2)
  end

  test "an out-of-window envelope names the direction and the client's version" do
    assert {:error, {:unsupported_protocol_version, :client_too_new, 2}} =
             Protocol.decode_client_frame(
               encode_frame(%{"v" => 2, "t" => "ping", "seq" => 1}, "")
             )

    assert {:error, {:unsupported_protocol_version, :client_too_old, 0}} =
             Protocol.decode_client_frame(
               encode_frame(%{"v" => 0, "t" => "ping", "seq" => 1}, "")
             )
  end

  test "event_part is server-only: a client-sent part is refused like any unknown event" do
    frame = client_frame("event_part", 1, %{"index" => 0, "count" => 2}, "{}")
    assert {:error, {:unknown_event, "event_part"}} = Protocol.decode_client_frame(frame)
  end

  test "an event within the header cap stays one frame" do
    assert {:ok, [frame]} = Protocol.encode_server_event("pong", %{}, 3, <<>>, [])
    assert {:ok, ^frame} = Protocol.encode_server_frame("pong", %{}, 3)
  end

  test "a header over 4 KiB travels as a contiguous event_part run that reassembles" do
    payload = %{"turn_id" => "turn-1", "server_seq" => 9, "text" => String.duplicate("a", 5_000)}

    assert {:ok, frames} = Protocol.encode_server_event("text_done", payload, 5, <<>>, version: 1)
    assert length(frames) == 2

    assert Enum.map(frames, &decode_frame!(&1).header) == [
             %{"v" => 1, "t" => "event_part", "seq" => 5, "index" => 0, "count" => 2},
             %{"v" => 1, "t" => "event_part", "seq" => 6, "index" => 1, "count" => 2}
           ]

    assert reassemble(frames) == Map.put(payload, "t", "text_done")
  end

  test "a 64 KiB reply splits into parts that each fit one Noise message" do
    payload = %{"turn_id" => "turn-1", "server_seq" => 9, "text" => String.duplicate("é", 32_768)}

    assert {:ok, frames} = Protocol.encode_server_event("text_done", payload, 1, <<>>, [])
    assert length(frames) == 2
    assert Enum.all?(frames, &(byte_size(&1) <= Protocol.max_plaintext_bytes()))
    assert Enum.all?(frames, &(byte_size(decode_frame!(&1).bytes) <= 61_440))
    assert reassemble(frames) == Map.put(payload, "t", "text_done")
  end

  test "a reply past the 1 MiB event cap is cut on a UTF-8 boundary and marked truncated" do
    # Two-byte characters and escaped newlines: the cut has to respect both the
    # codepoint boundary and the JSON escaping that lengthens the header.
    text = String.duplicate("é\n", 400_000)
    payload = %{"turn_id" => "turn-1", "server_seq" => 9, "text" => text}

    assert {:ok, frames} = Protocol.encode_server_event("text_done", payload, 1, <<>>, [])
    json = frames |> Enum.map(&decode_frame!(&1).bytes) |> IO.iodata_to_binary()
    assert byte_size(json) <= Protocol.max_event_bytes()

    event = Jason.decode!(json)
    assert event["truncated"] == true
    assert String.valid?(event["text"])
    assert String.starts_with?(text, event["text"])
    assert byte_size(event["text"]) > 600_000
  end

  test "a single history row past the event cap ships truncated; the page shape stays" do
    row = %{
      "server_seq" => 4,
      "role" => "assistant",
      "content" => String.duplicate("x", 1_100_000),
      "ts" => "2026-09-27T12:00:00Z",
      "media_refs" => []
    }

    payload = %{"profile_id" => "main", "messages" => [row], "next_after_seq" => 4}

    assert {:ok, frames} = Protocol.encode_server_event("history_page", payload, 1, <<>>, [])
    event = reassemble(frames)
    assert byte_size(Jason.encode!(event)) <= Protocol.max_event_bytes()
    assert [%{"truncated" => true, "content" => content, "server_seq" => 4}] = event["messages"]
    assert String.starts_with?(row["content"], content)
    assert event["next_after_seq"] == 4
  end

  test "a row announced past the event cap ships truncated, like the reply it carries" do
    payload = %{
      "profile_id" => "main",
      "server_seq" => 11,
      "role" => "assistant",
      "text" => String.duplicate("x", 1_100_000),
      "ts" => "2026-09-27T12:00:00Z"
    }

    assert {:ok, frames} = Protocol.encode_server_event("row", payload, 1, <<>>, [])
    event = reassemble(frames)
    assert byte_size(Jason.encode!(event)) <= Protocol.max_event_bytes()
    assert event["truncated"] == true
    assert event["server_seq"] == 11
    assert String.starts_with?(payload["text"], event["text"])
  end

  test "any other event past the 1 MiB cap is refused, never truncated" do
    payload = %{"kind" => "info", "text" => String.duplicate("x", 1_100_000)}

    assert {:error, {:event_too_large, size, 1_048_576}} =
             Protocol.encode_server_event("notice", payload, 1, <<>>, [])

    assert size > 1_048_576
  end

  test "event_part is a transport frame, not a logical event" do
    assert {:error, :nested_event_part} =
             Protocol.encode_server_event("event_part", %{"index" => 0, "count" => 2}, 1, "x", [])

    assert {:ok, _frame} =
             Protocol.encode_server_frame("event_part", %{"index" => 1, "count" => 2}, 1, "x")

    assert {:error, {:invalid_field, "index"}} =
             Protocol.encode_server_frame("event_part", %{"index" => 2, "count" => 2}, 1, "x")

    assert {:error, {:invalid_field, "count"}} =
             Protocol.encode_server_frame("event_part", %{"index" => 0, "count" => 1}, 1, "x")

    assert {:error, {:missing_field, "bytes"}} =
             Protocol.encode_server_frame("event_part", %{"index" => 0, "count" => 2}, 1)
  end

  test "decodes a valid hello and keeps additive fields" do
    frame =
      client_frame("hello", 1, %{
        "device_id" => "device-1",
        "app_version" => "1.0.0",
        "last_server_seq" => 0,
        "protocol_v" => 1,
        "future" => %{"ok" => true}
      })

    assert {:ok, event} = Protocol.decode_client_frame(frame)
    assert event.version == 1
    assert event.type == "hello"
    assert event.seq == 1
    assert event.bytes == <<>>
    assert event.payload["future"] == %{"ok" => true}
  end

  test "requires a positive u64 session sequence and matching protocol version" do
    fields = %{
      "device_id" => "device-1",
      "app_version" => "1.0.0",
      "last_server_seq" => 0,
      "protocol_v" => 1
    }

    assert {:error, :invalid_seq} = Protocol.decode_client_frame(client_frame("hello", 0, fields))

    assert {:error, :protocol_version_mismatch} =
             Protocol.decode_client_frame(client_frame("hello", 1, %{fields | "protocol_v" => 2}))

    too_large = 18_446_744_073_709_551_616

    assert {:error, :invalid_seq} =
             Protocol.decode_client_frame(client_frame("hello", too_large, fields))
  end

  test "validates message and history constraints" do
    assert {:ok, %{type: "msg"}} =
             Protocol.decode_client_frame(
               client_frame("msg", 2, %{
                 "client_msg_id" => "c-1",
                 "profile_id" => "main",
                 "text" => "hello",
                 "attach_ids" => []
               })
             )

    assert {:error, {:missing_field, "content"}} =
             Protocol.decode_client_frame(
               client_frame("msg", 2, %{
                 "client_msg_id" => "c-1",
                 "profile_id" => "main",
                 "text" => "",
                 "attach_ids" => []
               })
             )

    assert {:error, {:invalid_field, "limit"}} =
             Protocol.decode_client_frame(
               client_frame("history_pull", 3, %{
                 "profile_id" => "main",
                 "after_seq" => 0,
                 "limit" => 201
               })
             )
  end

  test "attach_begin carries the hash required for pre-transfer dedup" do
    hash = String.duplicate("a", 64)

    assert {:ok, %{type: "attach_begin", payload: %{"sha256" => ^hash}}} =
             Protocol.decode_client_frame(
               client_frame("attach_begin", 4, %{
                 "attach_id" => "a-1",
                 "kind" => "image",
                 "mime" => "image/jpeg",
                 "size_bytes" => 100,
                 "sha256" => hash
               })
             )

    assert {:error, {:invalid_field, "sha256"}} =
             Protocol.decode_client_frame(
               client_frame("attach_begin", 4, %{
                 "attach_id" => "a-1",
                 "kind" => "image",
                 "mime" => "image/jpeg",
                 "size_bytes" => 100,
                 "sha256" => "bad"
               })
             )
  end

  test "only chunk events accept raw bytes and enforce the 60 KiB cap" do
    bytes = :binary.copy(<<7>>, Protocol.max_raw_chunk_bytes())

    assert {:ok, %{type: "attach_chunk", bytes: ^bytes}} =
             Protocol.decode_client_frame(
               client_frame("attach_chunk", 5, %{"attach_id" => "a-1", "index" => 0}, bytes)
             )

    assert {:error, {:raw_chunk_too_large, 61_441, 61_440}} =
             Protocol.decode_client_frame(
               client_frame(
                 "attach_chunk",
                 5,
                 %{"attach_id" => "a-1", "index" => 0},
                 bytes <> <<0>>
               )
             )

    assert {:error, {:unexpected_binary, "ping"}} =
             Protocol.decode_client_frame(client_frame("ping", 6, %{}, <<1>>))
  end

  test "deterministic chunk corpus round-trips arbitrary binary tails" do
    for size <- [1, 2, 15, 16, 255, 1_024, 8_191, 32_768, 61_440] do
      bytes = for offset <- 0..(size - 1), into: <<>>, do: <<rem(offset * 131 + size, 256)>>
      frame = client_frame("attach_chunk", 5, %{"attach_id" => "a-1", "index" => 0}, bytes)
      assert {:ok, %{bytes: ^bytes}} = Protocol.decode_client_frame(frame)
    end
  end

  test "fails loudly on malformed, oversized, and unknown frames" do
    assert {:error, :truncated_frame} = Protocol.decode_client_frame(<<0, 0, 0>>)
    assert {:error, :invalid_json} = Protocol.decode_client_frame(<<0, 0, 0, 1, ?{>>)

    assert {:error, {:header_too_large, 4_097, 4_096}} =
             Protocol.decode_client_frame(<<4_097::32, 0>>)

    assert {:error, {:unknown_event, "bogus"}} =
             Protocol.decode_client_frame(client_frame("bogus", 1, %{}))
  end

  test "encodes the strengthened server handshake and reliability events" do
    assert {:ok, hello} =
             Protocol.encode_server_frame(
               "hello_ack",
               %{
                 "session_id" => "s-1",
                 "min_version" => 1,
                 "max_version" => 1,
                 "profiles" => [%{"id" => "main", "name" => "Fermix"}],
                 "candidates" => [],
                 "history_head_seq" => 9,
                 "read_up_to_seq" => 8,
                 "caps" => %{"max_media_bytes" => 20_971_520, "commands" => []}
               },
               1
             )

    assert {:ok, decoded} = decode_frame(hello)
    assert decoded.header["min_version"] == 1
    assert decoded.header["max_version"] == 1

    assert {:ok, _accepted} =
             Protocol.encode_server_frame(
               "accepted",
               %{"client_msg_id" => "c-1", "duplicate" => false},
               2
             )

    assert {:ok, _status} =
             Protocol.encode_server_frame(
               "attach_status",
               %{"attach_id" => "a-1", "status" => "present"},
               3
             )
  end

  test "approval requires bounded approve and deny command routes" do
    payload = %{
      "approval_id" => "approval-1",
      "kind" => "sandbox",
      "text" => "Allow access?",
      "token" => "opaque-token",
      "ttl_s" => 60,
      "approve_command" => "/confirm opaque-token",
      "deny_command" => "/deny opaque-token"
    }

    assert {:ok, _frame} = Protocol.encode_server_frame("approval", payload, 4)

    for field <- ~w(approve_command deny_command) do
      assert {:ok, _frame} =
               Protocol.encode_server_frame(
                 "approval",
                 Map.put(payload, field, String.duplicate("x", 1_024)),
                 4
               )

      assert {:error, {:missing_field, ^field}} =
               Protocol.encode_server_frame("approval", Map.delete(payload, field), 4)

      assert {:error, {:invalid_field, ^field}} =
               Protocol.encode_server_frame("approval", Map.put(payload, field, ""), 4)

      assert {:error, {:invalid_field, ^field}} =
               Protocol.encode_server_frame(
                 "approval",
                 Map.put(payload, field, String.duplicate("x", 1_025)),
                 4
               )
    end
  end

  test "encodes outbound media as a bounded three-event state machine" do
    hash = String.duplicate("b", 64)

    assert {:ok, _begin} =
             Protocol.encode_server_frame(
               "media_begin",
               %{
                 "ref" => hash,
                 "server_seq" => 7,
                 "kind" => "document",
                 "mime" => "application/pdf",
                 "size_bytes" => 3,
                 "sha256" => hash,
                 "filename" => "a.pdf"
               },
               4
             )

    assert {:ok, chunk} =
             Protocol.encode_server_frame(
               "media_chunk",
               %{"ref" => hash, "index" => 0},
               5,
               "pdf"
             )

    assert {:ok, %{bytes: "pdf"}} = decode_frame(chunk)

    assert {:ok, _end} =
             Protocol.encode_server_frame("media_end", %{"ref" => hash, "sha256" => hash}, 6)
  end

  # The phone stops one request's turn the way the Mac does, and hears a row
  # written elsewhere (a Mac message, a Mac turn's reply) as the Mac hears one.
  test "carries the shared cancel and row with the companion's shapes" do
    cancel = %{"profile_id" => "main", "client_msg_id" => "phone-1"}

    assert {:ok, %{type: "cancel"}} =
             Protocol.decode_client_frame(client_frame("cancel", 1, cancel))

    assert {:error, {:missing_field, "client_msg_id"}} =
             Protocol.decode_client_frame(client_frame("cancel", 1, %{"profile_id" => "main"}))

    row = %{
      "profile_id" => "main",
      "server_seq" => 7,
      "role" => "user",
      "text" => "from the Mac",
      "ts" => "2026-09-27T09:00:00Z"
    }

    assert {:ok, _frame} = Protocol.encode_server_frame("row", row, 1)

    assert {:error, {:missing_field, "ts"}} =
             Protocol.encode_server_frame("row", Map.delete(row, "ts"), 1)
  end

  test "a request's error names the request it ends" do
    error = %{"code" => "request_failed", "message" => "attachment unavailable"}
    assert {:ok, _frame} = Protocol.encode_server_frame("error", error, 1)

    assert {:ok, frame} =
             Protocol.encode_server_frame("error", Map.put(error, "client_msg_id", "phone-1"), 1)

    assert {:ok, %{header: %{"client_msg_id" => "phone-1"}}} = decode_frame(frame)

    assert {:error, {:invalid_field, "client_msg_id"}} =
             Protocol.encode_server_frame("error", Map.put(error, "client_msg_id", ""), 1)
  end

  test "encoder accepts atom payload keys but rejects reserved envelope fields" do
    assert {:ok, frame} = Protocol.encode_server_frame("pong", %{}, 1)
    assert {:ok, %{header: %{"t" => "pong"}}} = decode_frame(frame)

    assert {:error, {:reserved_field, "v"}} =
             Protocol.encode_server_frame("pong", %{v: 99}, 1)
  end

  # FEAT-4/STB-17: an absent optional field is an absent key on this wire,
  # never an explicit null, as the companion codec already enforces.
  test "the encoder refuses an explicit null in any field" do
    preview = %{
      "in_reply_to" => 7,
      "url" => "https://example.com",
      "site" => "Example",
      "title" => "Example"
    }

    assert {:ok, _frame} = Protocol.encode_server_frame("link_preview", preview, 1)

    for field <- ["description", "image_ref"] do
      assert {:error, {:null_field, ^field}} =
               Protocol.encode_server_frame("link_preview", Map.put(preview, field, nil), 1)

      assert {:error, {:null_field, ^field}} =
               Protocol.encode_server_event(
                 "link_preview",
                 Map.put(preview, field, nil),
                 1,
                 <<>>,
                 []
               )
    end

    assert {:error, {:null_field, "client_msg_id"}} =
             Protocol.encode_server_frame(
               "error",
               %{"code" => "x", "message" => "y", "client_msg_id" => nil},
               1
             )
  end

  test "encoder can pin a supported session version" do
    assert {:ok, frame} =
             Protocol.encode_server_frame("pong", %{}, 1, <<>>, version: 1)

    assert {:ok, %{header: %{"v" => 1}}} = decode_frame(frame)

    assert {:error, :client_too_new} =
             Protocol.encode_server_frame("pong", %{}, 1, <<>>, version: 2)
  end

  defp client_frame(type, seq, fields, bytes \\ <<>>) do
    encode_frame(Map.merge(%{"v" => 1, "t" => type, "seq" => seq}, fields), bytes)
  end

  defp encode_frame(header, bytes) do
    json = Jason.encode!(header)
    <<byte_size(json)::32, json::binary, bytes::binary>>
  end

  defp decode_frame(<<size::32, rest::binary>>) do
    <<json::binary-size(size), bytes::binary>> = rest
    {:ok, %{header: Jason.decode!(json), bytes: bytes}}
  end

  defp decode_frame!(frame) do
    {:ok, decoded} = decode_frame(frame)
    decoded
  end

  # The client's side of an event_part run: tails in index order, then one
  # logical event.
  defp reassemble(frames) do
    frames
    |> Enum.map(&decode_frame!/1)
    |> Enum.sort_by(& &1.header["index"])
    |> Enum.map(& &1.bytes)
    |> IO.iodata_to_binary()
    |> Jason.decode!()
  end
end
