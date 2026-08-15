defmodule FermixCore.Net.HttpClient do
  @moduledoc """
  Outbound HTTP wrapper with single-retry on stale-pool transport errors.

  Long-running daemons keep Finch HTTPS connection pools open to a small set
  of API hosts (OpenAI, ChatGPT, Telegram, Discord, Slack, WhatsApp). After
  the host machine sleeps or sits idle for hours, cloud LBs RST those
  connections without notifying the client. The first request after wake
  pulls a "live" pooled connection, hits the dead socket, and surfaces as
  `Req.TransportError{reason: :closed}` (or `:econnrefused` against some
  edges). A single retry opens a fresh connection and recovers transparently.

  Every request is pinned to the shared `FermixCore.Finch` pool (started in
  `FermixCore.Application`), whose `conn_max_idle_time` discards connections
  that sat idle too long at checkout — so the stale-socket class mostly
  self-heals before a request can hit it, and the retry below is guaranteed
  a freshly handshaked connection rather than a second dead socket from the
  same pool. Req forbids combining `:finch` with `:connect_options`, so
  callers must not pass `connect_options`; per-host connection options
  belong in the pool definition (see `FermixCore.Application`).

  This wrapper deliberately does NOT retry `:timeout` — a slow server should
  not be hammered. It also does NOT retry HTTP-level errors (4xx/5xx); use
  Req's own `:retry` option for those.

  Mid-stream `:closed` after some chunks have been consumed is also retried
  blindly here. That can occasionally cost a duplicate request when a real
  network blip hits mid-response. We accept the trade in exchange for
  recovering every wake-from-sleep failure transparently — the duplicate
  case is rare and the alternative is requiring per-caller bookkeeping for
  a single shared concern.

  Finch does NOT return an error tuple when a connection-pool checkout exceeds
  its queue timeout: it `reraise`s a `RuntimeError` ("Finch was unable to
  provide a connection within the timeout due to excess queuing for
  connections") in the caller. Unwrapped, that raise crashes the caller — a
  starved `api.telegram.org` pool once aborted an entire agent turn through the
  cosmetic typing indicator, surfacing only as the generic "I encountered an
  error" reply. `run/2` catches that raise and returns it as the
  `{:error, Exception.t()}` this function already promises, so a transient pool
  exhaustion fails the one request instead of the calling process. Programming
  errors (ArgumentError, FunctionClauseError, …) are not `RuntimeError`s and
  still crash loud.
  """

  require Logger

  @retry_reasons [:closed, :econnrefused]

  # Substring of the RuntimeError Finch reraises on a pool-checkout queue
  # timeout ("Finch was unable to provide a connection within the timeout due
  # to excess queuing for connections").
  @connection_unavailable_marker "unable to provide a connection"

  # Pool-checkout (queue) timeout. Finch's default is 5_000ms, but a per-host
  # pool process can block tearing down a stale keep-alive socket (a synchronous
  # `:ssl.close` on a half-open socket) — starving the very checkout that
  # triggered the teardown and surfacing as "excess queuing for connections".
  # There is NO bound on how long that blocks: `:ssl.close/2`'s 5000ms is only
  # the internal flush budget, while the outer `gen_statem` call runs with an
  # :infinity timeout, so a wedged socket can hold a pool process far longer
  # than any checkout budget. The wider budget therefore rides out the common
  # short teardown, not the pathological one; the checkout timeout is the escape
  # hatch, and callers treat the resulting error as retryable-before-response
  # (nothing was sent). Paired with a `count > 1` pool plus idle pool reaping
  # (see `FermixCore.Application.finch_pools/0`) so a blocked process is rarely
  # the only one. Applied to every shared-pool request.
  @pool_checkout_timeout_ms 15_000

  @spec request(Req.Request.t(), String.t()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(%Req.Request{} = req, label) when is_binary(label) do
    req = Req.merge(req, finch: FermixCore.Finch, pool_timeout: @pool_checkout_timeout_ms)

    case run(req, label) do
      {:error, %Req.TransportError{reason: reason}} when reason in @retry_reasons ->
        Logger.warning("#{label} transport #{reason} — retrying once with a fresh connection")
        run(req, label)

      result ->
        result
    end
  end

  # A Finch pool-checkout queue timeout reraises a RuntimeError rather than
  # returning {:error, _}. Convert it to the contract's error tuple so callers
  # treat pool exhaustion as an ordinary, non-fatal error. Pool exhaustion is
  # deliberately not retried here (the outer retry only matches transport
  # tuples) — re-queuing against an over-capacity pool would just hammer it.
  defp run(req, label) do
    Req.request(req)
  rescue
    exception in [RuntimeError] ->
      Logger.warning("#{label} HTTP request failed: #{Exception.message(exception)}")
      {:error, exception}
  end

  @doc """
  True when `exception` is the Finch pool-checkout queue timeout returned by
  `request/2` — the daemon could not obtain *any* connection before the
  checkout timed out.

  It fires whenever no pool process can hand over a connection in time:
  contention after a burst of concurrent requests, a pool process blocked
  tearing down stale sockets, or the wake-from-sleep case where the network is
  not ready yet and connects stall. Callers (e.g. the Codex adapter) use it to mint a typed
  `:connection_unavailable` transport error so transient-infrastructure
  recovery can key on the contract instead of a message string. Every other
  `RuntimeError` is a genuine bug and returns `false`.
  """
  @spec connection_unavailable?(Exception.t() | term()) :: boolean()
  def connection_unavailable?(%RuntimeError{message: message}) when is_binary(message) do
    String.contains?(message, @connection_unavailable_marker)
  end

  def connection_unavailable?(_other), do: false
end
