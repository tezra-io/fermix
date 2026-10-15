defmodule FermixChannels.Mobile.Iroh.RelaysTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Iroh.Relays
  alias FermixChannels.Mobile.Iroh.Relays.Source

  @us1 %{url: "https://us1.relay.fermix.ai/", quic_port: 7842}
  @eu1 %{url: "https://eu1.relay.fermix.ai/", quic_port: 7842}
  @ap1 %{url: "https://ap1.relay.fermix.ai/", quic_port: 7842}

  defp source(lists) do
    Source.parse!(%{
      "revisions" =>
        Enum.map(lists, fn relays -> %{"iroh" => "1.3.0", "relays" => Relays.to_wire(relays)} end)
    })
  end

  test "the shipped source launches with Fermix's two relays, at the iroh version they run" do
    assert Relays.launch_set() == [@us1, @eu1]
    assert %{iroh: "1.3.0", relays: [@us1, @eu1], id: id} = Relays.current()
    assert id =~ ~r/\A[0-9a-f]{16}\z/
  end

  test "a revision's id is the first 16 hex digits of the SHA-256 of its canonical relays" do
    assert Source.canonical_json([@us1, @eu1]) ==
             ~s([{"quic_port":7842,"url":"https://us1.relay.fermix.ai/"},) <>
               ~s({"quic_port":7842,"url":"https://eu1.relay.fermix.ai/"}])

    digest = :crypto.hash(:sha256, Source.canonical_json([@us1, @eu1]))
    assert Relays.current().id == digest |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  test "the source refuses a duplicate revision, a dropped launch relay and a bad relay" do
    assert_raise ArgumentError, ~r/same relays/, fn -> source([[@us1, @eu1], [@us1, @eu1]]) end
    assert_raise ArgumentError, ~r/drops a relay/, fn -> source([[@us1, @eu1], [@us1, @ap1]]) end
    assert_raise ArgumentError, ~r/no revisions/, fn -> Source.parse!(%{"revisions" => []}) end

    # The pairing link carries a relay as `host:quic_port` (M62 §4.2), so a
    # relay is `https`, on 443, at `/`, with a lowercase name: nothing the
    # compact form would lose.
    for url <- [
          "http://us1.relay.fermix.ai/",
          "https://us1.relay.fermix.ai",
          "https://u:p@x/",
          "https://us1.relay.fermix.ai:8443/",
          "https://US1.relay.fermix.ai/"
        ] do
      assert_raise ArgumentError, ~r/https:\/\/host\//, fn ->
        source([[%{url: url, quic_port: 7842}]])
      end
    end

    # One relay twice, on another port too, is the helper's `bad_request`.
    twice = [@us1, %{@us1 | quic_port: 7843}]
    assert_raise ArgumentError, ~r/names a relay twice/, fn -> source([twice]) end

    too_many = for n <- 1..9, do: %{url: "https://r#{n}.relay.fermix.ai/", quic_port: 7842}
    assert_raise ArgumentError, ~r/invalid revision/, fn -> source([too_many]) end
  end

  describe "acknowledged/2" do
    setup do
      revisions = source([[@us1, @eu1], [@us1, @eu1, @ap1]])
      [launch, added] = Enum.map(revisions, & &1.id)
      %{revisions: revisions, launch: launch, added: added}
    end

    test "with no paired phone, the endpoint uses the launch set", ctx do
      assert Relays.acknowledged([], ctx.revisions) == [@us1, @eu1]
    end

    test "a new relay is used only once every phone has acknowledged it", ctx do
      assert Relays.acknowledged([ctx.added, ctx.added], ctx.revisions) == [@us1, @eu1, @ap1]
      assert Relays.acknowledged([ctx.added, ctx.launch], ctx.revisions) == [@us1, @eu1]
    end

    test "a phone with no acknowledgment, or one this build does not know, counts as the launch set",
         ctx do
      assert Relays.acknowledged([ctx.added, nil], ctx.revisions) == [@us1, @eu1]
      assert Relays.acknowledged([ctx.added, "ffffffffffffffff"], ctx.revisions) == [@us1, @eu1]
    end
  end
end
