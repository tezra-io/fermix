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
  alias FermixCore.Trace

  @core_events [
    %{event: [:fermix, :provider, :call], trace_type: :llm_call, agent_field: :agent},
    %{event: [:fermix, :tool, :exec], trace_type: :tool_exec, agent_field: :agent},
    %{event: [:fermix, :channel, :message], trace_type: :channel_msg, agent_field: :agent},
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
      event: [:fermix, :agent, :reply],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "reply_delivery"
    },
    %{
      event: [:fermix, :capabilities, :select],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "capability_select"
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

  @spec attach(keyword()) :: :ok
  def attach(opts \\ []) do
    server = Keyword.get(opts, :trace_server, Trace)
    prefix = Keyword.get(opts, :handler_prefix, "fermix")
    config = %{trace_server: server}

    for %{event: event} <- event_definitions() do
      handler_id = "#{prefix}-#{Enum.join(event, "-")}"

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
  def handle_event(event, measurements, metadata, %{trace_server: server}) do
    config = event_config(event)
    {agent, data} = build_trace_payload(config, measurements, metadata)
    Trace.record(config.trace_type, agent, data, server: server)
  end

  defp event_definitions do
    @core_events ++ @mcp_inbound_events ++ LifecycleTelemetry.trace_event_definitions()
  end

  defp event_config(event) do
    Enum.find(event_definitions(), fn definition -> definition.event == event end) ||
      raise ArgumentError, "unhandled telemetry event: #{inspect(event)}"
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
