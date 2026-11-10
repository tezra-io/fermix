defmodule FermixChannels.Mobile.PeerEventsTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.PeerEvents
  alias FermixChannels.Mobile.Protocol

  @call "call-7f3a"
  @sha "9c56cc51b374c3ba189210d5b6d4bf57790d351c96c47c02190ecf1e430635ab"
  @node "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"

  describe "a desktop's events, as the primary decodes them" do
    test "a chunked manage frame carries its call, method and version" do
      fields = %{
        "call_id" => @call,
        "method" => "settings.get",
        "protocol_version" => 2,
        "index" => 0,
        "last" => true
      }

      assert {:ok, %{type: "manage", bytes: ~s({"section":"agent"})}} =
               decode("manage", fields, ~s({"section":"agent"}))

      assert {:error, {:invalid_field, "method"}} =
               decode("manage", %{fields | "method" => "Settings.Get"}, "{}")

      assert {:error, {:missing_field, "bytes"}} = decode("manage", fields, <<>>)

      assert {:error, {:missing_field, "last"}} =
               decode("manage", Map.delete(fields, "last"), "{}")
    end

    test "a companion channel is 1 to 64 and a line carries bytes" do
      line = %{"channel" => 1, "index" => 0, "last" => true}
      assert {:ok, _event} = decode("companion_line", line, "hello\n")

      for channel <- [0, 65, "1"] do
        assert {:error, {:invalid_field, "channel"}} =
                 decode("companion_open", %{"channel" => channel})
      end

      assert {:error, {:missing_field, "bytes"}} = decode("companion_line", line, <<>>)

      assert {:error, {:unexpected_binary, "companion_open"}} =
               decode("companion_open", %{"channel" => 2}, "x")
    end

    test "a loopback request's body may be empty" do
      request = %{
        "loopback_id" => "lb-1",
        "request_id" => "rq-1",
        "method" => "GET",
        "target" => "/callback?code=abc&state=xyz",
        "headers" => [["host", "127.0.0.1:53682"], ["accept", "text/html"]]
      }

      assert {:ok, %{bytes: <<>>}} = decode("loopback_request", request)

      assert {:error, {:raw_chunk_too_large, 16_385, 16_384}} =
               decode("loopback_request", request, :binary.copy("a", 16_385))

      crlf = %{request | "headers" => [["host", "a\r\nx-evil: 1"]]}
      assert {:error, {:invalid_field, "headers"}} = decode("loopback_request", crlf)

      assert {:error, {:invalid_field, "target"}} =
               decode("loopback_request", %{request | "target" => "http://x/"})
    end
  end

  describe "what the primary sends a desktop" do
    test "a loopback opens 1 to 8 ports" do
      open = %{"loopback_id" => "lb-1", "ports" => [53_682], "expires_in_s" => 900}
      assert {:ok, _frame} = encode("loopback_open", open)

      assert {:error, {:invalid_field, "ports"}} =
               encode("loopback_open", %{open | "ports" => Enum.to_list(1..9)})

      assert {:error, {:invalid_field, "expires_in_s"}} =
               encode("loopback_open", %{open | "expires_in_s" => 901})
    end

    test "an optional field is absent, never null" do
      assert {:ok, _frame} = encode("companion_close", %{"channel" => 3})

      assert {:ok, _frame} =
               encode("companion_close", %{"channel" => 3, "reason" => "closed by the app"})

      assert {:error, {:null_field, "reason"}} =
               encode("companion_close", %{"channel" => 3, "reason" => nil})
    end
  end

  describe "enrollment and the move" do
    test "an enrollment request names its host and its route, the rest optional" do
      request = %{
        "host" => %{
          "name" => "fermix-vm",
          "os" => "debian",
          "arch" => "arm64",
          "version" => "0.17.0"
        },
        "candidate" => %{
          "node_id" => @node,
          "relays" => [%{"url" => "https://us1.relay.fermix.ai/", "quic_port" => 7842}],
          "recipient" => Base.encode64(:binary.copy(<<7>>, 32))
        }
      }

      assert {:ok, _event} = decode("enroll_request", request)

      assert {:error, {:missing_field, "candidate.recipient"}} =
               decode(
                 "enroll_request",
                 update_in(request["candidate"], &Map.delete(&1, "recipient"))
               )

      # What a host says of its instance is no field of the request, so it
      # is not checked.
      assert {:ok, _event} =
               decode("enroll_request", Map.put(request, "instance", %{"region" => ""}))

      assert {:error, {:missing_field, "host.arch"}} =
               decode(
                 "enroll_request",
                 put_in(request, ["host"], Map.delete(request["host"], "arch"))
               )

      assert {:error, {:invalid_field, "candidate.relays"}} =
               decode("enroll_request", put_in(request, ["candidate", "relays"], []))

      # An Always On server's address hints: one to eight `ip:port`, or none.
      hinted =
        put_in(request, ["candidate", "addrs"], ["100.64.0.9:4033", "[fd7a:115c:a1e0::9]:4033"])

      assert {:ok, _event} = decode("enroll_request", hinted)

      for addrs <- [[], ["fermix-vm:4033"], ["100.64.0.9"], List.duplicate("100.64.0.9:4033", 9)] do
        assert {:error, {:invalid_field, "candidate.addrs"}} =
                 decode("enroll_request", put_in(request, ["candidate", "addrs"], addrs))
      end
    end

    test "a move offer, its chunks, and the candidate's one-time recipient" do
      offer = %{
        "move_id" => "mv-1",
        "size_bytes" => 12_345,
        "sha256" => @sha,
        "source_epoch" => 3,
        "attempt" => 1
      }

      assert {:ok, _event} = decode("move_offer", offer)

      assert {:error, {:missing_field, "attempt"}} =
               decode("move_offer", Map.delete(offer, "attempt"))

      recipient =
        "fxsnap1.c2FsdHNhbHRzYWx0.#{Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}"

      assert {:ok, _event} = decode("move_offer", Map.put(offer, "recovery_recipient", recipient))

      assert {:error, {:invalid_field, "recovery_recipient"}} =
               decode("move_offer", Map.put(offer, "recovery_recipient", "passphrase"))

      assert {:ok, _event} =
               decode("move_chunk", %{"move_id" => "mv-1", "index" => 0}, "ciphertext")

      assert {:error, {:missing_field, "bytes"}} =
               decode("move_chunk", %{"move_id" => "mv-1", "index" => 0})

      key = Base.encode64(:crypto.strong_rand_bytes(32))
      assert {:ok, _frame} = encode("move_accept", %{"move_id" => "mv-1", "recipient" => key})

      assert {:error, {:invalid_field, "recipient"}} =
               encode("move_accept", %{"move_id" => "mv-1", "recipient" => Base.encode64("short")})

      assert {:error, {:invalid_field, "epoch"}} =
               encode("move_ready", %{"move_id" => "mv-1", "epoch" => 0})
    end
  end

  # M87 §06: a call channel on a phone's session, carrying the Realtime wire's
  # own objects as raw tails and its audio as raw PCM16.
  describe "a phone's call channel" do
    @pcm :binary.copy(<<0, 1>>, 2_400)

    test "a call opens or resumes by its id" do
      assert {:ok, %{type: "call_open"}} =
               decode("call_open", %{"call_id" => @call, "resume" => false})

      assert {:error, {:missing_field, "resume"}} = decode("call_open", %{"call_id" => @call})

      assert {:error, {:invalid_field, "call_id"}} =
               decode("call_open", %{"call_id" => "", "resume" => true})

      assert {:error, {:unexpected_binary, "call_open"}} =
               decode("call_open", %{"call_id" => @call, "resume" => true}, "x")
    end

    # `seq` is the frame's own sequence, so the control's number is its own
    # field.
    test "a line carries one Realtime object, its control numbered" do
      line = ~s({"type":"mute","enabled":true})

      assert {:ok, %{bytes: ^line}} =
               decode("call_line", %{"call_id" => @call, "control_seq" => 3}, line)

      assert {:ok, _hello} =
               decode("call_line", %{"call_id" => @call}, ~s({"type":"client_hello"}))

      assert {:error, {:missing_field, "bytes"}} = decode("call_line", %{"call_id" => @call})

      assert {:error, {:invalid_field, "control_seq"}} =
               decode("call_line", %{"call_id" => @call, "control_seq" => 0}, line)

      assert {:ok, _line} = encode("call_line", %{"call_id" => @call}, ~s({"type":"state"}))
    end

    # PCM16 at 24 kHz mono: 100 ms is 4,800 bytes, and a sample is two.
    test "audio is whole PCM16 samples, at most 100 ms a frame" do
      assert {:ok, %{bytes: @pcm}} = decode("call_audio", %{"call_id" => @call}, @pcm)

      assert {:error, {:missing_field, "bytes"}} = decode("call_audio", %{"call_id" => @call})

      assert {:error, {:raw_chunk_too_large, 4_802, 4_800}} =
               decode("call_audio", %{"call_id" => @call}, @pcm <> <<0, 0>>)

      assert {:error, {:invalid_field, "bytes"}} =
               decode("call_audio", %{"call_id" => @call}, <<0, 0, 0>>)

      down = %{"call_id" => @call, "playback_id" => "p17"}
      assert {:ok, _frame} = encode("call_audio", down, @pcm)

      assert {:error, {:missing_field, "playback_id"}} =
               encode("call_audio", %{"call_id" => @call}, @pcm)

      assert {:error, {:invalid_field, "playback_id"}} =
               encode("call_audio", %{down | "playback_id" => String.duplicate("p", 65)}, @pcm)
    end

    # M87 Phase 2: a camera still, one JPEG of at most 60 KiB, with its size
    # and when the phone took it. Anything else is a malformed frame.
    test "a camera frame is one JPEG of at most 60 KiB, with its size and time" do
      header = %{"call_id" => @call, "width" => 768, "height" => 576, "captured_ms" => 1_234}
      jpeg = <<0xFF, 0xD8, 0xFF, 0xE0>> <> :binary.copy(<<0>>, 64)
      biggest = <<0xFF, 0xD8, 0xFF>> <> :binary.copy(<<0>>, 60 * 1_024 - 3)

      assert {:ok, %{type: "call_frame", bytes: ^jpeg}} = decode("call_frame", header, jpeg)
      assert {:ok, _frame} = decode("call_frame", header, biggest)

      assert {:error, {:raw_chunk_too_large, 61_441, 61_440}} =
               decode("call_frame", header, biggest <> <<0>>)

      assert {:error, {:missing_field, "bytes"}} = decode("call_frame", header)

      for not_jpeg <- [<<0x89, "PNG", 0, 0>>, <<0xFF, 0xD8>>] do
        assert {:error, {:invalid_field, "bytes"}} = decode("call_frame", header, not_jpeg)
      end

      for field <- ~w(call_id width height captured_ms) do
        assert {:error, {:missing_field, ^field}} =
                 decode("call_frame", Map.delete(header, field), jpeg)
      end

      for {field, bad} <- [{"width", 0}, {"width", 4_097}, {"height", 0}, {"captured_ms", -1}] do
        assert {:error, {:invalid_field, ^field}} =
                 decode("call_frame", Map.put(header, field, bad), jpeg)
      end
    end

    test "the primary attaches a call with its state as it holds it" do
      attached = %{
        "call_id" => @call,
        "resumed" => true,
        "muted" => false,
        "camera" => false,
        "control_seq" => 0
      }

      assert {:ok, _frame} = encode("call_attached", attached)

      assert {:error, {:invalid_field, "control_seq"}} =
               encode("call_attached", %{attached | "control_seq" => -1})

      assert {:error, {:missing_field, "camera"}} =
               encode("call_attached", Map.delete(attached, "camera"))
    end

    test "a close says why from the primary, and may from the phone" do
      for reason <- ~w(ended lost link_too_slow revoked unknown_call) do
        assert {:ok, _frame} = encode("call_close", %{"call_id" => @call, "reason" => reason})
      end

      assert {:error, {:missing_field, "reason"}} = encode("call_close", %{"call_id" => @call})

      # A string, so a later primary's reason reads as an end, not a bad frame.
      assert {:ok, _frame} = encode("call_close", %{"call_id" => @call, "reason" => "hung_up"})

      for bad <- ["", 7] do
        assert {:error, {:invalid_field, "reason"}} =
                 encode("call_close", %{"call_id" => @call, "reason" => bad})
      end

      assert {:ok, _event} = decode("call_close", %{"call_id" => @call})

      assert {:ok, _event} =
               decode("call_close", %{"call_id" => @call, "reason" => "Ended for a phone call"})
    end
  end

  # M97 §3.2, §5.3: a computer's own record on a desktop's session.
  describe "a computer's offers and path" do
    test "offers is a chunked payload under its revision, link_path a path" do
      rev = "0f1e2d3c4b5a6978"
      payload = ~s({"v":1,"offers":[]})
      chunk = %{"rev" => rev, "index" => 0, "last" => true}

      assert {:ok, _event} = decode("offers", chunk, payload)

      assert {:error, {:invalid_field, "rev"}} =
               decode("offers", %{chunk | "rev" => "XYZ"}, payload)

      assert {:error, {:missing_field, "bytes"}} = decode("offers", chunk)

      assert {:ok, _event} = decode("link_path", %{"path" => "relay"})
      assert {:error, {:invalid_field, "path"}} = decode("link_path", %{"path" => "carrier"})
    end

    test "a desktop's hello names its system, and nothing else is one" do
      hello = %{
        "device_id" => "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e",
        "app_version" => "0.19.0",
        "last_server_seq" => 0,
        "protocol_v" => Protocol.protocol_version()
      }

      assert {:ok, _event} = decode("hello", hello)
      assert {:ok, _event} = decode("hello", Map.put(hello, "platform", "linux"))

      assert {:error, {:invalid_field, "platform"}} =
               decode("hello", Map.put(hello, "platform", "ios"))
    end
  end

  test "the table and the catalogs agree, and every raw-tailed event is named" do
    for type <- PeerEvents.client_events(), do: assert(type in Protocol.client_events())
    for type <- PeerEvents.server_events(), do: assert(type in Protocol.server_events())

    assert Enum.sort(PeerEvents.raw_events(:client)) ==
             ~w(call_audio call_frame call_line companion_line loopback_request manage
                move_chunk offers)

    assert Enum.sort(PeerEvents.raw_events(:server)) ==
             ~w(call_audio call_line companion_line loopback_response manage_result
                snapshot_chunk)
  end

  defp decode(type, fields, bytes \\ <<>>) do
    header =
      fields
      |> Map.merge(%{"v" => Protocol.protocol_version(), "t" => type, "seq" => 1})
      |> Jason.encode!()

    Protocol.decode_client_frame(<<byte_size(header)::32, header::binary, bytes::binary>>)
  end

  defp encode(type, fields, bytes \\ <<>>),
    do: Protocol.encode_server_frame(type, fields, 1, bytes)
end
