defmodule FermixCore.Realtime.SocketBridge do
  @moduledoc """
  How the Mac or Linux app's `realtime.sock` carries its calls when this
  engine is not the home (M97 §9.2): the socket's other configuration.

  On a primary every connection's calls are its own sessions' (`CallClient`).
  On a device, a computer whose home moved to a server, the socket is served
  by a bridge instead (`FermixChannels.Desktop.CallBridge`): the app keeps its
  audio stack and the socket it speaks, and the bridge carries each call to
  the server, which runs the voice session with its own key, tools and
  memory. One socket, two configurations, and each refuses the other's work:
  a bridged socket starts no session here, and a primary's bridges nothing.

  `LocalVoiceSocket` keeps what is the socket's in both: the listener and its
  peer gate, the client cap, newline-delimited framing, and the
  `client_hello`/`server_hello` handshake, answered here at this engine's
  window. Once the handshake lands, the connection's handler calls the
  bridge from its own process:

    * `open/1` with the version the app negotiated (`:protocol_version`),
      the connection's config (`:config`), `:write` (one server line's JSON
      to the app, newline added) and `:emit` (one server event, encoded by
      `Protocol`), and the socket's `:bridge` options;
    * `event/2` with each decoded client event after the handshake;
    * `info/2` with every message the handler receives that is not its
      socket's, which is how the bridge's own mail (the link's frames, its
      timers) reaches it;
    * `close/1` once the connection ends, however it ends but a crash.

  `event/2` and `info/2` answer `{:cont, bridge}` to keep the connection or
  `{:stop, bridge}` after a terminal frame, as `CallClient`'s verbs do.
  """

  alias FermixCore.Realtime.Protocol

  @doc "The connection's bridge, once its handshake landed."
  @callback open(keyword()) :: term()

  @doc "One decoded client event after the handshake."
  @callback event(term(), Protocol.event()) :: {:cont, term()} | {:stop, term()}

  @doc "One message the connection's handler received that is not its socket's."
  @callback info(term(), term()) :: {:cont, term()} | {:stop, term()}

  @doc "The connection ended."
  @callback close(term()) :: :ok
end
