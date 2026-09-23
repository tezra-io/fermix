defmodule FermixCore.Realtime.LiveFrames do
  @moduledoc """
  The companion frames a Live call sends, built in one place.

  These payloads ARE the local wire contract (`Protocol` v2, exported in
  `priv/realtime/`), and `fermix-macos` vendors that contract by checksum. So
  every vocabulary word a Live call can emit — a `state` value, a `task` status,
  an `error` kind — is enumerated here and guarded: an undocumented word fails
  loud at the boundary instead of reaching a companion that renders it as
  nothing.

  Frames are compacted: a key whose value is `nil` is ABSENT, because the schema
  distinguishes "unknown" (no `provider_session_id` yet) from a null, and the
  companion decodes optional fields, not nullable ones.
  """

  alias FermixCore.Realtime.LiveText

  # Documented in PROTOCOL.md. The vocabulary is open and additive there, which
  # is exactly why a new value must be added deliberately rather than typed at a
  # call site: an unknown value renders as idle on every shipped companion.
  @states ~w(idle listening speaking muted thinking reconnecting)
  @task_statuses ~w(pending running completed failed cancelled)
  @speakers ~w(user assistant)

  # The wire's own bound on `task.summary`.
  @summary_max_chars 240

  @doc "Turn or session state."
  @spec state(String.t()) :: map()
  def state(value) when value in @states, do: %{type: "state", state: value}

  @doc "One chunk of generated speech, base64 as the provider sent it."
  @spec audio_delta(String.t()) :: map()
  def audio_delta(audio) when is_binary(audio), do: %{type: "audio_delta", audio: audio}

  @doc "Drop whatever is queued for playback right now."
  @spec playback_stop() :: map()
  def playback_stop, do: %{type: "playback_stop"}

  @doc "One verbatim transcript fragment."
  @spec caption(String.t(), String.t(), non_neg_integer(), non_neg_integer()) :: map()
  def caption(speaker, delta, start_ms, end_ms)
      when speaker in @speakers and is_binary(delta) and
             is_integer(start_ms) and start_ms >= 0 and
             is_integer(end_ms) and end_ms >= 0 do
    %{type: "caption", speaker: speaker, delta: delta, start_ms: start_ms, end_ms: end_ms}
  end

  @doc "The provider session is up and the call can carry audio."
  @spec call_ready(String.t(), String.t(), String.t() | nil, integer() | nil) :: map()
  def call_ready(engine, call_id, provider_session_id, expires_at)
      when is_binary(engine) and is_binary(call_id) do
    compact(%{
      type: "call_ready",
      engine: engine,
      call_id: call_id,
      provider_session_id: provider_session_id,
      expires_at: expires_at,
      captions: true
    })
  end

  @doc "One backend delegation's lifecycle. `summary` is bounded to the wire's limit."
  @spec task(String.t(), pos_integer(), String.t(), String.t() | nil) :: map()
  def task(delegation_id, revision, status, summary)
      when is_binary(delegation_id) and delegation_id != "" and
             is_integer(revision) and revision >= 1 and status in @task_statuses do
    compact(%{
      type: "task",
      delegation_id: delegation_id,
      revision: revision,
      status: status,
      summary: LiveText.summary(summary, @summary_max_chars)
    })
  end

  @doc """
  The call's spend, from `LiveLedger.usage_payload/1`.

  `status` overrides the ledger's own `"live"` for the one frame that reports a
  ceiling kill, so the companion can tell a routine update from the reason the
  call is ending.
  """
  @spec usage(map(), String.t() | nil) :: map()
  def usage(payload, status \\ nil) when is_map(payload) do
    payload
    |> Map.put(:type, "usage")
    |> put_status(status)
  end

  @doc """
  A terminal failure the companion should show.

  Deliberately NOT sent for a recoverable provider error: the companion treats
  `error` as the end of the call.

  `reason` is a `term()`, not an atom: the terminal reasons a caller names are
  atoms, but a transport failure arrives as whatever the library raised, and
  this frame is the LAST thing the companion hears — raising while building it
  costs the operator the call and the explanation both. `LiveText.reason/1`
  renders anything; `detail` is the vendor's own bounded sentence.
  """
  @spec error(term(), String.t() | nil) :: map()
  def error(reason, detail \\ nil) do
    compact(%{
      type: "error",
      reason: LiveText.reason(reason),
      kind: error_kind(reason),
      detail: LiveText.summary(detail, @summary_max_chars)
    })
  end

  @doc """
  The published `error.kind` for a terminal reason, or `nil` when the reason has
  no documented kind (the companion then falls back to `reason` alone).
  """
  @spec error_kind(term()) :: String.t() | nil
  def error_kind(:voice_bridge_unavailable), do: "bridge_unavailable"
  def error_kind(:bridge_unavailable), do: "bridge_unavailable"
  def error_kind(:cost_limit), do: "cost_limit"
  def error_kind(:session_expired), do: "session_expired"
  def error_kind(:close_timeout), do: "close_timeout"
  def error_kind(:max_session_duration), do: "max_session_duration"
  def error_kind(:provider_disconnected), do: "provider_disconnected"
  def error_kind(:provider_refused), do: "provider_refused"
  def error_kind(_reason), do: nil

  defp put_status(payload, nil), do: payload
  defp put_status(payload, status) when is_binary(status), do: Map.put(payload, :status, status)

  defp compact(frame) do
    Enum.reduce(frame, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end
end
