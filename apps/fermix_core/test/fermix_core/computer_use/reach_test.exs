defmodule FermixCore.ComputerUse.ReachTest do
  # M97 §6.4, §6.5: a server with no screen of its own reaches a computer's,
  # and the `computer_use` tool's offer, schema and words follow the helper of
  # the machine a call runs on.
  use ExUnit.Case, async: false

  alias Compux.Protocol
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Prompt
  alias FermixCore.ComputerUse.HelperActions
  alias FermixCore.ComputerUse.Reach
  alias FermixCore.Tools.ComputerUse

  # What a Linux helper whose pixel route was refused lists.
  @controls_only Protocol.actions() --
                   ~w(screenshot left_click right_click double_click mouse_move left_click_drag
                      scroll key wait_for_change paste windows inspect select_target release_target)

  setup do
    previous = Application.get_env(:fermix_core, :computer_use)
    # This host has no screen to drive: computer use is off here.
    Application.put_env(:fermix_core, :computer_use, enabled: false)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_core, :computer_use)
        value -> Application.put_env(:fermix_core, :computer_use, value)
      end
    end)
  end

  describe "the tool is offered on a screenless server" do
    test "while a computer the owner's turn can see offers its screen" do
      assert ComputerUse.advertise?(turn([computer("studio Mac", screen(:on))]))
      assert Reach.reachable?(turn([computer("studio Mac", screen(:on))]))
    end

    test "and not otherwise" do
      refute ComputerUse.advertise?(turn([]))
      refute ComputerUse.advertise?(turn([computer("studio Mac", screen(:off))]))
      refute ComputerUse.advertise?(turn([computer("studio Mac", [])]))

      # A computer the turn cannot see: a guest's turn, or a build without Always On.
      refute ComputerUse.advertise?(%{
               turn([computer("studio Mac", screen(:on))])
               | source_trust: :guest
             })

      refute ComputerUse.advertise?(
               Map.put(turn([computer("studio Mac", screen(:on))]), :always_on, false)
             )
    end
  end

  describe "the schema follows the helper of the machine the call runs on" do
    test "a computer whose helper works by controls alone is offered its controls, not pixels" do
      linux = computer("loft Linux", screen(:on, @controls_only, "standard"))
      schema = ComputerUse.dynamic_parameters(turn([linux]))
      enum = schema["properties"]["action"]["enum"]

      assert enum == HelperActions.encodable(@controls_only)
      refute "screenshot" in enum
      refute Map.has_key?(schema["properties"], "x")
      assert ComputerUse.dynamic_description(turn([linux])) =~ "CONTROLS ONLY"
    end

    test "a computer whose helper offers pixels is offered pixels" do
      mac = computer("studio Mac", screen(:on, HelperActions.pixel(), "standard"))
      enum = ComputerUse.dynamic_parameters(turn([mac]))["properties"]["action"]["enum"]

      assert "screenshot" in enum
      assert "left_click" in enum
      refute "press" in enum
    end

    test "its access level is that computer's sandbox mode" do
      strict = computer("studio Mac", screen(:on, HelperActions.pixel(), "strict"))
      open = computer("studio Mac", screen(:on, HelperActions.pixel(), "open"))

      assert action_description(turn([strict])) =~ "ACCESS=strict"
      assert action_description(turn([open])) =~ "ACCESS=open"
    end

    test "with several computers offering it, every action any offers and the strictest access" do
      mac = computer("studio Mac", screen(:on, HelperActions.pixel(), "open"))
      linux = computer("loft Linux", screen(:on, @controls_only, "strict"))
      reading = Reach.reading(turn([mac, linux]))

      assert reading.actions ==
               HelperActions.encodable(HelperActions.pixel() ++ @controls_only)

      assert reading.access == :strict
    end

    test "a computer that did not say what its helper offers is read as the pixel set" do
      offer = %{id: "computer_use", state: :on, sentence: nil, detail: "standard"}
      reading = Reach.of(%Computer{device_id: "d-1", name: "studio Mac", offers: [offer]})

      assert reading.actions == HelperActions.pixel()
      assert reading.input_methods == []
    end
  end

  test "a session on a computer's screen runs with courtesy off here and that computer's access" do
    config = Reach.config(computer("studio Mac", screen(:on, HelperActions.pixel(), "strict")))

    assert config.courtesy == :off
    assert config.access == :strict
    assert config.enabled?
    refute config.background?
  end

  test "the Computers section says a strict screen is look only" do
    section =
      Prompt.render(%{}, [
        computer("studio Mac", screen(:on, HelperActions.pixel(), "strict"))
      ])

    assert section =~ "screen (look only)"
  end

  defp action_description(context),
    do: ComputerUse.dynamic_parameters(context)["properties"]["action"]["description"]

  defp turn(computers) do
    %{
      source_trust: :operator,
      always_on: true,
      computers_opts: [role: :primary],
      computers: computers
    }
  end

  defp computer(name, offers) do
    %Computer{
      device_id: "device-" <> String.replace(name, " ", "-"),
      name: name,
      platform: :macos,
      connected: true,
      offers: offers
    }
  end

  defp screen(:off),
    do: [
      %{
        id: "computer_use",
        state: :off,
        sentence: "Switched off on this Mac. Only someone at this Mac can switch it on.",
        detail: nil
      }
    ]

  defp screen(:on), do: screen(:on, HelperActions.pixel(), "standard")

  defp screen(:on, actions, mode),
    do: [
      %{
        id: "computer_use",
        state: :on,
        sentence: nil,
        detail: mode,
        helper: %{actions: actions, input_methods: ["ax"]}
      }
    ]
end
