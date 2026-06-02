defmodule FermixCore.Tools.BrowserTest do
  use ExUnit.Case, async: false

  alias FermixCore.Tools.Browser

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
            ~w(doctor status start stop open navigate snapshot tabs focus close screenshot act pdf console dialog cookies storage upload download) do
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

    test "rejects old CLI click action" do
      assert {:ok, result} = Browser.execute(%{"action" => "click"}, @context)
      assert result.success == false
      assert result.error =~ "Invalid action"
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

  defp attach_telemetry do
    handler_id = "test-browser-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :tool, :exec],
      fn event, measurements, metadata, _config ->
        if metadata.tool == "browser" do
          send(test_pid, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    handler_id
  end
end
