defmodule FermixCore.PhoneCalls.OpenAILive.SidebandTest do
  @moduledoc """
  `OpenAILive.Sideband` against a local WebSocket stand-in for the vendor's
  attach endpoint (Bandit, loopback only). The stand-in tells the test every
  frame it receives and pushes whatever the test hands it, so each test waits
  on an event, never on time: a WebSocket keeps order, so a marker frame sent
  after the frames under test proves nothing else came before it.

  The test process is the owner, linked to the sideband, so it traps exits.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Net.Egress
  alias FermixCore.PhoneCalls.OpenAILive.Controls
  alias FermixCore.PhoneCalls.OpenAILive.Sideband

  @arrival_ms 10_000
  @api_key "sk-invented-key-0002"
  @session "live_u0_inv01"
  @direct Egress.new([])

  defmodule Vendor do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, %{test: test, mode: mode}) do
      send(test, {:attach_tried, conn.request_path, conn.req_headers})
      answer(conn, mode, test)
    end

    defp answer(conn, :refuse, _test),
      do: send_resp(conn, 404, ~s({"error":{"message":"No session with that id."}}))

    defp answer(conn, :accept, test),
      do: upgrade_adapter(conn, :websocket, {Vendor.Socket, %{test: test}, []})
  end

  defmodule Vendor.Socket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(%{test: test} = state) do
      send(test, {:vendor_socket, self()})
      {:ok, state}
    end

    @impl true
    def handle_in({text, opcode: :text}, state) do
      send(state.test, {:vendor_got, Jason.decode!(text)})
      {:ok, state}
    end

    @impl true
    def handle_info({:push, frames}, state), do: {:push, Enum.map(frames, &{:text, &1}), state}
    def handle_info({:close, code, text}, state), do: {:stop, :normal, {code, text}, state}
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defp vendor!(mode) do
    server =
      start_supervised!(
        {Bandit,
         plug: {Vendor, %{test: self(), mode: mode}},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "ws://127.0.0.1:#{port}"
  end

  defp start_sideband(base, opts \\ []) do
    Sideband.start_link(
      Keyword.merge(
        [session_id: @session, api_key: @api_key, ws_base_url: base, egress: @direct],
        opts
      )
    )
  end

  defp attach! do
    base = vendor!(:accept)
    assert {:ok, sideband} = start_sideband(base)
    assert_receive {:phone_sideband, ^sideband, :attached}, @arrival_ms
    assert_receive {:vendor_socket, socket}, @arrival_ms
    %{sideband: sideband, socket: socket}
  end

  defp push(socket, events), do: send(socket, {:push, Enum.map(events, &Jason.encode!/1)})

  defp event!(sideband) do
    assert_receive {:phone_sideband, ^sideband, {:event, event}}, @arrival_ms
    event
  end

  # A usage snapshot as the last frame: once it arrives, every frame pushed
  # before it has been handled.
  defp marker(n),
    do: %{
      "type" => "session.usage.updated",
      "event_id" => "marker_#{n}",
      "usage" => %{"seconds" => n}
    }

  describe "attaching" do
    test "dials the session's attach path with the bearer header and starts nothing" do
      %{sideband: sideband} = attach!()

      assert_received {:attach_tried, "/v1/live/sessions/live_u0_inv01/attach", headers}
      assert {"authorization", "Bearer " <> @api_key} in headers

      # The first frame the vendor sees is the test's own: nothing was sent on
      # attach, so no session.start.
      assert {:ok, event_id} = Sideband.send_dtmf(sideband, "1")
      assert_receive {:vendor_got, first}, @arrival_ms
      assert first == %{"type" => "transport.dtmf.send", "event_id" => event_id, "event" => "1"}
    end

    test "a refused upgrade is an attach failure with the status, and no reconnect" do
      base = vendor!(:refuse)
      assert {:ok, sideband} = start_sideband(base)

      assert_receive {:phone_sideband, ^sideband, {:attach_failed, {:http_status, 404, _phrase}}},
                     @arrival_ms

      assert_receive {:EXIT, ^sideband, _reason}, @arrival_ms
      assert_received {:attach_tried, _path, _headers}
      refute_received {:attach_tried, _path, _headers}
    end

    # Port 1 on loopback: nothing listens there and no test can bind it.
    test "nothing listening is an attach failure naming the transport reason" do
      assert {:ok, sideband} = start_sideband("ws://127.0.0.1:1")

      assert_receive {:phone_sideband, ^sideband, {:attach_failed, {:transport, :econnrefused}}},
                     @arrival_ms

      assert_receive {:EXIT, ^sideband, _reason}, @arrival_ms
    end

    # The upgrade request is written header by header with no check, so a key
    # carrying a line break would add a header of its own. Refused before any
    # connection: port 1 would otherwise answer with an attach failure.
    test "a key no request could carry is refused before dialing" do
      for key <- [@api_key <> "\n", @api_key <> "\r\nX-Injected: 1", "sk-invented key"] do
        assert {:error, {:invalid, :api_key}} =
                 start_sideband("ws://127.0.0.1:1", api_key: key)
      end

      refute_received {:phone_sideband, _sideband, _payload}
    end

    test "a route through the proxy is refused before dialing" do
      proxied = Egress.new(proxy: "http://proxy.invented.test:3128")

      assert {:error, :proxy_unsupported_transport} =
               start_sideband("wss://api.openai.com", egress: proxied)
    end

    # A listener that takes the connection and never answers the upgrade: the
    # owner's deadline stops it, and nothing more arrives for it.
    test "stop/1 ends an attach that never completes, with no message after it" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(listener) end)
      {:ok, {_address, port}} = :inet.sockname(listener)

      assert {:ok, sideband} = start_sideband("ws://127.0.0.1:#{port}")
      ref = Process.monitor(sideband)

      assert :ok = Sideband.stop(sideband)
      assert_receive {:DOWN, ^ref, :process, ^sideband, :killed}, @arrival_ms
      refute_received {:phone_sideband, ^sideband, _payload}
      refute_received {:EXIT, ^sideband, _reason}
    end
  end

  describe "events" do
    test "a replayed event id reaches the owner once" do
      %{sideband: sideband, socket: socket} = attach!()

      ringing = %{
        "type" => "transport.ringing",
        "event_id" => "event_call_1",
        "session_id" => @session
      }

      answered = %{
        "type" => "transport.answered",
        "event_id" => "event_call_2",
        "session_id" => @session
      }

      push(socket, [ringing, ringing, answered, answered, marker(1)])

      assert {:ringing, %{event_id: "event_call_1"}} = event!(sideband)
      assert {:answered, %{event_id: "event_call_2"}} = event!(sideband)
      assert {:usage, %{event_id: "marker_1"}} = event!(sideband)
      refute_received {:phone_sideband, ^sideband, {:event, _duplicate}}
    end

    test "progress out of order arrives in that order, and a missed ringing is not invented" do
      %{sideband: sideband, socket: socket} = attach!()

      answered = %{
        "type" => "transport.answered",
        "event_id" => "event_call_2",
        "session_id" => @session
      }

      ringing = %{
        "type" => "transport.ringing",
        "event_id" => "event_call_1",
        "session_id" => @session
      }

      push(socket, [answered, marker(1)])
      assert {:answered, _answered} = event!(sideband)
      assert {:usage, _marker} = event!(sideband)

      push(socket, [ringing, marker(2)])
      assert {:ringing, _late} = event!(sideband)
      assert {:usage, %{event_id: "marker_2"}} = event!(sideband)
    end

    test "reflected audio never reaches the owner" do
      %{sideband: sideband, socket: socket} = attach!()

      push(socket, [
        %{
          "type" => "session.output_audio.delta",
          "delta" => "AAAA",
          "start_ms" => 0,
          "end_ms" => 20
        },
        %{"type" => "session.input_audio.append", "audio" => "AAAA"},
        marker(1)
      ])

      assert {:usage, %{event_id: "marker_1"}} = event!(sideband)
      refute_received {:phone_sideband, ^sideband, {:event, _audio}}
    end

    test "a frame that is not a JSON object is reported, bounded, and the socket stays up" do
      %{sideband: sideband, socket: socket} = attach!()

      send(socket, {:push, ["not json", "[1,2]"]})

      assert_receive {:phone_sideband, ^sideband, {:invalid_frame, {:decode_failed, _}}},
                     @arrival_ms

      assert_receive {:phone_sideband, ^sideband, {:invalid_frame, {:not_an_object, _}}},
                     @arrival_ms

      push(socket, [marker(1)])
      assert {:usage, _marker} = event!(sideband)
    end

    test "an unknown event type is delivered as unknown, never dropped" do
      %{sideband: sideband, socket: socket} = attach!()
      future = %{"type" => "transport.transferred", "event_id" => "event_future"}

      push(socket, [future])

      assert {:unknown, "transport.transferred", ^future} = event!(sideband)
    end
  end

  describe "keypad" do
    test "one key, its acknowledgement correlated by event id" do
      %{sideband: sideband, socket: socket} = attach!()

      assert {:ok, event_id} = Sideband.send_dtmf(sideband, "#")

      assert_receive {:vendor_got, %{"type" => "transport.dtmf.send", "event" => "#"}},
                     @arrival_ms

      push(socket, [
        %{
          "type" => "transport.dtmf.sent",
          "event_id" => "event_dtmf_1",
          "event" => "#",
          "client_event_id" => event_id
        }
      ])

      assert :acknowledged = Controls.dtmf_outcome(event_id, event!(sideband))
    end

    test "a refused key comes back as the vendor's error for that send" do
      %{sideband: sideband, socket: socket} = attach!()
      assert {:ok, event_id} = Sideband.send_dtmf(sideband, "5")

      push(socket, [
        %{
          "type" => "error",
          "event_id" => "event_error_1",
          "error" => %{
            "type" => "invalid_request_error",
            "code" => "dtmf_not_supported",
            "message" => "DTMF is only available on SIP calls.",
            "client_event_id" => event_id
          }
        }
      ])

      assert {:refused,
              %{code: "dtmf_not_supported", message: "DTMF is only available on SIP calls."}} =
               Controls.dtmf_outcome(event_id, event!(sideband))
    end

    # No acknowledgement: the owner sees other events and nothing for the key,
    # and the sideband never sends the key again on its own.
    test "a missing acknowledgement leaves the key unconfirmed and it is never resent" do
      %{sideband: sideband, socket: socket} = attach!()
      assert {:ok, event_id} = Sideband.send_dtmf(sideband, "9")
      assert_receive {:vendor_got, %{"event_id" => ^event_id}}, @arrival_ms

      push(socket, [marker(1)])
      assert :unrelated = Controls.dtmf_outcome(event_id, event!(sideband))

      assert {:ok, next_id} = Sideband.send_commentary(sideband, nil, "One moment.")
      assert_receive {:vendor_got, next}, @arrival_ms
      assert next["event_id"] == next_id
      assert next["type"] == "session.commentary.append"
      refute_received {:vendor_got, %{"event_id" => ^event_id}}
    end

    test "anything but one allowed key is refused before sending, without echoing it" do
      %{sideband: sideband} = attach!()

      for key <- ["12", "x", "", "#\n"] do
        assert {:error, :invalid_dtmf_key} = Sideband.send_dtmf(sideband, key)
      end

      assert {:ok, marker_id} = Sideband.send_dtmf(sideband, "#")

      assert_receive {:vendor_got, %{"type" => "transport.dtmf.send", "event_id" => ^marker_id}},
                     @arrival_ms

      refute_received {:vendor_got, %{"type" => "transport.dtmf.send", "event" => "x"}}
    end
  end

  describe "the other controls" do
    test "a delegation result goes back as commentary carrying the delegation id" do
      %{sideband: sideband} = attach!()
      delegation = "item_9tA2bF3h7K9m2P5q8R1s4"

      assert {:ok, event_id} = Sideband.send_commentary(sideband, delegation, "Seven is free.")

      assert_receive {:vendor_got, sent}, @arrival_ms

      assert sent == %{
               "type" => "session.commentary.append",
               "event_id" => event_id,
               "delegation_id" => delegation,
               "content" => "Seven is free."
             }
    end

    test "something for the whole call keeps a null delegation id as JSON null" do
      %{sideband: sideband} = attach!()

      assert {:ok, _event_id} = Sideband.send_commentary(sideband, nil, "Still checking.")
      assert_receive {:vendor_got, %{"type" => "session.commentary.append"} = sent}, @arrival_ms
      assert Map.fetch!(sent, "delegation_id") == nil
    end

    test "session.start and audio appends are refused on the sideband" do
      %{sideband: sideband} = attach!()

      assert {:error, {:not_sent, {:forbidden_on_sideband, "session.start"}}} =
               Sideband.send_event(sideband, %{type: "session.start", event_id: "ev_x"})

      assert {:error, {:not_sent, {:forbidden_on_sideband, "session.input_audio.append"}}} =
               Sideband.send_event(sideband, %{type: "session.input_audio.append", audio: "AAAA"})
    end
  end

  # The one scrub, held for the life of the call: no message the owner gets
  # holds the key or a secret the sideband was given.
  describe "what the vendor says" do
    @password "pw-Invented-0002"

    test "every message to the owner is free of the key and the trunk password" do
      base = vendor!(:accept)
      assert {:ok, sideband} = start_sideband(base, secrets: [@password])
      assert_receive {:phone_sideband, ^sideband, :attached}, @arrival_ms
      assert_receive {:vendor_socket, socket}, @arrival_ms
      quoted = ~s(Bearer #{@api_key} for #{@password}; {"key":"#{@api_key}"})

      push(socket, [
        %{
          "type" => "error",
          "event_id" => "e1",
          "error" => %{"message" => quoted, "code" => quoted}
        },
        %{"type" => "transport.failed", "event_id" => "e2", "error" => %{"message" => quoted}},
        %{"type" => "vendor.#{@api_key}", "event_id" => "e3", "detail" => quoted},
        %{"type" => "session.input_transcript.delta", "event_id" => "e4", "note" => quoted},
        %{"type" => "session.closed", "event_id" => "e5", "reason" => quoted}
      ])

      send(socket, {:push, [Jason.encode!([quoted])]})
      send(socket, {:close, 4000, "dropped #{@api_key} #{@password}"})

      events = for _n <- 1..5, do: event!(sideband)

      assert [
               {:vendor_error, _},
               {:call_failed, _},
               {:unknown, _, _},
               {:malformed, _, _},
               {:session_closed, _}
             ] = events

      assert_receive {:phone_sideband, ^sideband, {:invalid_frame, frame}}, @arrival_ms
      assert_receive {:phone_sideband, ^sideband, {:closed, closed}}, @arrival_ms

      for message <- events ++ [frame, closed] do
        printed = inspect(message, limit: :infinity, printable_limit: :infinity)
        assert printed =~ "[REDACTED]", printed
        refute printed =~ @api_key, printed
        refute printed =~ @password, printed
      end

      assert_receive {:EXIT, ^sideband, _reason}, @arrival_ms
    end
  end

  describe "the end of the socket" do
    test "session.closed then a normal close: finalization confirmed" do
      %{sideband: sideband, socket: socket} = attach!()

      push(socket, [
        %{
          "type" => "session.closed",
          "event_id" => "event_closed",
          "reason" => "remote_hangup",
          "usage" => %{"seconds" => 41}
        }
      ])

      assert {:session_closed, %{reason: "remote_hangup", seconds: 41}} = event!(sideband)

      send(socket, {:close, 1000, ""})

      assert_receive {:phone_sideband, ^sideband, {:closed, {:remote_close, 1000, _text}}},
                     @arrival_ms

      assert_receive {:EXIT, ^sideband, :normal}, @arrival_ms
    end

    test "a close with no session.closed before it: finalization stays unconfirmed" do
      %{sideband: sideband, socket: socket} = attach!()

      push(socket, [marker(30)])
      assert {:usage, %{seconds: 30}} = event!(sideband)

      send(socket, {:close, 1011, "upstream gone"})

      assert_receive {:phone_sideband, ^sideband,
                      {:closed, {:remote_close, 1011, "upstream gone"}}},
                     @arrival_ms

      refute_received {:phone_sideband, ^sideband, {:event, {:session_closed, _closed}}}
      assert_receive {:EXIT, ^sideband, _reason}, @arrival_ms
    end

    test "a connection that drops without a close frame is connection_lost" do
      %{sideband: sideband, socket: socket} = attach!()

      Process.exit(socket, :kill)

      assert_receive {:phone_sideband, ^sideband, {:closed, :connection_lost}}, @arrival_ms
      assert_receive {:EXIT, ^sideband, _reason}, @arrival_ms
    end

    test "close/1 ends the socket normally; a send after it is known not to be sent" do
      %{sideband: sideband} = attach!()

      assert :ok = Sideband.close(sideband)
      assert_receive {:phone_sideband, ^sideband, {:closed, :local_close}}, @arrival_ms
      assert_receive {:EXIT, ^sideband, :normal}, @arrival_ms

      assert {:error, {:not_sent, :sideband_down}} = Sideband.send_dtmf(sideband, "1")
    end
  end
end
