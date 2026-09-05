defmodule FermixCore.ComputerHistory.Wire do
  @moduledoc """
  The Fermix side of the compux capture-mode wire (MILESTONE_32 §8.4a,
  `protocol_version` 6). The sidecar pushes NDJSON frames on its Port after
  `observe_start`; each line is one JSON object discriminated by `"type"`:

    * `{"type":"event", ...}` — an unsolicited captured interaction event
    * `{"type":"ack", "action":..., "protocol_version":6, ...}` — a solicited
      response to `observe_start`/`observe_stop`

  This module is a **pure codec**: it decodes one line into a typed result and
  maps an `event` frame onto the atom-keyed event map `Ingest` consumes (the
  `computer_history_events` columns, §7.1). It never touches a Port — the
  `Capturer` owns the Port and calls `decode/1` per inbound line. A malformed or
  under-specified frame decodes to `{:error, reason}` so the `Capturer` can
  emit an `observer.gap`, never crash on hostile input.

  Field mapping is **explicit**, never a blanket string→atom conversion: the
  frame carries untrusted content, so only the known columns are lifted (no
  atom-table growth from an attacker-controlled key), with three renames — the
  frame's `"type"` is the discriminator so the event's own taxonomy type is
  `"kind"` → `:type`, `"seq"` → `:source_seq`, and `app.bundle_id` → `:bundle_id`.
  `scan_flag` is deliberately absent from the wire: `Ingest` computes it from the
  injection scan, so the sidecar can never assert a false verdict.

  Timestamps are **range-checked here**: `ts`, and `gap_from_ts`/`gap_to_ts` when
  present, must be epoch milliseconds between 2000-01-01 and 2100-01-01; anything
  else is `{:error, {:invalid_field, name}}`. A far-future `ts` is never swept by
  the time-based retention (it stays newer than every cutoff) and every render of
  it would be a date decades away, so it is refused at the boundary rather than
  stored — the `Capturer` turns the refusal into an `observer.gap`, which is the
  honest record of an unusable frame.
  """

  @type frame :: {:event, map()} | {:ack, map()} | {:error, term()}

  # Wire event field -> event-map column atom, as a compile-time map so the
  # atoms are minted here (never `String.to_existing_atom` at runtime, which
  # would depend on load order). `kind`/`seq`/`app` are handled bespoke.
  @string_fields %{
    "prev_bundle_id" => :prev_bundle_id,
    "window_title" => :window_title,
    "page_title" => :page_title,
    "url" => :url,
    "host" => :host,
    "role" => :role,
    "role_desc" => :role_desc,
    "field_label" => :field_label,
    "text" => :text,
    "browser_id" => :browser_id,
    "window_ref" => :window_ref,
    "tab_ref" => :tab_ref,
    "private_state" => :private_state,
    "gap_reason" => :gap_reason
  }

  @integer_fields %{
    "gap_from_ts" => :gap_from_ts,
    "gap_to_ts" => :gap_to_ts,
    "char_len" => :char_len
  }

  # Epoch-ms sanity window: 2000-01-01 .. 2100-01-01. Retention sweeps by `ts`,
  # so a far-future stamp would never expire, and the summarizer would render it
  # as a date decades out on every batch.
  @min_ts 946_684_800_000
  @max_ts 4_102_444_800_000

  # The gap bounds that carry a time and must therefore be sane.
  @bounded_ts_fields ["gap_from_ts", "gap_to_ts"]

  @doc """
  Decode one inbound NDJSON line into a typed frame. Returns `{:error, reason}`
  for malformed JSON, an unknown/missing `type`, or an event missing a required
  field — the caller turns that into an `observer.gap`, never a crash.
  """
  @spec decode(binary()) :: frame()
  def decode(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "event"} = frame} -> decode_event(frame)
      {:ok, %{"type" => "ack"} = frame} -> {:ack, decode_ack(frame)}
      {:ok, %{"type" => other}} -> {:error, {:unknown_frame_type, other}}
      {:ok, _no_type} -> {:error, :missing_frame_type}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:bad_json, Exception.message(error)}}
    end
  end

  defp decode_event(frame) do
    with {:ok, boot_id} <- required_string(frame, "boot_id"),
         {:ok, source_seq} <- required_int(frame, "seq"),
         {:ok, ts} <- required_ts(frame, "ts"),
         {:ok, type} <- required_string(frame, "kind"),
         :ok <- bounded_ts_fields(frame) do
      {:event, build_event(frame, boot_id, source_seq, ts, type)}
    end
  end

  defp required_ts(frame, key) do
    with {:ok, ts} <- required_int(frame, key) do
      if in_epoch_window?(ts), do: {:ok, ts}, else: {:error, {:invalid_field, key}}
    end
  end

  # A non-integer bound is dropped by `put_integer_fields`, as before; an integer
  # one has to be sane, or the event claims a gap over a century.
  defp bounded_ts_fields(frame) do
    Enum.reduce_while(@bounded_ts_fields, :ok, fn key, :ok ->
      case Map.get(frame, key) do
        value when is_integer(value) -> bound_result(key, value)
        _absent_or_non_int -> {:cont, :ok}
      end
    end)
  end

  defp bound_result(key, value) do
    if in_epoch_window?(value), do: {:cont, :ok}, else: {:halt, {:error, {:invalid_field, key}}}
  end

  defp in_epoch_window?(ts), do: ts >= @min_ts and ts <= @max_ts

  defp build_event(frame, boot_id, source_seq, ts, type) do
    base = %{
      boot_id: boot_id,
      source_seq: source_seq,
      ts: ts,
      type: type,
      bundle_id: nested_bundle_id(frame),
      content_withheld: bool_field(frame, "content_withheld")
    }

    base
    |> put_string_fields(frame)
    |> put_integer_fields(frame)
  end

  # The app object is optional (system/gap events have no app); a missing or
  # malformed `app` yields a nil bundle_id. Ingest lets a nil bundle_id past the
  # app allowlist ONLY for the metadata-only kinds (`observer.gap`, `system.*`,
  # `session.*`, `user.switched`); an app-less content or app kind is dropped
  # there (§13.5 / inv. 11) — the decoder never has to judge it.
  defp nested_bundle_id(%{"app" => %{"bundle_id" => bundle}}) when is_binary(bundle), do: bundle
  defp nested_bundle_id(_frame), do: nil

  defp put_string_fields(event, frame) do
    Enum.reduce(@string_fields, event, fn {field, column}, acc ->
      case Map.get(frame, field) do
        value when is_binary(value) -> Map.put(acc, column, value)
        _absent_or_non_string -> acc
      end
    end)
  end

  defp put_integer_fields(event, frame) do
    Enum.reduce(@integer_fields, event, fn {field, column}, acc ->
      case Map.get(frame, field) do
        value when is_integer(value) -> Map.put(acc, column, value)
        _absent_or_non_int -> acc
      end
    end)
  end

  defp decode_ack(frame) do
    %{
      action: Map.get(frame, "action"),
      ok: Map.get(frame, "ok") == true,
      protocol_version: Map.get(frame, "protocol_version")
    }
  end

  defp bool_field(frame, key), do: Map.get(frame, key) == true

  defp required_string(frame, key) do
    case Map.get(frame, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:missing_field, key}}
    end
  end

  defp required_int(frame, key) do
    case Map.get(frame, key) do
      value when is_integer(value) -> {:ok, value}
      _missing -> {:error, {:missing_field, key}}
    end
  end
end
