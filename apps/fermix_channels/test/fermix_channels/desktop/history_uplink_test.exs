defmodule FermixChannels.Desktop.HistoryUplinkTest do
  # M97 §6.1, §8.1: a computer's `history.submit` is one the codec takes, in the
  # bulk lane, every time: its id is minted in the wire's own alphabet.
  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.HistoryUplink
  alias FermixChannels.Mobile.Lanes
  alias FermixChannels.Mobile.Protocol
  alias FermixCore.Computers.Switches

  defp decode(open) do
    header =
      open
      |> Map.merge(%{
        "v" => Protocol.protocol_version(),
        "seq" => 1,
        "index" => 0,
        "last" => true
      })
      |> Jason.encode!()

    Protocol.decode_client_frame(<<byte_size(header)::32, header::binary, "{}">>)
  end

  test "every sitting's request is one the codec takes, in the bulk lane" do
    for _request <- 1..500 do
      open = HistoryUplink.request(7)
      assert {:ok, %{type: "invoke_open"}} = decode(open), inspect(open)
      assert {:ok, :bulk} = Lanes.lane("invoke_open", open)
    end
  end

  test "a request names its capability, op and origin, and never a turn" do
    assert %{"capability" => "history", "op" => "submit", "origin" => "computer", "epoch" => 7} =
             open = HistoryUplink.request(7)

    refute Map.has_key?(open, "turn")
    refute HistoryUplink.request(7)["id"] == open["id"]
  end

  test "an answer no request waits on is not known" do
    assert :unknown = HistoryUplink.answer("hist-0", %{}, "{}", :history_uplink_test_waiter)
  end

  # M97 D27: a sitting or a report goes only while this computer offers its
  # history: its recorder on (its own setting), its master on and its
  # switches reviewed. Off, nothing reaches the relay.
  test "nothing is sent while the recorder, the master or the review says no" do
    relay = :history_uplink_test_no_relay

    for {switches, recording?} <- [
          {Switches.only([]), false},
          {Switches.only([], enabled: false), true},
          {Switches.only([], reviewed: false), true}
        ] do
      opts = [switches: switches, recording?: recording?, relay: relay]
      assert {:error, :switched_off} = HistoryUplink.submit(%{}, opts)
      assert {:error, :switched_off} = HistoryUplink.report(%{}, opts)
    end

    # Offered, it goes to the relay, which is not there here.
    assert {:error, :unreachable} =
             HistoryUplink.submit(%{},
               switches: Switches.only([]),
               recording?: true,
               relay: relay,
               waiter: :history_uplink_test_sender
             )
  end
end
