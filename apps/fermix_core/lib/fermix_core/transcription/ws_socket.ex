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
  | `{:transcription_ws, socket, {:disconnect, status}}` | the connection dropped; the socket stops right after |
  """

  use WebSockex

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

    WebSockex.start(url, __MODULE__, %{parent: parent},
      extra_headers: headers,
      handshake_timeout: Timeouts.transcription_ws_connect()
    )
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
  def handle_cast({:send_frame, frame}, state), do: {:reply, frame, state}

  def handle_cast(:close, state), do: {:close, state}

  @impl true
  def handle_disconnect(status, state) do
    send(state.parent, {:transcription_ws, self(), {:disconnect, status}})
    {:ok, state}
  end
end
