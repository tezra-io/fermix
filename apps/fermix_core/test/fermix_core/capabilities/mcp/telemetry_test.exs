defmodule FermixCore.Capabilities.MCP.TelemetryTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.MCP.Telemetry, as: MCPClientTelemetry

  # The phase surface is pinned, not inferred: adding a phase must be a deliberate
  # edit that also updates the JSONL loop below and the FermixOpik half of the
  # invariant (apps/fermix_opik/test/fermix_opik/aggregation_test.exs).
  @phases [
    :initialize,
    :discover,
    :ready,
    :drift,
    :reconnect,
    :security_block,
    :owner_down,
    :teardown
  ]

  # Synthetic stand-ins for the three classes of material a remote MCP client
  # holds that must never reach a trace. None is a real credential.
  @bearer "Bearer eden_pat_fakevalue_do_not_log"
  @mcp_session_id "mcp-sess-01JFAKE0000000000000000000"
  @workspace_id "ws_fake_0123456789"

  @lifecycle_event [:fermix, :mcp_client, :lifecycle]
  @collision_event [:fermix, :capability, :mcp_name_collision]

  setup do
    handler = "mcp-client-tel-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler,
      [@lifecycle_event, @collision_event],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:mcp_client, event, measurements, metadata})
      end,
      nil
    )

    prior = Application.get_env(:fermix_core, :telemetry, [])

    on_exit(fn ->
      :telemetry.detach(handler)
      Application.put_env(:fermix_core, :telemetry, prior)
    end)

    :ok
  end

  defp emit_error(reason) do
    MCPClientTelemetry.emit_lifecycle(
      :initialize,
      %{source_id: {:plugin, "eden"}},
      {:error, reason},
      9
    )
  end

  test "the emitter's own event names are what the consumers bind" do
    assert MCPClientTelemetry.lifecycle_event() == @lifecycle_event
    assert MCPClientTelemetry.collision_event() == @collision_event
  end

  describe "emit_lifecycle/5" do
    test "emits the stable event with a string-serialized source_id" do
      MCPClientTelemetry.emit_lifecycle(
        :ready,
        %{source_id: {:plugin, "eden"}, plugin: "eden"},
        :ok,
        142
      )

      assert_receive {:mcp_client, event, %{duration_ms: 142}, metadata}
      assert event == [:fermix, :mcp_client, :lifecycle]
      assert metadata.source_id == "plugin:eden"
      assert metadata.plugin == "eden"
      assert metadata.phase == :ready
      assert metadata.result == :ok
      refute Map.has_key?(metadata, :error_class)
    end

    test "an operator server carries no plugin key" do
      MCPClientTelemetry.emit_lifecycle(:initialize, %{source_id: {:operator, "fs"}}, :ok, 5)

      assert_receive {:mcp_client, _event, _measurements, metadata}
      assert metadata.source_id == "operator:fs"
      refute Map.has_key?(metadata, :plugin)
    end

    test "correlation ids ride only when the caller has a turn" do
      source = %{source_id: {:plugin, "eden"}}

      MCPClientTelemetry.emit_lifecycle(:security_block, source, {:error, :tool_not_allowed}, 1,
        session_id: "main-7",
        parent_session: "main-1",
        attempt: 2
      )

      assert_receive {:mcp_client, _event, _measurements, metadata}
      assert metadata.session_id == "main-7"
      assert metadata.parent_session == "main-1"
      assert metadata.attempt == 2

      MCPClientTelemetry.emit_lifecycle(:teardown, source, :ok, 3)

      assert_receive {:mcp_client, _event, _measurements, boot_metadata}
      refute Map.has_key?(boot_metadata, :session_id)
      refute Map.has_key?(boot_metadata, :parent_session)
      refute Map.has_key?(boot_metadata, :attempt)
    end

    test "every declared phase emits" do
      for phase <- @phases do
        MCPClientTelemetry.emit_lifecycle(phase, %{source_id: {:plugin, "eden"}}, :ok, 0)
        assert_receive {:mcp_client, _event, _measurements, %{phase: ^phase}}
      end
    end

    test "phases/0 pins the surface the consumers must cover" do
      assert MCPClientTelemetry.phases() == @phases
    end

    test "an unknown phase is refused loudly" do
      assert_raise FunctionClauseError, fn ->
        MCPClientTelemetry.emit_lifecycle(:handshake, %{source_id: {:plugin, "eden"}}, :ok, 1)
      end
    end

    test "a malformed source_id is refused loudly" do
      assert_raise ArgumentError, fn ->
        MCPClientTelemetry.emit_lifecycle(:ready, %{source_id: "plugin:eden"}, :ok, 1)
      end

      assert_raise ArgumentError, fn ->
        MCPClientTelemetry.emit_lifecycle(:ready, %{}, :ok, 1)
      end
    end

    test "a non-positive attempt is refused loudly" do
      assert_raise ArgumentError, fn ->
        MCPClientTelemetry.emit_lifecycle(:reconnect, %{source_id: {:plugin, "eden"}}, :ok, 1,
          attempt: 0
        )
      end
    end

    test "a negative duration is refused loudly" do
      assert_raise FunctionClauseError, fn ->
        MCPClientTelemetry.emit_lifecycle(:ready, %{source_id: {:plugin, "eden"}}, :ok, -1)
      end
    end
  end

  describe "error_class derivation" do
    test "an atom reason becomes its own class" do
      emit_error(:remote_unreachable)

      assert_receive {:mcp_client, _event, _measurements, metadata}
      assert metadata.result == :error
      assert metadata.error_class == "remote_unreachable"
    end

    test "a tagged tuple reason reduces to its atom head" do
      emit_error({:contract_drift, "tool eden_get_note_markdown changed shape"})

      assert_receive {:mcp_client, _event, _measurements, metadata}
      assert metadata.error_class == "contract_drift"
    end

    # The class is a label for grouping failures, not a diagnosis. A free-form
    # reason body is exactly where an endpoint URL or a credential would hide, so
    # it is flattened rather than passed through.
    test "a free-form reason body never reaches the class" do
      emit_error("401 Unauthorized for https://mcp.eden.so/mcp with #{@bearer}")

      assert_receive {:mcp_client, _event, _measurements, metadata}
      assert metadata.error_class == "unclassified"
    end

    test "a map reason is flattened too" do
      emit_error(%{status: 403, body: @workspace_id})

      assert_receive {:mcp_client, _event, _measurements, metadata}
      assert metadata.error_class == "unclassified"
    end

    test "an ok result carries no class" do
      MCPClientTelemetry.emit_lifecycle(:ready, %{source_id: {:plugin, "eden"}}, {:ok, 12}, 4)

      assert_receive {:mcp_client, _event, _measurements, metadata}
      assert metadata.result == :ok
      refute Map.has_key?(metadata, :error_class)
    end
  end

  # CANARY. The emitter accepts no free-form metadata map, so the only way a
  # secret could ride is through one of the five arguments. This test puts a
  # bearer token, an MCP session id and a workspace id in scope, emits, and
  # asserts the metadata key set is exactly the allowlist and that no value
  # anywhere in it contains any of them.
  describe "credential canary" do
    test "no bearer, MCP session id, or workspace id can reach the metadata" do
      Application.put_env(:fermix_core, :telemetry, capture_content: true)

      planted = [@bearer, @mcp_session_id, @workspace_id]

      MCPClientTelemetry.emit_lifecycle(
        :discover,
        %{source_id: {:plugin, "eden"}, plugin: "eden"},
        {:error, {:http_status, "#{@bearer} #{@mcp_session_id} #{@workspace_id}"}},
        87,
        session_id: "main-3",
        attempt: 1
      )

      assert_receive {:mcp_client, @lifecycle_event, measurements, metadata}

      assert Map.keys(metadata) |> Enum.sort() ==
               [:attempt, :error_class, :phase, :plugin, :result, :session_id, :source_id]

      rendered = inspect({measurements, metadata})

      for secret <- planted do
        refute String.contains?(rendered, secret)
      end

      assert metadata.error_class == "http_status"
    end

    test "content capture cannot widen the metadata — there is no gated field" do
      source = %{source_id: {:plugin, "eden"}, plugin: "eden"}

      Application.put_env(:fermix_core, :telemetry, capture_content: false)
      MCPClientTelemetry.emit_lifecycle(:ready, source, :ok, 10)
      assert_receive {:mcp_client, _event, _measurements, off}

      Application.put_env(:fermix_core, :telemetry, capture_content: true)
      MCPClientTelemetry.emit_lifecycle(:ready, source, :ok, 10)
      assert_receive {:mcp_client, _event, _measurements, on}

      assert off == on
    end
  end

  describe "emit_collision/4" do
    test "keeps the shipped event name and payload shape" do
      MCPClientTelemetry.emit_collision(
        "fs-local",
        "read_file",
        "mcp_fs_local_read_file",
        {"fs.local", "read_file"}
      )

      assert_receive {:mcp_client, event, %{count: 1}, metadata}
      assert event == [:fermix, :capability, :mcp_name_collision]

      assert metadata == %{
               server: "fs-local",
               original: "read_file",
               sanitized: "mcp_fs_local_read_file",
               collided_with: %{server: "fs.local", original: "read_file"}
             }
    end
  end

  describe "trace_event_definitions/0" do
    test "pins both events onto recordable Trace rows" do
      assert MCPClientTelemetry.trace_event_definitions() == [
               %{
                 event: [:fermix, :mcp_client, :lifecycle],
                 trace_event: "mcp_client_lifecycle",
                 trace_type: :agent_event,
                 agent_field: :source_id
               },
               %{
                 event: [:fermix, :capability, :mcp_name_collision],
                 trace_event: "mcp_name_collision",
                 trace_type: :agent_event,
                 agent_field: :server
               }
             ]
    end

    # `Trace.record/4` guards on the type, and the handler reads `agent_field` out
    # of the metadata — an agent_field naming a key the emitter never sets would
    # silently produce "unknown" rows.
    test "every agent_field is a key the emitter actually sets" do
      MCPClientTelemetry.emit_lifecycle(:ready, %{source_id: {:plugin, "eden"}}, :ok, 1)
      assert_receive {:mcp_client, _event, _measurements, lifecycle_metadata}
      assert Map.has_key?(lifecycle_metadata, :source_id)

      MCPClientTelemetry.emit_collision("a", "t", "mcp_a_t", {"b", "t"})
      assert_receive {:mcp_client, _event, _measurements, collision_metadata}
      assert Map.has_key?(collision_metadata, :server)
    end
  end
end
