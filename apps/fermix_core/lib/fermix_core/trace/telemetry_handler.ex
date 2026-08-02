defmodule FermixCore.Trace.TelemetryHandler do
  @moduledoc """
  Attaches to `:telemetry` events and routes them to `FermixCore.Trace`.

  Handled events:
  - `[:fermix, :provider, :call]` → `:llm_call`
  - `[:fermix, :tool, :exec]` → `:tool_exec`
  - `[:fermix, :channel, :message]` → `:channel_msg`
  - M2 lifecycle events → `:agent_event`
  """

  alias FermixCore.Agents.LifecycleTelemetry
  alias FermixCore.Capabilities.MCP.Telemetry, as: MCPClientTelemetry
  alias FermixCore.Harness.Telemetry, as: HarnessTelemetry
  alias FermixCore.Jobs.Telemetry, as: JobTelemetry
  alias FermixCore.SoulCuration.Telemetry, as: SoulTelemetry
  alias FermixCore.Trace

  @core_events [
    %{event: [:fermix, :provider, :call], trace_type: :llm_call, agent_field: :agent},
    %{
      event: [:fermix, :provider, :failover],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "provider_failover"
    },
    %{event: [:fermix, :tool, :exec], trace_type: :tool_exec, agent_field: :agent},
    # A background-reviewer durable memory write — recorded as a tool_exec row
    # (tool: "memory_write") so it is visible in the JSONL trace alongside tool
    # spans, mirroring the Opik mapping.
    %{event: [:fermix, :memory, :write], trace_type: :tool_exec, agent_field: :agent},
    # The background reviewer's run closer (status + op counts), carrying the run
    # session_id. Recorded as the review run's lifecycle row so the run is visible
    # in the JSONL trace rather than only reconstructable from its child spans.
    %{
      event: [:fermix, :memory, :review],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "memory_review"
    },
    %{event: [:fermix, :channel, :message], trace_type: :channel_msg, agent_field: :agent},
    %{
      event: [:fermix, :agent, :message],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "turn_complete"
    },
    %{
      event: [:fermix, :agent, :message_error],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "turn_error"
    },
    %{
      event: [:fermix, :agent, :prompt_context],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "prompt_context"
    },
    %{
      event: [:fermix, :agent, :history],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "history_load"
    },
    %{
      event: [:fermix, :channel, :reply],
      trace_type: :agent_event,
      agent_field: :channel,
      trace_event: "reply_delivery"
    },
    %{
      event: [:fermix, :capabilities, :select],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "capability_select"
    },
    # Plugin distribution ops (install/uninstall/gc). Catalog-scope
    # ops carry `plugin: nil`, so the row's agent is the op itself.
    %{
      event: [:fermix, :plugin, :dist],
      trace_type: :agent_event,
      agent_field: :op,
      trace_event: "plugin_dist"
    },
    # Tool-search bridge queries (M10): the search-miss rate (match_count == 0)
    # is the primary soak-health metric for tool-schema deferral.
    %{
      event: [:fermix, :tool_search, :query],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "tool_search_query"
    },
    # A fired failure-deadline timeout (FermixCore.Timeouts.expired/3). The
    # timeout `name` is the row's agent (these are not agent-scoped — they carry
    # session_id for correlation, mirroring plugin :dist using :op), so the
    # firing is visible in the JSONL trace, not only in Opik.
    %{
      event: [:fermix, :timeout, :expired],
      trace_type: :agent_event,
      agent_field: :name,
      trace_event: "timeout"
    }
  ]

  @mcp_inbound_events [
    %{
      event: [:fermix, :mcp, :inbound, :tools_listed],
      trace_type: :agent_event,
      agent_field: :client_name,
      trace_event: "mcp_inbound_tools_listed"
    },
    %{
      event: [:fermix, :mcp, :inbound, :call],
      trace_type: :tool_exec,
      agent_field: :client_name
    }
  ]

  # Realtime voice lifecycle (its own WebSocket session). Tool calls and the
  # model turn reuse `[:fermix, :tool, :exec]` / `[:fermix, :provider, :call]`;
  # only these provider-lifecycle markers are realtime-specific.
  @realtime_events [
    %{
      event: [:fermix, :realtime, :call_start],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "realtime_call_start"
    },
    %{
      event: [:fermix, :realtime, :session_created],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "realtime_session_created"
    },
    %{
      event: [:fermix, :realtime, :session_updated],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "realtime_session_updated"
    },
    %{
      event: [:fermix, :realtime, :provider_error],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "realtime_provider_error"
    },
    %{
      event: [:fermix, :realtime, :reconnect],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "realtime_reconnect"
    },
    %{
      event: [:fermix, :realtime, :call_stop],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "realtime_call_stop"
    },
    %{
      event: [:fermix, :realtime, :screen_feed_start],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "realtime_screen_feed_start"
    },
    %{
      event: [:fermix, :realtime, :frame_sent],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "realtime_screen_frame_sent"
    },
    %{
      event: [:fermix, :realtime, :frame_dropped],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "realtime_screen_frame_dropped"
    },
    %{
      event: [:fermix, :realtime, :screen_feed_stop],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "realtime_screen_feed_stop"
    }
  ]

  @spec attach(keyword()) :: :ok
  def attach(opts \\ []) do
    server = Keyword.get(opts, :trace_server, Trace)
    prefix = Keyword.get(opts, :handler_prefix, "fermix")
    base_config = %{trace_server: server}

    for %{event: event} = definition <- event_definitions() do
      handler_id = "#{prefix}-#{Enum.join(event, "-")}"
      config = Map.put(base_config, :definition, definition)

      case :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, config) do
        :ok ->
          :ok

        {:error, :already_exists} ->
          :telemetry.detach(handler_id)
          :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, config)
      end
    end

    :ok
  end

  @spec detach(String.t()) :: :ok
  def detach(prefix \\ "fermix") do
    for %{event: event} <- event_definitions() do
      handler_id = "#{prefix}-#{Enum.join(event, "-")}"
      :telemetry.detach(handler_id)
    end

    :ok
  end

  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event(_event, measurements, metadata, %{
        trace_server: server,
        definition: definition
      }) do
    {agent, data} = build_trace_payload(definition, measurements, metadata)
    Trace.record(definition.trace_type, agent, data, server: server)
  end

  defp event_definitions do
    @core_events ++
      @mcp_inbound_events ++
      @realtime_events ++
      LifecycleTelemetry.trace_event_definitions() ++
      JobTelemetry.trace_event_definitions() ++
      HarnessTelemetry.trace_event_definitions() ++
      SoulTelemetry.trace_event_definitions() ++
      MCPClientTelemetry.trace_event_definitions()
  end

  defp build_trace_payload(%{agent_field: agent_field} = config, measurements, metadata) do
    agent =
      metadata
      |> Map.get(agent_field, "unknown")
      |> to_string()

    data =
      measurements
      |> Map.merge(metadata |> sanitize_metadata(agent_field) |> json_safe())
      |> maybe_put_trace_event(config)

    {agent, data}
  end

  # Core events already expose `:agent` directly, so we drop the duplicate once
  # it has been promoted to the Trace row's top-level `agent` field.
  defp sanitize_metadata(metadata, :agent), do: Map.delete(metadata, :agent)

  # Lifecycle events derive the Trace row's top-level `agent` from `:name` or
  # `:skill`, but intentionally keep that original field in the payload. TEZ-316
  # consumers and acceptance tests rely on both the normalized `agent` and the
  # lifecycle-specific metadata key being present.
  defp sanitize_metadata(metadata, _agent_field), do: metadata

  # Structs match `is_map/1`, but `Map.new/2` on one raises (a struct is not
  # Enumerable). This runs in the emitting process, where an unhandled raise
  # permanently detaches the telemetry handler — so render structs to a string
  # rather than recurse into them.
  defp json_safe(%_struct{} = value), do: inspect(value)

  defp json_safe(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, json_safe(value)} end)

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: inspect(tuple)
  defp json_safe(value), do: value

  defp maybe_put_trace_event(data, %{trace_event: trace_event}) when is_binary(trace_event) do
    Map.put(data, :event, trace_event)
  end

  defp maybe_put_trace_event(data, _config), do: data
end
