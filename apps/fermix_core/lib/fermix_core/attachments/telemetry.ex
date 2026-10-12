defmodule FermixCore.Attachments.Telemetry do
  @moduledoc """
  The one emitter of `[:fermix, :attachment, :ingest]` (M67): one event per
  inbound attachment, once the gateway pipeline has settled what reached the
  model.

  Measurements: `duration_us` (download, classification and rendering of this
  attachment), `bytes` (its size), `rendered_bytes` (what rides the turn inline:
  the picture, the still, the PDF or the inlined text) and `parts` (content
  parts it adds). Metadata: `channel`, `kind`, `mime`, `outcome`
  (`:image | :poster | :document | :text | :transcript | :unusable`), `reason`
  (the unusable reason's leading atom, else nil) and `detail` (the whole reason,
  inspected and bounded to `@max_detail` characters, so an HTTP status or an
  exit reason reaches the trace, not only the log; else nil). The file name
  rides only when content capture is on; bytes never do.

  Pre-turn, like the transcription step: there is no session yet, so the trace
  records it as an `attachment_ingest` agent event and the Opik exporter does
  not subscribe.
  """

  alias FermixCore.Attachments
  alias FermixCore.Telemetry

  @event [:fermix, :attachment, :ingest]
  @max_detail 200

  @trace_event_definitions [
    %{
      event: @event,
      trace_type: :agent_event,
      agent_field: :kind,
      trace_event: "attachment_ingest"
    }
  ]

  @doc "Event definitions `FermixCore.Trace.TelemetryHandler` routes into the JSONL trace."
  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @spec emit_ingest(String.t(), Attachments.t(), non_neg_integer()) :: :ok
  def emit_ingest(channel, %Attachments{} = att, duration_us)
      when is_binary(channel) and is_integer(duration_us) and duration_us >= 0 do
    :telemetry.execute(
      @event,
      %{
        duration_us: duration_us,
        bytes: att.size_bytes || 0,
        rendered_bytes: rendered_bytes(att),
        parts: length(Attachments.parts([att]))
      },
      channel
      |> metadata(att)
      |> maybe_put_name(att)
    )
  end

  defp metadata(channel, att) do
    %{
      channel: channel,
      kind: att.kind,
      mime: att.mime_type,
      outcome: outcome(att),
      reason: reason(att.status),
      detail: detail(att.status)
    }
  end

  defp maybe_put_name(metadata, %Attachments{name: name}) do
    if Telemetry.capture_content?() and is_binary(name),
      do: Map.put(metadata, :name, name),
      else: metadata
  end

  defp outcome(%Attachments{status: {:unusable, _reason}}), do: :unusable
  defp outcome(%Attachments{status: :transcribed}), do: :transcript
  defp outcome(%Attachments{kind: :still}), do: :image
  defp outcome(%Attachments{kind: kind}) when kind in [:animation, :video], do: :poster
  defp outcome(%Attachments{kind: :document}), do: :document
  defp outcome(%Attachments{kind: :text}), do: :text

  defp reason({:unusable, reason}), do: elem(reason, 0)
  defp reason(_status), do: nil

  defp detail({:unusable, reason}),
    do: reason |> inspect(limit: 10, printable_limit: @max_detail) |> String.slice(0, @max_detail)

  defp detail(_status), do: nil

  defp rendered_bytes(%Attachments{status: :ready, poster: %{bytes: bytes}}), do: byte_size(bytes)

  defp rendered_bytes(%Attachments{status: :ready, bytes: bytes}) when is_binary(bytes),
    do: byte_size(bytes)

  defp rendered_bytes(%Attachments{}), do: 0
end
