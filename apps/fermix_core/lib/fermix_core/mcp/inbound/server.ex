defmodule FermixCore.MCP.Inbound.Server do
  @moduledoc """
  Hermes-backed MCP server exposing filtered Fermix capabilities as tools.
  """

  use Hermes.Server,
    name: "fermix",
    version: "0.1.0",
    capabilities: [:tools]

  alias FermixCore.Capabilities.Capability
  alias FermixCore.MCP.Inbound.CapabilityPort
  alias FermixCore.MCP.Inbound.Config
  alias FermixCore.MCP.Inbound.Exposure
  alias Hermes.MCP.Error
  alias Hermes.Server.Component.Schema
  alias Hermes.Server.Frame
  alias Hermes.Server.Handlers

  @impl true
  def server_info do
    config = Config.current()
    %{"name" => config.server_name, "version" => config.server_version}
  end

  @impl true
  def init(client_info, %Frame{} = frame) when is_map(client_info) do
    client = %{
      client_name: Map.get(client_info, "name"),
      client_version: Map.get(client_info, "version"),
      session_id: Frame.get_mcp_session_id(frame)
    }

    {:ok, Frame.put_private(frame, :mcp_inbound_client, client)}
  end

  @impl true
  def handle_request(%{"method" => "tools/list"}, %Frame{} = frame) do
    config = Config.current()
    port = CapabilityPort.impl()

    case port.list_capabilities() do
      {:ok, capabilities} ->
        exposed = Exposure.expose_for_inbound(capabilities, config)
        emit_list_telemetry(exposed, frame)
        {:reply, tools_list_response(exposed, config), frame}

      {:error, reason} ->
        {:error, mcp_error_internal(reason), frame}
    end
  end

  def handle_request(%{"method" => "tools/call", "params" => params}, %Frame{} = frame)
      when is_map(params) do
    name = Map.get(params, "name")
    args = Map.get(params, "arguments", %{})
    route_tool_call(name, args, frame)
  end

  def handle_request(%{"method" => "tools/call"}, %Frame{} = frame) do
    {:error, mcp_error_invalid_params("tools/call params must be a map"), frame}
  end

  def handle_request(request, frame), do: Handlers.handle(request, __MODULE__, frame)

  defp route_tool_call(name, args, %Frame{} = frame) when is_binary(name) and is_map(args) do
    config = Config.current()
    port = CapabilityPort.impl()

    with {:ok, capabilities} <- port.list_capabilities(),
         {:ok, capability} <- find_exposed(capabilities, name, config) do
      validate_and_execute(port, capability, args, frame)
    else
      :not_found -> reject_call(name, :unknown_tool, frame)
      {:error, reason} -> reject_call(name, {:port_error, reason}, frame)
    end
  end

  defp route_tool_call(_name, _args, %Frame{} = frame) do
    {:error, mcp_error_invalid_params("name must be a string and arguments must be a map"), frame}
  end

  defp validate_and_execute(port, %Capability{name: name} = capability, args, frame) do
    case validate_args(capability, args) do
      {:ok, validated_args} ->
        execute_and_telemetry(port, capability, validated_args, frame)

      {:error, {:invalid_args, errors}} ->
        reject_call(name, :invalid_params, frame, capability, format_arg_errors(errors))
    end
  end

  defp find_exposed(capabilities, name, config) do
    capabilities
    |> Exposure.expose_for_inbound(config)
    |> Enum.find(&(&1.name == name))
    |> case do
      nil -> :not_found
      capability -> {:ok, capability}
    end
  end

  defp validate_args(%Capability{parameters: schema}, args) when is_map(schema) do
    schema
    |> normalize_json_schema()
    |> Peri.from_json_schema()
    |> case do
      {:ok, peri_schema} -> Peri.validate(peri_schema, args)
      {:error, errors} -> {:error, errors}
    end
    |> case do
      # Discard Peri's coerced output; capabilities receive the original
      # JSON-typed payload from the MCP client unchanged.
      {:ok, _validated} -> {:ok, args}
      {:error, errors} -> {:error, {:invalid_args, List.wrap(errors)}}
    end
  end

  defp execute_and_telemetry(port, %Capability{name: name} = capability, args, frame) do
    started = System.monotonic_time(:millisecond)
    result = port.execute_capability(name, args, build_context(frame))
    duration_ms = System.monotonic_time(:millisecond) - started

    emit_call_telemetry(name, capability, duration_ms, result_tag(result), frame)
    tool_call_result(result, frame)
  end

  defp tool_call_result({:ok, payload}, frame) do
    case mcp_tool_response(payload) do
      {:ok, response} -> {:reply, response, frame}
      {:error, reason} -> {:error, mcp_error_internal(reason), frame}
    end
  end

  defp tool_call_result({:error, reason}, frame) do
    {:error, mcp_error_internal(reason), frame}
  end

  defp reject_call(name, reason, frame, capability \\ nil, message \\ nil) do
    emit_call_telemetry(name, capability, 0, {:error, reason}, frame)
    {:error, rejection_error(reason, name, message), frame}
  end

  defp rejection_error(:unknown_tool, name, _message), do: mcp_error_unknown_tool(name)
  defp rejection_error(:invalid_params, _name, message), do: mcp_error_invalid_params(message)
  defp rejection_error({:port_error, reason}, _name, _message), do: mcp_error_internal(reason)
  defp rejection_error(reason, _name, _message), do: mcp_error_internal(reason)

  defp tools_list_response(capabilities, %Config{} = config) do
    %{
      "tools" =>
        Enum.map(capabilities, &Exposure.to_mcp_tool_descriptor(&1, config.tool_overrides))
    }
  end

  defp build_context(frame) do
    %{source: :mcp_inbound, mcp_inbound_client: client_context(frame)}
  end

  defp client_context(frame) do
    Map.get(frame.private, :mcp_inbound_client, %{})
  end

  defp client_metadata(frame) do
    client = client_context(frame)

    %{
      client_name: Map.get(client, :client_name),
      client_version: Map.get(client, :client_version),
      session_id: Map.get(client, :session_id)
    }
  end

  defp emit_list_telemetry(capabilities, frame) do
    :telemetry.execute(
      [:fermix, :mcp, :inbound, :tools_listed],
      %{count: length(capabilities)},
      client_metadata(frame)
    )
  end

  defp emit_call_telemetry(name, capability, duration_ms, result, frame) do
    metadata =
      frame
      |> client_metadata()
      |> Map.merge(capability_metadata(capability))
      |> Map.merge(%{tool_name: name, result: result})

    :telemetry.execute([:fermix, :mcp, :inbound, :call], %{duration_ms: duration_ms}, metadata)
  end

  defp capability_metadata(%Capability{} = capability) do
    %{tool_kind: capability.kind, tool_policy_class: capability.policy_class}
  end

  defp capability_metadata(nil), do: %{tool_kind: nil, tool_policy_class: nil}

  defp result_tag({:ok, _payload}), do: :ok
  defp result_tag({:error, reason}), do: {:error, reason}

  defp mcp_tool_response(payload) when is_binary(payload),
    do: {:ok, text_response(payload, false)}

  defp mcp_tool_response(%{success: true, output: output, error: nil}) when is_binary(output) do
    {:ok, text_response(output, false)}
  end

  defp mcp_tool_response(%{success: false, output: output, error: error})
       when is_binary(output) and is_binary(error) do
    {:ok, text_response(error, true)}
  end

  defp mcp_tool_response(%{"content" => content, "isError" => is_error})
       when is_list(content) and is_boolean(is_error) do
    {:ok, %{"content" => content, "isError" => is_error}}
  end

  defp mcp_tool_response(payload), do: {:error, {:invalid_capability_payload, payload}}

  defp text_response(text, is_error?) do
    %{"content" => [%{"type" => "text", "text" => text}], "isError" => is_error?}
  end

  defp mcp_error_unknown_tool(name) do
    Error.protocol(:invalid_params, %{message: "Tool not found: #{name}"})
  end

  defp mcp_error_invalid_params(message) do
    Error.protocol(:invalid_params, %{message: message || "Invalid params"})
  end

  defp mcp_error_internal(reason) do
    Error.execution("inbound capability error", %{reason: inspect(reason)})
  end

  defp format_arg_errors(errors), do: Schema.format_errors(errors)

  defp normalize_json_schema(schema) do
    schema
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
