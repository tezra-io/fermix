defmodule FermixCore.Attachments.Telemetry do
  @moduledoc """
  The one emitter of the inbound attachment events (M67).

  `[:fermix, :attachment, :ingest]`: one event per inbound attachment, once the
  gateway pipeline has settled what reached the model. Measurements:
  `duration_us` (download, classification and rendering of this attachment),
  `bytes` (its size), `rendered_bytes` (what rides the turn inline: the picture,
  the frames or the still, the PDF or the inlined text) and `parts` (content
  parts it adds). Metadata: `channel`, `kind`, `mime`, `outcome`
  (`:image | :frames | :poster | :document | :text | :transcript | :unusable`),
  `reason` (the unusable reason's leading atom, such as `:render_failed`, else
  nil), `detail` (the whole reason, inspected and bounded to `@max_detail`
  characters, so an HTTP status or an ffmpeg exit reaches the trace, not only
  the log; else nil), `sound` (a video's sound: `:transcript | :no_speech |
  :no_sound | :failed`, else nil) and `sound_detail` (the transcription failure, bounded the
  same way). The file name rides only when content capture is on; bytes and
  transcripts never do. Pre-turn, like the transcription step: there is no
  session yet, so the trace records it as an `attachment_ingest` agent event.

  `[:fermix, :attachment, :save]`: one event per operator turn that kept
  attachments in the workspace (D1). Measurements: `duration_us` (prune and
  writes), `saved` and `failed` (attachments), `files` and `bytes` (written,
  stills and frames included), `pruned_files` and `pruned_bytes` (what the prune
  deleted). Metadata: `channel`, `session_id`, `outcome` (`:saved`, or `:failed`
  when any attachment was not saved) and `detail` (the first failure's sentence,
  bounded, else nil). The trace records it as an `attachment_save` agent event.

  The Opik exporter places the save under the turn's trace
  (`FermixOpik.Mapper.attachment_save_span/3`) and does not subscribe to the
  ingest, which has no session.
  """

  alias FermixCore.Attachments
  alias FermixCore.Telemetry

  @event [:fermix, :attachment, :ingest]
  @save_event [:fermix, :attachment, :save]
  @save_measurements [:saved, :failed, :files, :bytes, :pruned_files, :pruned_bytes]
  @max_detail 200

  @trace_event_definitions [
    %{
      event: @event,
      trace_type: :agent_event,
      agent_field: :kind,
      trace_event: "attachment_ingest"
    },
    %{
      event: @save_event,
      trace_type: :agent_event,
      agent_field: :channel,
      trace_event: "attachment_save"
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

  @typedoc "What one operator turn's workspace save did (`FermixCore.Attachments.Workspace`)."
  @type save_stats :: %{
          saved: non_neg_integer(),
          failed: non_neg_integer(),
          files: non_neg_integer(),
          bytes: non_neg_integer(),
          pruned_files: non_neg_integer(),
          pruned_bytes: non_neg_integer(),
          first_failure: String.t() | nil
        }

  @spec emit_save(String.t(), String.t() | nil, save_stats(), non_neg_integer()) :: :ok
  def emit_save(channel, session_id, %{first_failure: first_failure} = stats, duration_us)
      when is_binary(channel) and is_integer(duration_us) and duration_us >= 0 do
    :telemetry.execute(
      @save_event,
      stats |> Map.take(@save_measurements) |> Map.put(:duration_us, duration_us),
      %{
        channel: channel,
        session_id: session_id,
        outcome: if(stats.failed == 0, do: :saved, else: :failed),
        detail: bounded(first_failure)
      }
    )
  end

  defp metadata(channel, att) do
    %{
      channel: channel,
      kind: att.kind,
      mime: att.mime_type,
      outcome: outcome(att),
      reason: reason(att.status),
      detail: detail(att.status),
      sound: sound(att.sound),
      sound_detail: sound_detail(att.sound)
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

  defp outcome(%Attachments{kind: kind, frames: [_ | _]}) when kind in [:animation, :video],
    do: :frames

  defp outcome(%Attachments{kind: kind}) when kind in [:animation, :video], do: :poster
  defp outcome(%Attachments{kind: :document}), do: :document
  defp outcome(%Attachments{kind: :text}), do: :text

  defp reason({:unusable, reason}), do: elem(reason, 0)
  defp reason(_status), do: nil

  defp detail({:unusable, reason}), do: inspected(reason)
  defp detail(_status), do: nil

  defp sound({:transcript, _text}), do: :transcript
  defp sound(:no_speech), do: :no_speech
  defp sound(:no_sound), do: :no_sound
  defp sound({:failed, _reason}), do: :failed
  defp sound(nil), do: nil

  defp sound_detail({:failed, reason}), do: inspected(reason)
  defp sound_detail(_sound), do: nil

  defp inspected(reason),
    do: reason |> inspect(limit: 10, printable_limit: @max_detail) |> bounded()

  defp bounded(nil), do: nil
  defp bounded(text) when is_binary(text), do: String.slice(text, 0, @max_detail)

  defp rendered_bytes(%Attachments{status: :ready, frames: [_ | _] = frames}),
    do: frames |> Enum.map(&byte_size(&1.bytes)) |> Enum.sum()

  defp rendered_bytes(%Attachments{status: :ready, poster: %{bytes: bytes}}), do: byte_size(bytes)

  defp rendered_bytes(%Attachments{status: :ready, bytes: bytes}) when is_binary(bytes),
    do: byte_size(bytes)

  defp rendered_bytes(%Attachments{}), do: 0
end
