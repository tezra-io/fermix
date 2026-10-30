defmodule FermixChannels.Desktop.HandoffsTest do
  # A browser hand-off over the rail in one VM (M75 D18): the desktop's
  # `HandoffLink` sends, the primary's `handoff` family checks and stores
  # (the store stood in), and the answer comes back to the waiting owner.
  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.DeviceServices
  alias FermixChannels.Desktop.DeviceSupervisor
  alias FermixChannels.Desktop.HandoffLink
  alias FermixChannels.Desktop.Handoffs
  alias FermixChannels.Desktop.Loopback
  alias FermixChannels.Desktop.Relay
  alias FermixChannels.Desktop.SnapshotStore
  alias FermixChannels.Test.DesktopFamilyHost
  alias FermixCore.Browser.Handoff.Cookies
  alias FermixCore.Home.DesktopLink
  alias FermixTestSupport.SafeRm

  @desktop "desk-1"
  @sites ["news.example.org"]
  @expires ~U[2026-11-03 09:00:00Z]

  setup do
    me = self()
    link = :"handoff_link_#{System.unique_integer([:positive])}"
    start_supervised!({HandoffLink, name: link})

    to_desktop = fn @desktop, %{"t" => type} = event, payload, _opts ->
      send(me, {:to_desktop, type, event})
      HandoffLink.handle(link, type, Map.delete(event, "t"), payload)
    end

    %{me: me, link: link, to_desktop: to_desktop}
  end

  defp start_primary(ctx, store, wipe \\ fn _sites, _opts -> {:ok, %{cookies: 0}} end) do
    DesktopFamilyHost.start(
      Handoffs,
      %{device_id: @desktop, session: ctx.me, max_media_bytes: 1},
      options: [device_name: "Studio Mac", send: ctx.to_desktop, store: store, wipe: wipe]
    )
  end

  defp to_primary(host) do
    fn %{"t" => type} = event, payload ->
      GenServer.cast(host, {:event, type, Map.delete(event, "t"), payload})
      :ok
    end
  end

  defp cookies(names) do
    for name <- names do
      %{
        "site" => "news.example.org",
        "name" => name,
        "value" => "v-#{name}",
        "domain" => ".news.example.org",
        "path" => "/",
        "expires" => -1,
        "httpOnly" => true,
        "secure" => true
      }
    end
  end

  defp handoff(cookies) do
    %{
      handoff_id: "ho-#{System.unique_integer([:positive])}",
      sites: @sites,
      expires_at: @expires,
      count: length(cookies),
      payload: Cookies.encode(cookies)
    }
  end

  test "the primary stores what the desktop sent and the owner hears how many", ctx do
    me = ctx.me

    store = fn stored, _opts ->
      send(me, {:stored, stored})
      {:ok, %{cookies: length(stored.cookies), expires_at: stored.expires_at}}
    end

    host = start_primary(ctx, store)

    assert {:ok, %{cookies: 2, expires_at: @expires}} =
             HandoffLink.send_handoff(ctx.link, handoff(cookies(["sid", "pref"])),
               send: to_primary(host)
             )

    assert_received {:stored, stored}
    assert stored.from == "Studio Mac"
    assert stored.sites == @sites
    assert stored.expires_at == @expires
    assert Enum.map(stored.cookies, & &1["name"]) == ["sid", "pref"]
  end

  test "a store that refuses reaches the owner as the primary's sentence", ctx do
    host = start_primary(ctx, fn _stored, _opts -> {:error, {:invalid_expiry, @expires}} end)

    assert {:error, {:primary_refused, sentence}} =
             HandoffLink.send_handoff(ctx.link, handoff(cookies(["sid"])), send: to_primary(host))

    assert sentence =~ "within the next 30 days"
  end

  test "cookies for a site the hand-off did not name are refused, and nothing is stored", ctx do
    me = ctx.me
    host = start_primary(ctx, fn _stored, _opts -> send(me, :stored) && {:ok, %{}} end)

    foreign = [
      Map.merge(hd(cookies(["x"])), %{
        "site" => "tracker.example.com",
        "domain" => ".tracker.example.com"
      })
    ]

    assert {:error, {:primary_refused, sentence}} =
             HandoffLink.send_handoff(ctx.link, handoff(foreign), send: to_primary(host))

    assert sentence =~ "did not match what it named"
    refute_received :stored
  end

  test "cookies for a hand-off that never began are refused by name", ctx do
    host = start_primary(ctx, fn _stored, _opts -> {:ok, %{}} end)
    :ok = DesktopFamilyHost.event(host, "handoff_chunk", %{"handoff_id" => "ho-x"}, "{}")
    assert_receive {:to_desktop, "handoff_refused", %{"sentence" => sentence}}
    assert sentence =~ "no hand-off by that id"
  end

  test "at most 4 hand-offs wait for their cookies at once", ctx do
    host = start_primary(ctx, fn _stored, _opts -> {:ok, %{}} end)

    for n <- 1..5 do
      fields = %{
        "handoff_id" => "ho-#{n}",
        "sites" => @sites,
        "expires_at" => "2026-11-03T09:00:00Z",
        "count" => 1
      }

      :ok = DesktopFamilyHost.event(host, "handoff_begin", fields)
    end

    assert_receive {:to_desktop, "handoff_refused", %{"handoff_id" => "ho-5"}}
    refute_received {:to_desktop, "handoff_refused", %{"handoff_id" => "ho-1"}}
  end

  # G6: the primary answers a wipe with how many cookies it deleted, so the
  # owner on the desktop hears the count.
  test "a wipe from the desktop wipes those sites, or every hand-off, and hears how many", ctx do
    me = ctx.me
    wipe = fn sites, _opts -> send(me, {:wiped, sites}) && {:ok, %{cookies: 1}} end
    host = start_primary(ctx, fn _stored, _opts -> {:ok, %{}} end, wipe)

    assert {:ok, %{cookies: 1}} =
             HandoffLink.send_wipe(ctx.link, ["news.example.org"], send: to_primary(host))

    assert_receive {:wiped, ["news.example.org"]}
    assert_receive {:to_desktop, "handoff_wiped", %{"handoff_id" => _id, "cookies" => 1}}

    assert {:ok, %{cookies: 1}} = HandoffLink.send_wipe(ctx.link, nil, send: to_primary(host))
    assert_receive {:wiped, :all}
  end

  test "a wipe the primary could not finish reaches the owner as its sentence", ctx do
    wipe = fn _sites, _opts -> {:error, {:ledger_unreadable, :eacces}} end
    host = start_primary(ctx, fn _stored, _opts -> {:ok, %{}} end, wipe)

    assert {:error, {:primary_refused, sentence}} =
             HandoffLink.send_wipe(ctx.link, nil, send: to_primary(host))

    assert sentence == "The server could not wipe the hand-offs. Its daemon log says why."

    silent = fn _event, _payload -> :ok end

    assert {:error, :primary_timeout} =
             HandoffLink.send_wipe(ctx.link, nil, send: silent, answer_timeout_ms: 50)
  end

  test "a primary that does not answer is a timeout, and an unreachable one is named", ctx do
    silent = fn _event, _payload -> :ok end

    assert {:error, :primary_timeout} =
             HandoffLink.send_handoff(ctx.link, handoff(cookies(["sid"])),
               send: silent,
               answer_timeout_ms: 50
             )

    down = fn _event, _payload ->
      {:error, {:primary_unreachable, "The server vm-1 is unreachable."}}
    end

    assert {:error, {:primary_unreachable, "The server vm-1 is unreachable."}} =
             HandoffLink.send_handoff(ctx.link, handoff(cookies(["sid"])), send: down)
  end

  test "the relay hands the primary's answers and its other events to their servers" do
    inbound = Relay.inbound()

    for type <- ~w(handoff_stored handoff_refused handoff_wiped),
        do: assert(inbound[type] == HandoffLink)

    for type <- ~w(loopback_open loopback_response loopback_close),
        do: assert(inbound[type] == Loopback)

    for type <- ~w(snapshot_begin snapshot_chunk snapshot_end),
        do: assert(inbound[type] == SnapshotStore)
  end

  test "a linked desktop starts its services before the relay" do
    root = SafeRm.make_tmp_dir!("device_services")
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    link = DesktopLink.path(root)
    File.mkdir_p!(Path.dirname(link))
    File.write!(link, "{}")

    ids =
      root
      |> DeviceSupervisor.children()
      |> Enum.map(fn {module, _opts} -> module end)

    services = Enum.find_index(ids, &(&1 == DeviceServices))
    relay = Enum.find_index(ids, &(&1 == Relay))
    assert is_integer(services) and services < relay
  end
end
