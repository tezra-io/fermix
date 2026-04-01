defmodule FermixCore.Trace.TelemetryHandler do
  @moduledoc """
  Attaches to `:telemetry` events and routes them to `FermixCore.Trace`.

  Handled events:
  - `[:fermix, :provider, :call]` → `:llm_call`
  - `[:fermix, :tool, :exec]` → `:tool_exec`
  - `[:fermix, :channel, :message]` → `:channel_msg`
  """

  alias FermixCore.Trace

  @events [
    {[:fermix, :provider, :call], :llm_call},
    {[:fermix, :tool, :exec], :tool_exec},
    {[:fermix, :channel, :message], :channel_msg}
  ]

  @spec attach(keyword()) :: :ok
  def attach(opts \\ []) do
    server = Keyword.get(opts, :trace_server, Trace)
    prefix = Keyword.get(opts, :handler_prefix, "fermix")
    config = %{trace_server: server}

    for {event, _type} <- @events do
      handler_id = "#{prefix}-#{Enum.join(event, "-")}"

      case :telemetry.attach(handler_id, event, &handle_event/4, config) do
        :ok ->
          :ok

        {:error, :already_exists} ->
          :telemetry.detach(handler_id)
          :telemetry.attach(handler_id, event, &handle_event/4, config)
      end
    end

    :ok
  end

  @spec detach(String.t()) :: :ok
  def detach(prefix \\ "fermix") do
    for {event, _type} <- @events do
      handler_id = "#{prefix}-#{Enum.join(event, "-")}"
      :telemetry.detach(handler_id)
    end

    :ok
  end

  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event(event, measurements, metadata, %{trace_server: server}) do
    type = event_to_type(event)
    agent = Map.get(metadata, :agent, "unknown") |> to_string()
    data = Map.merge(measurements, Map.delete(metadata, :agent))
    Trace.record(type, agent, data, server: server)
  end

  for {event, type} <- @events do
    defp event_to_type(unquote(event)), do: unquote(type)
  end
end
