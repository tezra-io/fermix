defmodule FermixChannels.Mobile.ProtocolInitiatorTest do
  # The initiator's side of the plaintext codec (`Mobile.Rail`, M75 §4.2):
  # every exported fixture travels the other way through the same rules.
  # A client frame the initiator encodes is one the responder decodes, and a
  # server frame the responder encodes is one the initiator decodes.
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Protocol

  @fixtures Application.app_dir(:fermix_core, "priv/mobile/fixtures")

  defp lines(name) do
    @fixtures |> Path.join(name) |> File.read!() |> String.split("\n", trim: true)
  end

  defp headers(name), do: name |> lines() |> Enum.map(&Jason.decode!/1)

  defp binary_frames(name) do
    for line <- lines(name) do
      %{"header" => header, "bytes_b64" => bytes} = Jason.decode!(line)
      {header, Base.decode64!(bytes)}
    end
  end

  defp plaintext(header, bytes) do
    json = Jason.encode!(header)
    <<byte_size(json)::unsigned-big-32, json::binary, bytes::binary>>
  end

  defp envelope(header), do: Map.drop(header, ~w(v t seq))

  test "every client fixture encodes on the initiator's side and decodes on the responder's" do
    frames =
      Enum.map(headers("client_events.jsonl"), &{&1, <<>>}) ++
        binary_frames("client_binary_frames.jsonl")

    for {%{"v" => v, "t" => t, "seq" => seq} = header, bytes} <- frames do
      assert {:ok, frame} =
               Protocol.encode_client_frame(t, envelope(header), seq, bytes, version: v),
             inspect(header)

      assert {:ok, %{version: ^v, type: ^t, seq: ^seq, payload: payload, bytes: ^bytes}} =
               Protocol.decode_client_frame(frame)

      assert payload == envelope(header)
    end
  end

  test "every server fixture decodes on the initiator's side" do
    frames =
      Enum.map(headers("server_events.jsonl"), &{&1, <<>>}) ++
        binary_frames("server_binary_frames.jsonl")

    for {%{"v" => v, "t" => t, "seq" => seq} = header, bytes} <- frames do
      assert {:ok, %{version: ^v, type: ^t, seq: ^seq, payload: payload, bytes: ^bytes}} =
               Protocol.decode_server_frame(plaintext(header, bytes)),
             inspect(header)

      assert payload == envelope(header)
    end
  end

  test "the exported event_part run is the event it carries" do
    run =
      for {%{"t" => "event_part"} = header, bytes} <- binary_frames("server_binary_frames.jsonl"),
          do: {header, bytes}

    assert [{%{"seq" => first_seq, "v" => v}, _tail} | _rest] = run

    json = Enum.map_join(run, fn {_header, bytes} -> bytes end)

    assert {:ok,
            %{type: "text_done", seq: ^first_seq, version: ^v, bytes: <<>>, payload: payload}} =
             Protocol.decode_server_event(json, v, first_seq)

    assert payload == json |> Jason.decode!() |> Map.delete("t")
  end

  # This wire's hello names no oldest version, so an engine speaks the oldest
  # it serves as the initiator, and reads a server's hello_ack window as
  # holding that version, whatever the server's newest: a computer one
  # version ahead of its server still connects, and so does one behind.
  test "the initiator speaks the oldest version it serves and reads any window that holds it" do
    {min, _max} = Protocol.supported_version_range()
    assert Protocol.initiator_version() == min

    hello = %{
      "device_id" => "d",
      "app_version" => "1",
      "last_server_seq" => 0,
      "protocol_v" => min
    }

    assert {:ok, _frame} = Protocol.encode_client_frame("hello", hello, 1, <<>>, [])

    ack = %{
      "v" => min,
      "t" => "hello_ack",
      "seq" => 1,
      "session_id" => "s",
      "profiles" => [],
      "candidates" => [],
      "history_head_seq" => 0,
      "read_up_to_seq" => 0,
      "caps" => %{"commands" => [], "max_media_bytes" => 1},
      "primary_epoch" => 1
    }

    for {older, newer} <- [{min, min}, {min, min + 1}, {min - 1, min}] do
      window = Map.merge(ack, %{"min_version" => older, "max_version" => newer})
      assert {:ok, %{type: "hello_ack"}} = Protocol.decode_server_frame(plaintext(window, <<>>))
    end

    for {older, newer} <- [{min + 1, min + 2}, {min, min - 1}] do
      window = Map.merge(ack, %{"min_version" => older, "max_version" => newer})

      assert {:error, {:invalid_field, "version_range"}} =
               Protocol.decode_server_frame(plaintext(window, <<>>))
    end
  end

  test "the initiator holds a frame to the codec's rules, both ways" do
    assert {:error, {:unknown_event, "pong"}} =
             Protocol.encode_client_frame("pong", %{}, 1, <<>>, [])

    assert {:error, :invalid_seq} = Protocol.encode_client_frame("ping", %{}, 0, <<>>, [])

    assert {:error, {:reserved_field, "seq"}} =
             Protocol.encode_client_frame("ping", %{seq: 2}, 1, <<>>, [])

    assert {:error, _tail} = Protocol.encode_client_frame("ping", %{}, 1, "raw", [])

    hello = %{"device_id" => "d", "app_version" => "1", "last_server_seq" => 0, "protocol_v" => 3}
    assert {:error, _mismatch} = Protocol.encode_client_frame("hello", hello, 1, <<>>, [])

    assert {:error, {:unknown_event, "ping"}} =
             Protocol.decode_server_frame(plaintext(%{"v" => 2, "t" => "ping", "seq" => 1}, <<>>))

    assert {:error, _missing} =
             Protocol.decode_server_frame(
               plaintext(%{"v" => 2, "t" => "error", "seq" => 1}, <<>>)
             )

    assert {:error, _tail} =
             Protocol.decode_server_frame(
               plaintext(%{"v" => 2, "t" => "pong", "seq" => 1}, "raw")
             )

    # A run carries a whole event: never another run, never a raw tail's event,
    # never the envelope's own fields, never past 1 MiB.
    for json <- [
          ~s({"t":"event_part","index":0,"count":2}),
          ~s({"t":"media_chunk","ref":"r","index":0}),
          ~s({"t":"pong","seq":4}),
          ~s({"v":2,"t":"pong"}),
          ~s({"pong":true}),
          "not json",
          ~s({"t":"pong","x":") <> String.duplicate("x", Protocol.max_event_bytes()) <> ~s("})
        ] do
      assert {:error, _reason} = Protocol.decode_server_event(json, 2, 1), json
    end

    assert {:ok, %{type: "pong"}} = Protocol.decode_server_event(~s({"t":"pong"}), 2, 7)
  end
end
