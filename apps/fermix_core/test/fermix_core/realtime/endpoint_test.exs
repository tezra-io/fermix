defmodule FermixCore.Realtime.EndpointTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.DeviceIdentity
  alias FermixCore.Realtime.Endpoint

  @owner "owner-1"
  @mac "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b"

  describe "the endpoint's string form" do
    test "desktop and an accessory round-trip" do
      assert Endpoint.parse("desktop") == {:ok, :desktop}
      assert Endpoint.format(:desktop) == "desktop"

      assert Endpoint.parse("accessory:desk-robot_2") == {:ok, {:accessory, "desk-robot_2"}}
      assert Endpoint.format({:accessory, "desk-robot_2"}) == "accessory:desk-robot_2"
    end

    test "anything else is refused, naming what was given" do
      for given <- [
            "",
            "Desktop",
            "desktop:",
            "accessory",
            "accessory:",
            "accessory:desk robot",
            "accessory:a:b",
            "accessory:" <> String.duplicate("a", 65),
            "stackchan:robot-1",
            "phone:3f2b8c1e"
          ] do
        assert Endpoint.parse(given) == {:error, {:invalid_endpoint, given}}
      end
    end

    test "a malformed endpoint term fails loud" do
      assert_raise ArgumentError, ~r/invalid voice endpoint/, fn ->
        Endpoint.format({:accessory, "desk robot"})
      end

      assert_raise FunctionClauseError, fn -> apply(Endpoint, :format, [:phone]) end
      assert_raise FunctionClauseError, fn -> apply(Endpoint, :parse, [:desktop]) end
    end
  end

  describe "policy" do
    test "screen sharing is offered to the desktop alone" do
      assert Endpoint.screen_share?(:desktop)
      refute Endpoint.screen_share?({:accessory, "desk-robot"})
    end

    # The desktop keeps the identifier every call has carried, so OpenAI sees one
    # continuous sender; an accessory gets its own, whatever Mac it is plugged into.
    test "the safety identifier comes from the endpoint" do
      desktop = Endpoint.safety_identifier(:desktop, @owner, @mac)
      robot = Endpoint.safety_identifier({:accessory, "desk-robot"}, @owner, @mac)

      assert desktop == DeviceIdentity.safety_identifier(@owner, @mac)
      assert robot == DeviceIdentity.safety_identifier(@owner, "accessory:desk-robot")
      refute robot == desktop

      assert Endpoint.safety_identifier({:accessory, "desk-robot"}, @owner, "another-mac") ==
               robot
    end
  end
end
