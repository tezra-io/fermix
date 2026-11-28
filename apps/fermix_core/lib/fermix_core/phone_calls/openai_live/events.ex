defmodule FermixCore.PhoneCalls.OpenAILive.Events do
  @moduledoc """
  The sideband's server events, as the call worker reads them.

  `normalize/1` maps one decoded server event (a JSON object) to one tuple of
  the small vocabulary below. It is pure: it never reorders, never fills a
  missing field with a made-up value (a missing offset is `nil`, never `0`) and
  never infers a transition the event does not state. A `transport.answered`
  with no `transport.ringing` before it stays exactly that: the 3-second replay
  window means a late attach can miss earlier progress (OpenAI, *Telephony and
  SIP*).

  Every map carries the server's `event_id` (`nil` when the event has none)
  so a row or a trace can name the exact event.

  ## Vocabulary

    * `{:ringing, %{session_id, event_id}}` — `transport.ringing`: the carrier
      reports ringing or early media.
    * `{:answered, %{session_id, event_id}}` — `transport.answered`: the
      outbound leg answered and media is established. Answered says nothing
      about who answered (a person, a menu, voicemail).
    * `{:call_failed, %{session_id, code, message, param, event_id}}` —
      `transport.failed`: setup failed after initialization, with the vendor's
      own `error.code` and `error.message`.
    * `{:transcript, %{speaker, text, start_ms, end_ms, event_id}}` — one
      transcript fragment, verbatim. `speaker` is `:remote` for
      `session.input_transcript.delta` (what the model heard on the call) and
      `:assistant` for `session.output_transcript.delta` (what it said). A
      fragment is not a complete turn and may contain recognition mistakes.
    * `{:delegation, %{id, target, offset_ms, event_id}}` —
      `session.delegation.created`. It carries no request text; the request is
      in the transcript. Only a `target` of `"client"` is this application's to
      answer.
    * `{:usage, %{seconds, cumulative: true, context_usage_ratio, event_id}}` —
      `session.usage.updated`. `seconds` is the running total: replace the
      previous value, never add to it.
    * `{:dtmf_sent, %{key, client_event_id, event_id}}` — `transport.dtmf.sent`,
      the acknowledgement of one `transport.dtmf.send`; `client_event_id` is
      the `event_id` the send carried.
    * `{:dtmf_received, %{key, event_id}}` — `transport.dtmf.received`: the
      called party pressed a key.
    * `{:append_acked, %{kind, client_event_id, event_id}}` — the
      acknowledgement of an instructions, thinking or commentary append; `kind`
      is `:instructions`, `:thinking` or `:commentary`.
    * `{:session_started, %{session_id, expires_at, event_id}}` —
      `session.started`, when a replay carries it. `expires_at` is Unix seconds.
    * `{:session_closed, %{reason, seconds, event_id}}` — `session.closed`, the
      only event that confirms finalization. `reason` is the vendor's
      (`close_requested`, `expired`, `content`, `remote_hangup`,
      `connection_lost`); `seconds` is the final cumulative usage, `nil` when
      absent.
    * `{:vendor_error, %{type, code, message, param, client_event_id, event_id}}`
      — `error`, in the vendor's words. `client_event_id` names the client
      event it refuses (a DTMF send, an append), from `error.client_event_id`
      or the event's own.
    * `{:reflected_audio, :input | :output}` — reflected sideband audio. The
      sideband process discards it; it never reaches the call worker.
    * `{:malformed, type, event}` — a documented type without the field needed
      to act on it (a delegation with no id, usage with no number, a transcript
      with no text, an empty one included), or an object with no `type`.
    * `{:unknown, type, event}` — every other type, documented or future: kept
      observable, never a transition.

  ## Duplicates

  The sideband replays the last 3 seconds when it attaches, and replayed events
  keep their original `event_id`. `dedupe/2` drops an id it has already seen,
  within a bounded memory of the most recent `Limits.max_seen_event_ids/0` ids. Events with no
  id (reflected audio) are never treated as duplicates.
  """

  alias FermixCore.PhoneCalls.Limits

  @type speaker :: :remote | :assistant
  @type append_kind :: :instructions | :thinking | :commentary
  @type event_id :: String.t() | nil

  @type t ::
          {:ringing, %{session_id: String.t() | nil, event_id: event_id()}}
          | {:answered, %{session_id: String.t() | nil, event_id: event_id()}}
          | {:call_failed, map()}
          | {:transcript,
             %{
               speaker: speaker(),
               text: String.t(),
               start_ms: non_neg_integer() | nil,
               end_ms: non_neg_integer() | nil,
               event_id: event_id()
             }}
          | {:delegation,
             %{
               id: String.t(),
               target: String.t() | nil,
               offset_ms: non_neg_integer() | nil,
               event_id: event_id()
             }}
          | {:usage,
             %{
               seconds: number(),
               cumulative: true,
               context_usage_ratio: number() | nil,
               event_id: event_id()
             }}
          | {:dtmf_sent,
             %{key: String.t() | nil, client_event_id: event_id(), event_id: event_id()}}
          | {:dtmf_received, %{key: String.t() | nil, event_id: event_id()}}
          | {:append_acked,
             %{kind: append_kind(), client_event_id: event_id(), event_id: event_id()}}
          | {:session_started, map()}
          | {:session_closed,
             %{reason: String.t() | nil, seconds: number() | nil, event_id: event_id()}}
          | {:vendor_error, map()}
          | {:reflected_audio, :input | :output}
          | {:malformed, String.t() | nil, map()}
          | {:unknown, String.t(), map()}

  @opaque seen :: %{
            ids: MapSet.t(String.t()),
            order: :queue.queue(String.t()),
            cap: pos_integer()
          }

  @appended %{
    "session.instructions.appended" => :instructions,
    "session.thinking.appended" => :thinking,
    "session.commentary.appended" => :commentary
  }

  @doc "An empty memory of seen event ids, bounded to `cap` (default `Limits.max_seen_event_ids/0`)."
  @spec new_seen(pos_integer()) :: seen()
  def new_seen(cap \\ Limits.max_seen_event_ids()) when is_integer(cap) and cap > 0 do
    %{ids: MapSet.new(), order: :queue.new(), cap: cap}
  end

  @doc """
  `{:new, seen}` for an event to deliver, `:duplicate` for one whose
  `event_id` was already delivered. At the cap the oldest id is forgotten.
  """
  @spec dedupe(seen(), map()) :: {:new, seen()} | :duplicate
  def dedupe(%{ids: ids} = seen, %{"event_id" => id}) when is_binary(id) do
    if MapSet.member?(ids, id), do: :duplicate, else: {:new, remember(seen, id)}
  end

  def dedupe(%{ids: _ids} = seen, event) when is_map(event), do: {:new, seen}

  @doc "One decoded server event in the vocabulary above."
  @spec normalize(map()) :: t()
  def normalize(%{"type" => type} = event) when is_binary(type), do: by_type(type, event)
  def normalize(event) when is_map(event), do: {:malformed, nil, event}

  defp by_type("transport.ringing", event), do: {:ringing, progress(event)}
  defp by_type("transport.answered", event), do: {:answered, progress(event)}
  defp by_type("transport.failed", event), do: {:call_failed, call_failure(event)}
  defp by_type("session.input_transcript.delta", event), do: transcript(:remote, event)
  defp by_type("session.output_transcript.delta", event), do: transcript(:assistant, event)
  defp by_type("session.delegation.created", event), do: delegation(event)
  defp by_type("session.usage.updated", event), do: usage(event)
  defp by_type("transport.dtmf.sent", event), do: {:dtmf_sent, dtmf_sent(event)}
  defp by_type("transport.dtmf.received", event), do: {:dtmf_received, dtmf_received(event)}
  defp by_type("session.started", event), do: {:session_started, started(event)}
  defp by_type("session.closed", event), do: {:session_closed, closed(event)}
  defp by_type("error", event), do: {:vendor_error, vendor_error(event)}
  defp by_type("session.output_audio.delta", _event), do: {:reflected_audio, :output}
  defp by_type("session.input_audio.append", _event), do: {:reflected_audio, :input}

  defp by_type(type, event) when is_map_key(@appended, type),
    do: {:append_acked, appended(Map.fetch!(@appended, type), event)}

  defp by_type(type, event), do: {:unknown, type, event}

  defp progress(event), do: %{session_id: string(event, "session_id"), event_id: id(event)}

  defp call_failure(event) do
    error = map(event, "error")

    %{
      session_id: string(event, "session_id"),
      code: string(error, "code"),
      message: string(error, "message"),
      param: string(error, "param"),
      event_id: id(event)
    }
  end

  defp transcript(speaker, %{"delta" => text} = event) when is_binary(text) and text != "" do
    {:transcript,
     %{
       speaker: speaker,
       text: text,
       start_ms: offset(event, "start_ms"),
       end_ms: offset(event, "end_ms"),
       event_id: id(event)
     }}
  end

  defp transcript(_speaker, event), do: {:malformed, event["type"], event}

  defp delegation(%{"delegation" => %{"id" => delegation_id} = delegation} = event)
       when is_binary(delegation_id) and delegation_id != "" do
    {:delegation,
     %{
       id: delegation_id,
       target: string(delegation, "target"),
       offset_ms: offset(event, "offset_ms"),
       event_id: id(event)
     }}
  end

  defp delegation(event), do: {:malformed, event["type"], event}

  defp usage(%{"usage" => %{"seconds" => seconds}} = event)
       when is_number(seconds) and seconds >= 0 do
    {:usage,
     %{
       seconds: seconds,
       cumulative: true,
       context_usage_ratio: number(map(event, "context_window"), "usage_ratio"),
       event_id: id(event)
     }}
  end

  defp usage(event), do: {:malformed, event["type"], event}

  defp dtmf_sent(event) do
    %{
      key: string(event, "event"),
      client_event_id: string(event, "client_event_id"),
      event_id: id(event)
    }
  end

  defp dtmf_received(event), do: %{key: string(event, "event"), event_id: id(event)}

  defp appended(kind, event) do
    %{kind: kind, client_event_id: string(event, "client_event_id"), event_id: id(event)}
  end

  defp started(event) do
    session = map(event, "session")

    %{
      session_id: string(session, "id"),
      expires_at: integer(session, "expires_at"),
      event_id: id(event)
    }
  end

  defp closed(event) do
    %{
      reason: string(event, "reason"),
      seconds: number(map(event, "usage"), "seconds"),
      event_id: id(event)
    }
  end

  defp vendor_error(event) do
    error = map(event, "error")

    %{
      type: string(error, "type"),
      code: string(error, "code"),
      message: string(error, "message"),
      param: string(error, "param"),
      client_event_id: string(error, "client_event_id") || string(event, "client_event_id"),
      event_id: id(event)
    }
  end

  defp remember(%{ids: ids, order: order, cap: cap}, id) do
    {ids, order} = forget_oldest(ids, order, cap)
    %{ids: MapSet.put(ids, id), order: :queue.in(id, order), cap: cap}
  end

  defp forget_oldest(ids, order, cap) do
    if :queue.len(order) >= cap do
      {{:value, oldest}, order} = :queue.out(order)
      {MapSet.delete(ids, oldest), order}
    else
      {ids, order}
    end
  end

  defp id(event), do: string(event, "event_id")

  defp map(event, key) do
    case Map.get(event, key) do
      %{} = value -> value
      _absent -> %{}
    end
  end

  defp string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _absent -> nil
    end
  end

  defp number(map, key) do
    case Map.get(map, key) do
      value when is_number(value) -> value
      _absent -> nil
    end
  end

  defp integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _absent -> nil
    end
  end

  defp offset(event, key) do
    case Map.get(event, key) do
      value when is_integer(value) and value >= 0 -> value
      _absent -> nil
    end
  end
end
