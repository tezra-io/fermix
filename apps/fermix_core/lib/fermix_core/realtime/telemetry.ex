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

  @doc """
  The call ended, with WHY it ended.

  Every terminal exit carries a reason — `:call_stop`, `:cost_limit`,
  `:max_session_duration`, `:provider_disconnected` — because a teardown that
  emitted nothing was exactly what made a live freeze invisible: the cost ceiling
  tore a call down with no log, no telemetry, and a companion frame the pet has no
  handler for. The reason rides as metadata; measurements stay numeric per
  `docs/TELEMETRY_CONTRACT.md`.
  """
  @spec call_stop(meta(), map(), atom()) :: :ok
  def call_stop(meta, measurements, reason \\ :call_stop)
      when is_map(meta) and is_map(measurements) and is_atom(reason) do
    emit(:call_stop, measurements, Map.put(base(meta), :reason, Atom.to_string(reason)))
  end

  @doc "Screen sharing started for this call (M9.5)."
  @spec screen_feed_start(meta(), non_neg_integer()) :: :ok
  def screen_feed_start(meta, display) when is_map(meta) and is_integer(display) do
    emit(:screen_feed_start, %{}, Map.put(base(meta), :display, display))
  end

  @doc """
  One screen frame appended to the live session as passive context.

  `gated_out` is how many captures were dropped as unchanged since the previous
  frame — the number that shows the change gate working (a static screen sends
  nothing at all, so absence of this event IS the healthy case).
  """
  @spec frame_sent(meta(), non_neg_integer(), non_neg_integer(), String.t()) :: :ok
  def frame_sent(meta, bytes, gated_out, detail)
      when is_map(meta) and is_integer(bytes) and is_integer(gated_out) and is_binary(detail) do
    emit(
      :frame_sent,
      %{bytes: bytes, gated_out: gated_out},
      Map.put(base(meta), :detail, detail)
    )
  end

  @doc """
  A frame was dropped because the provider socket was behind. Expected and healthy
  under load — the newest frame supersedes it — but a run full of these means the
  uplink cannot carry the configured cadence.
  """
  @spec frame_dropped(meta(), non_neg_integer()) :: :ok
  def frame_dropped(meta, bytes) when is_map(meta) and is_integer(bytes) do
    emit(:frame_dropped, %{bytes: bytes}, base(meta))
  end

  @doc "Screen sharing ended, with the typed reason (requested / cost / capture failure)."
  @spec screen_feed_stop(meta(), String.t(), map()) :: :ok
  def screen_feed_stop(meta, reason, measurements)
      when is_map(meta) and is_binary(reason) and is_map(measurements) do
    emit(:screen_feed_stop, measurements, Map.put(base(meta), :reason, Telemetry.preview(reason)))
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
