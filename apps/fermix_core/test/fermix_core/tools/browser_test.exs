defmodule FermixCore.Tools.BrowserTest do
  use ExUnit.Case, async: false

  alias FermixCore.Browser.Scope
  alias FermixCore.Tools.Browser

  # A ProfileServer stand-in registered in the production registry under one
  # conversation's owner key, so `ProfileManager.dispatch/6` finds it on the
  # lock-free lookup and never starts a real profile. This is what lets a test
  # drive `Tools.Browser.execute/2` all the way through dispatch with no Chrome:
  # the manager consults its GenServer (and the launcher) only on a cold start.
  defmodule StubProfileServer do
    use GenServer

    def start_link(opts) do
      key = Keyword.fetch!(opts, :key)
      now = System.monotonic_time(:millisecond)
      registry = FermixCore.Browser.Registry
      GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {registry, key, now}})
    end

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_call({:request, %{args: args}}, _from, state),
      do: {:reply, {:ok, %{"ok" => true, "served" => Map.get(args, "name")}}, state}
  end

  # Unique chat id so the owner_key digest cannot collide with another test's
  # registration in the shared FermixCore.Browser.Registry.
  @chat_id "chat-#{System.unique_integer([:positive])}"
  @context %{agent_name: "test_agent", conversation_key: {"cli", @chat_id, :root}}

  describe "name/0" do
    test "returns browser" do
      assert Browser.name() == "browser"
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      desc = Browser.description()
      assert is_binary(desc)
      assert byte_size(desc) > 0
      refute desc =~ "agent-browser"
    end
  end

  # The turn `act` now saves is only saved if the model knows not to snapshot
  # again after a result that already carries the page. Steering that nobody
  # asserts rots silently.
  describe "steering for the post-action page report" do
    test "the prompt surface teaches `page` and one fill_form per form" do
      guidance = Browser.description() <> " " <> Browser.when_to_use()

      for word <-
            ~w(changed unchanged unobserved read_blocked read_origin_blocked page_reason
               click_coords fill_form) do
        assert guidance =~ word, "the prompt surface never mentions `#{word}`"
      end
    end

    # The precondition is the half a model cannot guess: a first click on a tab
    # it has never snapshotted returns no `page` key at all, and a model that
    # reads its absence as "nothing changed" stops looking.
    test "both halves of the prompt state that `page` needs a prior snapshot" do
      assert Browser.description() =~ "already snapshotted"
      assert Browser.when_to_use() =~ "already snapshotted"
    end

    test "both read refusals are documented as act outcomes, not only refusals" do
      for tag <- ~w(read_blocked read_origin_blocked) do
        %{description: description} = Enum.find(Browser.failure_modes(), &(&1.tag == tag))

        assert description =~ "act", "`#{tag}` is an act `page` value and does not say so"
      end
    end
  end

  describe "parameters/0" do
    test "returns flat JSON Schema with action as required" do
      params = Browser.parameters()
      assert params.type == "object"
      assert "action" in params.required
      assert Map.has_key?(params.properties, :action)
      refute Map.has_key?(params.properties, :headless)
    end

    test "includes native browser actions and snapshot options" do
      params = Browser.parameters()
      actions = params.properties.action.enum

      for action <-
            ~w(doctor status start stop open navigate snapshot tabs focus close screenshot act pdf console dialog cookies storage upload download webmcp) do
        assert action in actions
      end

      assert Map.has_key?(params.properties, :url)
      assert Map.has_key?(params.properties, :path)
      assert Map.has_key?(params.properties, :field)
      assert Map.has_key?(params.properties, :value)
      assert Map.has_key?(params.properties, :decision)
      assert Map.has_key?(params.properties, :format)
      assert Map.has_key?(params.properties, :quality)
      assert Map.has_key?(params.properties, :full_page)
      assert Map.has_key?(params.properties, :timeout_ms)
      assert Map.has_key?(params.properties, :interactive)
      assert Map.has_key?(params.properties, :compact)
      assert Map.has_key?(params.properties, :depth)
      assert Map.has_key?(params.properties, :include_urls)
    end

    # The model cannot call an argument it cannot see: `fill_form` is only worth
    # having if `fields` is in the schema beside the kind that reads it.
    test "carries the fill_form fields, and names the kind that takes them" do
      params = Browser.parameters()

      assert params.properties.fields.type == "array"
      assert params.properties.fields.items.type == "object"
      assert Map.has_key?(params.properties.fields.items.properties, :ref)
      assert Map.has_key?(params.properties.fields.items.properties, :text)
      assert params.properties.kind.description =~ "fill_form"
    end

    test "carries the webmcp arguments, with op as a closed enum" do
      params = Browser.parameters()

      assert params.properties.op.enum == ["list", "call"]
      assert params.properties.name.type == "string"
      assert params.properties.input.type == "object"
    end
  end

  describe "failure_modes/0" do
    test "names every refusal the new paths can return" do
      tags = Enum.map(Browser.failure_modes(), & &1.tag)

      for tag <- ~w(outcome_unknown webmcp_unavailable webmcp_unknown_tool webmcp_tool_threw
                    webmcp_timeout) do
        assert tag in tags, "`#{tag}` is returnable but undocumented"
      end
    end
  end

  describe "execute/2 - validation" do
    test "returns error for missing action parameter" do
      assert {:ok, result} = Browser.execute(%{}, @context)
      assert result.success == false
      assert result.error =~ "Missing required parameter: action"
    end

    test "returns error for invalid action" do
      assert {:ok, result} = Browser.execute(%{"action" => "destroy"}, @context)
      assert result.success == false
      assert result.error =~ "Invalid action"
    end

    test "returns error for missing url on navigate" do
      assert {:ok, result} = Browser.execute(%{"action" => "navigate"}, @context)
      assert result.success == false
      assert result.error =~ "url"
    end

    # Still rejected — `click` is an `act` kind, never a top-level action. The
    # message now names the call that works instead of stopping at "invalid".
    test "rejects old CLI click action" do
      assert {:ok, result} = Browser.execute(%{"action" => "click"}, @context)
      assert result.success == false
      assert result.error =~ ~s(`click` is an `act` kind, not an action)
      assert result.error =~ ~s("action": "act", "kind": "click")
    end

    # `wait`, `click`, `fill`… are `act` KINDS, not actions. The model reached for
    # `action: "wait"` after a click in three separate live sessions and got a
    # dead end every time, because the error named the mistake without naming the
    # form that works. Same family as dialog_blocked / stale_ref / no_rendered_box.
    test "an act KIND used as an action names the call that actually works" do
      assert {:ok, result} = Browser.execute(%{"action" => "wait"}, @context)

      assert result.success == false
      assert result.error =~ ~s(`wait` is an `act` kind, not an action)
      assert result.error =~ ~s("action": "act", "kind": "wait")
    end

    # The `wait` funnel (three live sessions reached for it) must not end in a
    # SECOND dead end: an argument-starved wait died deep in the runtime with the
    # misleading "Unsupported wait_until value".
    test "an argument-starved wait names each mode's required argument" do
      assert {:ok, result} = Browser.execute(%{"action" => "act", "kind" => "wait"}, @context)

      assert result.success == false
      assert result.error =~ "wait_until"
      assert result.error =~ "text"
      assert result.error =~ "no plain-pause mode"

      assert {:ok, starved} =
               Browser.execute(
                 %{"action" => "act", "kind" => "wait", "wait_until" => "text"},
                 @context
               )

      assert starved.success == false
      assert starved.error =~ "requires text"
    end

    test "press without a key names the missing argument" do
      assert {:ok, result} = Browser.execute(%{"action" => "act", "kind" => "press"}, @context)

      assert result.success == false
      assert result.error =~ "key"
      refute result.error =~ "Unsupported act kind"
    end

    test "get field=rect requires a selector" do
      assert {:ok, result} =
               Browser.execute(%{"action" => "act", "kind" => "get", "field" => "rect"}, @context)

      assert result.success == false
      assert result.error =~ "selector"
    end

    test "an unknown action lists the actions that exist" do
      assert {:ok, result} = Browser.execute(%{"action" => "destroy"}, @context)

      assert result.success == false
      assert result.error =~ "navigate"
      assert result.error =~ "snapshot"
      assert result.error =~ "act"
    end

    test "requires ref and path on upload" do
      assert {:ok, result} = Browser.execute(%{"action" => "upload", "ref" => "file_1"}, @context)
      assert result.success == false
      assert result.error =~ "path"
    end

    test "requires a known act kind" do
      assert {:ok, result} = Browser.execute(%{"action" => "act", "kind" => "upload"}, @context)
      assert result.success == false
      assert result.error =~ "Invalid act kind"
    end

    # `observe` decides whether a navigation hands the page back, so a value
    # that is not a boolean is refused before the navigation rather than read as
    # "observe anyway" — and, like the fill_form refusals below, it is decided
    # before any Chrome launch, so this stays hermetic.
    test "observe must be true or false, and says what false is for" do
      for action <- ["open", "navigate"] do
        args = %{"action" => action, "url" => "https://example.com", "observe" => "no"}
        assert {:ok, result} = Browser.execute(args, @context)

        assert result.success == false
        assert result.error =~ "must be true or false"
        assert result.error =~ "screenshot"
      end
    end

    test "recognizes submit as a ref-based act kind" do
      assert {:ok, result} = Browser.execute(%{"action" => "act", "kind" => "submit"}, @context)
      assert result.success == false
      assert result.error =~ "submit requires ref"
    end

    # Every fill_form refusal is decided before any Chrome launch, so these stay
    # hermetic while covering the shape the model has to get right.
    test "fill_form without fields says what a field is" do
      assert {:ok, result} =
               Browser.execute(%{"action" => "act", "kind" => "fill_form"}, @context)

      assert result.success == false
      assert result.error =~ "fields"
      assert result.error =~ "ref"
      assert result.error =~ "text"
      refute result.error =~ "Invalid act kind"
    end

    test "fill_form refuses an empty list, a bad entry, and more fields than the cap" do
      empty = %{"action" => "act", "kind" => "fill_form", "fields" => []}
      assert {:ok, result} = Browser.execute(empty, @context)
      assert result.success == false
      assert result.error =~ "fields"

      bad = %{
        "action" => "act",
        "kind" => "fill_form",
        "fields" => [%{"ref" => "textbox_1", "text" => "a"}, %{"ref" => "textbox_2"}]
      }

      assert {:ok, entry} = Browser.execute(bad, @context)
      assert entry.success == false
      assert entry.error =~ "field 2"
      assert entry.error =~ "text"

      many = %{
        "action" => "act",
        "kind" => "fill_form",
        "fields" => Enum.map(1..13, &%{"ref" => "textbox_#{&1}", "text" => "x"})
      }

      assert {:ok, over} = Browser.execute(many, @context)
      assert over.success == false
      assert over.error =~ "12"
    end

    # Every webmcp refusal below is decided before any Chrome launch, so these
    # stay hermetic while covering the whole validation surface.
    test "webmcp without an op names both ops and what each one needs" do
      assert {:ok, result} = Browser.execute(%{"action" => "webmcp"}, @context)

      assert result.success == false
      assert result.error =~ "op"
      assert result.error =~ "list"
      assert result.error =~ "call"
      assert result.error =~ "name"
    end

    test "webmcp rejects an op it does not have" do
      assert {:ok, result} =
               Browser.execute(%{"action" => "webmcp", "op" => "invoke"}, @context)

      assert result.success == false
      assert result.error =~ "op"
    end

    test "webmcp op=call requires a name, bounded in length" do
      assert {:ok, missing} = Browser.execute(%{"action" => "webmcp", "op" => "call"}, @context)
      assert missing.success == false
      assert missing.error =~ "name"

      long = %{"action" => "webmcp", "op" => "call", "name" => String.duplicate("t", 200)}
      assert {:ok, oversize} = Browser.execute(long, @context)
      assert oversize.success == false
      assert oversize.error =~ "name"
    end

    test "webmcp input must be a JSON object, bounded in size" do
      args = %{"action" => "webmcp", "op" => "call", "name" => "t", "input" => "e2e4"}
      assert {:ok, wrong_type} = Browser.execute(args, @context)
      assert wrong_type.success == false
      assert wrong_type.error =~ "object"

      big = %{args | "input" => %{"fen" => String.duplicate("q", 9_000)}}
      assert {:ok, oversize} = Browser.execute(big, @context)
      assert oversize.success == false
      assert oversize.error =~ "input"
    end

    test "surfaces the structured error code and details to the agent" do
      # A blocked scheme is rejected by URL policy before any Chrome launch, so
      # this stays hermetic while exercising the code + details surfacing.
      assert {:ok, result} =
               Browser.execute(%{"action" => "navigate", "url" => "file:///etc/passwd"}, @context)

      assert result.success == false
      assert result.error =~ "navigation_blocked"
      assert result.error =~ "file"
    end

    test "requires conversation_key from built-in tool context" do
      assert {:ok, result} = Browser.execute(%{"action" => "status"}, %{agent_name: "main"})
      assert result.success == false
      assert result.error =~ "conversation_key"
    end

    test "status returns structured JSON and does not expose raw owner" do
      assert {:ok, %{success: true, output: output}} =
               Browser.execute(%{"action" => "status"}, @context)

      assert {:ok, body} = Jason.decode(output)

      assert body["ok"] == true
      assert body["running"] == false
      refute Map.has_key?(body, "owner")
      refute output =~ @chat_id
    end
  end

  describe "telemetry" do
    test "emits [:fermix, :tool, :exec] event on validation error" do
      handler_id = attach_telemetry()

      Browser.execute(%{}, @context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert metadata.tool == "browser"
      assert metadata.agent == "test_agent"
      assert metadata.success == false

      :telemetry.detach(handler_id)
    end

    test "records the action so per-verb latency is traceable" do
      handler_id = attach_telemetry()

      Browser.execute(%{"action" => "destroy"}, @context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert metadata.tool == "browser"
      assert metadata.action == "destroy"
      assert metadata.success == false

      :telemetry.detach(handler_id)
    end

    test "records the act kind for action=act" do
      handler_id = attach_telemetry()

      # Invalid kind fails arg validation before any browser launch (hermetic).
      Browser.execute(%{"action" => "act", "kind" => "frobnicate"}, @context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
      assert metadata.action == "act"
      assert metadata.kind == "frobnicate"

      :telemetry.detach(handler_id)
    end

    # `op` is a validated enum, so it is safe for the always-on trace; the tool
    # NAME and its INPUT are page/model text and stay in the gated body.
    # The call must REACH dispatch: with no conversation_key `execute/2` stops at
    # the owner-key resolution, and this would pass with validation and dispatch
    # both broken. It gets there against a stub profile registered under this
    # test's own owner — the whole tool path, and still no Chrome.
    test "records the webmcp op and keeps the tool name and input out of metadata" do
      set_capture(false)
      session = "webmcp-meta-#{System.unique_integer([:positive])}"
      conversation = {"cli", "chat-webmcp-#{System.unique_integer([:positive])}", :root}
      stub_profile!(conversation)
      handler_id = attach_telemetry(session)

      context = %{agent_name: "test_agent", conversation_key: conversation, session_id: session}

      assert {:ok, %{success: true, output: output}} =
               Browser.execute(
                 %{
                   "action" => "webmcp",
                   "op" => "call",
                   "name" => "chess_move",
                   "input" => %{"to" => "e4"}
                 },
                 context
               )

      # The stub's answer, so validation passed and the request was dispatched.
      assert {:ok, %{"served" => "chess_move"}} = Jason.decode(output)

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
      assert metadata.action == "webmcp"
      assert metadata.op == "call"
      assert metadata.success == true
      refute Map.has_key?(metadata, :name)
      refute Map.has_key?(metadata, :input)

      # One model tool call is exactly one tool exec.
      refute_receive {:telemetry, [:fermix, :tool, :exec], _measurements, _metadata}, 100

      :telemetry.detach(handler_id)
    end

    # A model can put anything in `op`. Only the two validated spellings are
    # safe for the always-on trace; anything else rides the gated body or not
    # at all.
    test "an op outside the enum is kept out of the always-on metadata" do
      set_capture(false)
      handler_id = attach_telemetry()

      Browser.execute(%{"action" => "webmcp", "op" => %{"sneaky" => "map"}}, @context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
      assert metadata.action == "webmcp"
      refute Map.has_key?(metadata, :op)

      :telemetry.detach(handler_id)
    end

    test "failed action records safe failure fields and no bodies when capture is off" do
      set_capture(false)
      handler_id = attach_telemetry()

      Browser.execute(%{"action" => "navigate", "url" => "file:///etc/passwd"}, @context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
      assert metadata.action == "navigate"
      assert metadata.success == false
      assert metadata.error_code == "navigation_blocked"
      assert is_binary(metadata.error_summary)
      # file:// has no network host → url is dropped (no local path leak)
      refute Map.has_key?(metadata, :url)
      # raw bodies stay gated
      refute Map.has_key?(metadata, :input)
      refute Map.has_key?(metadata, :output)

      :telemetry.detach(handler_id)
    end

    test "includes bounded input/output previews only when capture is on" do
      set_capture(true)
      handler_id = attach_telemetry()

      Browser.execute(%{"action" => "navigate", "url" => "file:///etc/passwd"}, @context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
      assert Map.has_key?(metadata, :input)
      assert Map.has_key?(metadata, :output)
      # safe failure fields remain present alongside the gated bodies
      assert metadata.error_code == "navigation_blocked"

      :telemetry.detach(handler_id)
    end
  end

  describe "sanitize_url/1" do
    test "keeps scheme/host/path and drops query, fragment, and userinfo" do
      assert Browser.sanitize_url("https://user:pass@example.com/a/b?token=secret#frag") ==
               "https://example.com/a/b"
    end

    test "drops urls without a network host" do
      assert Browser.sanitize_url("file:///etc/passwd") == nil
      assert Browser.sanitize_url("/relative/path") == nil
      assert Browser.sanitize_url("about:blank") == nil
    end

    test "is nil-safe" do
      assert Browser.sanitize_url(nil) == nil
    end
  end

  describe "execute/2 - diagnostics" do
    # Hermetic: `doctor` only probes for a Chrome executable, never launches it,
    # and asserts on ok ∈ {true, false}, so it is correct with or without Chrome.
    test "doctor returns structured diagnostics without agent-browser" do
      assert {:ok, %{success: true, output: output}} =
               Browser.execute(%{"action" => "doctor"}, @context)

      assert {:ok, body} = Jason.decode(output)

      assert body["ok"] in [true, false]
      assert is_map(body["chrome"])
      refute output =~ "agent-browser"
    end
  end

  describe "screenshot_aware_success/1" do
    setup do
      dir =
        Path.join([
          System.tmp_dir!(),
          "fermix-browser-shot-test",
          "run-#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(dir)
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(dir) end)
      %{dir: dir}
    end

    test "a screenshot result materializes the artifact bytes as an image content part",
         %{dir: dir} do
      png = <<137, 80, 78, 71, 13, 10>>
      path = Path.join(dir, "shot.png")
      File.write!(path, png)

      json =
        Jason.encode!(%{
          "ok" => true,
          "target" => "t1",
          "path" => path,
          "mime_type" => "image/png"
        })

      assert %{success: true, output: ^json, error: nil, images: [image]} =
               Browser.screenshot_aware_success(json)

      assert image == %{type: :image, mime_type: "image/png", data: png}
    end

    test "a non-image result returns the plain text summary with no images" do
      json = Jason.encode!(%{"ok" => true, "tabs" => []})
      result = Browser.screenshot_aware_success(json)

      assert result == %{success: true, output: json, error: nil}
      refute Map.has_key?(result, :images)
    end

    test "an unreadable artifact degrades to the text summary and logs (never crashes)" do
      json =
        Jason.encode!(%{
          "ok" => true,
          "path" => "/nonexistent/shot.png",
          "mime_type" => "image/png"
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result = Browser.screenshot_aware_success(json)
          assert result == %{success: true, output: json, error: nil}
          refute Map.has_key?(result, :images)
        end)

      assert log =~ "artifact unreadable"
    end
  end

  defp set_capture(value) do
    prev = Application.get_env(:fermix_core, :telemetry, [])
    Application.put_env(:fermix_core, :telemetry, Keyword.put(prev, :capture_content, value))
    on_exit(fn -> Application.put_env(:fermix_core, :telemetry, prev) end)
  end

  # Its own conversation, so the registration cannot be the `status` test's
  # profile — or any other module's — seen as running.
  defp stub_profile!(conversation_key) do
    {:ok, owner} = Scope.owner_key(%{conversation_key: conversation_key})
    start_supervised!({StubProfileServer, key: {owner, "fermix"}}, id: {:stub_profile, owner})
  end

  defp attach_telemetry, do: attach_telemetry(nil)

  # A globally attached handler sees every async module's events, so a test that
  # counts them pins its own correlation id and lets the rest through.
  defp attach_telemetry(session_id) do
    handler_id = "test-browser-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :tool, :exec],
      fn event, measurements, metadata, _config ->
        if metadata.tool == "browser" and mine?(metadata, session_id) do
          send(test_pid, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    handler_id
  end

  defp mine?(_metadata, nil), do: true
  defp mine?(metadata, session_id), do: Map.get(metadata, :session_id) == session_id
end
