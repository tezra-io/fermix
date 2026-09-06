defmodule FermixCore.Meetings.Rtms.ProtocolTest do
  # Pure module — no processes, no sockets, no global state.
  use ExUnit.Case, async: true

  alias FermixCore.Meetings.Rtms.Protocol

  @fixtures Path.expand("fixtures", __DIR__)

  @client_id "client-fixture"
  @client_secret "s3cr3t-fixture"
  @meeting_uuid "aBcD1234EfGh5678=="
  @stream_id "rtms_stream_fixture_001"

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  describe "oauth_request/3" do
    test "puts the account credentials grant in the query and Basic auth in the headers" do
      request = Protocol.oauth_request("acct-1", @client_id, @client_secret)

      assert %URI{query: query} = URI.parse(request.url)
      params = URI.decode_query(query)

      assert params["grant_type"] == "account_credentials"
      assert params["account_id"] == "acct-1"

      assert {"authorization", "Basic " <> encoded} =
               List.keyfind(request.headers, "authorization", 0)

      assert Base.decode64!(encoded) == "#{@client_id}:#{@client_secret}"
    end
  end

  describe "decode_oauth/1" do
    test "reads the bearer token" do
      assert Protocol.decode_oauth(%{"access_token" => "tok-1", "expires_in" => 3600}) ==
               {:ok, "tok-1"}
    end

    test "a body with no usable token fails loud rather than yielding a blank credential" do
      assert Protocol.decode_oauth(%{"access_token" => ""}) == {:error, :no_access_token}
      assert Protocol.decode_oauth(%{"error" => "invalid_client"}) == {:error, :no_access_token}
    end
  end

  describe "event_ws_url/2" do
    test "carries the subscription id and the token in the query string" do
      url = Protocol.event_ws_url("sub-9", "tok 1/2+3")
      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert String.starts_with?(url, "wss://ws.zoom.us/ws?")
      assert params["subscriptionId"] == "sub-9"
      assert params["access_token"] == "tok 1/2+3"
    end
  end

  describe "signature/4" do
    test "is a stable lower-case hex HMAC-SHA256 over the comma-joined ids" do
      # Fixed vector: if this changes, every handshake in the field changes with
      # it, so a correction to the concatenation order has to be deliberate.
      assert Protocol.signature(@client_id, @client_secret, @meeting_uuid, @stream_id) ==
               "b9da76533c399c7294ee4e1d1fde57a061d8a171aab7c8eafd9080de0c0c9d57"
    end

    test "a different stream id yields a different signature" do
      other = Protocol.signature(@client_id, @client_secret, @meeting_uuid, "other-stream")

      refute other == Protocol.signature(@client_id, @client_secret, @meeting_uuid, @stream_id)
    end
  end

  describe "handshake builders" do
    test "the signaling request names the stream and carries the signature" do
      signature = Protocol.signature(@client_id, @client_secret, @meeting_uuid, @stream_id)
      request = Protocol.signaling_handshake(@meeting_uuid, @stream_id, signature)

      assert request["msg_type"] == "SIGNALING_HAND_SHAKE_REQ"
      assert request["meeting_uuid"] == @meeting_uuid
      assert request["rtms_stream_id"] == @stream_id
      assert request["signature"] == signature
    end

    test "the media request asks for 16 kHz mono raw audio, one channel per participant" do
      request = Protocol.media_handshake(@meeting_uuid, @stream_id, "sig")

      assert request["msg_type"] == "DATA_HAND_SHAKE_REQ"
      assert request["payload_encryption"] == false

      assert request["media_params"]["audio"] == %{
               "content_type" => "RAW_AUDIO",
               "sample_rate" => 16_000,
               "channel" => "MONO",
               "data_opt" => "AUDIO_MULTI_CHANNELS"
             }
    end
  end

  describe "decode_event/1" do
    test "reads the stream identifiers out of meeting.rtms_started" do
      assert {:rtms_started, stream} = Protocol.decode_event(fixture("event_rtms_started.json"))

      assert stream == %{
               meeting_no: "8123456789",
               meeting_uuid: @meeting_uuid,
               rtms_stream_id: @stream_id,
               server_urls: "wss://rtms.example.zoom.us/signaling"
             }
    end

    test "reads meeting.rtms_stopped" do
      assert Protocol.decode_event(fixture("event_rtms_stopped.json")) ==
               {:rtms_stopped, %{meeting_no: "8123456789"}}
    end

    test "unwraps the subscription envelope's JSON-string payload" do
      inner = Jason.encode!(fixture("event_rtms_started.json"))

      assert {:rtms_started, %{meeting_no: "8123456789"}} =
               Protocol.decode_event(%{"module" => "message", "content" => inner})
    end

    test "an envelope whose payload is not JSON is a protocol error, not a skipped frame" do
      assert {:protocol_error, {:undecodable_event_envelope, _detail}} =
               Protocol.decode_event(%{"content" => "{not json"})
    end

    test "a started event missing the stream identifiers refuses instead of half-joining" do
      truncated = %{"event" => "meeting.rtms_started", "payload" => %{"object" => %{"id" => "1"}}}

      assert Protocol.decode_event(truncated) == {:protocol_error, :incomplete_rtms_started}
    end

    test "traffic we have no use for is ignored" do
      assert Protocol.decode_event(%{"module" => "heartbeat"}) == :ignored
      assert Protocol.decode_event(%{"event" => "meeting.started"}) == :ignored
    end
  end

  describe "decode_signaling/1" do
    test "a successful handshake names the media server" do
      assert Protocol.decode_signaling(fixture("signaling_handshake_ok.json")) ==
               {:handshake_ok, "wss://rtms.example.zoom.us/media/audio"}
    end

    test "the media server may be offered under the all-media key" do
      response = %{
        "msg_type" => "SIGNALING_HAND_SHAKE_RESP",
        "status_code" => "STATUS_OK",
        "media_server" => %{"server_urls" => %{"all" => "wss://media.example/all"}}
      }

      assert Protocol.decode_signaling(response) == {:handshake_ok, "wss://media.example/all"}
    end

    test "a rejected handshake reports the server's own status and reason" do
      assert {:handshake_failed, detail} =
               Protocol.decode_signaling(fixture("signaling_handshake_denied.json"))

      assert detail.status_code == "STATUS_UNAUTHORIZED"
      assert detail.reason == "signature verification failed"
    end

    test "an OK handshake with no media URL is a protocol error" do
      response = %{"msg_type" => "SIGNALING_HAND_SHAKE_RESP", "status_code" => "STATUS_OK"}

      assert Protocol.decode_signaling(response) == {:protocol_error, :no_media_server_url}
    end

    test "keep-alive requests are surfaced with their timestamp" do
      assert Protocol.decode_signaling(fixture("keep_alive_req.json")) ==
               {:keepalive, 1_760_000_030_000}
    end
  end

  describe "decode_media/1" do
    test "a successful data handshake is what admitted means on this lane" do
      assert Protocol.decode_media(fixture("media_handshake_ok.json")) == :handshake_ok
    end

    test "a rejected data handshake reports the server's reason" do
      assert {:handshake_failed, detail} =
               Protocol.decode_media(fixture("media_handshake_denied.json"))

      assert detail.status_code == "STATUS_INVALID_MESSAGE"
    end

    test "an audio message decodes to one participant's raw PCM" do
      assert {:audio, frame} = Protocol.decode_media(fixture("audio_participant_one.json"))

      assert frame.user_id == "u-1001"
      assert frame.user_name == "Ada Lovelace"
      assert frame.timestamp == 0
      # 100 ms of 16 kHz mono s16le.
      assert byte_size(frame.pcm) == 3_200
    end

    test "an audio payload that is not base64 fails loud" do
      message = fixture("audio_participant_one.json") |> Map.put("data", "!!!not base64!!!")

      assert Protocol.decode_media(message) == {:protocol_error, :undecodable_audio_payload}
    end

    test "an audio message missing a field fails loud" do
      message = fixture("audio_participant_one.json") |> Map.delete("user_name")

      assert Protocol.decode_media(message) == {:protocol_error, :incomplete_audio_message}
    end

    test "a terminated stream ends the meeting" do
      assert {:stream_ended, detail} = Protocol.decode_media(fixture("stream_terminated.json"))
      assert detail.reason == "host ended the meeting"
    end

    test "keep-alive requests are surfaced with their timestamp" do
      assert Protocol.decode_media(fixture("keep_alive_req.json")) ==
               {:keepalive, 1_760_000_030_000}
    end

    test "traffic we have no use for is ignored" do
      assert Protocol.decode_media(%{"msg_type" => "SESSION_STATE_UPDATE"}) == :ignored
    end
  end

  describe "keepalive_response/1" do
    test "echoes the request's timestamp verbatim" do
      assert {:keepalive, timestamp} = Protocol.decode_media(fixture("keep_alive_req.json"))

      assert Protocol.keepalive_response(timestamp) == %{
               "msg_type" => "KEEP_ALIVE_RESP",
               "timestamp" => 1_760_000_030_000
             }
    end
  end

  describe "fixtures" do
    test "every fixture carries the synthesized-from-docs warning" do
      files = File.ls!(@fixtures)

      assert files != []

      for name <- files do
        assert fixture(name)["_synthesized"] =~ "revalidate against a live RTMS capture",
               "#{name} lost its provenance header"
      end
    end
  end
end
