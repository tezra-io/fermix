defmodule FermixCore.Meetings.Sidecar.FrameTest do
  use ExUnit.Case, async: true

  alias FermixCore.Meetings.Sidecar.Frame

  @control 0x01
  @audio 0x02

  describe "control frames" do
    test "every known type in both directions round-trips" do
      for type <- Frame.known_types(:s2d) ++ Frame.known_types(:d2s) do
        msg = %{"type" => type, "detail" => "round-trip"}
        assert Frame.decode(Frame.encode_control(msg)) == {:control, msg}
        assert Frame.decode_control!(Frame.encode_control(msg)) == msg
      end
    end

    test "encoding prefixes the control type byte" do
      assert <<@control, json::binary>> = Frame.encode_control(%{"type" => "ping"})
      assert Jason.decode!(json) == %{"type" => "ping"}
    end

    test "encoding a non-map raises rather than reaching the wire" do
      assert_raise FunctionClauseError, fn -> Frame.encode_control("ping") end
    end

    test "the two directions do not overlap" do
      assert Frame.known_types(:s2d) -- Frame.known_types(:d2s) == Frame.known_types(:s2d)
    end
  end

  describe "audio frames" do
    test "a well-formed payload decodes to the raw PCM" do
      pcm = :binary.copy(<<0, 1>>, 800)
      assert Frame.decode(<<@audio, pcm::binary>>) == {:audio, pcm}
      assert Frame.validate_audio(pcm) == :ok
    end

    test "an empty payload is valid (a silent frame is still a frame)" do
      assert Frame.decode(<<@audio>>) == {:audio, <<>>}
    end
  end

  describe "decode errors" do
    test "an empty frame" do
      assert Frame.decode(<<>>) == {:error, :empty_frame}
    end

    test "an unknown frame type byte" do
      assert Frame.decode(<<0x09, "whatever">>) == {:error, {:unknown_frame_type, 0x09}}
    end

    test "an oversized control payload" do
      json = Jason.encode!(%{"type" => "log", "message" => String.duplicate("x", 70_000)})
      size = byte_size(json)

      assert Frame.decode(<<@control, json::binary>>) == {:error, {:control_too_large, size}}
    end

    test "an oversized audio payload" do
      pcm = :binary.copy(<<0>>, Frame.max_audio_bytes() + 2)

      assert Frame.decode(<<@audio, pcm::binary>>) ==
               {:error, {:audio_too_large, Frame.max_audio_bytes() + 2}}

      assert Frame.validate_audio(pcm) == {:error, {:audio_too_large, byte_size(pcm)}}
    end

    test "an odd-length audio payload is a truncated sample, not a short frame" do
      pcm = :binary.copy(<<0>>, 401)

      assert Frame.decode(<<@audio, pcm::binary>>) == {:error, {:audio_odd_bytes, 401}}
    end

    test "a control payload that is not JSON" do
      assert {:error, {:invalid_json, detail}} = Frame.decode(<<@control, "{not json">>)
      assert is_binary(detail)
    end

    test "a control payload that is JSON but not an object" do
      assert Frame.decode(<<@control, "[1,2]">>) ==
               {:error, {:invalid_json, "control frame is not a JSON object"}}
    end

    test "a control object with no type" do
      assert Frame.decode(<<@control, ~s({"phase":"joining"})>>) ==
               {:error, {:invalid_json, ~s(control frame has no "type" string)}}
    end

    test "an unknown control type" do
      frame = <<@control, ~s({"type":"signin"})>>

      assert Frame.decode(frame) == {:error, {:unknown_control_type, "signin"}}
    end

    test "decode_control! raises on a rejected frame and on audio" do
      assert_raise ArgumentError, fn -> Frame.decode_control!(<<@control, "{">>) end
      assert_raise ArgumentError, fn -> Frame.decode_control!(<<@audio, 0, 1>>) end
    end
  end

  test "the caps and the version are the ones the sidecar is built against" do
    assert Frame.protocol_version() == 1
    assert Frame.max_control_bytes() == 65_536
    assert Frame.max_audio_bytes() == 32_768
  end
end
