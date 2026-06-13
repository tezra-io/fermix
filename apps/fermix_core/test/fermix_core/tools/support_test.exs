defmodule FermixCore.Tools.SupportTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Tools.Support

  describe "run/3 telemetry merge order" do
    test "extra metadata cannot override reserved fields" do
      handler_id = "support-reserved-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:fermix, :tool, :exec],
        fn _event, _measurements, metadata, _config ->
          if metadata.tool == "real_tool", do: send(test_pid, {:trace, metadata})
        end,
        nil
      )

      context = %{agent_name: "real_agent"}

      Support.run("real_tool", context, fn ->
        {:ok, Tool.success("ok"),
         %{
           tool: "spoofed",
           agent: "spoofed",
           success: false,
           error: "spoofed",
           result_count: 7
         }}
      end)

      assert_receive {:trace, metadata}
      assert metadata.tool == "real_tool"
      assert metadata.agent == "real_agent"
      assert metadata.success == true
      refute Map.has_key?(metadata, :error)
      assert metadata.result_count == 7

      :telemetry.detach(handler_id)
    end

    test "extra metadata adds non-reserved keys" do
      handler_id = "support-extra-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:fermix, :tool, :exec],
        fn _event, _measurements, metadata, _config ->
          if metadata.tool == "tool_a", do: send(test_pid, {:trace, metadata})
        end,
        nil
      )

      Support.run("tool_a", %{agent_name: "a"}, fn ->
        {:ok, Tool.success("ok"), %{backend: "test", result_count: 0}}
      end)

      assert_receive {:trace, metadata}
      assert metadata.backend == "test"
      assert metadata.result_count == 0
      assert metadata.tool == "tool_a"

      :telemetry.detach(handler_id)
    end
  end
end
