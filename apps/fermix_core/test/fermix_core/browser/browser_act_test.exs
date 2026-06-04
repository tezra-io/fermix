defmodule FermixCore.Browser.BrowserActTest do
  # Drives the real act path (handle_act -> run_ref_action) through an injected
  # fake CDP connection, asserting the exact CDP methods each verb dispatches.
  # async: false — it registers a global collector name for the dispatched calls.
  use ExUnit.Case, async: false

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.ProfileServer

  # Records every dispatched CDP method to the registered collector and returns
  # canned shapes sufficient for attach -> snapshot -> act to succeed.
  defmodule FakeConnection do
    use Agent

    # The field starts pre-filled with "Rome" so the tests prove REPLACE vs
    # APPEND behaviorally: fill must yield "Amsterdam"; type must yield
    # "RomeAmsterdam" (the original bug — now the intended `type` semantics).
    def start_link(_url, opts),
      do: Agent.start_link(fn -> %{owner: Keyword.get(opts, :owner), value: "Rome"} end)

    def close(pid), do: Agent.stop(pid)

    def command(pid, method, params, _session_id, _timeout_ms, _grace_ms) do
      owner = Agent.get(pid, & &1.owner)
      if c = Process.whereis(:fake_cdp_collector), do: send(c, {:cdp, owner, method, params})
      run(pid, method, params)
    end

    defp run(_pid, "Target.getTargets", _params) do
      {:ok,
       %{
         "targetInfos" => [
           %{
             "targetId" => "T1",
             "type" => "page",
             "url" => "https://example.com",
             "title" => "Ex"
           },
           # a stray blank popup that MUST be filtered out (not tracked) — if it
           # weren't, two targets would make resolve_tab(nil) ambiguous and break
           # every fill/type/submit/click test below.
           %{"targetId" => "POP", "type" => "page", "url" => "about:blank", "title" => ""}
         ]
       }}
    end

    defp run(_pid, "Target.attachToTarget", _params), do: {:ok, %{"sessionId" => "S1"}}
    defp run(_pid, "Accessibility.getFullAXTree", _params), do: {:ok, %{"nodes" => ax_nodes()}}

    defp run(_pid, "DOM.getBoxModel", _params),
      do: {:ok, %{"model" => %{"content" => [0, 0, 20, 0, 20, 20, 0, 20]}}}

    defp run(_pid, "DOM.resolveNode", _params), do: {:ok, %{"object" => %{"objectId" => "OBJ1"}}}

    # insertText APPENDS at the cursor — exactly the real CDP behavior.
    defp run(pid, "Input.insertText", %{text: text}) do
      Agent.update(pid, fn s -> %{s | value: (s.value || "") <> text} end)
      {:ok, %{}}
    end

    # submit JS uses querySelector; read-receipt JS has "return this.value"; clear JS
    # sets value="" (matches neither).
    defp run(pid, "Runtime.callFunctionOn", %{functionDeclaration: fd}) do
      cond do
        String.contains?(fd, "querySelector") ->
          {:ok, %{"result" => %{"value" => "Search"}}}

        String.contains?(fd, "return this.value") ->
          {:ok, %{"result" => %{"value" => Agent.get(pid, & &1.value)}}}

        true ->
          Agent.update(pid, fn s -> %{s | value: ""} end)
          {:ok, %{"result" => %{}}}
      end
    end

    defp run(_pid, "Runtime.evaluate", %{expression: "location.href"}),
      do: {:ok, %{"result" => %{"value" => "https://example.com/results"}}}

    defp run(_pid, _method, _params), do: {:ok, %{}}

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

  defmodule BlankOnlyConnection do
    use Agent

    def start_link(_url, opts),
      do: Agent.start_link(fn -> %{owner: Keyword.get(opts, :owner)} end)

    def close(pid), do: Agent.stop(pid)

    def command(_pid, "Target.getTargets", _params, _session_id, _timeout_ms, _grace_ms) do
      {:ok,
       %{
         "targetInfos" => [
           %{"targetId" => "BLANK", "type" => "page", "url" => "about:blank", "title" => ""}
         ]
       }}
    end

    def command(_pid, _method, _params, _session_id, _timeout_ms, _grace_ms), do: {:ok, %{}}
  end

  defmodule NoLauncher do
    def attach(_config, _profile, _owner, _name), do: :none
    def start(_config, _profile, _owner, _name), do: {:error, :unused}
    def stop(_runtime, _config), do: :ok
  end

  setup do
    Process.register(self(), :fake_cdp_collector)
    {:ok, config} = Config.current()

    pid =
      start_supervised!(
        {ProfileServer,
         owner_key: "owner-test",
         profile_name: "fermix",
         profile: %{cdp_url: "ws://fake/devtools/browser/x"},
         config: config,
         launcher: NoLauncher,
         connection: FakeConnection}
      )

    on_exit(fn ->
      if Process.whereis(:fake_cdp_collector), do: Process.unregister(:fake_cdp_collector)
    end)

    %{pid: pid}
  end

  defp req(pid, action, args \\ %{}),
    do: ProfileServer.request(pid, %{action: action, args: args, context: %{agent_name: "t"}})

  defp flush_cdp do
    receive do
      {:cdp, _, _, _} -> flush_cdp()
    after
      0 -> :ok
    end
  end

  defp ready(pid) do
    assert match?({:ok, _}, req(pid, "start"))
    assert match?({:ok, _}, req(pid, "snapshot"))
    flush_cdp()
  end

  test "fill REPLACES: clears the field via the resolved node before inserting", %{pid: pid} do
    ready(pid)

    assert {:ok, %{"action" => "fill", "value" => "Amsterdam"}} =
             req(pid, "act", %{"kind" => "fill", "ref" => "textbox_1", "text" => "Amsterdam"})

    # the clear happens on the exact targeted node, then the text is inserted
    assert_receive {:cdp, _, "DOM.resolveNode", %{backendNodeId: 42}}
    assert_receive {:cdp, _, "Runtime.callFunctionOn", %{functionDeclaration: fd}}
    assert fd =~ "value"
    assert_receive {:cdp, _, "Input.insertText", %{text: "Amsterdam"}}
    # and never the old broken keystroke select-all (Ctrl+Shift+A)
    refute_received {:cdp, _, "Input.dispatchKeyEvent", _}
  end

  test "type APPENDS: 'Rome' + type 'Amsterdam' = 'RomeAmsterdam' (no clear)", %{pid: pid} do
    ready(pid)

    # The field already holds "Rome"; `type` appends — reproducing the old
    # concatenation ON PURPOSE for this verb (`fill` is the one that replaces).
    assert {:ok, %{"action" => "type", "value" => "RomeAmsterdam"}} =
             req(pid, "act", %{"kind" => "type", "ref" => "textbox_1", "text" => "Amsterdam"})

    assert_receive {:cdp, _, "Input.insertText", %{text: "Amsterdam"}}
  end

  test "click returns a url receipt so the agent can confirm navigation", %{pid: pid} do
    ready(pid)

    assert {:ok, %{"action" => "click", "url" => "https://example.com/results"}} =
             req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})
  end

  test "submit finds and clicks the form's primary control, returns label + url", %{pid: pid} do
    ready(pid)

    assert {:ok,
            %{
              "action" => "submit",
              "submitted" => "Search",
              "url" => "https://example.com/results"
            }} = req(pid, "act", %{"kind" => "submit", "ref" => "textbox_1"})
  end

  test "about:blank popups are filtered — only the real page is tracked", %{pid: pid} do
    assert {:ok, _} = req(pid, "start")
    assert {:ok, %{"tabs" => tabs}} = req(pid, "tabs")
    assert length(tabs) == 1
  end

  test "about:blank startup tab is tracked when it is the only page target" do
    {:ok, config} = Config.current()

    pid =
      start_supervised!(
        {ProfileServer,
         owner_key: "owner-blank-test",
         profile_name: "fermix",
         profile: %{cdp_url: "ws://fake/devtools/browser/blank"},
         config: config,
         launcher: NoLauncher,
         connection: BlankOnlyConnection},
        id: :blank_only_profile_server
      )

    assert {:ok, _} = req(pid, "start")
    assert {:ok, %{"tabs" => [%{"url" => "about:blank"}]}} = req(pid, "tabs")
  end
end
