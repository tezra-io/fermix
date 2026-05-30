defmodule FermixCore.Sandbox.DecisionTelemetry do
  @moduledoc """
  Persists denied sandbox decisions to Trace.
  """

  alias FermixCore.Trace

  @event [:fermix, :sandbox, :decision]

  @spec attach(keyword()) :: :ok
  def attach(opts \\ []) do
    server = Keyword.get(opts, :trace_server, Trace)
    prefix = Keyword.get(opts, :handler_prefix, "fermix")
    handler_id = "#{prefix}-sandbox-decision-trace"
    config = %{trace_server: server}

    case :telemetry.attach(handler_id, @event, &__MODULE__.handle_event/4, config) do
      :ok ->
        :ok

      {:error, :already_exists} ->
        :telemetry.detach(handler_id)
        :telemetry.attach(handler_id, @event, &__MODULE__.handle_event/4, config)
    end
  end

  @spec detach(String.t()) :: :ok
  def detach(prefix \\ "fermix") do
    :telemetry.detach("#{prefix}-sandbox-decision-trace")
    :ok
  end

  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event(@event, _measurements, %{decision: :allow}, _config), do: :ok

  def handle_event(@event, _measurements, metadata, %{trace_server: server}) do
    {agent, data} = build_trace_payload(metadata)
    Trace.record(:sandbox_event, agent, data, server: server)
  end

  defp build_trace_payload(metadata) do
    reason = Map.get(metadata, :reason)
    {reason_tag, resource} = reason_fields(reason)

    data = %{
      event: "sandbox_decision",
      decision: metadata |> Map.get(:decision, :unknown) |> format_value(),
      capability: metadata |> Map.get(:operation, :unknown) |> format_value(),
      policy_class: metadata |> Map.get(:policy_class, :unknown) |> format_value(),
      reason_tag: format_value(reason_tag),
      resource: format_value(resource),
      conversation_key: metadata |> Map.get(:conversation_key) |> format_optional()
    }

    {metadata |> Map.get(:agent, "unknown") |> to_string(), data}
  end

  defp reason_fields({tag, resource})
       when tag in [:outside_root, :blocked_root, :protected_path] do
    {tag, resource}
  end

  defp reason_fields({:missing_env, name}), do: {:missing_env, name}
  defp reason_fields(reason) when is_binary(reason), do: {:hardline, reason}
  defp reason_fields(reason), do: {:unknown, inspect(reason)}

  defp format_optional(nil), do: nil
  defp format_optional(value), do: format_value(value)

  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)
end
