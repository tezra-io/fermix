defmodule FermixCore.Realtime.EndpointTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.DeviceIdentity
  alias FermixCore.Realtime.Endpoint

  @owner "owner-1"
  @mac "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b"
  @phone "0d7f6a52-91c3-4b8e-a1f0-5e2d9c4b7a13"

  describe "the endpoint's string form" do
    test "desktop, an accessory and a phone round-trip" do
      assert Endpoint.parse("desktop") == {:ok, :desktop}
      assert Endpoint.format(:desktop) == "desktop"

      assert Endpoint.parse("accessory:desk-robot_2") == {:ok, {:accessory, "desk-robot_2"}}
      assert Endpoint.format({:accessory, "desk-robot_2"}) == "accessory:desk-robot_2"

      assert Endpoint.parse("phone:" <> @phone) == {:ok, {:phone, @phone}}
      assert Endpoint.format({:phone, @phone}) == "phone:" <> @phone
    end

    # A paired phone's device id is the trust store's lowercase UUID, which the
    # id rule takes as it is.
    test "a paired phone's device id fits the id rule" do
      assert {:ok, {:phone, @phone}} = Endpoint.parse(Endpoint.format({:phone, @phone}))
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
            "phone",
            "phone:",
            "phone:a b",
            "phone:a:b",
            "phone:" <> String.duplicate("a", 65)
          ] do
        assert Endpoint.parse(given) == {:error, {:invalid_endpoint, given}}
      end
    end

    test "a malformed endpoint term fails loud" do
      assert_raise ArgumentError, ~r/invalid voice endpoint/, fn ->
        Endpoint.format({:accessory, "desk robot"})
      end

      assert_raise ArgumentError, ~r/invalid voice endpoint/, fn ->
        Endpoint.format({:phone, "a:b"})
      end

      assert_raise FunctionClauseError, fn -> apply(Endpoint, :format, [:phone]) end
      assert_raise FunctionClauseError, fn -> apply(Endpoint, :parse, [:desktop]) end
    end
  end

  describe "policy" do
    test "screen sharing is offered to the desktop alone" do
      assert Endpoint.screen_share?(:desktop)
      refute Endpoint.screen_share?({:accessory, "desk-robot"})
      refute Endpoint.screen_share?({:phone, @phone})
    end

    # M87 Phase 2: the camera is the phone's, whose frames ride its own
    # session; the Mac's socket and an accessory carry none.
    test "the camera is a phone's alone" do
      assert Endpoint.camera?({:phone, @phone})
      refute Endpoint.camera?(:desktop)
      refute Endpoint.camera?({:accessory, "desk-robot"})
    end

    # The Realtime engine runs no chat and leaves no gist, and its screen_share
    # tool would watch a Mac nobody at the phone can see (M87 D2).
    test "a phone takes a call only on a task engine" do
      assert Endpoint.admit_engine({:phone, @phone}, "openai_realtime") ==
               {:error, :engine_not_for_phones}

      assert Endpoint.admit_engine({:phone, @phone}, "openai_live") == :ok
      assert Endpoint.admit_engine({:phone, @phone}, "xai_realtime") == :ok

      for endpoint <- [:desktop, {:accessory, "desk-robot"}],
          engine <- ["openai_realtime", "openai_live", "xai_realtime"] do
        assert Endpoint.admit_engine(endpoint, engine) == :ok
      end
    end

    # A phone's call holds 1 s of audio unplayed on the phone; a Grok window
    # of seconds would pile a fast reply up behind it until it aged out.
    test "a phone's Grok audio is paced in a short window; the others keep the default" do
      assert Endpoint.grok_playback_opts({:phone, @phone}) == [window_ms: 300]
      assert Endpoint.grok_playback_opts(:desktop) == []
      assert Endpoint.grok_playback_opts({:accessory, "desk-robot"}) == []
      assert_raise ArgumentError, fn -> Endpoint.grok_playback_opts({:phone, "a:b"}) end
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

      phone = Endpoint.safety_identifier({:phone, @phone}, @owner, @mac)
      assert phone == DeviceIdentity.safety_identifier(@owner, "phone:" <> @phone)
      refute phone == desktop
      assert Endpoint.safety_identifier({:phone, @phone}, @owner, "another-mac") == phone
    end
  end
end
