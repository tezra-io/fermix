defmodule FermixCore.Timeouts.Telemetry do
  @moduledoc """
  The single emitter for `[:fermix, :timeout, :expired]`.

  One **stable** event name; the specific timeout `name` rides in metadata. A
  dynamic `[:fermix, :timeout, <name>]` tail would never be delivered — both
  `FermixCore.Trace.TelemetryHandler` and `FermixOpik.Reporter` bind exact event
  names, so a varying last element silently drops.

  Correlation identifiers (`:session_id`, `:parent_session`) always ride the
  event so a timeout nests under the run that hit it. Any other context is
  attached only when `FermixCore.Telemetry.capture_content?/0` is true, and is
  redacted first — mirroring `Tools.Telemetry`/`Providers.Telemetry`, content
  never leaks into always-on traces.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Telemetry

  @doc "Emit one `[:fermix, :timeout, :expired]` event for a fired failure deadline."
  @spec emit_expired(atom(), non_neg_integer(), map()) :: :ok
  def emit_expired(name, ms, ctx)
      when is_atom(name) and is_integer(ms) and ms >= 0 and is_map(ctx) do
    metadata =
      %{name: name}
      |> Map.merge(Telemetry.correlation(ctx))
      |> maybe_put_context(ctx)

    :telemetry.execute([:fermix, :timeout, :expired], %{ms: ms}, metadata)
  end

  defp maybe_put_context(metadata, ctx) do
    if Telemetry.capture_content?() do
      Map.put(metadata, :context, Telemetry.preview(Redaction.redact(ctx)))
    else
      metadata
    end
  end
end
