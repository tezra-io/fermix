defmodule FermixChannels.Desktop.OffersTest do
  # M97 §3.2, §5.3: what this computer offers its server, sent once a session
  # takes it, and again only when it changed.
  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.Offers
  alias FermixCore.Computers.Facts
  alias FermixCore.Computers.Switches
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Management.Copy
  alias FermixTestSupport.SafeRm

  @takes %{"computer" => %{"v" => 1, "offers" => true, "link_path" => true}}
  @mac [
    os: :macos,
    arch: "arm64",
    landlock: :not_asked,
    helpers: %{computer_use: true},
    sandbox_mode: :standard
  ]

  # A relay that answers every send, telling the test what it was asked.
  defmodule FakeRelay do
    @moduledoc false
    use GenServer

    def start_link(test), do: GenServer.start_link(__MODULE__, test)

    @impl true
    def init(test), do: {:ok, test}

    @impl true
    def handle_call({:send, type, fields, payload}, _from, test) do
      send(test, {:sent, type, fields, payload})
      {:reply, :ok, test}
    end
  end

  setup do
    home = SafeRm.make_tmp_dir!("desktop_offers")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    relay = start_supervised!({FakeRelay, self()})
    switches = start_supervised!({Agent, fn -> Switches.only([:files, :shell]) end})
    name = :"desktop_offers_#{System.unique_integer([:positive])}"
    test = self()

    start_supervised!(
      {Offers,
       name: name,
       home: home,
       relay: relay,
       facts: fn -> Facts.read(@mac) end,
       switches: fn -> Agent.get(switches, & &1) end,
       timer: fn message, delay -> send(test, {:timer, message, delay}) && make_ref() end}
    )

    assert_receive {:timer, :offers_tick, 60_000}
    %{name: name, switches: switches, home: home}
  end

  defp offered(payload) do
    {:ok, offers} = FermixCore.Computers.Offers.decode(payload)
    for %{state: :on, id: id} <- offers, do: id
  end

  test "nothing goes until a session takes it, then once per revision", ctx do
    :ok = Offers.changed(ctx.name)
    _ = Offers.current(ctx.name)
    refute_received {:sent, "offers", _fields, _payload}

    :ok = Offers.connected(ctx.name, @takes)
    assert_receive {:sent, "offers", %{"rev" => rev}, payload}
    assert rev == FermixCore.Computers.Offers.rev(payload)
    assert offered(payload) == ["files", "shell"]

    # The same offers are not sent twice.
    send(ctx.name, :offers_tick)
    :ok = Offers.changed(ctx.name)
    _ = Offers.current(ctx.name)
    refute_received {:sent, "offers", _fields, _payload}

    # A switch moved: they go again.
    Agent.update(ctx.switches, fn _ -> Switches.only([:files]) end)
    :ok = Offers.changed(ctx.name)
    assert_receive {:sent, "offers", %{"rev" => moved}, payload}
    assert moved != rev
    assert offered(payload) == ["files"]
  end

  test "a new session hears the offers again, the same ones included", ctx do
    :ok = Offers.connected(ctx.name, @takes)
    assert_receive {:sent, "offers", %{"rev" => rev}, _payload}

    :ok = Offers.connected(ctx.name, @takes)
    assert_receive {:sent, "offers", %{"rev" => ^rev}, _payload}
  end

  test "a server older than the computer record hears nothing", ctx do
    :ok = Offers.connected(ctx.name, %{"max_media_bytes" => 1})
    :ok = Offers.changed(ctx.name)
    _ = Offers.current(ctx.name)
    refute_received {:sent, _type, _fields, _payload}

    :ok = Offers.connected(ctx.name, %{"computer" => %{"v" => 1, "offers" => false}})
    _ = Offers.current(ctx.name)
    refute_received {:sent, _type, _fields, _payload}
  end

  test "every switch has its module, in the switches' order" do
    assert Enum.map(Offers.modules(), & &1.id()) == Switches.offers()

    offers =
      FermixCore.Computers.Offers.compute(
        Offers.modules(),
        Switches.only(Switches.offers()),
        Facts.read(@mac)
      )

    # The device ends of later stages are unavailable, whatever the switch.
    for %{id: id, state: state, sentence: sentence} <- offers,
        id in ~w(voice attachments accessory notifications) do
      assert state == :unavailable
      assert sentence =~ "later update of Fermix"
    end
  end

  # The copy gate (`Management.Copy`) for the offers whose device end lives
  # beside the link: an app and the prompt show their words as they are.
  test "every offer this computer says obeys the copy rules" do
    switches = [Switches.only(Switches.offers()), Switches.only([]), []]
    facts = [Facts.read(@mac), Facts.read(Keyword.put(@mac, :os, :linux))]

    for module <- Offers.modules(), s <- switches, f <- facts do
      assert Copy.violations(module.label(), :name) == [], module.label()

      case module.state(s, f) do
        {:on, _detail} -> :ok
        {_state, said} -> assert Copy.violations(said, :prose) == [], said
      end
    end
  end

  test "a computer that moved before M97 starts waiting for its review" do
    home = SafeRm.make_tmp_dir!("desktop_offers_moved")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    File.mkdir_p!(Path.dirname(DesktopLink.path(home)))
    File.write!(DesktopLink.path(home), "{}")
    relay = start_supervised!({FakeRelay, self()}, id: :moved_relay)

    start_supervised!(
      {Offers,
       name: :"desktop_offers_moved_#{System.unique_integer([:positive])}",
       home: home,
       relay: relay,
       facts: fn -> Facts.read(@mac) end,
       timer: fn _message, _delay -> make_ref() end},
      id: :moved_offers
    )

    assert {:ok, switches} = Switches.read(home)
    refute Switches.reviewed?(switches)
    assert :files in Switches.switched_on(switches)
  end
end
