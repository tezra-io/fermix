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

    test "an empty file is an empty blob, and a body may be empty" do
      blob = %{"invocation_id" => "inv-1", "index" => 0, "last" => true}
      assert {:ok, %{bytes: <<>>}} = decode("invoke_blob", blob)

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

    test "receipts are bounded lists" do
      receipt = %{
        "invocation_id" => "inv-1",
        "status" => "ok",
        "finished_at" => "2026-10-21T08:14:03Z"
      }

      answer = %{"status_id" => "st-1", "receipts" => [receipt]}
      assert {:ok, _event} = decode("invoke_receipts", answer)
      assert {:ok, _event} = decode("invoke_receipts", %{answer | "receipts" => []})

      assert {:error, {:missing_field, "status_id"}} =
               decode("invoke_receipts", Map.delete(answer, "status_id"))

      assert {:error, {:invalid_field, "receipts"}} =
               decode("invoke_receipts", %{answer | "receipts" => List.duplicate(receipt, 33)})

      assert {:error, {:invalid_field, "receipts"}} =
               decode("invoke_receipts", %{
                 answer
                 | "receipts" => [%{receipt | "status" => "running"}]
               })

      # RFC 3339 in UTC: an offset is refused here, never mistaken further on.
      for at <- ["2026-10-21T10:14:03+02:00", "2026-10-21T03:14:03-05:00", "next week"] do
        assert {:error, {:invalid_field, "receipts"}} =
                 decode("invoke_receipts", %{
                   answer
                   | "receipts" => [%{receipt | "finished_at" => at}]
                 })
      end
    end
  end

  describe "what the primary sends a desktop" do
    test "an invoke runs within its deadline and names a snake_case action" do
      invoke = %{
        "invocation_id" => "inv-1",
        "action" => "run_command",
        "deadline_s" => 60,
        "index" => 0,
        "last" => true
      }

      assert {:ok, _frame} = encode("invoke", invoke, ~s({"command":"ls"}))

      for deadline <- [0, 601] do
        assert {:error, {:invalid_field, "deadline_s"}} =
                 encode("invoke", %{invoke | "deadline_s" => deadline}, "{}")
      end

      assert {:error, {:invalid_field, "action"}} =
               encode("invoke", %{invoke | "action" => "Run Command"}, "{}")
    end

    test "status asks after 1 to 32 invocations and a loopback opens 1 to 8 ports" do
      status = %{"status_id" => "st-1", "invocation_ids" => ["inv-1"]}
      assert {:ok, _frame} = encode("invoke_status", status)

      assert {:error, {:missing_field, "status_id"}} =
               encode("invoke_status", Map.delete(status, "status_id"))

      for ids <- [[], List.duplicate("inv-1", 33)] do
        assert {:error, {:invalid_field, "invocation_ids"}} =
                 encode("invoke_status", %{status | "invocation_ids" => ids})
      end

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

  describe "pairing from a phone (D16)" do
    test "the window carries the pairing link, and only a pairing link" do
      window = %{"session_id" => "5b0c7d2e-8f41-4a6b-9c3d-2e7f1a8b4c60", "expires_in_s" => 120}

      assert {:ok, _frame} =
               encode("pair_window", Map.put(window, "link", "fermix://pair?v=2&secret=x"))

      assert {:error, {:invalid_field, "link"}} =
               encode("pair_window", Map.put(window, "link", "https://fermix.ai/pair"))
    end

    test "a pending request shows its six-digit SAS, and a decision names a known ending" do
      pending = %{
        "session_id" => "s-1",
        "device_name" => "Garden phone",
        "model" => "Google Pixel 9",
        "platform" => "android",
        "sas" => "042917",
        "expires_in_s" => 88
      }

      assert {:ok, _frame} = encode("pair_pending", pending)

      assert {:error, {:invalid_field, "sas"}} =
               encode("pair_pending", %{pending | "sas" => "42917"})

      assert {:error, {:invalid_field, "device_name"}} =
               encode("pair_pending", %{pending | "device_name" => "bad\e[2Jname"})

      for outcome <- ~w(approved denied timeout cancelled device_disconnected attestation) do
        assert {:ok, _frame} =
                 encode("pair_decided", %{"session_id" => "s-1", "outcome" => outcome})
      end

      assert {:error, {:invalid_field, "outcome"}} =
               encode("pair_decided", %{"session_id" => "s-1", "outcome" => "expired"})

      assert {:ok, _event} = decode("pair_start", %{})

      assert {:error, {:invalid_field, "approved"}} =
               decode("pair_decide", %{"session_id" => "s-1", "approved" => "yes"})
    end
  end

  describe "devices from a phone" do
    test "a phone lists and revokes by id, and the list is the owner's devices" do
      assert {:ok, _event} = decode("devices_list", %{})
      assert {:ok, _event} = decode("device_revoke", %{"device_id" => "6f1e2d3c-4b5a"})
      assert {:error, {:missing_field, "device_id"}} = decode("device_revoke", %{})

      desktop = %{
        "device_id" => "6f1e2d3c-4b5a",
        "name" => "Studio Mac",
        "model" => "macOS desktop",
        "kind" => "desktop",
        "created_at" => "2026-10-20T09:00:00Z",
        "executor" => true,
        "this_device" => false
      }

      assert {:ok, _frame} = encode("devices", %{"devices" => [desktop]})
      assert {:ok, _frame} = encode("devices", %{"devices" => []})

      assert {:error, {:invalid_field, "devices"}} =
               encode("devices", %{"devices" => [%{desktop | "kind" => "tablet"}]})

      assert {:error, {:invalid_field, "devices"}} =
               encode("devices", %{"devices" => List.duplicate(desktop, 65)})
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

      instance = %{"provider" => "hetzner", "instance_id" => "61839204", "region" => "fsn1"}

      assert {:ok, _event} = decode("enroll_request", Map.put(request, "instance", instance))

      assert {:ok, _event} =
               decode(
                 "enroll_request",
                 Map.put(request, "instance", Map.put(instance, "account_id", "invented-7"))
               )

      assert {:error, {:invalid_field, "instance.account_id"}} =
               decode(
                 "enroll_request",
                 Map.put(request, "instance", Map.put(instance, "account_id", ""))
               )

      assert {:error, {:missing_field, "host.arch"}} =
               decode(
                 "enroll_request",
                 put_in(request, ["host"], Map.delete(request["host"], "arch"))
               )

      assert {:error, {:invalid_field, "candidate.relays"}} =
               decode("enroll_request", put_in(request, ["candidate", "relays"], []))

      assert {:error, {:invalid_field, "instance.region"}} =
               decode(
                 "enroll_request",
                 Map.put(request, "instance", %{instance | "region" => ""})
               )
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
             ~w(companion_line invoke_blob invoke_result loopback_request manage move_chunk)

    assert Enum.sort(PeerEvents.raw_events(:server)) ==
             ~w(companion_line invoke loopback_response manage_result snapshot_chunk)
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
