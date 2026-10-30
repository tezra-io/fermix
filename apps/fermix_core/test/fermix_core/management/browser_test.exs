defmodule FermixCore.Management.BrowserTest do
  # The browser hand-off's management methods (M75 D18), through the router as
  # `daemon.sock` reaches them, with the DevTools session, the rail and the
  # role stood in.
  use ExUnit.Case, async: true

  alias FermixCore.Browser.Handoff.Cookies
  alias FermixCore.Browser.Handoff.Ledger
  alias FermixCore.Management.Browser
  alias FermixCore.Management.Copy
  alias FermixCore.Management.Placement
  alias FermixCore.Management.Router
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2026-10-27 09:00:00Z]
  @device %{role: :device, primary: "vm-1"}
  @primary %{role: :primary, primary: nil}

  defmodule StubLink do
    @moduledoc false
    @behaviour FermixCore.Browser.Handoff.Link

    # The test process is told what was sent, and the answer is the one the
    # test put in the process dictionary of the caller.
    @impl true
    def send_handoff(handoff) do
      send(Process.get(:test_pid), {:sent, handoff})
      Process.get(:link_answer)
    end

    @impl true
    def send_wipe(sites) do
      send(Process.get(:test_pid), {:wipe_sent, sites})
      Process.get(:wipe_answer, {:ok, %{cookies: 0}})
    end
  end

  setup do
    home = SafeRm.make_tmp_dir!("management_browser")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    Process.put(:test_pid, self())
    %{home: home}
  end

  defp cookie(name, domain) do
    %{
      "name" => name,
      "value" => "v",
      "domain" => domain,
      "path" => "/",
      "expires" => -1,
      "httpOnly" => true,
      "secure" => true
    }
  end

  defp devtools(cookies) do
    fn _mode, fun, _opts ->
      fun.(fn
        "Storage.getCookies", %{} -> {:ok, %{"cookies" => cookies}}
        "Storage.setCookies", %{} -> {:ok, %{}}
      end)
    end
  end

  defp route(method, params, role, extra) do
    browser = [now: fn -> @now end, link: StubLink] ++ extra

    Router.route(%{method: method, protocol_version: 2, params: params},
      engine_role: role,
      operation_opts: [browser: browser]
    )
  end

  describe "browser.handoff.send" do
    test "sends exactly the named sites' cookies and answers what the primary stored" do
      Process.put(:link_answer, {:ok, %{cookies: 2, expires_at: ~U[2026-11-03 09:00:00Z]}})
      TelemetryCapture.attach([[:fermix, :browser, :handoff]], :emitter)

      cookies = [
        cookie("sid", ".news.example.org"),
        cookie("pref", "news.example.org"),
        cookie("track", ".ads.example.com")
      ]

      assert {:ok, result} =
               route("browser.handoff.send", %{"sites" => ["news.example.org"]}, @device,
                 devtools: devtools(cookies)
               )

      assert %{
               "cookies_sent" => 2,
               "cookies_stored" => 2,
               "expires_at" => "2026-11-03T09:00:00Z",
               "sites" => [%{"site" => "news.example.org", "cookies" => 2}]
             } = result

      assert_received {:sent, handoff}
      assert handoff.sites == ["news.example.org"]
      assert handoff.count == 2
      assert handoff.expires_at == ~U[2026-11-03 09:00:00Z]
      assert {:ok, sent} = Cookies.decode(handoff.payload, ["news.example.org"], 2)
      assert sent |> Enum.map(& &1["name"]) |> Enum.sort() == ["pref", "sid"]

      assert_received {:telemetry, [:fermix, :browser, :handoff], %{cookies: 2},
                       %{op: :sent, result: :ok, sites: 1}}
    end

    test "an identity provider moves only with the flag" do
      Process.put(:link_answer, {:ok, %{cookies: 1, expires_at: ~U[2026-11-03 09:00:00Z]}})
      cookies = [cookie("SID", ".accounts.google.com")]

      assert {:error, :invalid_params, %{"field" => "sites", "sentence" => sentence}} =
               route("browser.handoff.send", %{"sites" => ["accounts.google.com"]}, @device,
                 devtools: devtools(cookies)
               )

      assert sentence =~ "moves only when you allow identity providers in the hand-off"
      refute_received {:sent, _handoff}

      assert {:ok, %{"cookies_stored" => 1}} =
               route(
                 "browser.handoff.send",
                 %{"sites" => ["accounts.google.com"], "allow_identity_provider" => true},
                 @device,
                 devtools: devtools(cookies)
               )
    end

    test "the expiry is 7 days unless said, and at most 30" do
      Process.put(:link_answer, {:ok, %{cookies: 1, expires_at: ~U[2026-10-28 09:00:00Z]}})
      cookies = [cookie("sid", ".news.example.org")]
      params = %{"sites" => ["news.example.org"], "expires_s" => 86_400}

      assert {:ok, _} =
               route("browser.handoff.send", params, @device, devtools: devtools(cookies))

      assert_received {:sent, %{expires_at: ~U[2026-10-28 09:00:00Z]}}

      assert {:error, :invalid_params, %{"field" => "expires_s"}} =
               route("browser.handoff.send", %{params | "expires_s" => 31 * 86_400}, @device,
                 devtools: devtools(cookies)
               )
    end

    test "only a desktop starts one" do
      assert {:error, :unavailable, %{"capability" => "browser", "sentence" => sentence}} =
               route("browser.handoff.send", %{"sites" => ["news.example.org"]}, @primary, [])

      assert sentence =~ "starts on a desktop"
    end

    test "no cookies, an unreachable primary and a refusal are each named" do
      assert {:error, :unavailable, %{"sentence" => no_cookies}} =
               route("browser.handoff.send", %{"sites" => ["news.example.org"]}, @device,
                 devtools: devtools([])
               )

      assert no_cookies =~ "Sign in to them in Fermix's browser on this computer first."
      cookies = [cookie("sid", ".news.example.org")]

      Process.put(
        :link_answer,
        {:error, {:primary_unreachable, "The server vm-1 is unreachable."}}
      )

      assert {:error, :primary_unreachable, %{"sentence" => "The server vm-1 is unreachable."}} =
               route("browser.handoff.send", %{"sites" => ["news.example.org"]}, @device,
                 devtools: devtools(cookies)
               )

      Process.put(:link_answer, {:error, {:primary_refused, "The server stored nothing."}})

      assert {:error, :unavailable, %{"sentence" => "The server stored nothing."}} =
               route("browser.handoff.send", %{"sites" => ["news.example.org"]}, @device,
                 devtools: devtools(cookies)
               )
    end

    test "unknown params are refused" do
      assert {:error, :invalid_params, %{"field" => "site"}} =
               route("browser.handoff.send", %{"site" => "x"}, @device, [])
    end
  end

  describe "browser.handoffs.list and wipe" do
    setup %{home: home} do
      key = %{
        "site" => "news.example.org",
        "domain" => ".news.example.org",
        "name" => "sid",
        "path" => "/"
      }

      ledger =
        Ledger.record(Ledger.empty(), %{
          handoff_id: "ho-1",
          from: "Studio Mac",
          sites: ["news.example.org"],
          stored_at: @now,
          expires_at: ~U[2026-11-03 09:00:00Z],
          cookies: [key]
        })

      :ok = Ledger.write(home, ledger)
      :ok
    end

    test "lists the hand-offs this primary stores", %{home: home} do
      assert {:ok, %{"handoffs" => [row], "sentence" => "One hand-off is stored here."}} =
               route("browser.handoffs.list", %{}, @primary, home: home)

      assert row == %{
               "handoff_id" => "ho-1",
               "from" => "Studio Mac",
               "sites" => ["news.example.org"],
               "cookies" => 1,
               "stored_at" => "2026-10-27T09:00:00Z",
               "expires_at" => "2026-11-03T09:00:00Z",
               "expired" => false
             }
    end

    test "the primary wipes here; a desktop asks its primary", %{home: home} do
      test = self()

      deleting = fn mode, fun, _opts ->
        send(test, {:devtools, mode})

        fun.(fn "Storage.setCookies", %{"cookies" => params} ->
          send(test, {:deleted, params}) && {:ok, %{}}
        end)
      end

      assert {:ok, %{"cookies" => 1, "sites" => ["news.example.org"]}} =
               route("browser.handoffs.wipe", %{"sites" => ["news.example.org"]}, @primary,
                 home: home,
                 devtools: deleting
               )

      assert_received {:devtools, :launch_headless}
      assert_received {:deleted, [%{"name" => "sid", "expires" => 1}]}
      assert {:ok, %{handoffs: []}} = Ledger.read(home)

      # G6: the primary answers a desktop's wipe with how many it deleted.
      Process.put(:wipe_answer, {:ok, %{cookies: 3}})

      assert {:ok,
              %{
                "sites" => nil,
                "cookies" => 3,
                "sentence" => "Every hand-off is wiped: 3 cookies deleted."
              }} = route("browser.handoffs.wipe", %{}, @device, home: home)

      assert_received {:wipe_sent, nil}

      Process.put(:wipe_answer, {:error, :primary_timeout})

      assert {:error, :unavailable, %{"sentence" => sentence}} =
               route("browser.handoffs.wipe", %{"sites" => ["news.example.org"]}, @device,
                 home: home
               )

      assert sentence ==
               "The server did not confirm the wipe in time. Its list of hand-offs shows what " <>
                 "it still holds."
    end
  end

  describe "browser.signin.open" do
    test "opens an http or https address, and refuses anything else" do
      test = self()
      open = fn url, _opts -> send(test, {:opened, url}) && :ok end

      assert {:ok, %{"sentence" => _sentence}} =
               route("browser.signin.open", %{"url" => "https://news.example.org/login"}, @device,
                 open_headed: open,
                 display?: fn -> true end
               )

      assert_received {:opened, "https://news.example.org/login"}

      for url <- ["file:///etc/hosts", "javascript:alert(1)", "news.example.org", 42] do
        assert {:error, :invalid_params, %{"field" => "url"}} =
                 route("browser.signin.open", %{"url" => url}, @device,
                   open_headed: open,
                   display?: fn -> true end
                 )
      end
    end

    test "a profile that is not a Fermix Chrome is named" do
      open = fn _url, _opts -> {:error, :profile_not_managed} end

      assert {:error, :unavailable, %{"sentence" => sentence}} =
               route("browser.signin.open", %{"url" => "https://a.example/"}, @device,
                 open_headed: open,
                 display?: fn -> true end
               )

      assert sentence =~ "not one Fermix runs Chrome in"
    end

    test "a host with no screen (a headless server) refuses it by name and opens nothing" do
      test = self()
      open = fn url, _opts -> send(test, {:opened, url}) && :ok end

      assert {:error, :unavailable, %{"capability" => "browser", "sentence" => sentence}} =
               route("browser.signin.open", %{"url" => "https://a.example/"}, @primary,
                 open_headed: open,
                 display?: fn -> false end
               )

      assert sentence =~ "This computer has no screen to open a sign-in window on."
      refute sentence =~ "fermix "
      refute_received {:opened, _url}
    end
  end

  describe "placement and copy" do
    test "the hand-off, the sign-in and the wipe are the desktop's; the list is the primary's" do
      assert Placement.place("browser.handoff.send", %{}) == :device
      assert Placement.place("browser.signin.open", %{}) == :device
      assert Placement.place("browser.handoffs.wipe", %{}) == :device
      assert Placement.place("browser.handoffs.list", %{}) == :primary
    end

    test "every sentence obeys the copy rules" do
      for sentence <- Browser.sentences() do
        assert Copy.violations(sentence, :prose) == [], sentence
      end
    end
  end
end
