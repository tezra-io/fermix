defmodule FermixCore.PhoneCalls.GptLiveWireContractTest do
  @moduledoc """
  The GPT-Live SIP wire shapes, read from the one file the eval runners'
  simulated endpoint is held to as well
  (`test/fixtures/phone_calls/gpt_live_wire.json`;
  `benchmark/bin/test_phone_sim.py` reads it too): every server event the
  simulator sends normalizes to its named event and none to `:unknown` or
  `:malformed`, a replayed event is delivered once, each acknowledgement
  correlates with the client event it answers, the client events and the
  create body are the ones this transport builds, and every create and hangup
  answer is classified as named. A change to either side's reading of the
  vendor's pages fails here or there.

  The sideband case runs a loopback stand-in (Bandit) that pushes every
  exemplar; nothing reaches a vendor.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Net.Egress
  alias FermixCore.PhoneCalls.OpenAILive
  alias FermixCore.PhoneCalls.OpenAILive.Controls
  alias FermixCore.PhoneCalls.OpenAILive.Events
  alias FermixCore.PhoneCalls.OpenAILive.Sideband

  @fixture Path.expand("../../fixtures/phone_calls/gpt_live_wire.json", __DIR__)
  @external_resource @fixture
  @wire @fixture |> File.read!() |> Jason.decode!()
  @arrival_ms 10_000
  @direct Egress.new([])

  defmodule Pusher do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, %{frames: frames}),
      do: upgrade_adapter(conn, :websocket, {Pusher.Socket, %{frames: frames}, []})
  end

  defmodule Pusher.Socket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(%{frames: frames} = state), do: {:push, Enum.map(frames, &{:text, &1}), state}

    @impl true
    def handle_in(_frame, state), do: {:ok, state}

    @impl true
    def handle_info(_message, state), do: {:ok, state}
  end

  describe "server events" do
    test "every event the simulator sends normalizes to its named event" do
      for {type, %{"event" => event, "normalized" => tag}} <- @wire["server_events"] do
        normalized = Events.normalize(event)
        assert elem(normalized, 0) == String.to_existing_atom(tag), type
        refute elem(normalized, 0) in [:unknown, :malformed], type
      end
    end

    test "a replayed event keeps its id and is delivered once" do
      replayed = @wire["server_events"][@wire["replayed"]]["event"]
      assert {:new, seen} = Events.dedupe(Events.new_seen(), replayed)
      assert :duplicate = Events.dedupe(seen, replayed)
    end

    test "each acknowledgement correlates with the client event it answers" do
      events = @wire["server_events"]

      # The keypad is the one control whose acknowledgement the call reads.
      %{"event" => sent, "acknowledged_by" => ack} = @wire["client_events"]["transport.dtmf.send"]
      acknowledged = Events.normalize(events[ack]["event"])
      assert Controls.dtmf_outcome(sent["event_id"], acknowledged) == :acknowledged

      refused = Events.normalize(events["error"]["event"])
      assert {:refused, _error} = Controls.dtmf_outcome("ev_wire_7", refused)
    end

    test "the sideband delivers every exemplar once, in order, the replay dropped" do
      # The sideband is linked to its owner, the test.
      Process.flag(:trap_exit, true)
      events = Enum.map(@wire["server_events"], fn {_type, entry} -> entry end)
      replayed = @wire["server_events"][@wire["replayed"]]["event"]
      frames = Enum.map(events, &Jason.encode!(&1["event"])) ++ [Jason.encode!(replayed)]
      base = pusher!(frames)

      assert {:ok, pid} =
               Sideband.start_link(
                 session_id: "live_sim_0123456789abcdef",
                 api_key: "sk-eval-invented-phone-0094",
                 ws_base_url: base,
                 egress: @direct
               )

      assert_receive {:phone_sideband, ^pid, :attached}, @arrival_ms

      for %{"normalized" => tag} <- events do
        assert_receive {:phone_sideband, ^pid, {:event, normalized}}, @arrival_ms
        assert elem(normalized, 0) == String.to_existing_atom(tag)
      end

      refute_received {:phone_sideband, ^pid, {:event, _replayed}}
      Sideband.stop(pid)
    end
  end

  describe "client events" do
    test "the keypad and commentary events are the ones this transport builds" do
      client = @wire["client_events"]
      dtmf = client["transport.dtmf.send"]["event"]
      assert {:ok, built} = Controls.dtmf_event(dtmf["event_id"], dtmf["event"])
      assert json(built) == dtmf

      reply = client["session.commentary.append"]["event"]

      assert json(
               Controls.commentary_event(
                 reply["event_id"],
                 reply["delegation_id"],
                 reply["content"]
               )
             ) ==
               reply
    end
  end

  describe "the create and the hangup" do
    test "the create body for the exemplar request is the exemplar body" do
      assert OpenAILive.create_body(request(@wire["create"]["request"])) ==
               @wire["create"]["body"]
    end

    test "every create answer is classified as named" do
      for {name, %{"status" => status, "body" => body, "classified" => class}} <-
            @wire["create"]["answers"] do
        result = OpenAILive.classify_create({:ok, response(status, body)}, [])
        assert class(result) == class, name
      end
    end

    test "every hangup answer is classified as named" do
      for {name, %{"status" => status, "body" => body, "classified" => class}} <- @wire["hangup"] do
        result = OpenAILive.classify_hangup({:ok, response(status, body)}, [])
        assert hangup_class(result) == class, name
      end
    end
  end

  defp request(raw) do
    trunk = raw["trunk"]

    %{
      api_key: raw["api_key"],
      model: raw["model"],
      instructions: raw["instructions"],
      input: raw["input"],
      voice: raw["voice"],
      destination: raw["destination"],
      trunk: %{
        provider_url: trunk["provider_url"],
        username: trunk["username"],
        password: trunk["password"],
        caller_number: trunk["caller_number"]
      }
    }
  end

  defp response(status, body) when is_binary(body),
    do: Req.Response.new(status: status, body: body)

  defp response(status, body), do: Req.Response.new(status: status, body: Jason.encode!(body))

  defp class({:ok, %{session_id: id}}) when is_binary(id), do: "ok"
  defp class({:error, {:rejected, _status, _vendor}}), do: "rejected"
  defp class({:error, {:unknown, _reason}}), do: "unknown"

  defp hangup_class({:ok, :accepted}), do: "accepted"
  defp hangup_class({:ok, {:already_ended, _status, _vendor}}), do: "already_ended"
  defp hangup_class({:error, {kind, _reason}}), do: Atom.to_string(kind)

  defp json(map), do: map |> Jason.encode!() |> Jason.decode!()

  defp pusher!(frames) do
    server =
      start_supervised!(
        {Bandit,
         plug: {Pusher, %{frames: frames}}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "ws://127.0.0.1:#{port}"
  end
end
