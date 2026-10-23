defmodule FermixCore.Cues.Source.Stream.Socket do
  @moduledoc """
  The WebSocket transport of `Cues.Source.Stream`: deliberately dumb. It
  carries frames and pongs to its owner and decodes nothing.

  Started with `WebSockex.start/4` (`async: true`), never `start_link/4`: the
  owning worker monitors it, so a dropped connection arrives as a `:DOWN` whose
  reason says why (`{:error, %WebSockex.RequestError{code: 401}}` for a refused
  handshake) and the worker's own backoff decides what follows. It never
  reconnects itself (`handle_disconnect/2` returns `{:ok, state}`). Once
  connected it monitors its owner and closes when the owner is gone, so no
  connection outlives the worker that opened it.

  The peer is verified against the OS trust store via `FermixCore.Net.Tls`
  (WebSockex alone fails open), and a route the outbound proxy would have to
  carry is refused with `Net.Egress.ensure_direct/2`: this socket cannot
  tunnel, so it never dials around the proxy. The handshake is bounded by
  WebSockex's `handshake_timeout`.

  Messages to the owner: `{:cue_stream, socket, :connected}`,
  `{:cue_stream, socket, {:frame, {:text | :binary, payload}}}` and
  `{:cue_stream, socket, :pong}`.
  """

  use WebSockex

  @behaviour FermixCore.Cues.Source.Stream

  alias FermixCore.Net.Egress
  alias FermixCore.Net.Tls

  @impl FermixCore.Cues.Source.Stream
  def start(url, owner, opts) when is_binary(url) and is_pid(owner) and is_list(opts) do
    egress = Keyword.get_lazy(opts, :egress, &Egress.active/0)
    handshake_timeout = Keyword.fetch!(opts, :handshake_timeout)

    with :ok <- Egress.ensure_direct(url, egress),
         {:ok, start_opts} <- start_options(url, handshake_timeout) do
      WebSockex.start(url, __MODULE__, %{owner: owner, owner_ref: nil}, start_opts)
    end
  end

  @doc """
  The `WebSockex` options for `url`, or `{:error, :ws_url_without_host}` when
  the URL names no host: there would be nothing to verify the peer against.
  """
  @spec start_options(String.t(), timeout()) :: {:ok, keyword()} | {:error, :ws_url_without_host}
  def start_options(url, handshake_timeout) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        {:ok,
         [
           async: true,
           handshake_timeout: handshake_timeout,
           ssl_options: Tls.client_options(host)
         ]}

      %URI{} ->
        {:error, :ws_url_without_host}
    end
  end

  @impl FermixCore.Cues.Source.Stream
  def ping(socket) when is_pid(socket) do
    send(socket, :cue_ping)
    :ok
  end

  @impl FermixCore.Cues.Source.Stream
  def close(socket) when is_pid(socket), do: WebSockex.cast(socket, :close)

  @impl WebSockex
  def handle_connect(_conn, state) do
    send(state.owner, {:cue_stream, self(), :connected})
    {:ok, %{state | owner_ref: state.owner_ref || Process.monitor(state.owner)}}
  end

  @impl WebSockex
  def handle_frame({kind, payload} = frame, state)
      when kind in [:text, :binary] and is_binary(payload) do
    send(state.owner, {:cue_stream, self(), {:frame, frame}})
    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl WebSockex
  def handle_pong(_pong, state) do
    send(state.owner, {:cue_stream, self(), :pong})
    {:ok, state}
  end

  @impl WebSockex
  def handle_info(:cue_ping, state), do: {:reply, :ping, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:close, state}

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSockex
  def handle_cast(:close, state), do: {:close, state}

  @impl WebSockex
  def handle_disconnect(_status, state), do: {:ok, state}
end
