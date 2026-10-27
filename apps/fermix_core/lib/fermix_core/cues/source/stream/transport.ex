defmodule FermixCore.Cues.Source.Stream.Transport do
  @moduledoc """
  The connection a stream worker (`Cues.Source.Stream`) owns:
  `Cues.Source.Stream.Socket` in production, a fake in tests.

  `start/3` returns at once with the transport's pid and a monitor it took in
  the caller's process (the owner), so no exit can come before the owner
  watches it; the transport is never linked. The connection is made inside the
  transport process. The transport sends its owner
  `{:cue_stream, socket, event}` with `event` one of `:connected`,
  `{:frame, {:text | :binary, payload}}` and `:pong`, and holds at most a
  window of frames the owner has not acknowledged with `ack/1`.

  Options of `start/3`: `:handshake_timeout` (ms; bounds connecting, TLS and the
  upgrade), `:headers` (`[{name, value}]` sent on the upgrade), `:messages`
  (text frames sent in order as soon as the upgrade completes, before the owner
  hears `:connected`), `:max_frame_bytes` (a frame, or a fragmented message,
  past it ends the connection before it is whole), `:egress` (the outbound
  route, `Net.Egress`). Headers and messages may carry credentials: the
  transport holds them only until they are written, and never logs them.

  `start/3` refuses without connecting with `{:error, :proxy_unsupported_transport}`
  (the route would need the outbound proxy) or `{:error, :url_without_host}`.
  Once started, the transport's exit reason says why the connection ended:

    * `{:upgrade_refused, status}`: the HTTP upgrade was answered with `status`;
    * `:address_refused`: the host resolved to an address `Net.Guard` refuses;
    * `:frame_too_large`: past `:max_frame_bytes`;
    * `{:remote_closed, code}`: the peer closed (`code` an integer or nil);
    * `{:connect_failed, reason}`: DNS, TCP, TLS or the handshake timeout;
    * `:normal`: closed by `close/1`, or the owner is gone.
  """

  @doc "Connects to `url` for `owner`."
  @callback start(url :: String.t(), owner :: pid(), opts :: keyword()) ::
              {:ok, pid(), reference()}
              | {:error, :proxy_unsupported_transport | :url_without_host}

  @doc "The owner has handled one frame."
  @callback ack(socket :: pid()) :: :ok

  @doc "Asks the peer for a pong."
  @callback ping(socket :: pid()) :: :ok

  @doc "Closes the connection; the transport then exits `:normal`."
  @callback close(socket :: pid()) :: :ok
end
