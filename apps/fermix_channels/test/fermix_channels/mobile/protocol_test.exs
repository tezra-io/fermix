defmodule FermixChannels.Mobile.ProtocolTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Protocol

  @client_events ~w(
    hello msg attach_begin attach_chunk attach_end command history_pull media_fetch
    push_register ack read_state pair_request unpair ping
  )
  @server_events ~w(
    hello_ack accepted attach_status turn_started text_delta tool_event text_done
    media_begin media_chunk media_end turn_error reaction approval approval_resolved
    link_preview read_state history_page notice pair_approved pair_denied error pong
  )

  test "publishes the v1 N/N-1 window and approved event catalogs" do
    assert Protocol.protocol_version() == 1
    assert Protocol.supported_version_range() == {1, 1}
    assert Protocol.client_events() == @client_events
    assert Protocol.server_events() == @server_events
    assert Protocol.max_header_bytes() == 4_096
    assert Protocol.max_raw_chunk_bytes() == 61_440
    assert Protocol.max_plaintext_bytes() == 65_519
  end

  test "negotiates supported, old, and new clients directionally" do
    assert :ok = Protocol.negotiate(1)
    assert {:error, :client_too_old} = Protocol.negotiate(0)
    assert {:error, :client_too_new} = Protocol.negotiate(2)
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

  test "encoder accepts atom payload keys but rejects reserved envelope fields" do
    assert {:ok, frame} = Protocol.encode_server_frame("pong", %{}, 1)
    assert {:ok, %{header: %{"t" => "pong"}}} = decode_frame(frame)

    assert {:error, {:reserved_field, "v"}} =
             Protocol.encode_server_frame("pong", %{v: 99}, 1)
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
end
