defmodule FermixCore.Browser.ProfileServerAddressTest do
  # The browser policy judges where a name POINTS, not only how it is spelled.
  # Two halves, driven through an injected resolver and a fake page that reports
  # its documents the way Chrome does:
  #
  #   * before Chrome is sent anywhere, and before a page is read, a name is
  #     looked up once and refused when an answer is link-local, metadata or
  #     unspecified;
  #   * on every read, the address the browser says it loaded the document from
  #     is judged the same way — the half a rebinding name cannot pass, because
  #     Chrome's own lookup produced it.
  #
  # async: false — FERMIX_HOME is process-global (the read verbs resolve their
  # artifact paths against it) and the fake page reports dispatched CDP
  # commands to a registered collector.
  use ExUnit.Case, async: false

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.ProfileServer
  alias FermixTestSupport.SafeRm

  @collector :address_cdp_collector

  # One tab, `T1`. Its connect URL carries the address every document it loads
  # is served from, so each test decides where Chrome "really" went — or
  # `hang`, a server that never answers, `unreachable`, a host Chrome could not
  # load, or `download` and `no-content`, a request that commits nothing, each
  # answered the way Chrome answers it. Like Chrome, it reports a document's
  # response only on a session that enabled `Network`, and it reports it BEFORE
  # it answers the `Page.navigate` that caused it. A page whose url says
  # `opens-popup` opens a second tab, `T2`, the moment it loads — already on
  # its own url, so nothing is ever reported about its document.
  defmodule Page do
    use Agent

    alias FermixCore.Browser.Error

    def start_link("ws://fake/" <> served, opts) do
      page = %{owner: Keyword.get(opts, :owner), served: served, href: "about:blank", popup: nil}
      Agent.start_link(fn -> Map.put(page, :network, false) end)
    end

    def close(pid), do: Agent.stop(pid)

    def command(pid, method, params, session_id, _timeout_ms, _grace_ms) do
      page = Agent.get(pid, & &1)

      if collector = Process.whereis(:address_cdp_collector) do
        send(collector, {:cdp, method, params})
      end

      run(pid, page, method, params, session_id)
    end

    defp run(pid, _page, "Network.enable", _params, _session_id) do
      Agent.update(pid, &%{&1 | network: true})
      {:ok, %{}}
    end

    defp run(_pid, %{served: "hang"}, "Page.navigate", _params, _session_id),
      do: {:error, Error.new("cdp_timeout", "CDP command timed out: Page.navigate")}

    # No document at all: Chrome names the network error, commits its own error
    # page in the tab, and reports no response for it.
    defp run(pid, %{served: "unreachable"}, "Page.navigate", _params, _session_id) do
      Agent.update(pid, &%{&1 | href: "chrome-error://chromewebdata/"})
      {:ok, navigated("net::ERR_NAME_NOT_RESOLVED", false)}
    end

    # A download and a 204 leave the tab where it was.
    defp run(_pid, %{served: "download"}, "Page.navigate", _params, _session_id),
      do: {:ok, navigated("net::ERR_ABORTED", true)}

    defp run(_pid, %{served: "no-content"}, "Page.navigate", _params, _session_id),
      do: {:ok, navigated("net::ERR_ABORTED", false)}

    defp run(pid, page, "Page.navigate", %{url: url}, session_id) do
      Agent.update(pid, &%{&1 | href: url, popup: popup(url)})
      if page.network, do: send(page.owner, document_response(url, page.served, session_id))
      {:ok, %{"frameId" => "T1", "loaderId" => "L1"}}
    end

    # Chrome starts loading the moment the target exists, long before anyone can
    # attach to it — so a tab created ON a url reports nothing about it.
    defp run(pid, _page, "Target.createTarget", %{url: url}, _session_id) do
      Agent.update(pid, &%{&1 | href: url})
      {:ok, %{"targetId" => "T1"}}
    end

    defp run(_pid, page, "Target.getTargets", _params, _session_id) do
      tabs = for {id, url} <- [{"T1", page.href}, {"T2", page.popup}], url, do: target(id, url)
      {:ok, %{"targetInfos" => tabs}}
    end

    # A session names the target it was attached to, so a read answers from the
    # tab it was asked about.
    defp run(_pid, _page, "Target.attachToTarget", %{targetId: target}, _session_id),
      do: {:ok, %{"sessionId" => "#{target}:S#{System.unique_integer([:positive])}"}}

    defp run(_pid, _page, "Accessibility.getFullAXTree", _params, _session_id),
      do: {:ok, %{"nodes" => ax_nodes()}}

    defp run(_pid, _page, "Page.captureScreenshot", _params, _session_id),
      do: {:ok, %{"data" => Base.encode64("PNG-BYTES")}}

    defp run(_pid, page, "Runtime.evaluate", %{expression: "location.href"}, session_id),
      do: {:ok, %{"result" => %{"value" => href(page, session_id)}}}

    defp run(_pid, page, "Runtime.evaluate", %{expression: expression}, session_id) do
      if String.contains?(expression, "document.location.href") do
        meta = %{"url" => href(page, session_id), "title" => "Page", "ready" => "complete"}
        {:ok, %{"result" => %{"value" => meta}}}
      else
        {:ok, %{"result" => %{"value" => "<html>ami-0abc</html>"}}}
      end
    end

    defp run(_pid, _page, _method, _params, _session_id), do: {:ok, %{}}

    defp popup(url) do
      if String.contains?(url, "opens-popup"),
        do: "http://meta.example/latest/meta-data/iam/security-credentials/"
    end

    defp target(id, url),
      do: %{"targetId" => id, "type" => "page", "url" => url, "title" => "Page"}

    defp navigated(error, download?) do
      %{"frameId" => "T1", "loaderId" => "L1", "errorText" => error, "isDownload" => download?}
    end

    defp href(page, "T2:" <> _session), do: page.popup
    defp href(page, _session), do: page.href

    defp document_response(url, served, session_id) do
      params = %{
        "requestId" => "L1",
        "loaderId" => "L1",
        "frameId" => "T1",
        "type" => "Document",
        "response" => %{"url" => url, "remoteIPAddress" => served, "status" => 200}
      }

      event = %{"method" => "Network.responseReceived", "params" => params}
      {:cdp_event, "Network.responseReceived", Map.put(event, "sessionId", session_id)}
    end

    defp ax_nodes do
      [
        %{"nodeId" => "1", "role" => %{"value" => "RootWebArea"}, "childIds" => ["2"]},
        %{
          "nodeId" => "2",
          "role" => %{"value" => "textbox"},
          "name" => %{"value" => "ami-0abc"},
          "backendDOMNodeId" => 42,
          "childIds" => []
        }
      ]
    end
  end

  defmodule NoLauncher do
    def attach(_config, _profile, _owner, _name), do: :none
    def start(_config, _profile, _owner, _name), do: {:error, :unused}
    def stop(_runtime, _config), do: :ok
  end

  @owner "owner-address"
  @public {93, 184, 216, 34}
  @metadata {169, 254, 169, 254}

  setup do
    Process.register(self(), @collector)
    home = SafeRm.make_tmp_dir!("browser-address")
    File.mkdir_p!(Path.join(home, "workspace"))
    previous_home = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      restore_home(previous_home)
      if Process.whereis(@collector), do: Process.unregister(@collector)
      SafeRm.rm_rf!(home)
    end)

    :ok
  end

  # `answers` is what every lookup returns, or, as a map, what each host's does
  # (an unlisted host does not resolve); each lookup is reported to the test so
  # the per-host cache can be counted.
  defp start_page(served, answers, id) do
    test = self()

    resolver = fn host ->
      send(test, {:resolved, host})
      answer_for(answers, host)
    end

    start_supervised!(
      {ProfileServer,
       owner_key: @owner,
       profile_name: "fermix",
       profile: %{cdp_url: "ws://fake/" <> served},
       config: public_config(),
       launcher: NoLauncher,
       connection: Page,
       resolver: resolver},
      id: id
    )
  end

  defp answer_for(%{} = by_host, host), do: Map.get(by_host, host, {:error, :nxdomain})
  defp answer_for(answers, _host), do: answers

  defp public_config do
    # The shipped posture, established rather than inherited.
    {:ok, config} = Config.current(allow_private_network: false)
    config
  end

  defp req(pid, action, args \\ %{}),
    do: ProfileServer.request(pid, %{action: action, args: args, context: %{agent_name: "t"}})

  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(value), do: System.put_env("FERMIX_HOME", value)

  # ── before Chrome is sent anywhere ─────────────────────────────────────────

  test "a name that resolves to the metadata endpoint is refused before Chrome goes there" do
    pid = start_page("93.184.216.34", {:ok, [@metadata]}, :address_refused)
    assert {:ok, _} = req(pid, "start")

    for action <- ["open", "navigate"] do
      assert {:error, %Error{code: "navigation_blocked"} = error} =
               req(pid, action, %{"url" => "http://meta.example/latest/meta-data/"})

      assert error.details["reason"] == "link_local_address"
      assert error.message =~ "allowed_hosts"
    end

    refute_received {:cdp, "Target.createTarget", _params}
    refute_received {:cdp, "Page.navigate", _params}
  end

  # Phase 1 costs nobody anything: a LAN, homelab or tailnet name still
  # resolves where it always did, and a lookup that fails is Chrome's to fail.
  test "a name on the operator's own network, or one that does not resolve, still navigates" do
    lan = start_page("192.168.1.1", {:ok, [{192, 168, 1, 1}]}, :address_lan)
    assert {:ok, _} = req(lan, "start")
    assert {:ok, %{"page" => "changed"}} = req(lan, "navigate", %{"url" => "http://nas.example/"})

    dark = start_page("93.184.216.34", {:error, :nxdomain}, :address_nxdomain)
    assert {:ok, _} = req(dark, "start")

    assert {:ok, %{"page" => "changed"}} =
             req(dark, "navigate", %{"url" => "http://offline.example/"})
  end

  test "a host is looked up once, however many checks ask about it" do
    pid = start_page("93.184.216.34", {:ok, [@public]}, :address_cache)
    assert {:ok, _} = req(pid, "start")

    # A navigate asks twice — before, and on the committed URL — and a second
    # navigate and an open ask again.
    assert {:ok, _} = req(pid, "navigate", %{"url" => "http://site.example/a"})
    assert {:ok, _} = req(pid, "navigate", %{"url" => "http://site.example/b"})
    assert {:ok, _} = req(pid, "open", %{"url" => "http://site.example/c"})

    assert_received {:resolved, "site.example"}
    refute_received {:resolved, "site.example"}
  end

  test "a download from a name that resolves to link-local space is blocked" do
    pid = start_page("93.184.216.34", {:ok, [@metadata]}, :address_download)
    assert {:ok, _} = req(pid, "start")

    send(
      pid,
      {:cdp_event, "Browser.downloadWillBegin",
       %{
         "params" => %{
           "guid" => "G1",
           "url" => "http://meta.example/creds",
           "suggestedFilename" => "c"
         }
       }}
    )

    assert {:error, %Error{code: "download_blocked"}} =
             req(pid, "download", %{"timeout_ms" => 50})
  end

  # ── where the page actually came from ──────────────────────────────────────

  # DNS rebinding: the name answered publicly when it was checked, and Chrome's
  # own lookup a moment later sent it to the metadata endpoint. The navigation
  # happened; nothing it found comes back, now or on any later read.
  test "a page Chrome loaded from the metadata endpoint under a public name returns nothing" do
    pid = start_page("169.254.169.254", {:ok, [@public]}, :address_rebind)
    assert {:ok, _} = req(pid, "start")

    assert {:ok, result} = req(pid, "navigate", %{"url" => "http://rebind.example/latest/"})
    assert result["page"] == "read_blocked"
    assert result["page_reason"] =~ "169.254.169.254"

    for withheld <- ~w(snapshot url title) do
      refute Map.has_key?(result, withheld), "navigate returned the page's #{withheld}"
    end

    for {action, args} <- [
          {"snapshot", %{}},
          {"screenshot", %{}},
          {"act", %{"kind" => "get", "field" => "html"}}
        ] do
      assert {:error, %Error{code: "read_blocked"}} = req(pid, action, args),
             "`#{action}` read a page served from the metadata endpoint"
    end
  end

  # The tab `open` creates is navigated, never created on the url: a target
  # starts loading before anything can attach to it, so a document it was
  # created on is one nobody saw arrive.
  test "open watches the document it asked for arrive" do
    pid = start_page("169.254.169.254", {:ok, [@public]}, :address_open)
    assert {:ok, _} = req(pid, "start")
    flush_cdp()

    assert {:ok, result} = req(pid, "open", %{"url" => "http://rebind.example/latest/"})
    assert result["page"] == "read_blocked"
    refute Map.has_key?(result, "snapshot")

    commands = drain_cdp()
    assert {"Target.createTarget", %{url: "about:blank"}} in commands

    methods = Enum.map(commands, &elem(&1, 0))
    network = Enum.find_index(methods, &(&1 == "Network.enable"))
    navigate = Enum.find_index(methods, &(&1 == "Page.navigate"))
    assert network && navigate && network < navigate, "Network was not on before the request"
  end

  # `open` makes a tab before it navigates it, so a navigation that fails leaves
  # a blank tab no listing shows. It is closed again, and the answer is the
  # navigation's own error.
  test "a tab open made and could not load is closed again" do
    pid = start_page("hang", {:ok, [@public]}, :address_hang)
    assert {:ok, _} = req(pid, "start")

    assert {:error, %Error{code: "cdp_timeout"}} =
             req(pid, "open", %{"url" => "http://slow.example/"})

    assert_received {:cdp, "Target.closeTarget", %{targetId: "T1"}}
  end

  # A typo, a name nobody serves, a dev server that is not running: the page
  # did not load, and nothing refused it. Chrome's error page commits under a
  # `chrome-error:` address, which is not what the answer may be judged on — a
  # site that is merely down must not read as a policy refusal whose recovery
  # is `allowed_hosts`. The tab `navigate` moved stays; the one `open` made for
  # the page is closed again.
  test "a page that does not load says so, and is not called a refusal" do
    pid = start_page("unreachable", {:error, :nxdomain}, :address_unreachable)
    assert {:ok, _} = req(pid, "start")

    assert {:error, %Error{code: "navigation_failed"} = error} =
             req(pid, "navigate", %{"url" => "http://typo.example/"})

    assert error.details["net_error"] == "net::ERR_NAME_NOT_RESOLVED"
    assert error.message =~ "net::ERR_NAME_NOT_RESOLVED"
    refute error.message =~ "allowed_hosts"
    refute_received {:cdp, "Target.closeTarget", _params}

    assert {:error, %Error{code: "navigation_failed"}} =
             req(pid, "open", %{"url" => "http://typo.example/"})

    assert_received {:cdp, "Target.closeTarget", %{targetId: "T1"}}
  end

  # Chrome answers a download and a 204 with an aborted request too, and they
  # commit nothing: the navigation carries on as one that landed nowhere new.
  test "a download or an empty answer is not a page that failed to load" do
    for {served, id} <- [{"download", :address_download_link}, {"no-content", :address_204}] do
      pid = start_page(served, {:ok, [@public]}, id)
      assert {:ok, _} = req(pid, "start")

      for action <- ["navigate", "open"] do
        args = %{"url" => "http://files.example/report", "observe" => false}
        assert {:ok, _} = req(pid, action, args), "#{action} of a #{served} answer failed"
      end
    end
  end

  test "an IPv6 metadata address, as the browser brackets it, is refused too" do
    pid = start_page("[fd00:ec2::254]", {:ok, [@public]}, :address_v6)
    assert {:ok, _} = req(pid, "start")

    assert {:ok, %{"page" => "read_blocked"}} =
             req(pid, "navigate", %{"url" => "http://rebind.example/"})
  end

  # A private remote address is what a corporate proxy reports for every page,
  # and what an intranet server is. Neither is refused.
  test "a page served through a private proxy address still reads" do
    pid = start_page("10.0.0.5", {:ok, [@public]}, :address_proxy)
    assert {:ok, _} = req(pid, "start")

    assert {:ok, %{"page" => "changed"}} =
             req(pid, "navigate", %{"url" => "http://site.example/"})

    assert {:ok, %{"snapshot" => snapshot}} = req(pid, "snapshot")
    assert snapshot =~ "ami-0abc"
  end

  # A look the model opted out of reads nothing in the request, so the document
  # response is recorded between requests instead — and the next read still
  # refuses.
  test "a refusal is recorded between requests too" do
    pid = start_page("169.254.169.254", {:ok, [@public]}, :address_between)
    assert {:ok, _} = req(pid, "start")

    assert {:ok, _} =
             req(pid, "navigate", %{"url" => "http://rebind.example/", "observe" => false})

    assert {:error, %Error{code: "read_blocked"}} = req(pid, "snapshot")
  end

  # A tab the page opened itself — a `target=_blank` link the model was steered
  # into clicking, a `window.open` — loads before anything can attach to it, so
  # no watch saw its document arrive and the browser never says where it came
  # from. Its name is still looked up before it is read: one that points at the
  # metadata endpoint returns nothing, whichever verb asks.
  test "a tab the page opened onto a name that points at link-local space returns nothing" do
    answers = %{"site.example" => {:ok, [@public]}, "meta.example" => {:ok, [@metadata]}}
    pid = start_page("93.184.216.34", answers, :address_popup)
    assert {:ok, _} = req(pid, "start")
    assert {:ok, _} = req(pid, "navigate", %{"url" => "http://site.example/opens-popup"})

    popup = popup_tab(pid)

    for {action, args} <- [
          {"snapshot", %{"target" => popup}},
          {"screenshot", %{"target" => popup}},
          {"act", %{"kind" => "get", "field" => "html", "target" => popup}}
        ] do
      assert {:error, %Error{code: "read_blocked"} = error} = req(pid, action, args),
             "`#{action}` read a tab the page opened onto the metadata endpoint"

      assert error.details["reason"] == "link_local_address"
    end
  end

  # The same lookup costs a popup on an ordinary name nothing.
  test "a tab the page opened onto a public name still reads" do
    answers = %{"site.example" => {:ok, [@public]}, "meta.example" => {:ok, [@public]}}
    pid = start_page("93.184.216.34", answers, :address_popup_public)
    assert {:ok, _} = req(pid, "start")
    assert {:ok, _} = req(pid, "navigate", %{"url" => "http://site.example/opens-popup"})

    assert {:ok, %{"snapshot" => snapshot}} = req(pid, "snapshot", %{"target" => popup_tab(pid)})
    assert snapshot =~ "ami-0abc"
  end

  # The same page reloaded, and this time Chrome's lookup landed on the metadata
  # endpoint. The response arrives while a `wait` polls, and the poll that takes
  # it in refuses — then and on every read after.
  test "a document served mid-wait is judged by the next poll and remembered" do
    pid = start_page("93.184.216.34", {:ok, [@public]}, :address_mid_wait)
    assert {:ok, _} = req(pid, "start")
    assert {:ok, _} = req(pid, "navigate", %{"url" => "http://site.example/"})

    send_later(pid, "http://site.example/", "169.254.169.254")

    assert {:error, %Error{code: "read_blocked"}} =
             req(pid, "act", %{
               "kind" => "wait",
               "wait_until" => "url",
               "text" => "never",
               "timeout_ms" => 2_000
             })

    assert {:error, %Error{code: "read_blocked"}} = req(pid, "snapshot")
  end

  # The download waiter takes every event out of the mailbox while it waits. One
  # it took in is recorded in the state that wait built — which its timeout must
  # hand back, or the next read judges a document it never heard of.
  test "a document served while a download wait runs is not lost when the wait times out" do
    pid = start_page("93.184.216.34", {:ok, [@public]}, :address_mid_download)
    assert {:ok, _} = req(pid, "start")
    assert {:ok, _} = req(pid, "navigate", %{"url" => "http://site.example/"})

    send_later(pid, "http://site.example/", "169.254.169.254")

    assert {:error, %Error{code: "timeout"}} = req(pid, "download", %{"timeout_ms" => 300})
    assert {:error, %Error{code: "read_blocked"}} = req(pid, "snapshot")
  end

  # Sessions are re-opened after every target refresh and never closed, so a
  # watch per session would repeat every network event once per session the
  # tab ever had.
  test "the network watch is one per tab, not one per session" do
    pid = start_page("93.184.216.34", {:ok, [@public]}, :address_one_watch)
    assert {:ok, _} = req(pid, "start")
    flush_cdp()

    assert {:ok, _} = req(pid, "navigate", %{"url" => "http://site.example/"})

    # Each `tabs` refreshes the target set, so the `snapshot` after it attaches
    # a fresh session.
    for _round <- 1..3 do
      assert {:ok, _} = req(pid, "tabs")
      assert {:ok, _} = req(pid, "snapshot")
    end

    commands = drain_cdp()
    attaches = Enum.count(commands, &match?({"Target.attachToTarget", _}, &1))
    assert attaches > 1, "the test no longer re-attaches, so it proves nothing"
    assert Enum.count(commands, &match?({"Network.enable", _}, &1)) == 1

    # Only a response's address is read, so Chrome is told to keep no bodies.
    assert {"Network.enable", %{maxTotalBufferSize: 0, maxResourceBufferSize: 0}} in commands
  end

  defp popup_tab(pid) do
    assert {:ok, %{"tabs" => tabs}} = req(pid, "tabs")
    assert %{"id" => id} = Enum.find(tabs, &(&1["url"] =~ "meta.example")), "no popup tab listed"
    id
  end

  # A main-frame document response for `url`, delivered while the next request
  # is already running.
  defp send_later(pid, url, served) do
    response = %{"url" => url, "remoteIPAddress" => served}
    params = %{"type" => "Document", "frameId" => "T1", "response" => response}
    event = %{"method" => "Network.responseReceived", "params" => params}
    Process.send_after(pid, {:cdp_event, "Network.responseReceived", event}, 100)
  end

  defp drain_cdp(acc \\ []) do
    receive do
      {:cdp, method, params} -> drain_cdp([{method, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp flush_cdp, do: drain_cdp() && :ok
end
