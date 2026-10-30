defmodule FermixCore.Browser.HandoffTest do
  # The hand-off's operations against a stand-in Chrome profile: a cookie jar
  # answering `Storage.getCookies` and `Storage.setCookies` the way Chrome
  # does (an entry set with an expiry in the past deletes the cookie its name,
  # domain and path name). The clock is injected; nothing waits on time.
  use ExUnit.Case, async: true

  alias FermixCore.Browser.Handoff
  alias FermixCore.Browser.Handoff.Cookies
  alias FermixCore.Browser.Handoff.Ledger
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2026-10-27 09:00:00Z]
  @sites ["news.example.org"]

  setup do
    home = SafeRm.make_tmp_dir!("handoff_ops")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    jar = start_supervised!({Agent, fn -> %{running: true, cookies: %{}} end})
    %{home: home, jar: jar}
  end

  # The stand-in DevTools session: `:running_only` finds no Chrome when the
  # jar says none runs, as `DevTools.run/3` would.
  defp devtools(jar) do
    fn mode, fun, _opts ->
      if mode == :running_only and not Agent.get(jar, & &1.running),
        do: {:error, :not_running},
        else: fun.(&command(jar, &1, &2))
    end
  end

  defp command(jar, "Storage.getCookies", %{}),
    do: {:ok, %{"cookies" => Agent.get(jar, &Map.values(&1.cookies))}}

  defp command(jar, "Storage.setCookies", %{"cookies" => params}) do
    Agent.update(jar, fn state ->
      %{state | cookies: Enum.reduce(params, state.cookies, &set_cookie/2)}
    end)

    {:ok, %{}}
  end

  defp set_cookie(%{"expires" => 1} = param, cookies), do: Map.delete(cookies, jar_key(param))

  defp set_cookie(param, cookies) do
    domain = param["domain"] || URI.parse(param["url"]).host
    cookie = param |> Map.delete("url") |> Map.put("domain", domain)
    Map.put(cookies, jar_key(param), cookie)
  end

  defp jar_key(param),
    do: {param["domain"] || URI.parse(param["url"]).host, param["name"], param["path"]}

  defp put_cookies(jar, cookies),
    do:
      Agent.update(jar, fn state -> %{state | cookies: Map.new(cookies, &{jar_key(&1), &1})} end)

  defp jar_names(jar),
    do: jar |> Agent.get(&Map.values(&1.cookies)) |> Enum.map(& &1["name"]) |> Enum.sort()

  defp cookie(name, domain, extra \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "value" => "value-of-#{name}",
        "domain" => domain,
        "path" => "/",
        "expires" => -1,
        "httpOnly" => true,
        "secure" => true
      },
      extra
    )
  end

  defp opts(ctx, now \\ @now),
    do: [home: ctx.home, now: fn -> now end, devtools: devtools(ctx.jar)]

  defp handoff(cookies, expires_at \\ ~U[2026-11-03 09:00:00Z]) do
    %{
      handoff_id: "ho-1",
      from: "Studio Mac",
      sites: @sites,
      expires_at: expires_at,
      cookies: Cookies.select(cookies, @sites)
    }
  end

  describe "collect/2 (the desktop)" do
    test "reads the profile's cookies for exactly the named sites", ctx do
      put_cookies(ctx.jar, [
        cookie("sid", ".news.example.org"),
        cookie("pref", "www.news.example.org"),
        cookie("track", ".ads.example.com")
      ])

      assert {:ok, cookies} = Handoff.collect(@sites, opts(ctx))
      assert cookies |> Enum.map(& &1["name"]) |> Enum.sort() == ["pref", "sid"]
      assert Enum.all?(cookies, &(&1["site"] == "news.example.org"))
    end

    test "a profile with no cookie for the sites is refused by name", ctx do
      put_cookies(ctx.jar, [cookie("track", ".ads.example.com")])
      assert {:error, :no_cookies} = Handoff.collect(@sites, opts(ctx))
    end
  end

  describe "store/2 (the primary)" do
    test "stores the cookies capped at the hand-off's expiry and records keys, never values",
         ctx do
      TelemetryCapture.attach([[:fermix, :browser, :handoff]], :emitter)

      cookies = [
        cookie("sid", ".news.example.org"),
        cookie("pref", "news.example.org", %{"expires" => 1_900_000_000})
      ]

      assert {:ok, %{cookies: 2, expires_at: ~U[2026-11-03 09:00:00Z]}} =
               Handoff.store(handoff(cookies), opts(ctx))

      cap = DateTime.to_unix(~U[2026-11-03 09:00:00Z])
      stored = Agent.get(ctx.jar, &Map.values(&1.cookies))
      assert Enum.all?(stored, &(&1["expires"] == cap))

      raw = File.read!(Ledger.path(ctx.home))
      refute raw =~ "value-of-"
      assert {:ok, %{handoffs: [entry]}} = Ledger.read(ctx.home)
      assert entry.from == "Studio Mac"
      assert length(entry.cookies) == 2

      assert_receive {:telemetry, [:fermix, :browser, :handoff], %{cookies: 2},
                      %{op: :stored, result: :ok, sites: 1}}
    end

    test "refuses an expiry past 30 days or already passed", ctx do
      cookies = [cookie("sid", ".news.example.org")]

      assert {:error, {:invalid_expiry, _at}} =
               Handoff.store(handoff(cookies, ~U[2026-12-27 09:00:00Z]), opts(ctx))

      assert {:error, {:invalid_expiry, _at}} =
               Handoff.store(handoff(cookies, ~U[2026-10-27 08:00:00Z]), opts(ctx))

      assert jar_names(ctx.jar) == []
    end

    test "a profile that refuses the cookies leaves no record", ctx do
      refusing = fn _mode, _fun, _opts -> {:error, :profile_not_managed} end
      cookies = [cookie("sid", ".news.example.org")]

      assert {:error, :profile_not_managed} =
               Handoff.store(handoff(cookies), Keyword.put(opts(ctx), :devtools, refusing))

      assert {:ok, %{handoffs: []}} = Ledger.read(ctx.home)
    end
  end

  describe "expiry" do
    setup ctx do
      {:ok, _stored} =
        Handoff.store(handoff([cookie("sid", ".news.example.org")]), opts(ctx))

      put_cookies(
        ctx.jar,
        Agent.get(ctx.jar, &Map.values(&1.cookies)) ++ [cookie("own", "other.example")]
      )

      :ok
    end

    test "the sweep deletes an expired hand-off's cookies from the running Chrome", ctx do
      TelemetryCapture.attach([[:fermix, :browser, :handoff]], :emitter)

      assert {:ok, 0} = Handoff.sweep(opts(ctx, ~U[2026-11-03 08:59:59Z]))
      assert jar_names(ctx.jar) == ["own", "sid"]

      assert {:ok, 1} = Handoff.sweep(opts(ctx, ~U[2026-11-03 09:00:00Z]))
      assert jar_names(ctx.jar) == ["own"]
      assert {:ok, %{handoffs: []}} = Ledger.read(ctx.home)

      assert_receive {:telemetry, [:fermix, :browser, :handoff], %{cookies: 1},
                      %{op: :expired, result: :ok}}
    end

    test "a site that set the cookie again since is still deleted by its key", ctx do
      refreshed = cookie("sid", ".news.example.org", %{"expires" => 2_100_000_000})
      put_cookies(ctx.jar, [refreshed, cookie("own", "other.example")])

      assert {:ok, 1} = Handoff.sweep(opts(ctx, ~U[2026-11-04 00:00:00Z]))
      assert jar_names(ctx.jar) == ["own"]
    end

    test "what a running Chrome deleted is deleted once more as the next one starts", ctx do
      assert {:ok, 1} = Handoff.sweep(opts(ctx, ~U[2026-11-03 09:00:00Z]))
      assert {:ok, %{purge: [%{"name" => "sid"}]}} = Ledger.read(ctx.home)

      # That Chrome was stopped before it wrote the deletion: the cookie is back.
      put_cookies(ctx.jar, [cookie("sid", ".news.example.org"), cookie("own", "other.example")])
      launch = &command(ctx.jar, &1, &2)

      assert {:ok, 0} = Handoff.purge_on_launch(launch, home: ctx.home, now: fn -> @now end)
      assert jar_names(ctx.jar) == ["own"]
      assert {:ok, %{handoffs: [], purge: []}} = Ledger.read(ctx.home)
    end

    test "with no Chrome running they wait for the next launch, which deletes them", ctx do
      Agent.update(ctx.jar, &%{&1 | running: false})
      later = ~U[2026-11-04 00:00:00Z]

      assert {:ok, 0} = Handoff.sweep(opts(ctx, later))
      assert {:ok, %{handoffs: [_still]}} = Ledger.read(ctx.home)
      assert jar_names(ctx.jar) == ["own", "sid"]

      launch = &command(ctx.jar, &1, &2)
      assert {:ok, 1} = Handoff.purge_on_launch(launch, home: ctx.home, now: fn -> later end)
      assert jar_names(ctx.jar) == ["own"]
      assert {:ok, %{handoffs: []}} = Ledger.read(ctx.home)
    end
  end

  describe "wipe/2" do
    test "deletes a site's hand-offs now, and only theirs", ctx do
      other = %{
        handoff_id: "ho-2",
        from: "Studio Mac",
        sites: ["mail.example.net"],
        expires_at: ~U[2026-11-03 09:00:00Z],
        cookies: Cookies.select([cookie("pref", ".mail.example.net")], ["mail.example.net"])
      }

      {:ok, _} = Handoff.store(handoff([cookie("sid", ".news.example.org")]), opts(ctx))
      {:ok, _} = Handoff.store(other, opts(ctx))

      assert {:ok, %{cookies: 1}} = Handoff.wipe(["news.example.org"], opts(ctx))
      assert jar_names(ctx.jar) == ["pref"]
      assert {:ok, %{handoffs: [%{handoff_id: "ho-2"}]}} = Ledger.read(ctx.home)

      assert {:ok, %{cookies: 1, sites: :all}} = Handoff.wipe(:all, opts(ctx))
      assert jar_names(ctx.jar) == []
      assert {:ok, %{handoffs: []}} = Ledger.read(ctx.home)
    end

    test "a wipe whose deletion fails keeps the record for the next try", ctx do
      {:ok, _} = Handoff.store(handoff([cookie("sid", ".news.example.org")]), opts(ctx))
      failing = fn _mode, _fun, _opts -> {:error, :devtools_timeout} end

      assert {:error, :devtools_timeout} =
               Handoff.wipe(:all, Keyword.put(opts(ctx), :devtools, failing))

      assert {:ok, %{handoffs: [_kept]}} = Ledger.read(ctx.home)
    end
  end

  test "expires_at/2: 7 days unless said, at most 30" do
    assert Handoff.expires_at(nil, @now) == {:ok, ~U[2026-11-03 09:00:00Z]}
    assert Handoff.expires_at(3_600, @now) == {:ok, ~U[2026-10-27 10:00:00Z]}
    assert {:ok, _} = Handoff.expires_at(30 * 86_400, @now)
    assert {:error, {:expiry_too_long, _}} = Handoff.expires_at(30 * 86_400 + 1, @now)
  end
end
