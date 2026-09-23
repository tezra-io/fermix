defmodule FermixCore.Browser.AttachedTabTest do
  # Drives a `ProfileServer` in `:attached_tab` mode through the real
  # `ExtensionTransport` and a real `Bridge.Grants`, with a stand-in for the
  # `Peer` — so everything between the tool and the socket is the shipping code.
  #
  # async: false — FERMIX_HOME is process-global (the read gate and the artifact
  # writers resolve against it).
  use ExUnit.Case, async: false

  alias FermixCore.Browser
  alias FermixCore.Browser.Bridge.Grants
  alias FermixCore.Browser.Capabilities
  alias FermixCore.Browser.CDP.ExtensionTransport
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.ProfileServer
  alias FermixTestSupport.SafeRm

  # The extension, as far as the daemon can tell: it answers `cdp` frames for
  # the one tab it granted and reports the `release` it is told to perform.
  # `href` is what the page's live-URL read returns, which is the one input the
  # read gate takes.
  defmodule FakeExtension do
    def start_link(page, reporter) do
      {:ok, spawn_link(fn -> loop(page, reporter) end)}
    end

    defp loop(page, reporter) do
      receive do
        {:bridge_command, from, id, _tab_id, method, params, _session} ->
          send(reporter, {:cdp, method, params})
          send(from, {:bridge_reply, id, run(page, method, params)})
          loop(page, reporter)

        {:release_tab, tab_id} ->
          send(reporter, {:released, tab_id})
          loop(page, reporter)
      end
    end

    defp run(_page, "Accessibility.getFullAXTree", _params), do: {:ok, %{"nodes" => ax_nodes()}}

    defp run(_page, "DOM.resolveNode", _params),
      do: {:ok, %{"object" => %{"objectId" => "OBJ1"}}}

    defp run(_page, "DOM.getBoxModel", _params),
      do: {:ok, %{"model" => %{"content" => [0, 0, 20, 0, 20, 20, 0, 20]}}}

    defp run(_page, "Page.captureScreenshot", _params),
      do: {:ok, %{"data" => Base.encode64("PNG-BYTES")}}

    defp run(_page, "Page.printToPDF", _params),
      do: {:ok, %{"data" => Base.encode64("%PDF-1.4")}}

    defp run({href, title}, "Runtime.evaluate", %{expression: expression}) do
      if String.contains?(expression, "document.location.href") do
        {:ok,
         %{"result" => %{"value" => %{"url" => href, "title" => title, "ready" => "complete"}}}}
      else
        {:ok, %{"result" => %{"value" => nil}}}
      end
    end

    defp run(_page, _method, _params), do: {:ok, %{}}

    defp ax_nodes do
      [
        %{"nodeId" => "1", "role" => %{"value" => "RootWebArea"}, "childIds" => ["2"]},
        %{
          "nodeId" => "2",
          "role" => %{"value" => "textbox"},
          "name" => %{"value" => "Where to?"},
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

  @owner "owner-attached"
  @tab_id 4242
  @blocked "http://169.254.169.254/latest/meta-data/"

  setup do
    home = SafeRm.make_tmp_dir!("attached-tab")
    File.mkdir_p!(Path.join(home, "workspace"))
    previous = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", home)

    grants = start_supervised!({Grants, name: nil})

    on_exit(fn ->
      restore_home(previous)
      SafeRm.rm_rf!(home)
    end)

    %{home: home, grants: grants}
  end

  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(value), do: System.put_env("FERMIX_HOME", value)

  defp public_config do
    {:ok, config} = Config.current(allow_private_network: false)
    config
  end

  defp grant!(grants, href, opts \\ []) do
    tab_id = Keyword.get(opts, :tab_id, @tab_id)
    title = Keyword.get(opts, :title, "Page")
    {:ok, peer} = FakeExtension.start_link({href, title}, self())
    :ok = Grants.grant(grants, peer, tab_id, %{"url" => href, "title" => title})
    peer
  end

  defp start_server(ctx, id, opts \\ []) do
    start_supervised!(
      {ProfileServer,
       owner_key: Keyword.get(opts, :owner, @owner),
       profile_name: "selected_tab",
       profile: %{mode: :attached_tab, headless: false, cdp_port: :auto},
       config: public_config(),
       launcher: NoLauncher,
       grants: ctx.grants,
       connection: ExtensionTransport},
      id: id
    )
  end

  defp req(pid, action, args \\ %{}),
    do: ProfileServer.request(pid, %{action: action, args: args, context: %{agent_name: "t"}})

  # ── the grant is the connection ────────────────────────────────────────────

  test "with nothing granted, every action asks for the click", ctx do
    pid = start_server(ctx, :attached_none)

    assert {:error, %Error{code: "attached_tab_not_granted"} = error} = req(pid, "start")
    assert error.message =~ "Click the Fermix extension"

    assert {:error, %Error{code: "attached_tab_not_granted"}} = req(pid, "snapshot")
  end

  test "a granted tab is the profile's whole tab set", ctx do
    grant!(ctx.grants, "https://example.com/dash")
    pid = start_server(ctx, :attached_tabs)

    assert {:ok, %{"tabs" => [tab]}} = req(pid, "tabs")
    assert tab["url"] == "https://example.com/dash"
    assert tab["title"] == "Page"
  end

  test "a grant is claimed by exactly one conversation", ctx do
    grant!(ctx.grants, "https://example.com/dash")

    first = start_server(ctx, :attached_first, owner: "owner-one")
    second = start_server(ctx, :attached_second, owner: "owner-two")

    assert {:ok, _} = req(first, "start")
    assert {:error, %Error{code: "attached_tab_not_granted"}} = req(second, "start")
  end

  test "stopping the profile releases the tab back to the person", ctx do
    grant!(ctx.grants, "https://example.com/dash")
    pid = start_server(ctx, :attached_release)

    assert {:ok, _} = req(pid, "start")
    assert {:ok, %{"stopped" => true}} = req(pid, "stop")

    assert_receive {:released, @tab_id}, 1_000
  end

  test "a revoke mid-session says which way the tab was taken back", ctx do
    peer = grant!(ctx.grants, "https://example.com/dash")
    pid = start_server(ctx, :attached_revoke)

    assert {:ok, _} = req(pid, "start")
    :ok = Grants.revoke(ctx.grants, peer, @tab_id, "devtools_opened")

    assert {:error, %Error{code: "attached_tab_detached"} = error} = eventually_detached(pid)
    assert error.message =~ "DevTools"
  end

  # The revoke travels peer -> Grants -> transport -> ProfileServer as messages,
  # so the first request after it may still be served by a runtime that is on
  # its way out. Poll for the verdict rather than sleeping for one.
  defp eventually_detached(pid, attempts \\ 20) do
    case req(pid, "snapshot") do
      {:error, %Error{code: "attached_tab_detached"}} = detached ->
        detached

      _retry when attempts > 0 ->
        Process.sleep(25)
        eventually_detached(pid, attempts - 1)

      other ->
        other
    end
  end

  # A second grant appearing anywhere — another browser, another tab — must not
  # be bound by a conversation that is still holding a tab it has lost. The
  # detach is delivered first; only the step after it may claim afresh.
  test "a lost tab is reported before any other grant can be bound", ctx do
    peer = grant!(ctx.grants, "https://example.com/safe", title: "Safe page")
    pid = start_server(ctx, :attached_steal)

    assert {:ok, %{"tabs" => [%{"title" => "Safe page"}]}} = req(pid, "tabs")

    # The person's tab goes, and a different one is granted in the same breath.
    :ok = Grants.revoke(ctx.grants, peer, @tab_id, "tab_closed")
    grant!(ctx.grants, "https://other.example/inbox", tab_id: 9999, title: "Other browser tab")

    assert {:error, %Error{code: "attached_tab_detached"} = error} = eventually_detached(pid)
    assert error.message =~ "That tab is closed"

    # Only now, with the refusal delivered, may the fresh grant be bound.
    assert {:ok, %{"tabs" => [%{"title" => "Other browser tab"}]}} = req(pid, "tabs")
  end

  test "a regrant of the same tab is still a detach the model hears about", ctx do
    peer = grant!(ctx.grants, "https://example.com/safe")
    pid = start_server(ctx, :attached_regrant)
    assert {:ok, _} = req(pid, "start")

    # The person clicks the extension on the same tab again: a new debugger
    # session, and the old one is not the conversation's any more.
    :ok = Grants.grant(ctx.grants, peer, @tab_id, %{"url" => "https://example.com/safe"})

    assert {:error, %Error{code: "attached_tab_detached"}} = eventually_detached(pid)
    assert {:ok, _} = req(pid, "start")
  end

  test "a released tab is gone, not left as a phantom grant", ctx do
    grant!(ctx.grants, "https://example.com/dash")
    pid = start_server(ctx, :attached_phantom)

    assert {:ok, _} = req(pid, "start")
    assert {:ok, %{"stopped" => true}} = req(pid, "stop")
    assert_receive {:released, @tab_id}, 1_000

    assert eventually_no_grant(ctx.grants)
    assert %{tabs: 0} = Grants.summary(ctx.grants)
  end

  defp eventually_no_grant(grants, attempts \\ 40) do
    case Grants.claim(grants, "somebody-else") do
      {:error, :no_grant} ->
        true

      {:ok, _grant} when attempts > 0 ->
        Process.sleep(25)
        eventually_no_grant(grants, attempts - 1)

      {:ok, _grant} ->
        false
    end
  end

  # A gate has to work in every world it can be reached from, and the browser
  # bridge runs in the daemon and nowhere else: a source boot or a test tree has
  # no grants table at all.
  test "with no bridge in this tree the tool answers, it does not take the server down" do
    home = SafeRm.make_tmp_dir!("attached-nobridge")
    File.mkdir_p!(Path.join(home, "workspace"))
    previous = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      restore_home(previous)
      SafeRm.rm_rf!(home)
    end)

    refute Process.whereis(Grants), "this tree unexpectedly has a bridge running"

    pid =
      start_supervised!(
        {ProfileServer,
         owner_key: @owner,
         profile_name: "selected_tab",
         profile: %{mode: :attached_tab, headless: false, cdp_port: :auto},
         config: public_config(),
         launcher: NoLauncher,
         connection: ExtensionTransport},
        id: :attached_no_bridge
      )

    assert {:error, %Error{code: "browser_bridge_unavailable"} = error} = req(pid, "start")
    assert error.message =~ "managed browser profile"
    assert Process.alive?(pid)
  end

  # ── the capability surface, whole ──────────────────────────────────────────

  # Every capability a granted tab does NOT have, and the action that asks for
  # it. The three with no action are init steps rather than verbs, named here
  # with the reason — so a capability added later either declares its action or
  # fails this test, and cannot quietly become a browser-wide command that
  # reaches the person's browser.
  @capability_actions %{
    new_tab: {"open", %{"url" => "https://example.com"}},
    close_tab: {"close", %{}},
    focus_tab: {"focus", %{}},
    cookies: {"cookies", %{}},
    downloads: {"download", %{"timeout_ms" => 50}},
    download_redirect: :not_an_action,
    target_discovery: :not_an_action,
    target_attach: :not_an_action
  }

  test "every browser-wide capability the grant lacks refuses by name", ctx do
    grant!(ctx.grants, "https://example.com/dash")
    pid = start_server(ctx, :attached_caps)
    assert {:ok, _} = req(pid, "start")

    withheld = for {capability, false} <- Capabilities.for_mode(:attached_tab), do: capability
    refute withheld == [], "the attached-tab mode withholds nothing — the map is vacuous"

    for capability <- withheld do
      assert Map.has_key?(@capability_actions, capability),
             "`#{capability}` is withheld but this test does not say which action asks for it"

      assert_capability_refusal(pid, Map.fetch!(@capability_actions, capability), capability)
    end
  end

  defp assert_capability_refusal(_pid, :not_an_action, _capability), do: :ok

  defp assert_capability_refusal(pid, {action, args}, capability) do
    result = req(pid, action, args)

    assert match?({:error, %Error{code: "unsupported_in_attached_tab"}}, result),
           "`#{action}` (#{capability}) was not refused: #{inspect(result)}"

    {:error, %Error{message: message}} = result

    assert message =~ ~r/managed browser profile|yourself/,
           "`#{action}` refused without naming the next move: #{message}"
  end

  # ── the read gate, unchanged and still in force ────────────────────────────

  # Everything that does not return bytes read from the page, with the reason.
  # The walk below takes `FermixCore.Browser.actions/0` — the same list the
  # tool's schema is built from — so an action added later either lands here
  # with a reason or has to refuse a blocked page.
  @no_page_read %{
    "doctor" => "chrome discovery; never reaches a profile or a page",
    "status" => "profile liveness counters; reads no page",
    "start" => "lifecycle; reads no page",
    "stop" => "lifecycle; reads no page",
    "open" => "refused as a browser-wide capability before any page is read",
    "navigate" =>
      "a navigation — the destination is refused first; the page it hands back goes through " <>
        "the gate in its own test below",
    "focus" => "refused as a browser-wide capability",
    "close" => "refused as a browser-wide capability",
    "dialog" => "answers or lists a JS dialog; needed to unblock a stuck page",
    "cookies" => "refused as a browser-wide capability",
    "download" => "refused as a browser-wide capability",
    "upload" => "a write into a file input; confined by the upload path guard",
    "act" => "one action, nine kinds — driven kind by kind below"
  }

  test "NO read verb returns content from the granted tab once its URL is private", ctx do
    grant!(ctx.grants, @blocked, title: "Instance metadata")
    pid = start_server(ctx, :attached_gate)
    assert {:ok, _} = req(pid, "start")

    read_verbs = Enum.reject(Browser.actions(), &Map.has_key?(@no_page_read, &1))
    refute read_verbs == [], "every action was exempted — the invariant would be vacuous"

    for action <- read_verbs do
      result = req(pid, action)
      rendered = inspect(result)

      refute rendered =~ @blocked, "`#{action}` returned the blocked page's address"
      refute rendered =~ "Instance metadata", "`#{action}` returned the blocked page's title"

      assert blocked_verdict?(result),
             "`#{action}` neither refused nor marked the page blocked: #{rendered}"
    end
  end

  # Two shapes of one verdict. A read verb refuses outright; `tabs` still has to
  # answer with the tab id the model needs to address it, so it carries the
  # verdict in the `page` field `act` already uses and nothing of the page.
  defp blocked_verdict?({:error, %Error{code: "read_blocked"}}), do: true
  defp blocked_verdict?({:ok, %{"tabs" => [%{"page" => "read_blocked"}]}}), do: true
  defp blocked_verdict?(_other), do: false

  # The other half: what `tabs` publishes is read live, not what the page was
  # when the person clicked the extension on it.
  test "tabs reports the live page, never the grant-time url and title", ctx do
    grant!(ctx.grants, "https://example.com/now", title: "Live title")
    pid = start_server(ctx, :attached_live_tabs)

    assert {:ok, %{"tabs" => [tab]}} = req(pid, "tabs")
    assert tab["url"] == "https://example.com/now"
    assert tab["title"] == "Live title"
  end

  test "console is a read of the granted tab, so it faces the same gate", ctx do
    grant!(ctx.grants, @blocked)
    pid = start_server(ctx, :attached_console)
    assert {:ok, _} = req(pid, "start")

    send(
      pid,
      {:cdp_event, "Runtime.consoleAPICalled",
       %{"params" => %{"type" => "log", "args" => [%{"value" => "secret from the blocked page"}]}}}
    )

    assert {:error, %Error{code: "read_blocked"}} = req(pid, "console")
  end

  @page_read_kinds %{
    "get html" => %{"kind" => "get", "field" => "html"},
    "get text" => %{"kind" => "get", "field" => "text"},
    "get rect" => %{"kind" => "get", "field" => "rect", "selector" => "canvas"},
    "wait text" => %{"kind" => "wait", "wait_until" => "text", "text" => "ami-"},
    "wait url" => %{"kind" => "wait", "wait_until" => "url", "text" => "meta-data"},
    "wait load" => %{"kind" => "wait", "wait_until" => "load"},
    "wait element" => %{"kind" => "wait", "wait_until" => "element", "selector" => "body"}
  }

  test "NO act kind returns page content from a granted tab on a private host", ctx do
    grant!(ctx.grants, @blocked)
    pid = start_server(ctx, :attached_gate_kinds)
    assert {:ok, _} = req(pid, "start")

    for {label, args} <- @page_read_kinds do
      result = req(pid, "act", Map.put(args, "timeout_ms", 50))

      assert match?({:error, %Error{code: "read_blocked"}}, result),
             "`act #{label}` did not refuse a policy-blocked URL: #{inspect(result)}"
    end
  end

  # `navigate` hands the page back now (M47 §3.6), and it is the one navigation
  # a granted tab may make — `open` stays refused as a browser-wide capability.
  # Observing is a read of the person's own tab, so it goes through the same
  # gate, on the address the page actually committed to.
  test "a navigate in the granted tab is observed through the read gate", ctx do
    grant!(ctx.grants, @blocked, title: "Instance metadata")
    pid = start_server(ctx, :attached_nav_gate)
    assert {:ok, _} = req(pid, "start")

    assert {:ok, result} = req(pid, "navigate", %{"url" => "https://example.com/allowed"})

    assert result["page"] == "read_blocked"
    assert result["page_reason"] =~ "browser policy"

    # The id stays so the tab can still be addressed; the blocked document's
    # text, address and title do not, exactly as `tabs` answers on this verdict.
    assert result["target"] =~ "tab_"

    for withheld <- ~w(snapshot url title) do
      refute Map.has_key?(result, withheld), "navigate returned the blocked page's #{withheld}"
    end
  end

  test "a navigate in the granted tab hands back the page it landed on", ctx do
    grant!(ctx.grants, "https://example.com/dash")
    pid = start_server(ctx, :attached_nav_page)
    assert {:ok, _} = req(pid, "start")

    assert {:ok, result} = req(pid, "navigate", %{"url" => "https://example.com/dash"})

    assert result["page"] == "changed"
    assert result["snapshot"] =~ ~s(@textbox_1 [textbox] "Where to?")
  end

  test "the gate does not over-block: an allowed page still reads", ctx do
    grant!(ctx.grants, "https://example.com/results")
    pid = start_server(ctx, :attached_allowed)
    assert {:ok, _} = req(pid, "start")

    assert {:ok, %{"url" => "https://example.com/results"}} = req(pid, "snapshot")
    assert {:ok, %{"mime_type" => "image/png"}} = req(pid, "screenshot")
    assert {:ok, %{"ok" => true}} = req(pid, "act", %{"kind" => "get", "field" => "html"})
  end

  # ── no browser-wide CDP command ever leaves the daemon ─────────────────────

  test "attaching a granted tab sends no Target or Browser command", ctx do
    grant!(ctx.grants, "https://example.com/results")
    pid = start_server(ctx, :attached_no_target)

    assert {:ok, _} = req(pid, "start")
    assert {:ok, _} = req(pid, "snapshot")

    for {method, _params} <- collected_cdp() do
      refute String.starts_with?(method, ["Target.", "Browser.", "Network."]),
             "`#{method}` reached the extension from a granted tab"
    end
  end

  defp collected_cdp(acc \\ []) do
    receive do
      {:cdp, method, params} -> collected_cdp([{method, params} | acc])
    after
      0 -> acc
    end
  end

  # ── only a turn the owner is present for ──────────────────────────────────

  # Each context is complete rather than merged over the attended one: a
  # scheduled run is identified by the ABSENCE of `computer_use_origin`, which a
  # merge would put straight back.
  @base %{agent_name: "main", conversation_key: {"cli", "1", :root}}
  @attended Map.merge(@base, %{source_trust: :operator, computer_use_origin: :interactive})

  @unattended [
    {"a guest", Map.merge(@base, %{source_trust: :guest, computer_use_origin: :interactive})},
    {"a scheduled run", Map.merge(@base, %{source_trust: :operator})},
    {"a detached background run",
     Map.merge(@base, %{source_trust: :operator, computer_use_origin: :unattended})},
    {"a delegated subagent", Map.put(@attended, :subagent_depth, 1)},
    {"a coding continuation", Map.put(@attended, :harness_continuation_depth, 1)},
    {"a context with no trust at all", Map.put(@base, :computer_use_origin, :interactive)}
  ]

  test "the person's own tab is refused to every turn they are not present for" do
    for {label, context} <- @unattended do
      result = Browser.execute(%{"action" => "status", "profile" => "selected_tab"}, context)

      assert match?({:error, %Error{code: "attached_tab_not_allowed"}}, result),
             "#{label} reached the granted tab: #{inspect(result)}"
    end
  end

  test "an attended owner turn reaches it, and the managed profile is untouched" do
    assert {:ok, json} =
             Browser.execute(%{"action" => "status", "profile" => "selected_tab"}, @attended)

    assert %{"profile" => "selected_tab", "running" => false} = Jason.decode!(json)

    guest = Map.merge(@base, %{source_trust: :guest, computer_use_origin: :interactive})
    assert {:ok, managed} = Browser.execute(%{"action" => "status"}, guest)
    assert %{"running" => false} = Jason.decode!(managed)
  end
end
