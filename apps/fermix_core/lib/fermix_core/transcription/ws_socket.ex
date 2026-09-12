defmodule FermixCore.Transcription.WsSocket do
  @moduledoc """
  The WebSocket transport both native transcription streamers share.

  Deliberately dumb: it carries frames and reports disconnects, and decodes
  nothing — each vendor's codec lives in its own session module. Sends are
  casts, so a slow uplink can queue on the socket process instead of blocking
  (or killing, via a `:gen.call` exit) the session that owns the audio.

  Started with `WebSockex.start/4`, never `start_link/4`: the owning session
  monitors this pid, and a socket crash must arrive as a `:DOWN` the session can
  reconnect from rather than a signal that takes the session down with it. There
  is no reconnect here either — `handle_disconnect/2` returns `{:ok, state}`, so
  the socket stops and the session's own bounded reconnect policy decides what
  happens next.

  The peer is verified against the OS trust store via `FermixCore.Net.Tls` —
  the vendor's API key travels in the handshake headers, so an unverified socket
  would hand it to whoever answered.

  The connect deadline is `FermixCore.Timeouts.transcription_ws_connect/0`,
  enforced by WebSockex's own `handshake_timeout`. A blown handshake surfaces as
  `{:error, reason}` from `start/1`, which the session returns from its `open`
  — there is no `Timeouts.expired/3` call for it, and no second timer belongs
  here.

  Messages to `parent`:

  | Message | When |
  |---|---|
  | `{:transcription_ws, socket, {:frame, {:text, payload}}}` | a text frame arrived |
  | `{:transcription_ws, socket, {:frame, {:binary, payload}}}` | a binary frame arrived (neither vendor sends these; sessions count them as malformed) |
  | `{:transcription_ws, socket, {:sent, bytes}}` | a queued binary frame reached the wire (text frames are not acked) |
  | `{:transcription_ws, socket, {:disconnect, status}}` | the connection dropped; the socket stops right after |

  The `:sent` acknowledgement is what bounds this process's mailbox. Sends are
  casts, so a vendor that stops draining leaves this process blocked inside one
  write while every later cast queues behind it — and because the process is
  single-threaded, an ack for frame N proves every earlier send completed. Bytes
  cast minus bytes acked is therefore the session's measure of that backlog, to
  within the one frame being written; a wedged socket simply stops acking, which
  is exactly the signal `FermixCore.Transcription.Outbox` watches.
  """

  use WebSockex

  alias FermixCore.Net.Tls
  alias FermixCore.Timeouts

  @doc """
  Connects to `opts[:url]` with `opts[:headers]`, reporting frames and the
  disconnect to `opts[:parent]`. Returns once the handshake completed.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts) when is_list(opts) do
    url = Keyword.fetch!(opts, :url)
    headers = Keyword.fetch!(opts, :headers)
    parent = Keyword.fetch!(opts, :parent)

    with {:ok, start_opts} <- start_options(url, headers) do
      WebSockex.start(url, __MODULE__, %{parent: parent}, start_opts)
    end
  end

  @doc """
  The `WebSockex` options for `url`, or `{:error, :ws_url_without_host}` when
  the URL names no host.

  A hostless URL is refused here, before the dial, because there would be
  nothing to verify the peer against — and dialing anyway means WebSockex's
  `verify_none`, which is exactly the posture `Tls.client_options/2` exists to
  replace.
  """
  @spec start_options(String.t(), [{String.t(), String.t()}]) ::
          {:ok, keyword()} | {:error, :ws_url_without_host}
  def start_options(url, headers) when is_binary(url) and is_list(headers) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        {:ok,
         [
           extra_headers: headers,
           handshake_timeout: Timeouts.transcription_ws_connect(),
           ssl_options: Tls.client_options(host)
         ]}

      %URI{} ->
        {:error, :ws_url_without_host}
    end
  end

  @doc "Queues a binary frame (audio) on the socket. Never blocks the caller."
  @spec send_binary(pid(), binary()) :: :ok
  def send_binary(socket, payload) when is_pid(socket) and is_binary(payload),
    do: WebSockex.cast(socket, {:send_frame, {:binary, payload}})

  @doc "Queues a text frame (a control message) on the socket. Never blocks the caller."
  @spec send_text(pid(), String.t()) :: :ok
  def send_text(socket, payload) when is_pid(socket) and is_binary(payload),
    do: WebSockex.cast(socket, {:send_frame, {:text, payload}})

  @doc "Closes the connection. The socket then stops and the session sees its `:DOWN`."
  @spec close(pid()) :: :ok
  def close(socket) when is_pid(socket), do: WebSockex.cast(socket, :close)

  @impl true
  def handle_frame({kind, payload}, state) when kind in [:text, :binary] do
    send(state.parent, {:transcription_ws, self(), {:frame, {kind, payload}}})
    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast({:send_frame, {:binary, payload}}, state) do
    # Acked BEFORE the reply, because WebSockex performs the blocking send after
    # this callback returns: the session must hear about the frame that is about
    # to be written, and hear nothing at all once a send stops returning.
    send(state.parent, {:transcription_ws, self(), {:sent, byte_size(payload)}})
    {:reply, {:binary, payload}, state}
  end

  def handle_cast({:send_frame, frame}, state), do: {:reply, frame, state}

  def handle_cast(:close, state), do: {:close, state}

  @impl true
  def handle_disconnect(status, state) do
    send(state.parent, {:transcription_ws, self(), {:disconnect, status}})
    {:ok, state}
  end
end
