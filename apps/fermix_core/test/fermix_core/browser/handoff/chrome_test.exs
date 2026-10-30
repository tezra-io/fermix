defmodule FermixCore.Browser.Handoff.ChromeTest do
  # The hand-off's DevTools round trip against a real headless Chrome (M75
  # D18, B10): cookies read from one owner profile (the desktop's), stored in
  # another (the primary's) and deleted there again. Opt in with
  # `--only chrome` on a machine with Chrome installed; each step launches it.
  #
  # Sync: each home is chosen through `FERMIX_HOME`, which is process-global.
  use ExUnit.Case, async: false

  alias FermixCore.Browser.ChromeLauncher
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Handoff
  alias FermixCore.Browser.Handoff.Cookies
  alias FermixCore.Browser.Handoff.DevTools
  alias FermixCore.Browser.Handoff.Ledger
  alias FermixTestSupport.SafeRm

  @moduletag :chrome
  @moduletag timeout: 180_000

  @sites ["news.example.org"]
  @now ~U[2026-10-27 09:00:00Z]
  @expires ~U[2026-11-03 09:00:00Z]

  setup do
    tmp = SafeRm.make_tmp_dir!("handoff_chrome")
    previous = System.get_env("FERMIX_HOME")

    on_exit(fn ->
      if previous,
        do: System.put_env("FERMIX_HOME", previous),
        else: System.delete_env("FERMIX_HOME")

      SafeRm.rm_rf!(tmp)
    end)

    %{desktop: Path.join(tmp, "desktop"), primary: Path.join(tmp, "primary")}
  end

  defp at_home(home), do: System.put_env("FERMIX_HOME", home)
  defp opts(home, now \\ @now), do: [home: home, now: fn -> now end, browser_config: []]

  defp cookie(name, domain, extra) do
    Map.merge(
      %{
        "name" => name,
        "value" => "value-of-#{name}",
        "url" => "https://#{String.trim_leading(domain, ".")}/",
        "path" => "/",
        "secure" => true,
        "httpOnly" => true
      },
      extra
    )
  end

  defp all_cookies do
    DevTools.run(
      :launch_headless,
      fn command ->
        {:ok, %{"cookies" => cookies}} = command.("Storage.getCookies", %{})
        cookies
      end,
      browser_config: []
    )
  end

  defp names(cookies, site),
    do:
      cookies
      |> Enum.filter(&String.ends_with?(&1["domain"], site))
      |> Enum.map(& &1["name"])
      |> Enum.sort()

  test "cookies read on the desktop are stored on the primary, capped, and deleted again", ctx do
    # The owner's sign-in on the desktop, set straight into the profile's
    # running Chrome: a session cookie lives only as long as that Chrome, so
    # the hand-off reads it from the Chrome the owner signed in with.
    at_home(ctx.desktop)

    signed_in = [
      cookie("sid", ".news.example.org", %{"domain" => ".news.example.org", "sameSite" => "None"}),
      cookie("pref", "news.example.org", %{
        "expires" => DateTime.to_unix(~U[2027-01-01 00:00:00Z])
      }),
      cookie("track", ".ads.example.com", %{"domain" => ".ads.example.com"})
    ]

    runtime = start_chrome()

    collected =
      try do
        :ok =
          DevTools.run(
            :running_only,
            fn command ->
              {:ok, _} = command.("Storage.setCookies", %{"cookies" => signed_in})
              :ok
            end,
            browser_config: []
          )

        assert {:ok, collected} = Handoff.collect(@sites, opts(ctx.desktop))
        collected
      after
        stop_chrome(runtime)
      end

    assert collected |> Enum.map(& &1["name"]) |> Enum.sort() == ["pref", "sid"]
    host_only = Enum.find(collected, &(&1["name"] == "pref"))
    assert host_only["domain"] == "news.example.org"

    # The primary stores them, each no longer than the hand-off.
    at_home(ctx.primary)

    handoff = %{
      handoff_id: "ho-chrome",
      from: "Studio Mac",
      sites: @sites,
      expires_at: @expires,
      cookies: Cookies.decode(Cookies.encode(collected), @sites, 2) |> elem(1)
    }

    assert {:ok, %{cookies: 2}} = Handoff.store(handoff, opts(ctx.primary))

    stored = all_cookies()
    assert names(stored, "news.example.org") == ["pref", "sid"]
    assert names(stored, "ads.example.com") == []
    assert Enum.all?(stored, &(&1["expires"] <= DateTime.to_unix(@expires)))
    assert Enum.find(stored, &(&1["name"] == "pref"))["domain"] == "news.example.org"
    assert Enum.find(stored, &(&1["name"] == "sid"))["domain"] == ".news.example.org"

    # Expired while no Chrome ran: the sweep leaves them, the next launch deletes them.
    later = ~U[2026-11-04 00:00:00Z]
    assert {:ok, 0} = Handoff.sweep(opts(ctx.primary, later))

    {:ok, 2} =
      DevTools.run(
        :launch_headless,
        fn command ->
          Handoff.purge_on_launch(command, opts(ctx.primary, later))
        end,
        browser_config: []
      )

    assert names(all_cookies(), "news.example.org") == []
    assert {:ok, %{handoffs: []}} = Ledger.read(ctx.primary)
  end

  test "the sweep deletes from a Chrome that is running, and a wipe launches one", ctx do
    at_home(ctx.primary)
    cookies = Cookies.select([stored_cookie("sid")], @sites)

    handoff = %{
      handoff_id: "ho-1",
      from: "Studio Mac",
      sites: @sites,
      expires_at: @expires,
      cookies: cookies
    }

    assert {:ok, %{cookies: 1}} = Handoff.store(handoff, opts(ctx.primary))

    later = ~U[2026-11-04 00:00:00Z]
    runtime = start_chrome()

    try do
      assert {:ok, 1} = Handoff.sweep(opts(ctx.primary, later))
      assert names(running_cookies(), "news.example.org") == []
    after
      stop_chrome(runtime)
    end

    # That Chrome was stopped by signal, which may come before it wrote the
    # deletion; the next Chrome to start deletes it once more.
    {:ok, 0} =
      DevTools.run(
        :launch_headless,
        fn command -> Handoff.purge_on_launch(command, opts(ctx.primary, later)) end,
        browser_config: []
      )

    assert names(all_cookies(), "news.example.org") == []
    assert {:ok, %{handoffs: [], purge: []}} = Ledger.read(ctx.primary)

    assert {:ok, %{cookies: 1}} =
             Handoff.store(%{handoff | handoff_id: "ho-2"}, opts(ctx.primary))

    assert {:ok, %{cookies: 1}} = Handoff.wipe(:all, opts(ctx.primary))
    assert names(all_cookies(), "news.example.org") == []
  end

  defp running_cookies do
    DevTools.run(
      :running_only,
      fn command ->
        {:ok, %{"cookies" => cookies}} = command.("Storage.getCookies", %{})
        cookies
      end,
      browser_config: []
    )
  end

  # A Chrome on the owner profile of the home `FERMIX_HOME` names, as the
  # owner's own or the engine's would be running.
  defp start_chrome do
    {:ok, config} = Config.current([])
    {:ok, profile, name} = Config.profile(config, nil)
    {:ok, runtime} = ChromeLauncher.start(config, %{profile | headless: true}, "owner", name)
    {runtime, config}
  end

  defp stop_chrome({runtime, config}), do: ChromeLauncher.stop(runtime, config)

  defp stored_cookie(name) do
    %{
      "name" => name,
      "value" => "v",
      "domain" => ".news.example.org",
      "path" => "/",
      "expires" => -1,
      "httpOnly" => true,
      "secure" => true
    }
  end
end
