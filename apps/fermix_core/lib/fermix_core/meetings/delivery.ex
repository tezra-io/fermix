defmodule FermixCore.Meetings.Delivery do
  @moduledoc """
  Where a finished meeting's notes go, and the one bounded attempt ladder that
  gets them there (MILESTONE_21 C2 §10).

  The Session calls this inline from its `summarizing` completion step, so this
  module owns three things and nothing else: resolving the destination, building
  the delivered text in exactly one place, and retrying only what is worth
  retrying.

  Resolution is **one deterministic path per origin shape**, never a chain of
  attempts — the `Delivery.OwnerInbox` "one concept, one resolver" rule. A
  meeting requested from a channel conversation has an `origin_session_id` of
  the `platform:destination:thread_scope` shape (the exact
  `Jobs.Delivery.origin_target/1` split), and its notes go back to that
  conversation. Everything else — a nil origin, a `cron_*`/job session id, an
  unparseable id, or a platform that is not a configured send target — is a
  meeting with no conversation of its own, and its notes go to the owner's
  inbox. Those are two origin *configurations*, not two tries at one.

  When neither rung answers, `{:error, :no_delivery_target}` comes back rather
  than a swallowed success: the Session records the row `failed` with the
  artifact path in the error text, so `list_meetings` still surfaces a summary
  that exists on disk but could not be sent.

  Retry is bounded by `@max_attempts` with fixed backoff and classifies through
  `transient?/1`. The classifier reads the closed vocabulary the channel
  adapters already return (`FermixCore.Delivery.Error`): timeouts, closed
  transports, and 5xx. A 4xx, an unknown adapter, or a missing credential is
  terminal on the first attempt — resending cannot fix it and would only
  duplicate the notes if it did.
  """

  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Delivery.OwnerInbox

  @max_attempts 3

  # Between attempts 1→2 and 2→3. Indexed by the attempt that just failed.
  @retry_backoff_ms [5_000, 25_000]

  # Per attempt, via `ChannelSend.with_timeout/2` — a wedged adapter can never
  # hold the Session, which is still the meeting's only live process.
  @send_timeout_ms 60_000

  @root_scope "root"

  # Transport reasons that are weather rather than a defect, mirroring
  # `Delivery.Error`'s `@transport_reasons` table so the two classifiers cannot
  # disagree about what a dropped connection is.
  @transient_transport_reasons [
    :closed,
    :timeout,
    :econnrefused,
    :econnreset,
    :ehostunreach,
    :enetunreach,
    :nxdomain
  ]

  @type target :: %{platform: String.t(), destination: String.t(), opts: keyword()}

  @typedoc """
  The finished meeting as Delivery reads it. `:duration_ms` and
  `:participants_peak` are the Session's own run counters, not columns on the
  meetings row, and `:end_reason` is the §2.7 end-cause atom.
  """
  @type meeting :: %{
          required(:url) => String.t(),
          required(:artifact_dir) => String.t(),
          required(:duration_ms) => non_neg_integer(),
          required(:participants_peak) => non_neg_integer(),
          optional(:title) => String.t() | nil,
          optional(:end_reason) => atom() | nil,
          optional(:origin_session_id) => String.t() | nil
        }

  @doc """
  Sends the meeting notes and returns once they are delivered or terminally not.

  `opts` carries the test seams — `:channel_send` (a module exporting
  `resolve_adapter/2`, `with_timeout/2` and `send/5`, default
  `FermixCore.Delivery.ChannelSend`), `:owner_inbox` (default
  `FermixCore.Delivery.OwnerInbox`), and `:sleep_fn` for the backoff — plus the
  `:adapter`/`:channels` seams `ChannelSend` itself understands.
  """
  @spec deliver(meeting(), String.t(), keyword()) ::
          {:ok, :sent} | {:error, :no_delivery_target} | {:error, term()}
  def deliver(meeting, text, opts \\ [])
      when is_map(meeting) and is_binary(text) and is_list(opts) do
    case resolve_target(meeting, opts) do
      {:ok, target} -> send_with_retry(target, message_text(meeting, text), opts, 1)
      :no_delivery_target -> {:error, :no_delivery_target}
    end
  end

  @doc """
  True only for send failures another attempt could plausibly clear.

  The shapes are the ones the channel adapters actually produce: the closed
  `Delivery.Error` vocabulary, the raw transport structs beneath it, and the
  bare timeout atoms the watchdog and the CLI-backed adapters return.
  """
  @spec transient?(term()) :: boolean()
  def transient?(:timeout), do: true
  def transient?({:timeout, _detail}), do: true
  def transient?(:delivery_timeout), do: true
  def transient?(:closed), do: true
  def transient?(:transport_closed), do: true
  def transient?({:transport, kind}), do: kind in @transient_transport_reasons

  def transient?(%Mint.TransportError{reason: reason}),
    do: reason in @transient_transport_reasons

  def transient?(%Req.TransportError{reason: reason}),
    do: reason in @transient_transport_reasons

  def transient?({:http_status, status}) when is_integer(status), do: status >= 500
  def transient?({:http_status, status, _body}) when is_integer(status), do: status >= 500
  def transient?(_reason), do: false

  # --- resolution ----------------------------------------------------------

  defp resolve_target(meeting, opts) do
    case channel_origin(Map.get(meeting, :origin_session_id), opts) do
      {:ok, target} -> {:ok, target}
      :not_a_channel_origin -> owner_inbox_target(opts)
    end
  end

  defp channel_origin(session_id, opts) when is_binary(session_id) do
    case String.split(session_id, ":", parts: 3) do
      [platform, destination, scope] when platform != "" and destination != "" ->
        channel_target(platform, destination, scope, opts)

      _parts ->
        :not_a_channel_origin
    end
  end

  defp channel_origin(_session_id, _opts), do: :not_a_channel_origin

  # A parseable origin whose platform is not a configured send target is not a
  # conversation Fermix can answer in, so it is an owner-inbox meeting — not a
  # send that fails at the adapter after every gate reported OK.
  defp channel_target(platform, destination, scope, opts) do
    case channel_send(opts).resolve_adapter(platform, send_opts(opts)) do
      {:ok, _adapter} ->
        {:ok, %{platform: platform, destination: destination, opts: scope_opts(scope)}}

      {:error, _reason} ->
        :not_a_channel_origin
    end
  end

  defp scope_opts(@root_scope), do: []
  defp scope_opts(scope), do: [thread_ts: scope, message_thread_id: scope]

  defp owner_inbox_target(opts) do
    case owner_inbox(opts).resolve([]) do
      {:ok, %{platform: platform, destination: destination}} ->
        {:ok, %{platform: platform, destination: destination, opts: []}}

      :no_delivery_target ->
        :no_delivery_target
    end
  end

  # --- send ladder ---------------------------------------------------------

  defp send_with_retry(target, text, opts, attempt) do
    case attempt_send(target, text, opts) do
      :ok -> {:ok, :sent}
      {:error, reason} -> retry_or_fail(target, text, opts, attempt, reason)
      other -> {:error, {:delivery_failed, {:unexpected_delivery_result, other}}}
    end
  end

  defp retry_or_fail(target, text, opts, attempt, reason) do
    if attempt < @max_attempts and transient?(reason) do
      sleep(opts, Enum.at(@retry_backoff_ms, attempt - 1))
      send_with_retry(target, text, opts, attempt + 1)
    else
      {:error, {:delivery_failed, reason}}
    end
  end

  # `delivery_max_attempts: 1` keeps `ChannelSend`'s own transient loop from
  # stacking underneath this one (the `Temporal.Delivery.send_once/6` rule).
  defp attempt_send(target, text, opts) do
    channel_send = channel_send(opts)
    send_opts = Keyword.put(send_opts(opts), :delivery_max_attempts, 1)

    channel_send.with_timeout(@send_timeout_ms, fn ->
      channel_send.send(target.platform, target.destination, text, target.opts, send_opts)
    end)
  end

  defp sleep(opts, backoff_ms), do: Keyword.get(opts, :sleep_fn, &Process.sleep/1).(backoff_ms)

  # --- the delivered text --------------------------------------------------

  defp message_text(meeting, summary_text) do
    lines = warning_line(meeting) ++ [header(meeting), summary_text, "", artifacts_line(meeting)]
    Enum.join(lines, "\n")
  end

  defp header(meeting) do
    "📝 Meeting notes — #{title_or_url(meeting)} " <>
      "(#{div(Map.fetch!(meeting, :duration_ms), 60_000)}m, " <>
      "#{Map.fetch!(meeting, :participants_peak)} participants)"
  end

  defp artifacts_line(meeting) do
    "Transcript & artifacts: #{Map.fetch!(meeting, :artifact_dir)}"
  end

  defp title_or_url(meeting) do
    case Map.get(meeting, :title) do
      title when is_binary(title) and title != "" -> title
      _untitled -> Map.fetch!(meeting, :url)
    end
  end

  # §2.7: a capture cut short is labelled degradation, never a quietly shorter
  # set of notes. Every other end cause is a normal ending and says nothing.
  defp warning_line(%{end_reason: reason} = meeting)
       when reason in [:sidecar_crashed, :rtms_stream_lost, :stt_stream_failed] do
    ["⚠️ Capture ended early (#{reason}) — notes cover the first #{mm_ss(meeting)} only."]
  end

  defp warning_line(_meeting), do: []

  defp mm_ss(meeting) do
    seconds = div(Map.fetch!(meeting, :duration_ms), 1_000)
    "#{pad(div(seconds, 60))}:#{pad(rem(seconds, 60))}"
  end

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  # --- seams ---------------------------------------------------------------

  defp channel_send(opts), do: Keyword.get(opts, :channel_send, ChannelSend)
  defp owner_inbox(opts), do: Keyword.get(opts, :owner_inbox, OwnerInbox)
  defp send_opts(opts), do: Keyword.take(opts, [:adapter, :channels])
end
