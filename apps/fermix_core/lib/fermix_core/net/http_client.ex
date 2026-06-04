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
  """

  require Logger

  @retry_reasons [:closed, :econnrefused]

  @spec request(Req.Request.t(), String.t()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(%Req.Request{} = req, label) when is_binary(label) do
    req = Req.merge(req, finch: FermixCore.Finch)

    case Req.request(req) do
      {:error, %Req.TransportError{reason: reason}} when reason in @retry_reasons ->
        Logger.warning("#{label} transport #{reason} — retrying once with a fresh connection")
        Req.request(req)

      result ->
        result
    end
  end
end
