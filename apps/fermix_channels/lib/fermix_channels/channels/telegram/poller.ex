defmodule FermixChannels.Channels.Telegram.Poller do
  @moduledoc """
  Long-polls Telegram's getUpdates API for incoming messages.

  Startup/backlog policy:
  - The first poll cycle is a zero-timeout startup probe.
  - Any updates already queued in Telegram when the poller starts are treated as stale backlog.
  - The poller advances its offset past that backlog without processing it.
  - This also applies when switching from webhook mode to polling: queued pre-switch
    updates are dropped, and only updates that arrive after the startup probe are processed.

  Parsed messages are forwarded to `Gateway.AlbumBuffer` (a separate,
  non-blocking process) for album coalescing and dispatch. The poller never
  buffers or dispatches inline: it blocks for tens of seconds inside getUpdates
  long-polling, so an in-poller flush timer could not fire on time. Keeping the
  album buffer out of this process is what makes coalescing prompt.

  Reuses Telegram.parse_update/1 for message parsing.
  """

  use GenServer

  require Logger

  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Gateway.AlbumBuffer
  alias FermixChannels.Telemetry

  @bot_api_base "https://api.telegram.org"
  @default_error_backoff_ms 5_000
  @default_transient_backoff_ms 250
  @startup_probe_timeout 0
  @poll_timeout 50
  @receive_timeout_ms 60_000
  @transient_transport_errors [:closed, :timeout, :econnreset, :socket_closed_remotely]

  # Defined cap behavior (Rule 2): the POLL LOOP is unbounded by design — a
  # poller that stops polling is a dead channel, and a degraded one that stopped
  # could never observe its own recovery. What is bounded is the ESCALATION.
  # After this many consecutive failures the poller reports degraded exactly
  # once — to `/health` and to telemetry — and stops logging every attempt.
  # Prod logged 27,394 consecutive timeouts across two days at roughly one per
  # six seconds with no signal anywhere; five failures is ~30s of real outage.
  @default_degraded_after_failures 5
  @default_degraded_log_interval_ms 900_000

  @typedoc "Non-blocking view of the poll loop's health, published for `/health`."
  @type poll_health :: %{
          status: :polling | :degraded,
          consecutive_failures: non_neg_integer(),
          since: DateTime.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  Poll health for `/health`, read without touching the poller process.

  This must never become a `GenServer.call`. The poll loop blocks inside
  `Req.request/1` for up to the receive timeout, so a synchronous read would
  time out precisely when the channel is unhealthy — and on a healthy daemon
  that merely happens to be mid-long-poll, which is most of the time.

  `nil` means no poller has published health in this VM — a poller that does
  not exist, never one that is fine. `init/1` publishes on every start, so an
  absent entry is the honest answer rather than a fabricated healthy one.
  """
  @spec poll_health(atom()) :: poll_health() | nil
  def poll_health(name \\ __MODULE__) when is_atom(name) do
    :persistent_term.get(poll_health_key(name), nil)
  end

  @doc "Drops a poller's published health, as a healthy poll of the same poller does."
  @spec forget_poll_health(atom()) :: :ok
  def forget_poll_health(name \\ __MODULE__) when is_atom(name) do
    _erased? = :persistent_term.erase(poll_health_key(name))
    :ok
  end

  @impl true
  def init(opts) do
    state = %{
      offset: 0,
      startup_phase: :drain_backlog,
      req_options: Keyword.get(opts, :req_options, []),
      poll_interval: Keyword.get(opts, :poll_interval, :immediate),
      error_backoff_ms: Keyword.get(opts, :error_backoff_ms, @default_error_backoff_ms),
      transient_backoff_ms:
        Keyword.get(opts, :transient_backoff_ms, @default_transient_backoff_ms),
      buffer: Keyword.get(opts, :buffer, AlbumBuffer.name_for(Telegram)),
      name: Keyword.get(opts, :name, __MODULE__),
      consecutive_failures: 0,
      poll_status: :polling,
      degraded_since: nil,
      degraded_logged_at: nil,
      degraded_after_failures:
        Keyword.get(opts, :degraded_after_failures, @default_degraded_after_failures),
      degraded_log_interval_ms:
        Keyword.get(opts, :degraded_log_interval_ms, @default_degraded_log_interval_ms)
    }

    # Publish before the first poll. `:persistent_term` is VM-scoped but the
    # counter is process-scoped, so a poller that crashed while degraded would
    # otherwise restart clean on top of a stale `:degraded` entry that only a
    # recovery it can no longer reach would clear — pinning /health at 503 for
    # the life of the VM.
    state = publish_poll_health(state)

    if state.poll_interval == :immediate do
      send(self(), :poll)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:poll, %{startup_phase: :drain_backlog} = state) do
    {result, elapsed_ms} = probe_startup_backlog(state)

    case result do
      {:ok, updates, state} ->
        state =
          state
          |> note_poll_success()
          |> advance_offset(updates)
          |> Map.put(:startup_phase, :polling)

        if state.poll_interval == :immediate do
          send(self(), :poll)
        end

        {:noreply, state}

      {:error, reason, state} ->
        state = note_poll_failure(state, "startup probe", reason, elapsed_ms)
        schedule_error_retry(state, reason)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    {result, elapsed_ms} = do_poll(state)

    case result do
      {:ok, updates, state} ->
        process_updates(updates, state)

        state =
          state
          |> note_poll_success()
          |> advance_offset(updates)

        if state.poll_interval == :immediate do
          send(self(), :poll)
        end

        {:noreply, state}

      {:error, reason, state} ->
        state = note_poll_failure(state, "poll", reason, elapsed_ms)
        schedule_error_retry(state, reason)
        {:noreply, state}
    end
  end

  defp probe_startup_backlog(state) do
    timed_get_updates(state, @startup_probe_timeout)
  end

  defp do_poll(state) do
    timed_get_updates(state, @poll_timeout)
  end

  # Times the whole call, not just the HTTP leg: `get_updates/2` short-circuits
  # on a missing bot token before any request, and a fabricated 0 there would
  # read as a real 0ms network call. Every path reports a genuinely measured
  # value.
  defp timed_get_updates(state, timeout) do
    started = System.monotonic_time(:millisecond)
    result = get_updates(state, timeout)
    {result, System.monotonic_time(:millisecond) - started}
  end

  defp get_updates(state, timeout) do
    with {:ok, token} <- Telegram.get_bot_token() do
      url = "#{@bot_api_base}/bot#{token}/getUpdates"

      body = %{
        offset: state.offset,
        timeout: timeout,
        allowed_updates: ["message", "callback_query"]
      }

      result =
        Req.new(url: url, method: :post, json: body, receive_timeout: @receive_timeout_ms)
        |> Req.merge(state.req_options)
        |> Req.request()

      case result do
        {:ok, %{status: 200, body: %{"ok" => true, "result" => updates}}} ->
          {:ok, updates, state}

        {:ok, %{status: status, body: resp_body}} ->
          {:error, "Telegram API error #{status}: #{inspect(resp_body)}", state}

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Only an answered `getUpdates` clears the counter. Resetting on anything that
  # merely looks different — a new error shape, a transient/permanent switch —
  # is the bug that defeats strike counters: an outage that alternates two
  # failure kinds would never escalate.
  defp note_poll_success(%{poll_status: :degraded} = state) do
    Logger.warning(
      "Telegram poller recovered after #{state.consecutive_failures} consecutive failures"
    )

    Telemetry.emit_transport(:telegram, :recovered, state.consecutive_failures, :none)

    # Publish the recovered posture rather than erasing it: an absent entry
    # means "no poller", and this poller is very much alive.
    publish_poll_health(%{
      state
      | consecutive_failures: 0,
        poll_status: :polling,
        degraded_since: nil,
        degraded_logged_at: nil
    })
  end

  defp note_poll_success(state), do: %{state | consecutive_failures: 0}

  # One counter across both failure classes. The transient/non-transient split
  # below governs backoff only; a total outage that alternates `:closed` with an
  # HTTP 502 is still one outage and must still escalate.
  defp note_poll_failure(state, context, reason, elapsed_ms) do
    failures = state.consecutive_failures + 1
    state = %{state | consecutive_failures: failures}

    cond do
      failures < state.degraded_after_failures ->
        log_poll_error(context, reason, elapsed_ms, failures, state.degraded_after_failures)
        state

      state.poll_status == :polling ->
        enter_degraded(state, reason, elapsed_ms)

      degraded_relog_due?(state) ->
        relog_degraded(state, reason, elapsed_ms)

      true ->
        state
    end
  end

  defp enter_degraded(state, reason, elapsed_ms) do
    Logger.error(
      "Telegram poller degraded after #{state.consecutive_failures} consecutive failures " <>
        "(#{error_class(reason)}, elapsed_ms=#{elapsed_ms}): #{inspect(reason)}; polling continues"
    )

    Telemetry.emit_transport(
      :telegram,
      :degraded,
      state.consecutive_failures,
      error_class(reason)
    )

    state
    |> Map.merge(%{
      poll_status: :degraded,
      degraded_since: DateTime.utc_now(),
      degraded_logged_at: System.monotonic_time(:millisecond)
    })
    |> publish_poll_health()
  end

  defp relog_degraded(state, reason, elapsed_ms) do
    Logger.error(
      "Telegram poller still degraded after #{state.consecutive_failures} consecutive " <>
        "failures (#{error_class(reason)}, elapsed_ms=#{elapsed_ms}): #{inspect(reason)}"
    )

    state
    |> Map.put(:degraded_logged_at, System.monotonic_time(:millisecond))
    |> publish_poll_health()
  end

  defp degraded_relog_due?(%{degraded_logged_at: nil}), do: true

  defp degraded_relog_due?(state) do
    System.monotonic_time(:millisecond) - state.degraded_logged_at >=
      state.degraded_log_interval_ms
  end

  # Written on transitions and on the throttled re-log only. `:persistent_term`
  # copies the table on every write, so a put per failure would cost what the
  # per-attempt log line cost.
  defp publish_poll_health(state) do
    :persistent_term.put(poll_health_key(state.name), %{
      status: state.poll_status,
      consecutive_failures: state.consecutive_failures,
      since: state.degraded_since
    })

    state
  end

  defp poll_health_key(name), do: {__MODULE__, :poll_health, name}

  # A bounded atom for the trace; the raw reason still reaches the Logger, which
  # inspects it. In this module a binary reason is always the "Telegram API error
  # <status>: ..." string built by `get_updates/2`.
  defp error_class(%Req.TransportError{reason: reason}) when is_atom(reason), do: reason
  defp error_class(reason) when is_atom(reason), do: reason
  defp error_class(reason) when is_binary(reason), do: :api_error
  defp error_class({tag, _detail}) when is_atom(tag), do: tag
  defp error_class(_reason), do: :unclassified

  defp log_poll_error(context, reason, elapsed_ms, attempt, max_attempts) do
    suffix = "(attempt #{attempt}/#{max_attempts}, elapsed_ms=#{elapsed_ms})"

    if transient_transport_error?(reason) do
      Logger.warning("Telegram poller #{context} reconnecting after #{inspect(reason)} #{suffix}")
    else
      Logger.error("Telegram poller #{context} error #{suffix}: #{inspect(reason)}")
    end
  end

  defp schedule_error_retry(state, reason) do
    backoff =
      if transient_transport_error?(reason) do
        state.transient_backoff_ms
      else
        state.error_backoff_ms
      end

    Process.send_after(self(), :poll, backoff)
  end

  defp transient_transport_error?(%Req.TransportError{reason: reason})
       when reason in @transient_transport_errors,
       do: true

  defp transient_transport_error?(_reason), do: false

  # Forward each parsed message to the album buffer (a separate, non-blocking
  # process) for coalescing and dispatch. Returns :ok — the poller carries no
  # album state; offset advance is handled separately by the caller.
  defp process_updates(updates, state) do
    Enum.each(updates, fn update ->
      case Telegram.parse_update(update) do
        {:ok, messages} when messages != [] ->
          emit_inbound_telemetry(length(messages))
          Enum.each(messages, &AlbumBuffer.ingest(&1, state.buffer))
          maybe_ack_callback(update, state)

        _ ->
          :ok
      end
    end)
  end

  # An inline-button tap is dispatched as its synthesized `/confirm` message above;
  # here we clear the tap's spinner and strip the used button. Best-effort UI
  # cleanup — the token is single-use, so a tap always spends the button, and the
  # confirm result reaches the owner through the normal `/confirm` text reply.
  defp maybe_ack_callback(%{"callback_query" => callback}, state) when is_map(callback) do
    Telegram.acknowledge_callback(callback, req_options: state.req_options)
    :ok
  end

  defp maybe_ack_callback(_update, _state), do: :ok

  defp emit_inbound_telemetry(count) do
    :telemetry.execute(
      [:fermix, :channel, :message],
      %{count: count},
      %{channel: :telegram, direction: :inbound}
    )
  end

  defp advance_offset(state, []), do: state

  defp advance_offset(state, updates) do
    max_id =
      updates
      |> Enum.map(& &1["update_id"])
      |> Enum.max()

    %{state | offset: max_id + 1}
  end
end
