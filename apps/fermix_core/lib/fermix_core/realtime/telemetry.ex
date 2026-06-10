defmodule FermixCore.Realtime.Telemetry do
  @moduledoc """
  Single emitter for `[:fermix, :realtime, ...]` lifecycle events.

  Realtime voice runs on its own WebSocket session rather than the provider
  adapters, so these events give a call a traceable lifecycle. Only the
  Realtime-provider lifecycle (which has no request/response analog) lives here —
  tool execution and the model turn are emitted through the shared
  `FermixCore.Tools.Telemetry` / `FermixCore.Providers.Telemetry` emitters so they
  reuse the existing JSONL and Opik aggregation.

  Every event carries the call's `session_id` so the JSONL handler and Opik
  reassemble one realtime call into one trace.
  """

  alias FermixCore.Telemetry

  @type meta :: %{
          session_id: String.t(),
          device_id: String.t(),
          model: String.t(),
          voice: String.t(),
          session_scope: String.t()
        }

  @spec call_start(meta()) :: :ok
  def call_start(meta) when is_map(meta), do: emit(:call_start, %{}, base(meta))

  @spec session_created(meta()) :: :ok
  def session_created(meta) when is_map(meta), do: emit(:session_created, %{}, base(meta))

  @spec session_updated(meta()) :: :ok
  def session_updated(meta) when is_map(meta), do: emit(:session_updated, %{}, base(meta))

  @spec reconnect(meta(), non_neg_integer()) :: :ok
  def reconnect(meta, attempt) when is_map(meta) and is_integer(attempt) and attempt >= 0 do
    emit(:reconnect, %{}, Map.put(base(meta), :attempt, attempt))
  end

  @spec provider_error(meta(), String.t()) :: :ok
  def provider_error(meta, reason) when is_map(meta) and is_binary(reason) do
    emit(:provider_error, %{}, Map.put(base(meta), :reason, Telemetry.preview(reason)))
  end

  @spec call_stop(meta(), map()) :: :ok
  def call_stop(meta, measurements) when is_map(meta) and is_map(measurements) do
    emit(:call_stop, measurements, base(meta))
  end

  defp base(meta) do
    %{
      agent: "realtime",
      session_id: meta.session_id,
      device_id: meta.device_id,
      model: meta.model,
      voice: meta.voice,
      session_scope: meta.session_scope
    }
  end

  defp emit(name, measurements, metadata) do
    :telemetry.execute([:fermix, :realtime, name], measurements, metadata)
  end
end
