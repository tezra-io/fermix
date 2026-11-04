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

  test "the table and the catalogs agree, and every raw-tailed event is named" do
    for type <- PeerEvents.client_events(), do: assert(type in Protocol.client_events())
    for type <- PeerEvents.server_events(), do: assert(type in Protocol.server_events())

    assert Enum.sort(PeerEvents.raw_events(:client)) ==
             ~w(companion_line loopback_request manage move_chunk)

    assert Enum.sort(PeerEvents.raw_events(:server)) ==
             ~w(companion_line loopback_response manage_result snapshot_chunk)
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
