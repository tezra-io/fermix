defmodule FermixChannels.Channels.IMessage.ProtocolTest do
  @moduledoc """
  Golden tests for the Fermix Messages wire (MILESTONE_54 §6). The fixtures under
  `test/fixtures/imessage/protocol/` are NDJSON, one wire frame per line, one file
  per method and per notification; the helper repo's `Protocol.swift` is tested
  against copies of the same files, so a change here is a protocol change.
  """
  use ExUnit.Case, async: true

  alias FermixChannels.Channels.IMessage.Protocol

  @fixtures Path.expand("../../../fixtures/imessage/protocol", __DIR__)

  defp frames(file) do
    @fixtures
    |> Path.join(file)
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  describe "fixture completeness" do
    test "every method and every notification has its own fixture file" do
      expected =
        Enum.map(Protocol.methods(), &"#{&1}.jsonl") ++
          Enum.map(Protocol.events(), &"notification.#{&1}.jsonl") ++ ["errors.jsonl"]

      assert Enum.sort(File.ls!(@fixtures)) == Enum.sort(expected)
    end

    test "errors.jsonl names every error kind of the closed set exactly once" do
      kinds =
        "errors.jsonl"
        |> frames()
        |> Enum.map(fn line -> line |> Jason.decode!() |> get_in(["error", "kind"]) end)

      assert Enum.sort(kinds) == Enum.sort(Enum.map(Protocol.error_kinds(), &Atom.to_string/1))
    end
  end

  describe "requests" do
    test "encode_request/3 reproduces the first line of every method fixture" do
      for method <- Protocol.methods() do
        [request_line | _responses] = frames("#{method}.jsonl")
        %{"id" => id, "method" => ^method, "params" => params} = Jason.decode!(request_line)

        assert {:ok, encoded} = Protocol.encode_request(id, method, params)
        assert String.ends_with?(encoded, "\n")
        refute encoded |> String.trim_trailing("\n") |> String.contains?("\n")
        assert Jason.decode!(encoded) == Jason.decode!(request_line), method
      end
    end

    test "an unknown method is refused before anything reaches the wire" do
      assert Protocol.encode_request(1, "messages.delete", %{}) ==
               {:error, {:unknown_method, "messages.delete"}}
    end

    test "initialize_params/1 pins protocol version 1 and names the client" do
      assert Protocol.protocol_version() == 1

      assert Protocol.initialize_params("0.12.1") == %{
               "protocol_version" => 1,
               "client" => "fermix 0.12.1"
             }
    end
  end

  describe "responses" do
    test "every result line of every method fixture decodes to its id and result" do
      for method <- Protocol.methods(),
          line <- tl(frames("#{method}.jsonl")),
          %{"result" => result} = frame <- [Jason.decode!(line)] do
        assert Protocol.decode(line) == {:ok, {:response, frame["id"], {:ok, result}}}, method
      end
    end

    test "every error kind decodes to its closed atom with message and data" do
      for line <- frames("errors.jsonl") do
        %{"id" => id, "error" => %{"kind" => kind, "message" => message, "data" => data}} =
          Jason.decode!(line)

        assert {:ok, {:response, ^id, {:error, {atom, ^message, ^data}}}} = Protocol.decode(line)
        assert Atom.to_string(atom) == kind
      end
    end

    test "method fixtures' error lines decode to typed errors" do
      [_request, _result, _null_generation, mismatch] = frames("initialize.jsonl")

      assert {:ok, {:response, 1, {:error, {:protocol_mismatch, _message, %{"helper" => 2}}}}} =
               Protocol.decode(mismatch)

      [_request, _recorded, _uncertain, _uncertain_timeout, _failed, violation] =
        frames("send.text.jsonl")

      assert {:ok, {:response, 9, {:error, {:policy_violation, _message, data}}}} =
               Protocol.decode(violation)

      assert data == %{"handle" => "+15559999999"}
    end

    test "an unknown error kind is refused with a typed error that keeps the request id" do
      line = ~s({"id":7,"error":{"kind":"teleported","message":"?","data":{}}})

      assert Protocol.decode(line) == {:error, {:unknown_error_kind, 7, "teleported"}}

      assert Protocol.decode_error_kind("teleported") ==
               {:error, {:unknown_error_kind, "teleported"}}
    end

    test "an error without data decodes with an empty data map" do
      line = ~s({"id":3,"error":{"kind":"busy","message":"slow down"}})
      assert Protocol.decode(line) == {:ok, {:response, 3, {:error, {:busy, "slow down", %{}}}}}
    end
  end

  describe "notifications" do
    test "every notification fixture decodes to its event and params" do
      for event <- Protocol.events(), line <- frames("notification.#{event}.jsonl") do
        %{"event" => ^event, "params" => params} = Jason.decode!(line)
        assert Protocol.decode(line) == {:ok, {:notification, event, params}}, event
      end
    end

    test "an unknown event is refused" do
      assert Protocol.decode(~s({"event":"typing","params":{}})) ==
               {:error, {:unknown_event, "typing"}}
    end
  end

  describe "malformed input" do
    test "is refused with a named class, never raised" do
      assert Protocol.decode("not json") == {:error, :invalid_json}
      assert Protocol.decode("[1,2]") == {:error, :not_an_object}
      assert Protocol.decode(~s({"id":"x","result":{}})) == {:error, :malformed_frame}
      assert Protocol.decode(~s({"id":1,"result":[]})) == {:error, :malformed_frame}
      assert Protocol.decode(~s({"event":"message","params":[]})) == {:error, :malformed_frame}
      assert Protocol.decode(~s({"id":1,"error":{"kind":"busy"}})) == {:error, :malformed_frame}
    end
  end

  describe "normalize_handle/1 (one rule for both sides, §7.4)" do
    test "phone numbers become E.164 with a leading plus and no separators" do
      assert Protocol.normalize_handle("+1 (555) 123-4567") == {:ok, "+15551234567"}
      assert Protocol.normalize_handle(" +44 20 7946 0958 ") == {:ok, "+442079460958"}
      assert Protocol.normalize_handle("+15551234567") == {:ok, "+15551234567"}
    end

    test "emails are lower-cased" do
      assert Protocol.normalize_handle(" Owner@Example.COM ") == {:ok, "owner@example.com"}
    end

    test "anything else is refused rather than guessed" do
      for value <- [
            "5551234567",
            "+",
            "",
            "not a handle",
            "a@b@c",
            "+1555abc4567",
            nil,
            15_551_234_567
          ] do
        assert Protocol.normalize_handle(value) == {:error, :invalid_handle}, inspect(value)
      end
    end
  end

  describe "redact_handle/1 (logs never carry a whole handle, §13)" do
    test "keeps only the ends of a phone number and the first letter of an email" do
      assert Protocol.redact_handle("+15551234567") == "+1555…4567"
      assert Protocol.redact_handle("someone@example.com") == "s…@example.com"
      assert Protocol.redact_handle("+1234") == "…"
    end
  end
end
