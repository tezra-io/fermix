defmodule FermixCore.Plugins.Dist.Telemetry do
  @moduledoc """
  Emitter for `[:fermix, :plugin, :dist]` — one event per distribution
  operation (`:install`, `:uninstall`, `:gc`) with its outcome and duration.
  Registered in `Trace.TelemetryHandler` and `FermixOpik` per
  `docs/TELEMETRY_CONTRACT.md`; never hand-roll this event elsewhere.
  """

  @event [:fermix, :plugin, :dist]

  @ops [:install, :uninstall, :gc]

  @doc "Monotonic start timestamp for a span, in milliseconds."
  @spec start() :: integer()
  def start, do: System.monotonic_time(:millisecond)

  @doc """
  Emit the outcome of a distribution op started at `started_ms` (from
  `start/0`). `result` is the op's return value verbatim — its tag is derived
  (`{:ok, :installed}` → `:installed`, `:ok` → `:ok`, `{:error, r}` →
  `:error` with `reason: r`).
  """
  @spec emit(atom(), String.t() | nil, String.t() | nil, term(), integer()) :: :ok
  def emit(op, plugin, version, result, started_ms)
      when op in @ops and is_integer(started_ms) do
    duration = System.monotonic_time(:millisecond) - started_ms

    :telemetry.execute(@event, %{duration_ms: duration}, %{
      op: op,
      plugin: plugin,
      version: version,
      result: result_tag(result),
      reason: result_reason(result)
    })
  end

  defp result_tag(:ok), do: :ok
  defp result_tag({:ok, tag}) when is_atom(tag), do: tag
  defp result_tag({:ok, _other}), do: :ok
  defp result_tag({:error, _reason}), do: :error

  defp result_reason({:error, reason}), do: reason
  defp result_reason(_result), do: nil
end
