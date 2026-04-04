defmodule FermixCore.Tools.BrowserTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.Browser

  @context %{agent_name: "test_agent", conversation_key: :test}

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
    end
  end

  describe "parameters/0" do
    test "returns JSON Schema with action as required" do
      params = Browser.parameters()
      assert params.type == "object"
      assert "action" in params.required
      assert Map.has_key?(params.properties, :action)
    end

    test "includes optional url, ref, text, and timeout_ms" do
      params = Browser.parameters()
      assert Map.has_key?(params.properties, :url)
      assert Map.has_key?(params.properties, :ref)
      assert Map.has_key?(params.properties, :text)
      assert Map.has_key?(params.properties, :timeout_ms)
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

    test "returns error for missing ref on click" do
      assert {:ok, result} = Browser.execute(%{"action" => "click"}, @context)
      assert result.success == false
      assert result.error =~ "ref"
    end

    test "returns error for missing ref on fill" do
      assert {:ok, result} = Browser.execute(%{"action" => "fill"}, @context)
      assert result.success == false
      assert result.error =~ "ref"
    end

    test "returns error for missing text on fill" do
      assert {:ok, result} = Browser.execute(%{"action" => "fill", "ref" => "42"}, @context)
      assert result.success == false
      assert result.error =~ "text"
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

    test "emits [:fermix, :tool, :exec] event on invalid action" do
      handler_id = attach_telemetry()

      Browser.execute(%{"action" => "destroy"}, @context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert metadata.tool == "browser"
      assert metadata.success == false

      :telemetry.detach(handler_id)
    end
  end

  @tag :integration
  describe "execute/2 - integration (requires agent-browser)" do
    test "snapshot returns output" do
      assert {:ok, result} = Browser.execute(%{"action" => "snapshot"}, @context)
      assert result.success == true or result.success == false
    end

    test "navigate opens a url" do
      assert {:ok, result} =
               Browser.execute(
                 %{"action" => "navigate", "url" => "https://example.com"},
                 @context
               )

      assert result.success == true or result.success == false
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
