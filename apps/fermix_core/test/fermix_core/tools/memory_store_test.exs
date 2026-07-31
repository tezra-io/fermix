defmodule FermixCore.Tools.MemoryStoreTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Store
  alias FermixCore.Tools.MemoryStore

  setup do
    {:ok, store} = Store.start_link(name: :"mem_store_tool_#{System.unique_integer([:positive])}")
    conv_key = {"telegram", "chat_#{System.unique_integer([:positive])}"}
    context = %{agent_name: "test_agent", conversation_key: conv_key, memory_store: store}
    %{context: context, conv_key: conv_key, store: store}
  end

  describe "name/0" do
    test "returns memory_store" do
      assert MemoryStore.name() == "memory_store"
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      desc = MemoryStore.description()
      assert is_binary(desc)
      assert byte_size(desc) > 0
    end
  end

  describe "parameters/0" do
    test "returns JSON Schema with key and value as required" do
      params = MemoryStore.parameters()
      assert params.type == "object"
      assert "key" in params.required
      assert "value" in params.required
      assert Map.has_key?(params.properties, :key)
      assert Map.has_key?(params.properties, :value)
    end
  end

  describe "execute/2" do
    test "stores a memory and returns success", %{
      context: context,
      conv_key: conv_key,
      store: store
    } do
      args = %{"key" => "user_name", "value" => "Alice"}
      assert {:ok, result} = MemoryStore.execute(args, context)
      assert result.success == true
      assert result.output =~ "user_name"

      assert {:ok, "Alice"} = Store.recall(conv_key, "user_name", server: store)
    end

    test "overwrites existing memory", %{context: context, conv_key: conv_key, store: store} do
      MemoryStore.execute(%{"key" => "lang", "value" => "en"}, context)
      MemoryStore.execute(%{"key" => "lang", "value" => "fr"}, context)

      assert {:ok, "fr"} = Store.recall(conv_key, "lang", server: store)
    end
  end

  describe "telemetry" do
    test "emits [:fermix, :tool, :exec] on success", %{context: context} do
      handler_id = attach_telemetry()

      MemoryStore.execute(%{"key" => "k", "value" => "v"}, context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert metadata.tool == "memory_store"
      assert metadata.agent == "test_agent"
      assert metadata.success == true

      :telemetry.detach(handler_id)
    end
  end

  defp attach_telemetry do
    handler_id = "test-memory-store-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :tool, :exec],
      fn event, measurements, metadata, _config ->
        if self() == test_pid and metadata.tool == "memory_store" do
          send(test_pid, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    handler_id
  end
end
