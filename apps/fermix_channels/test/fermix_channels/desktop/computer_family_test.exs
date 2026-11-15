defmodule FermixChannels.Desktop.ComputerFamilyTest do
  # M97 §3.2, §5.3: a computer's own record, from its offers reporter through
  # its relay and a real primary session to the home's live view, and never
  # to a server whose hello_ack does not take it.
  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.ComputerFamily
  alias FermixChannels.Desktop.Offers
  alias FermixChannels.Desktop.Relay
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Test.DesktopRail
  alias FermixCore.Computers.Facts
  alias FermixCore.Computers.Registry
  alias FermixCore.Computers.Switches
  alias FermixTestSupport.SafeRm

  @mac [
    os: :macos,
    arch: "arm64",
    landlock: :not_asked,
    helpers: %{computer_use: true},
    sandbox_mode: :standard,
    recording: false
  ]

  setup do
    home = SafeRm.make_tmp_dir!("computer_family")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    registry = :"computer_family_registry_#{System.unique_integer([:positive])}"
    test = self()

    start_supervised!(
      {Registry,
       name: registry,
       home: home,
       status_changed: fn -> send(test, :computers_changed) && :ok end,
       announce: fn name -> send(test, {:announce, name}) && :ok end}
    )

    assert_receive {:announce, ^registry}
    %{registry: registry, home: home}
  end

  # The desktop: its offers reporter, then its relay, each naming the other.
  defp desktop!(primary, switches) do
    suffix = System.unique_integer([:positive])
    relay = :"computer_family_relay_#{suffix}"
    offers = :"computer_family_offers_#{suffix}"
    root = DesktopRail.desktop_home!(primary)
    agent = start_supervised!({Agent, fn -> switches end}, id: {:switches, suffix})

    start_supervised!(
      {Offers,
       name: offers,
       home: root,
       relay: relay,
       facts: fn -> Facts.read(@mac) end,
       switches: fn -> Agent.get(agent, & &1) end,
       timer: fn _message, _delay -> make_ref() end},
      id: offers
    )

    DesktopRail.start_relay!(root, primary, name: relay, offers: offers)
    DesktopRail.await_connected(relay)
    %{relay: relay, offers: offers, switches: agent}
  end

  defp on_ids(offers), do: for(%{state: :on, id: id} <- offers, do: id)

  defp await_offers(registry, wanted) do
    assert_receive :computers_changed, 10_000

    case Registry.live(registry)[DesktopRail.device_id()] do
      %{offers: offers} when offers != [] ->
        if on_ids(offers) == wanted, do: offers, else: await_offers(registry, wanted)

      _waiting ->
        await_offers(registry, wanted)
    end
  end

  test "a computer's offers reach the home's live view, and again when they change", ctx do
    primary =
      DesktopRail.primary!(families: %{computer: {ComputerFamily, registry: ctx.registry}})

    desktop = desktop!(primary, Switches.only([:files_and_shell]))

    offers = await_offers(ctx.registry, ["files", "shell"])
    assert Enum.find(offers, &(&1.id == "shell")).detail == "standard"
    assert %{since: %DateTime{}} = Registry.live(ctx.registry)[DesktopRail.device_id()]

    Agent.update(desktop.switches, fn _ -> Switches.only([:browser]) end)
    :ok = Offers.changed(desktop.offers)
    assert await_offers(ctx.registry, ["browser"])
  end

  test "a server whose hello_ack does not take them is sent none", ctx do
    {min_version, max_version} = Protocol.supported_version_range()

    older = %{
      "session_id" => "older-server",
      "min_version" => min_version,
      "max_version" => max_version,
      "profiles" => [%{"id" => "main", "name" => "Fermix"}],
      "candidates" => [],
      "history_head_seq" => 0,
      "read_up_to_seq" => 0,
      "caps" => %{"commands" => [], "max_media_bytes" => 20_971_520},
      "primary_epoch" => 3
    }

    primary =
      DesktopRail.primary!(
        hello_ack_builder: fn _state -> {:ok, older} end,
        families: %{computer: {ComputerFamily, registry: ctx.registry}}
      )

    desktop = desktop!(primary, Switches.only([:files_and_shell]))

    # The relay refuses a computer's own event the session does not take, so
    # nothing reaches a server that would close the session on it.
    assert {:error, {:not_taken, "offers"}} =
             Relay.send_event(
               desktop.relay,
               %{"t" => "offers", "rev" => "0123456789abcdef"},
               "{}"
             )

    assert {:error, {:not_taken, "link_path"}} =
             Relay.send_event(desktop.relay, %{"t" => "link_path", "path" => "direct"})

    # Nor the invocation's events (M97 §6.1), under the cap that names them.
    result = %{"t" => "invoke_result", "id" => "inv-1", "status" => "unknown", "duration_ms" => 0}
    assert {:error, {:not_taken, "invoke_result"}} = Relay.send_event(desktop.relay, result, "{}")

    assert %{connected: true} = Relay.status(desktop.relay)
    assert Registry.live(ctx.registry)[DesktopRail.device_id()].offers == []
  end

  describe "the family alone" do
    setup ctx do
      session = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(session, :stop) end)
      peers = :"computer_family_peers_#{System.unique_integer([:positive])}"
      start_supervised!({Elixir.Registry, keys: :unique, name: peers})

      {:ok, state} =
        ComputerFamily.init(%{
          device_id: DesktopRail.device_id(),
          session: session,
          peer: self(),
          registry: peers,
          standing: :behind,
          options: [registry: ctx.registry]
        })

      assert_receive :computers_changed
      Map.put(ctx, :state, state)
    end

    test "a payload that is not one fails closed, and the session goes on", ctx do
      good = ~s({"v":1,"offers":[{"id":"files","state":"on"}]})
      rev = FermixCore.Computers.Offers.rev(good)

      assert {:ok, state} =
               ComputerFamily.handle_event("offers", %{"rev" => rev}, good, ctx.state)

      await_offers(ctx.registry, ["files"])

      bad = ~s({"v":1,"offers":[{"id":"files","state":"maybe"}]})

      # The family keeps what it told the view: nothing offered.
      assert {:error, {:invalid_offers, sentence}, %{offers: {[], nil}} = state} =
               ComputerFamily.handle_event(
                 "offers",
                 %{"rev" => FermixCore.Computers.Offers.rev(bad)},
                 bad,
                 state
               )

      assert sentence =~ "not on, off or unavailable"

      assert {:error, {:invalid_offers, _said}, ^state} =
               ComputerFamily.handle_event("offers", %{"rev" => "0123456789abcdef"}, good, state)

      assert_receive :computers_changed
      assert Registry.live(ctx.registry)[DesktopRail.device_id()].offers == []
    end

    test "the path the computer reports is kept", ctx do
      assert {:ok, _state} =
               ComputerFamily.handle_event("link_path", %{"path" => "relay"}, <<>>, ctx.state)

      assert_receive :computers_changed
      assert Registry.live(ctx.registry)[DesktopRail.device_id()].path == :relay
    end

    # A live view that restarted holds nothing; asked, the family says again
    # what its session said: up since when, where it stands, its offers and
    # its path. A view it does not report to is not its own.
    test "the family says its facts again when its live view asks", ctx do
      good = ~s({"v":1,"offers":[{"id":"files","state":"on"}]})
      rev = FermixCore.Computers.Offers.rev(good)
      {:ok, state} = ComputerFamily.handle_event("offers", %{"rev" => rev}, good, ctx.state)
      {:ok, state} = ComputerFamily.handle_event("link_path", %{"path" => "relay"}, <<>>, state)
      said = await_offers(ctx.registry, ["files"])

      old = Process.whereis(ctx.registry)
      ref = Process.monitor(old)
      Process.exit(old, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old, :killed}
      registry = ctx.registry
      assert_receive {:announce, ^registry}, 10_000
      assert Registry.live(ctx.registry) == %{}

      assert {:ok, ^state} = ComputerFamily.handle_info({:announce, :another_view}, state)
      assert {:ok, ^state} = ComputerFamily.handle_info({:announce, ctx.registry}, state)

      assert %{standing: :behind, offers: ^said} =
               await_live(ctx.registry, &match?(%{path: :relay}, &1))
    end
  end

  # End to end: the live view that restarts under an open session asks the
  # sessions' families, through each peer, to say their facts again
  # (`Home.Link`'s `announce_computers/1`), so it is rebuilt.
  test "a live view that restarts is rebuilt from the open sessions", ctx do
    view = :"computer_family_view_#{System.unique_integer([:positive])}"
    test = self()

    primary = DesktopRail.primary!(families: %{computer: {ComputerFamily, registry: view}})

    start_supervised!(
      {Registry,
       name: view,
       home: ctx.home,
       status_changed: fn -> send(test, :computers_changed) && :ok end,
       announce: &ComputerFamily.announce(&1, primary.peers)},
      id: :view
    )

    _desktop = desktop!(primary, Switches.only([:files_and_shell]))
    said = await_offers(view, ["files", "shell"])

    old = Process.whereis(view)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}

    assert await_offers(view, ["files", "shell"]) == said
    refute Process.whereis(view) == old
  end

  # The computer's live facts once `ready?` holds, read at each change.
  defp await_live(registry, ready?) do
    assert_receive :computers_changed, 10_000
    live = Registry.live(registry)[DesktopRail.device_id()]
    if live && ready?.(live), do: live, else: await_live(registry, ready?)
  end
end
