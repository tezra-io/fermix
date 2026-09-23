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

    alias FermixCore.Browser.Error

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

    # One text the page refuses, so a fill that fails PART WAY through a
    # `fill_form` is drivable.
    defp run(_pid, "Input.insertText", %{text: "BOOM"}),
      do: {:error, Error.new("cdp_error", "Input.insertText failed")}

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

    defp run(_pid, "Runtime.evaluate", %{expression: "window.devicePixelRatio"}),
      do: {:ok, %{"result" => %{"value" => 2}}}

    defp run(_pid, "Runtime.evaluate", %{expression: expr}) do
      cond do
        # Every page read now resolves the tab's LIVE url before it releases any
        # bytes, and an unreadable url is a refusal by design — so the double
        # has to answer this one.
        String.contains?(expr, "document.location.href") ->
          {:ok,
           %{
             "result" => %{
               "value" => %{
                 "url" => "https://example.com/results",
                 "title" => "Ex",
                 "ready" => "complete"
               }
             }
           }}

        String.contains?(expr, "getBoundingClientRect") and String.contains?(expr, "missing") ->
          {:ok, %{"result" => %{"value" => nil}}}

        String.contains?(expr, "getBoundingClientRect") ->
          {:ok,
           %{"result" => %{"value" => %{"x" => 40, "y" => 120, "width" => 480, "height" => 480}}}}

        true ->
          {:ok, %{"result" => %{"value" => nil}}}
      end
    end

    defp run(_pid, "Page.captureScreenshot", _params),
      do: {:ok, %{"data" => Base.encode64("png-bytes")}}

    defp run(_pid, _method, _params), do: {:ok, %{}}

    defp ax_nodes do
      [
        %{"nodeId" => "1", "role" => %{"value" => "RootWebArea"}, "childIds" => ["2", "3"]},
        %{
          "nodeId" => "2",
          "role" => %{"value" => "textbox"},
          "name" => %{"value" => "Where to?"},
          "backendDOMNodeId" => 42,
          "childIds" => []
        },
        %{
          "nodeId" => "3",
          "role" => %{"value" => "textbox"},
          "name" => %{"value" => "When?"},
          "backendDOMNodeId" => 43,
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

  # Chrome serves the Accessibility domain's CACHED tree if it stays enabled,
  # which lags a navigation/SPA swap — observed live: a snapshot 4s after
  # lichess navigated to the created game returned the HOMEPAGE tree under the
  # live game url. Cycling the domain forces a rebuild from the current document.
  test "snapshot cycles the Accessibility domain so the tree is never stale", %{pid: pid} do
    ready(pid)

    assert {:ok, _} = req(pid, "snapshot")

    assert_receive {:cdp, _, "Accessibility.disable", _}
    assert_receive {:cdp, _, "Accessibility.enable", _}
    assert_receive {:cdp, _, "Accessibility.getFullAXTree", _}
  end

  # Every control the snapshot text already names as `@ref [role] "name"` was
  # repeated in a `refs` array beside it, so each name was paid for twice in
  # every later turn of the conversation. The ref map stays server-side; the
  # text is the one thing the model reads.
  test "the snapshot result carries the text alone, not a second copy of the refs", %{pid: pid} do
    assert {:ok, _} = req(pid, "start")
    assert {:ok, result} = req(pid, "snapshot")

    refute Map.has_key?(result, "refs")
    assert result["snapshot"] =~ "@textbox_1 [textbox] \"Where to?\""

    # And the ref map is still there, server-side: the ref works.
    assert {:ok, %{"action" => "click"}} =
             req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})
  end

  # The snapshot prints each ref behind an `@`, and a model sends the ref back as
  # printed. The lookup wanted the bare name, so `@link_3` was refused as stale,
  # and the fresh snapshot the refusal prescribed printed `@link_3` again: four of
  # five trials of a live Wikipedia lookup ended in that loop on 2026-09-22.
  test "a ref sent back as the snapshot prints it acts on that element", %{pid: pid} do
    assert {:ok, _} = req(pid, "start")
    assert {:ok, %{"snapshot" => text}} = req(pid, "snapshot")
    [printed] = Regex.run(~r/@textbox_1\b/, text)

    assert {:ok, %{"action" => "fill", "value" => "Amsterdam"}} =
             req(pid, "act", %{"kind" => "fill", "ref" => printed, "text" => "Amsterdam"})

    assert {:ok, %{"action" => "click"}} = req(pid, "act", %{"kind" => "click", "ref" => printed})
  end

  test "fill_form takes its refs as the snapshot prints them", %{pid: pid} do
    ready(pid)

    assert {:ok, %{"action" => "fill_form"}} =
             req(pid, "act", %{
               "kind" => "fill_form",
               "fields" => [
                 %{"ref" => "@textbox_1", "text" => "Paris"},
                 %{"ref" => "@textbox_2", "text" => "Rome"}
               ]
             })

    assert_receive {:cdp, _, "Input.insertText", %{text: "Paris"}}
    assert_receive {:cdp, _, "Input.insertText", %{text: "Rome"}}
  end

  # The facade refuses a ref that is not a string, but the server is also called
  # directly. A bad ref is an error for that call, never a crash of the profile.
  test "a ref that is not a string is refused and the profile keeps serving", %{pid: pid} do
    ready(pid)

    assert {:error, %{code: "invalid_arg"}} =
             req(pid, "act", %{"kind" => "click", "ref" => nil})

    assert Process.alive?(pid)

    assert {:ok, %{"action" => "click"}} =
             req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})
  end

  # A ref below the fold clicked at its box-model center dispatches into nothing
  # and reports success. Scroll it into view first (a no-op when already visible).
  test "a ref click scrolls the element into view before reading its box", %{pid: pid} do
    ready(pid)

    assert {:ok, _result} = req(pid, "act", %{"kind" => "click", "ref" => "textbox_1"})

    assert_receive {:cdp, _, "DOM.scrollIntoViewIfNeeded", %{backendNodeId: 42}}
    assert_receive {:cdp, _, "DOM.getBoxModel", %{backendNodeId: 42}}
  end

  # The deterministic route onto a canvas-like surface (a chess board): read the
  # element's geometry, then click square centers with click_coords — same CSS
  # viewport space, no pixel guessing, no dependency on window position.
  test "get field=rect returns the first match's viewport box", %{pid: pid} do
    ready(pid)

    assert {:ok, %{"value" => rect}} =
             req(pid, "act", %{"kind" => "get", "field" => "rect", "selector" => "cg-board"})

    assert rect == %{"x" => 40, "y" => 120, "width" => 480, "height" => 480}
  end

  test "get field=rect on a selector with no match is a typed not_found", %{pid: pid} do
    ready(pid)

    assert {:error, error} =
             req(pid, "act", %{"kind" => "get", "field" => "rect", "selector" => ".missing"})

    assert error.code == "not_found"
  end

  test "click_coords returns a url receipt like ref clicks do", %{pid: pid} do
    ready(pid)

    assert {:ok, %{"action" => "click_coords", "url" => "https://example.com/results"}} =
             req(pid, "act", %{"kind" => "click_coords", "x" => 10, "y" => 20})
  end

  # The two screenshots a model can aim from live in different spaces (CSS
  # viewport vs device pixels); the ratio is what converts between them.
  test "screenshot reports the device pixel ratio", %{pid: pid} do
    ready(pid)

    assert {:ok, %{"device_pixel_ratio" => 2}} = req(pid, "screenshot", %{})
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

  # M47 §3.5: a five-field form used to be five model turns. One call, one
  # receipt per field, in order.
  test "fill_form fills every field in order and receipts each one", %{pid: pid} do
    ready(pid)

    assert {:ok, result} =
             req(pid, "act", %{
               "kind" => "fill_form",
               "fields" => [
                 %{"ref" => "textbox_1", "text" => "Paris"},
                 %{"ref" => "textbox_2", "text" => "Rome"}
               ]
             })

    assert result["action"] == "fill_form"

    assert result["filled"] == [
             %{"ref" => "textbox_1", "value" => "Paris"},
             %{"ref" => "textbox_2", "value" => "Rome"}
           ]

    # A fill is not a page-changing action, so it does not observe.
    refute Map.has_key?(result, "page")

    assert_receive {:cdp, _, "Input.insertText", %{text: "Paris"}}
    assert_receive {:cdp, _, "Input.insertText", %{text: "Rome"}}
  end

  # A form half filled from a stale snapshot is worse than one not filled at
  # all: the model cannot tell which fields took. So every ref is checked before
  # the first keystroke.
  test "an unknown ref refuses the whole call before any input", %{pid: pid} do
    ready(pid)

    assert {:error, error} =
             req(pid, "act", %{
               "kind" => "fill_form",
               "fields" => [
                 %{"ref" => "textbox_1", "text" => "Paris"},
                 %{"ref" => "textbox_9", "text" => "Rome"}
               ]
             })

    assert error.code == "stale_ref"
    assert error.message =~ "textbox_9"
    refute error.message =~ "textbox_1"
    refute_received {:cdp, _, "Input.insertText", _params}
  end

  # The facade is what teaches the shape, but a call that reaches the server
  # without it must not be told this kind does not exist — the same floor
  # `webmcp` keeps under a missing `op`.
  test "a fill_form with no fields names the argument, not a missing kind", %{pid: pid} do
    ready(pid)

    assert {:error, error} = req(pid, "act", %{"kind" => "fill_form"})

    assert error.code == "missing_arg"
    assert error.message =~ "fields"
    refute error.message =~ "Unsupported act kind"
  end

  # The floor has to hold for every shape, not just the missing one: a non-map
  # entry raised inside the ref check, and a nil `text` would have been typed
  # into the page. Both are refused before any input, in the facade's words.
  test "a fill_form entry that is not a ref and a text is refused before any input", %{pid: pid} do
    ready(pid)

    malformed = [
      {[%{"ref" => "textbox_1", "text" => "Paris"}, "textbox_2"], "field 2"},
      {[%{"ref" => "textbox_1"}], "field 1"},
      {[%{"ref" => "textbox_1", "text" => nil}], "field 1"},
      {[%{"text" => "Paris"}], "field 1"},
      {[%{"ref" => "", "text" => "Paris"}], "field 1"}
    ]

    for {fields, named} <- malformed do
      assert {:error, error} = req(pid, "act", %{"kind" => "fill_form", "fields" => fields})

      assert error.code == "invalid_arg", "#{inspect(fields)} was not refused"
      assert error.message =~ named
      refute_received {:cdp, _, "Input.insertText", _params}
    end
  end

  test "a direct fill_form is still capped at twelve fields", %{pid: pid} do
    ready(pid)

    fields = Enum.map(1..13, &%{"ref" => "textbox_1", "text" => "x#{&1}"})

    assert {:error, error} = req(pid, "act", %{"kind" => "fill_form", "fields" => fields})

    assert error.code == "invalid_arg"
    assert error.message =~ "12"
    refute_received {:cdp, _, "Input.insertText", _params}
  end

  test "a mid-list failure stops there and reports the index and what was filled", %{pid: pid} do
    ready(pid)

    assert {:error, error} =
             req(pid, "act", %{
               "kind" => "fill_form",
               "fields" => [
                 %{"ref" => "textbox_1", "text" => "Paris"},
                 %{"ref" => "textbox_2", "text" => "BOOM"},
                 %{"ref" => "textbox_1", "text" => "Never typed"}
               ]
             })

    assert error.details["failed_index"] == 1
    assert error.details["filled"] == ["textbox_1"]

    # The call stopped at the failure.
    refute_received {:cdp, _, "Input.insertText", %{text: "Never typed"}}
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
