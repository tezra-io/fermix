defmodule FermixCore.Tools.MemoryRecallTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Store
  alias FermixCore.Tools.MemoryRecall

  setup do
    {:ok, store} =
      Store.start_link(name: :"mem_recall_tool_#{System.unique_integer([:positive])}")

    conv_key = {"telegram", "chat_#{System.unique_integer([:positive])}"}
    context = %{agent_name: "test_agent", conversation_key: conv_key, memory_store: store}
    %{context: context, conv_key: conv_key, store: store}
  end

  describe "name/0" do
    test "returns memory_recall" do
      assert MemoryRecall.name() == "memory_recall"
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      desc = MemoryRecall.description()
      assert is_binary(desc)
      assert byte_size(desc) > 0
    end
  end

  describe "parameters/0" do
    test "returns JSON Schema with optional key" do
      params = MemoryRecall.parameters()
      assert params.type == "object"
      assert Map.has_key?(params.properties, :key)
      refute Map.has_key?(params, :required)
    end
  end

  describe "execute/2 - recall by key" do
    test "returns stored value", %{context: context, conv_key: conv_key, store: store} do
      Store.store(conv_key, "user_name", "Alice", server: store)

      assert {:ok, result} = MemoryRecall.execute(%{"key" => "user_name"}, context)
      assert result.success == true
      assert result.output == "Alice"
    end

    test "returns error for missing key", %{context: context} do
      assert {:ok, result} = MemoryRecall.execute(%{"key" => "missing"}, context)
      assert result.success == false
      assert result.error =~ "No memory found"
    end
  end

  describe "execute/2 - recall all" do
    test "returns all memories when key omitted", %{
      context: context,
      conv_key: conv_key,
      store: store
    } do
      Store.store(conv_key, "name", "Alice", server: store)
      Store.store(conv_key, "lang", "en", server: store)

      assert {:ok, result} = MemoryRecall.execute(%{}, context)
      assert result.success == true
      assert result.output =~ "name"
      assert result.output =~ "Alice"
      assert result.output =~ "lang"
      assert result.output =~ "en"
    end

    test "returns message when no memories exist", %{context: context} do
      assert {:ok, result} = MemoryRecall.execute(%{}, context)
      assert result.success == true
      assert result.output =~ "No memories"
    end
  end

  describe "telemetry" do
    test "emits [:fermix, :tool, :exec] on success", %{
      context: context,
      conv_key: conv_key,
      store: store
    } do
      handler_id = attach_telemetry()
      Store.store(conv_key, "k", "v", server: store)

      MemoryRecall.execute(%{"key" => "k"}, context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert metadata.tool == "memory_recall"
      assert metadata.agent == "test_agent"
      assert metadata.success == true

      :telemetry.detach(handler_id)
    end

    test "emits [:fermix, :tool, :exec] on not found", %{context: context} do
      handler_id = attach_telemetry()

      MemoryRecall.execute(%{"key" => "missing"}, context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert metadata.tool == "memory_recall"
      assert metadata.success == false

      :telemetry.detach(handler_id)
    end
  end

  defp attach_telemetry do
    handler_id = "test-memory-recall-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :tool, :exec],
      fn event, measurements, metadata, _config ->
        if metadata.tool == "memory_recall" do
          send(test_pid, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    handler_id
  end
end
