defmodule FermixChannels.Mobile.LanesTest do
  @moduledoc """
  The lane table (M97 §5.1): every event the wire carries rides a lane, so a
  new event cannot ship without one, and a lane is a function of an event's
  type and header.
  """

  use ExUnit.Case, async: true

  require FermixChannels.Mobile.Lanes

  alias FermixChannels.Mobile.Lanes
  alias FermixChannels.Mobile.PeerEvents
  alias FermixChannels.Mobile.Peers
  alias FermixChannels.Mobile.Protocol

  # A run of `event_part` carries one event whole, in that event's lane.
  @not_events ["event_part"]
  # An event whose lane its header decides, with the fields the wire
  # requires of it: every other event rides its lane with any header.
  @headers %{"invoke_part" => %{"size_bytes" => 1}}

  test "every event the codec knows, either way, rides a lane" do
    known = Enum.uniq(Protocol.client_events() ++ Protocol.server_events()) -- @not_events

    missing =
      for type <- known, Lanes.lane(type, header(type)) == {:error, {:no_lane, type}}, do: type

    assert missing == [], "events with no lane: #{inspect(missing)}"
  end

  test "every event any session kind may send or be sent rides a lane" do
    for kind <- Peers.kinds(),
        type <- Peers.client_events(kind) ++ Peers.server_events(kind),
        type not in @not_events do
      assert {:ok, _lane} = Lanes.lane(type, header(type)), "#{kind} #{type} has no lane"
    end
  end

  test "the table names only events the codec knows" do
    known = MapSet.new(Protocol.client_events() ++ Protocol.server_events())
    named = Lanes.types()

    assert named -- Enum.uniq(named) == []
    assert Enum.reject(named, &MapSet.member?(known, &1)) == []
  end

  # The wire and the table agree here: a header field that decides a lane is
  # one the codec requires of that event either way, so no frame the codec
  # takes is without a lane.
  test "every header field that decides a lane is one the wire requires, either way" do
    for {type, fields} <- Lanes.header_fields(), direction <- [:client, :server] do
      assert PeerEvents.event?(direction, type), "#{type} is no #{direction} event"

      assert fields -- PeerEvents.required(direction, type) == [],
             "#{direction} #{type} does not require #{inspect(fields)}"
    end

    assert :ok =
             PeerEvents.validate(:client, "invoke_part", %{
               "id" => "inv-a",
               "index" => 0,
               "last" => true,
               "size_bytes" => 9
             })

    assert {:error, _missing} =
             PeerEvents.validate(:client, "invoke_part", %{
               "id" => "inv-a",
               "index" => 0,
               "last" => true
             })
  end

  defp header(type), do: Map.get(@headers, type, %{})

  test "a call's frames are live, a stream's frames bulk, the rest interactive" do
    for type <- ~w(call_open call_attached call_line call_audio call_frame call_close),
        do: assert(Lanes.lane(type, %{}) == {:ok, :live})

    for type <- ~w(invoke_cancel invoke_result invoke_status manage manage_result
                   companion_line loopback_request hello ping pong error ack
                   offers link_path),
        do: assert(Lanes.lane(type, %{}) == {:ok, :interactive})

    for type <- ~w(snapshot_begin snapshot_chunk snapshot_end snapshot_stored media_fetch
                   media_begin media_chunk media_end attach_chunk move_chunk),
        do: assert(Lanes.lane(type, %{}) == {:ok, :bulk})
  end

  test "an invocation's part is interactive up to 256 KiB announced, bulk above; none, no lane" do
    assert Lanes.lane("invoke_part", %{"size_bytes" => 0}) == {:ok, :interactive}
    assert Lanes.lane("invoke_part", %{"size_bytes" => 262_144}) == {:ok, :interactive}
    assert Lanes.lane("invoke_part", %{"size_bytes" => 262_145}) == {:ok, :bulk}

    assert Lanes.lane("invoke_part", %{"t" => "invoke_part", "size_bytes" => 9}) ==
             {:ok, :interactive}

    assert Lanes.lane("invoke_part", %{}) == {:error, {:no_lane, "invoke_part"}}

    assert Lanes.lane("invoke_part", %{"size_bytes" => "big"}) ==
             {:error, {:no_lane, "invoke_part"}}
  end

  test "an invocation that submits a history sitting is bulk; every other open interactive" do
    assert Lanes.lane("invoke_open", %{"capability" => "history", "op" => "submit"}) ==
             {:ok, :bulk}

    for header <- [
          %{"capability" => "history", "op" => "status"},
          %{"capability" => "files", "op" => "submit"},
          %{"capability" => "shell", "op" => "run"},
          %{}
        ],
        do: assert(Lanes.lane("invoke_open", header) == {:ok, :interactive})
  end

  test "the header fields the table reads are named in one place" do
    assert Lanes.header_fields() == %{
             "invoke_part" => ["size_bytes"],
             "invoke_open" => ["capability", "op"]
           }
  end

  test "each guard is the table: an event rides exactly the lane its guards say" do
    headers = [
      %{},
      %{"size_bytes" => 10},
      %{"size_bytes" => 300_000},
      %{"capability" => "history", "op" => "submit"}
    ]

    for type <- Lanes.types() ++ ["not_an_event"], header <- headers do
      guards = [
        live: Lanes.live?(type, header),
        interactive: Lanes.interactive?(type, header),
        bulk: Lanes.bulk?(type, header)
      ]

      case for({lane, true} <- guards, do: lane) do
        [] -> assert Lanes.lane(type, header) == {:error, {:no_lane, type}}
        [lane] -> assert Lanes.lane(type, header) == {:ok, lane}
      end
    end
  end

  test "lanes come in the order they are written; an unknown event has none" do
    assert Lanes.lanes() == [:live, :interactive, :bulk]
    assert Lanes.lane("event_part", %{}) == {:error, {:no_lane, "event_part"}}
    assert Lanes.lane("not_an_event", %{}) == {:error, {:no_lane, "not_an_event"}}
  end
end
