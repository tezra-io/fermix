defmodule FermixCore.Browser.BrowserObserveTest do
  # M47 §3.1: after a click, a submit, an Enter or a click_coords, `act` reports
  # whether the page changed and hands back the fresh snapshot when it did, so a
  # structural change no longer costs a whole extra model turn to look again.
  #
  # async: false — the fake page is a named Agent (ProfileServer starts the
  # connection itself and never hands its pid back) and the dispatched CDP
  # commands are reported to a registered collector.
  use ExUnit.Case, async: false

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.ProfileServer

  @page :observe_fake_page
  @collector :observe_cdp_collector

  # A page the TEST steers: its accessibility tree, its live url, its ready
  # states and whether the Accessibility domain answers at all are read out of
  # the Agent, so a test can change the page between calls exactly as a real
  # click would.
  defmodule Page do
    use Agent

    alias FermixCore.Browser.Error

    # `url` and `ready` are QUEUES read by the live-URL probe, oldest first, and
    # the last entry sticks: that is how a page that commits a navigation a
    # moment after the click, or reaches "complete" a poll later, is driven.
    # Everything else (the tab list, the action's own `location.href` receipt)
    # reads the head, which is exactly the stale sample a receipt takes before
    # the navigation commits.
    def start_link(_url, opts) do
      state = %{
        owner: Keyword.get(opts, :owner),
        tree: :before,
        url: ["https://example.com/form"],
        ready: ["complete"],
        ax: :ok,
        href: :ok,
        probes: 0
      }

      Agent.start_link(fn -> state end, name: :observe_fake_page)
    end

    def close(pid), do: Agent.stop(pid)

    def command(pid, method, params, _session_id, timeout_ms, _grace_ms) do
      page = Agent.get(pid, & &1)

      if collector = Process.whereis(:observe_cdp_collector) do
        send(collector, {:cdp, method, params, timeout_ms})
      end

      run(pid, page, method, params)
    end

    defp run(_pid, page, "Target.getTargets", _params) do
      {:ok,
       %{
         "targetInfos" => [
           %{"targetId" => "T1", "type" => "page", "url" => current(page.url), "title" => "Form"}
         ]
       }}
    end

    defp run(_pid, _page, "Target.attachToTarget", _params), do: {:ok, %{"sessionId" => "S1"}}

    defp run(_pid, %{ax: :error}, "Accessibility.getFullAXTree", _params),
      do: {:error, Error.new("cdp_timeout", "Accessibility.getFullAXTree timed out")}

    # Two replies that succeed and carry no tree: no key at all, and the key
    # present and null. The second one matches `%{"nodes" => nodes}` and only
    # dies later, inside the renderer's own guard.
    defp run(_pid, %{ax: :malformed}, "Accessibility.getFullAXTree", _params), do: {:ok, %{}}

    defp run(_pid, %{ax: :null_nodes}, "Accessibility.getFullAXTree", _params),
      do: {:ok, %{"nodes" => nil}}

    defp run(_pid, page, "Accessibility.getFullAXTree", _params),
      do: {:ok, %{"nodes" => ax_nodes(page.tree)}}

    defp run(_pid, _page, "DOM.getBoxModel", _params),
      do: {:ok, %{"model" => %{"content" => [0, 0, 20, 0, 20, 20, 0, 20]}}}

    defp run(_pid, _page, "DOM.resolveNode", _params),
      do: {:ok, %{"object" => %{"objectId" => "OBJ1"}}}

    defp run(_pid, _page, "Runtime.callFunctionOn", %{functionDeclaration: declaration}) do
      if String.contains?(declaration, "querySelector"),
        do: {:ok, %{"result" => %{"value" => "Search"}}},
        else: {:ok, %{"result" => %{"value" => "typed"}}}
    end

    # The action's own receipt read, which a blocked or busy page can fail
    # independently of the live-URL probe the gate uses.
    defp run(_pid, %{href: :error}, "Runtime.evaluate", %{expression: "location.href"}),
      do: {:error, Error.new("cdp_timeout", "Runtime.evaluate timed out")}

    defp run(_pid, page, "Runtime.evaluate", %{expression: "location.href"}),
      do: {:ok, %{"result" => %{"value" => current(page.url)}}}

    defp run(pid, page, "Runtime.evaluate", %{expression: expression}) do
      if String.contains?(expression, "document.location.href") do
        live_meta(pid, page)
      else
        {:ok, %{"result" => %{"value" => nil}}}
      end
    end

    defp run(_pid, _page, _method, _params), do: {:ok, %{}}

    # One probe of the live URL: it reports the heads of both queues and then
    # advances them, and it counts itself so a test can bound the poll loop.
    defp live_meta(pid, page) do
      meta = %{"url" => current(page.url), "title" => "Form", "ready" => current(page.ready)}

      Agent.update(pid, fn state ->
        %{state | url: advance(state.url), ready: advance(state.ready), probes: state.probes + 1}
      end)

      {:ok, %{"result" => %{"value" => meta}}}
    end

    defp current([head | _rest]), do: head
    defp advance([last]), do: [last]
    defp advance([_head | rest]), do: rest

    defp ax_nodes(:before) do
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

    # The same tree, re-mounted: identical roles and names — so identical
    # snapshot text — behind brand new backend node ids. A routine framework
    # re-render after a click looks exactly like this.
    defp ax_nodes(:remounted) do
      [
        %{"nodeId" => "1", "role" => %{"value" => "RootWebArea"}, "childIds" => ["2"]},
        %{
          "nodeId" => "2",
          "role" => %{"value" => "textbox"},
          "name" => %{"value" => "Where to?"},
          "backendDOMNodeId" => 99,
          "childIds" => []
        }
      ]
    end

    defp ax_nodes(:after) do
      [
        %{"nodeId" => "1", "role" => %{"value" => "RootWebArea"}, "childIds" => ["2"]},
        %{
          "nodeId" => "2",
          "role" => %{"value" => "button"},
          "name" => %{"value" => "Book this flight"},
          "backendDOMNodeId" => 77,
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

  setup do
    Process.register(self(), @collector)
    {:ok, config} = Config.current()

    pid =
      start_supervised!(
        {ProfileServer,
         owner_key: "owner-observe",
         profile_name: "fermix",
         profile: %{cdp_url: "ws://fake/observe"},
         config: config,
         launcher: NoLauncher,
         connection: Page}
      )

    on_exit(fn -> if Process.whereis(@collector), do: Process.unregister(@collector) end)

    %{pid: pid, config: config}
  end

  defp req(pid, action, args \\ %{}),
    do: ProfileServer.request(pid, %{action: action, args: args, context: %{agent_name: "t"}})

  defp snapshotted(pid) do
    assert {:ok, _} = req(pid, "start")
    assert {:ok, _} = req(pid, "snapshot")
    flush_cdp()
  end

  defp change_page, do: Agent.update(@page, &%{&1 | tree: :after})

  defp flush_cdp do
    receive do
      {:cdp, _method, _params, _timeout} -> flush_cdp()
    after
      0 -> :ok
    end
  end

  defp drain_cdp(acc \\ []) do
    receive do
      {:cdp, method, _params, timeout} -> drain_cdp([{method, timeout} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The whole point: a click that restructures the page hands back the new
  # snapshot in the same result, and the refs it names are the ones now live.
  test "a click that changes the page returns the fresh snapshot and swaps the refs", %{pid: pid} do
    snapshotted(pid)
    change_page()

    assert {:ok, result} = req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})

    assert result["page"] == "changed"
    assert result["snapshot"] =~ "@button_1 [button] \"Book this flight\""
    assert result["truncated"] == false
    assert result["url"] == "https://example.com/form"
    assert is_list(result["tabs"])

    # The ref map was replaced exactly as a `snapshot` call would replace it:
    # the new ref works and the one it superseded is stale.
    assert {:ok, _} = req(pid, "act", %{"kind" => "click", "ref" => "button_1"})

    assert {:error, %Error{code: "stale_ref"}} =
             req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})
  end

  # `unchanged` is the model's licence to keep using the refs it already has,
  # which is what saves the turn.
  test "a click that changes nothing says so and leaves the refs valid", %{pid: pid} do
    snapshotted(pid)

    assert {:ok, result} = req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})

    assert result["page"] == "unchanged"
    refute Map.has_key?(result, "snapshot")

    assert {:ok, %{"page" => "unchanged"}} =
             req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})
  end

  # Identical text means identical ref NAMES in identical order, so the model's
  # refs are unchanged from where it sits — but a framework re-render leaves the
  # ids behind them dead. Re-pointing the map at the live nodes is what keeps
  # the next act from failing on a page that, to the model, did not change.
  test "unchanged still re-points the refs at the live nodes", %{pid: pid} do
    snapshotted(pid)
    Agent.update(@page, &%{&1 | tree: :remounted})

    assert {:ok, %{"page" => "unchanged"} = result} =
             req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})

    refute Map.has_key?(result, "snapshot")
    flush_cdp()

    assert {:ok, _} = req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})
    assert_received {:cdp, "DOM.getBoxModel", %{backendNodeId: 99}, _timeout}
  end

  # The receipt samples `location.href` before the navigation commits, and the
  # observation then waits for and renders the page it commits TO. Reporting the
  # sampled address beside the new page's snapshot names the wrong page.
  test "a settled observation reports the address it settled on", %{pid: pid} do
    snapshotted(pid)
    change_page()

    Agent.update(
      @page,
      &%{&1 | url: ["https://example.com/form", "https://example.com/results"]}
    )

    assert {:ok, %{"page" => "changed"} = result} =
             req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})

    assert result["url"] == "https://example.com/results"
  end

  # `press` carried no url at all, so an Enter that submitted a form left the
  # model with nothing to confirm the navigation from.
  test "an observed Enter reports the settled url too", %{pid: pid} do
    snapshotted(pid)

    Agent.update(
      @page,
      &%{&1 | url: ["https://example.com/form", "https://example.com/results"]}
    )

    assert {:ok, result} = req(pid, "act", %{"kind" => "press", "key" => "Enter"})

    assert result["url"] == "https://example.com/results"
  end

  test "submit and click_coords observe too", %{pid: pid} do
    snapshotted(pid)

    assert {:ok, %{"page" => "unchanged", "submitted" => "Search"}} =
             req(pid, "act", %{"kind" => "submit", "ref" => "textbox_1"})

    change_page()

    assert {:ok, %{"page" => "changed"} = result} =
             req(pid, "act", %{"kind" => "click_coords", "x" => 10, "y" => 20})

    assert result["snapshot"] =~ "Book this flight"
  end

  # An arrow key or Tab moves focus, which changes the accessibility tree — so
  # observing every press would hand back a full snapshot per keystroke.
  test "press observes Enter and nothing else", %{pid: pid} do
    snapshotted(pid)

    assert {:ok, enter} = req(pid, "act", %{"kind" => "press", "key" => "Enter"})
    assert enter["page"] == "unchanged"

    flush_cdp()
    assert {:ok, tab} = req(pid, "act", %{"kind" => "press", "key" => "Tab"})
    refute Map.has_key?(tab, "page")
    refute_received {:cdp, "Accessibility.getFullAXTree", _params, _timeout}
  end

  # Filling rarely changes structure, and five fills must not mean five
  # snapshots.
  test "fill, type and hover keep today's result", %{pid: pid} do
    snapshotted(pid)

    for kind <- ~w(fill type hover) do
      assert {:ok, result} =
               req(pid, "act", %{"kind" => kind, "ref" => "textbox_1", "text" => "Rome"})

      refute Map.has_key?(result, "page"), "`#{kind}` observed the page"
    end
  end

  # A canvas driven purely by click_coords never asked for a snapshot; handing
  # it one it did not ask for is the cost this item exists to remove.
  test "a tab with no snapshot is never handed one", %{pid: pid, config: config} do
    assert {:ok, _} = req(pid, "start")
    flush_cdp()

    assert {:ok, result} = req(pid, "act", %{"kind" => "click_coords", "x" => 10, "y" => 20})

    refute Map.has_key?(result, "page")
    refute Map.has_key?(result, "snapshot")
    refute_received {:cdp, "Accessibility.getFullAXTree", _params, _timeout}

    # And with no observation to pay for, the receipt keeps the full action
    # budget: the shortened budget applies only where it buys something.
    assert_received {:cdp, "Runtime.evaluate", %{expression: "location.href"}, timeout}
    assert timeout == config.action_timeout_ms
  end

  # The mouse event has already been dispatched by the time the receipt is read,
  # so a receipt that fails must not report the click as failed — the same rule
  # every other receipt in this file follows.
  test "a click_coords whose receipt read fails still reports the click", %{pid: pid} do
    assert {:ok, _} = req(pid, "start")
    Agent.update(@page, &%{&1 | href: :error})

    assert {:ok, result} = req(pid, "act", %{"kind" => "click_coords", "x" => 10, "y" => 20})

    assert result["ok"] == true
    assert result["action"] == "click_coords"
    refute Map.has_key?(result, "url")
  end

  # `ref_maps` is cleared when the browser goes away; the mark beside it is the
  # same fact about the same tab and must go with it, or a click on a restarted
  # profile observes against a page nobody ever looked at.
  test "stopping the browser forgets what the model was shown", %{pid: pid} do
    snapshotted(pid)

    assert {:ok, _} = req(pid, "stop")
    assert {:ok, _} = req(pid, "start")
    flush_cdp()

    assert {:ok, result} = req(pid, "act", %{"kind" => "click_coords", "x" => 10, "y" => 20})

    refute Map.has_key?(result, "page")
    refute_received {:cdp, "Accessibility.getFullAXTree", _params, _timeout}
  end

  # The click has already happened by the time the observation runs, so an
  # observation failure that failed the action would say the wrong thing.
  test "an observation that fails does not fail the action", %{pid: pid} do
    snapshotted(pid)
    Agent.update(@page, &%{&1 | ax: :error})

    assert {:ok, result} = req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})

    assert result["ok"] == true
    assert result["page"] == "unobserved"
    assert result["url"] == "https://example.com/form"
    refute Map.has_key?(result, "snapshot")

    # The refs it already had were not touched, so it can still act.
    Agent.update(@page, &%{&1 | ax: :ok})

    assert {:ok, %{"action" => "click"}} =
             req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})
  end

  # The click already happened, so a reply the renderer cannot read must not
  # take the profile down with it — every way of not seeing the page is
  # `unobserved`.
  test "a reply the renderer cannot use is unobserved, not a crash", %{pid: pid} do
    snapshotted(pid)
    Agent.update(@page, &%{&1 | ax: :malformed})

    assert {:ok, %{"ok" => true, "page" => "unobserved"}} =
             req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})

    assert Process.alive?(pid)
  end

  # A `"nodes" => null` reply matches the shape the render step destructures and
  # only dies inside `Snapshot.render/2`'s own guard — the same crash after a
  # click, for the one shape the typed refusal missed.
  test "a null accessibility tree is unobserved, not a crash", %{pid: pid} do
    snapshotted(pid)
    Agent.update(@page, &%{&1 | ax: :null_nodes})

    assert {:ok, %{"ok" => true, "page" => "unobserved"}} =
             req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})

    assert Process.alive?(pid)

    # And the same reply to a plain `snapshot` is a typed refusal, not a raise.
    assert {:error, %Error{code: "snapshot_unavailable"}} = req(pid, "snapshot")
    assert Process.alive?(pid)
  end

  test "the observation waits for the document to be complete", %{pid: pid} do
    snapshotted(pid)
    Agent.update(@page, &%{&1 | ready: ["loading", "loading", "complete"]})
    change_page()

    assert {:ok, %{"page" => "changed"}} =
             req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})
  end

  # A document that never reaches "complete" is routine (a hung subresource, a
  # streaming response). It answers every probe instantly, so nothing but an
  # explicit deadline ends the poll — and `request/2` is an :infinity call, so
  # an unbounded loop is a wedged profile, not a slow one.
  test "a page that never settles gives up inside the budget", %{pid: pid} do
    snapshotted(pid)
    Agent.update(@page, &%{&1 | ready: ["loading"], probes: 0})

    started = System.monotonic_time(:millisecond)
    assert {:ok, result} = req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})
    elapsed = System.monotonic_time(:millisecond) - started

    assert result["ok"] == true
    assert result["page"] == "unobserved"

    budget = Config.act_limits().settle_budget_ms
    assert elapsed < budget * 2, "the settle loop ran for #{elapsed} ms"

    probes = Agent.get(@page, & &1.probes)
    max_probes = div(budget, 100) + 2
    assert probes <= max_probes, "the settle loop probed #{probes} times"
    assert probes > 1, "the settle loop never polled at all"
  end

  # A page holding a JS dialog answers nothing, and a dialog opened by the click
  # itself is invisible to this callback — so every command from the action's own
  # receipt onwards carries what is LEFT of the budget, never the 8 s action
  # timeout. (The real ceiling is the budget plus one poll plus the CDP response
  # grace per command; what is asserted here is that no command gets more.)
  test "every command after the action is bounded by the settle budget", %{
    pid: pid,
    config: config
  } do
    snapshotted(pid)
    budget = Config.act_limits().settle_budget_ms
    assert config.action_timeout_ms > budget

    assert {:ok, _} = req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})

    observed = drain_cdp()

    bounded =
      ~w(Runtime.evaluate Accessibility.disable Accessibility.enable Accessibility.getFullAXTree)

    for method <- bounded do
      timeouts = for {^method, timeout} <- observed, do: timeout
      refute timeouts == [], "`#{method}` was never dispatched after the action"

      for timeout <- timeouts do
        assert timeout <= budget,
               "`#{method}` was given #{timeout} ms, not the #{budget} ms settle budget"
      end
    end
  end
end
