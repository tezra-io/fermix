defmodule FermixCore.Browser.Handoff.LedgerTest do
  # The primary's record of stored hand-offs (M75 D18): keys and expiries,
  # never a value.
  use ExUnit.Case, async: true

  alias FermixCore.Browser.Handoff.Ledger
  alias FermixCore.Home.DeviceLocal
  alias FermixTestSupport.SafeRm

  @now ~U[2026-10-27 09:00:00Z]

  setup do
    home = SafeRm.make_tmp_dir!("handoff_ledger")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  defp key(site, domain, name),
    do: %{"site" => site, "domain" => domain, "name" => name, "path" => "/"}

  defp entry(id, expires_at, cookies) do
    %{
      handoff_id: id,
      from: "Studio Mac",
      sites: cookies |> Enum.map(& &1["site"]) |> Enum.uniq(),
      stored_at: @now,
      expires_at: expires_at,
      cookies: cookies
    }
  end

  test "an absent ledger is empty; a written one reads back, 0600", %{home: home} do
    assert {:ok, %{handoffs: []}} = Ledger.read(home)

    ledger =
      Ledger.record(
        Ledger.empty(),
        entry("ho-1", ~U[2026-11-03 09:00:00Z], [
          key("news.example.org", ".news.example.org", "sid")
        ])
      )

    assert :ok = Ledger.write(home, ledger)
    assert {:ok, ^ledger} = Ledger.read(home)
    assert {:ok, %File.Stat{mode: mode}} = File.stat(Ledger.path(home))
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "refuses to record anything but a cookie's key" do
    with_value = Map.put(key("a.example", "a.example", "sid"), "value", "secret")

    assert_raise ArgumentError, fn ->
      Ledger.record(Ledger.empty(), entry("ho-1", @now, [with_value]))
    end
  end

  test "a cookie handed off again belongs to the newer hand-off" do
    sid = key("news.example.org", ".news.example.org", "sid")
    pref = key("news.example.org", ".news.example.org", "pref")

    ledger =
      Ledger.empty()
      |> Ledger.record(entry("ho-1", ~U[2026-10-28 09:00:00Z], [sid, pref]))
      |> Ledger.record(entry("ho-2", ~U[2026-11-03 09:00:00Z], [sid]))

    assert [%{handoff_id: "ho-1", cookies: [^pref]}, %{handoff_id: "ho-2", cookies: [^sid]}] =
             ledger.handoffs

    ledger = Ledger.record(ledger, entry("ho-3", ~U[2026-11-04 09:00:00Z], [pref]))
    assert Enum.map(ledger.handoffs, & &1.handoff_id) == ["ho-2", "ho-3"]
  end

  test "expired/2 and drop/2" do
    ledger =
      Ledger.empty()
      |> Ledger.record(
        entry("old", ~U[2026-10-27 08:59:59Z], [key("a.example", "a.example", "x")])
      )
      |> Ledger.record(entry("edge", @now, [key("b.example", "b.example", "x")]))
      |> Ledger.record(
        entry("new", ~U[2026-10-27 09:00:01Z], [key("c.example", "c.example", "x")])
      )

    assert ledger |> Ledger.expired(@now) |> Enum.map(& &1.handoff_id) == ["old", "edge"]
    assert ledger |> Ledger.drop(["old", "edge"]) |> Map.fetch!(:handoffs) |> length() == 1
  end

  test "take/2 by site and all" do
    a = key("a.example", "a.example", "x")
    b = key("b.example", ".b.example", "y")

    ledger = Ledger.record(Ledger.empty(), entry("ho-1", @now, [a, b]))

    assert {[^a], %{handoffs: [%{cookies: [^b]}]}} = Ledger.take(ledger, ["a.example"])
    assert {[^a, ^b], %{handoffs: []}} = Ledger.take(ledger, :all)
    assert {[], ^ledger} = Ledger.take(ledger, ["c.example"])
  end

  test "the ledger stays on this machine, like the profile it describes" do
    assert DeviceLocal.excluded?("browser/handoffs.json")
    assert DeviceLocal.excluded?("browser/handoffs.json.tmp")
  end

  test "an unreadable ledger says so", %{home: home} do
    File.mkdir_p!(Path.dirname(Ledger.path(home)))
    File.write!(Ledger.path(home), "{not json")
    assert {:error, {:ledger_unreadable, :invalid}} = Ledger.read(home)
  end
end
