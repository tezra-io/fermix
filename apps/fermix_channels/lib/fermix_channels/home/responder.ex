defmodule FermixChannels.Home.Responder do
  @moduledoc """
  A responder for one of M75's own preludes (`FXM1 0x03` enrollment,
  `FXM1 0x04` the move), served on the carrier a phone's session runs on.

  `Mobile.Session` parses the five-byte prelude; when the mode is one a
  responder serves (`serving?/1` says so now), the session hands the whole
  first wire to `init/2` and every later frame, message and the close to the
  responder, with the carrier contract unchanged: each callback answers what a
  session's callback answers (`{:ok, state}`, `{:push, frames, state}`,
  `{:stop, reason, close, state}` or `{:stop, reason, close, frames, state}`,
  frames being Noise messages).

  `init/2` gets the responder's own options, plus `:peer` (where the stream
  came from) and `:load_gateway_keypair` (the session's loader of the
  gateway identity, a 0-arity function).
  """

  @type state :: term()
  @type close :: {non_neg_integer(), String.t()}
  @type result ::
          {:ok, state()}
          | {:push, [binary()], state()}
          | {:stop, term(), close(), state()}
          | {:stop, term(), close(), [binary()], state()}

  @doc "Whether this responder serves its prelude now."
  @callback serving?(keyword()) :: boolean()

  @doc "Takes the stream's first wire (prelude and the first handshake message)."
  @callback init(binary(), keyword()) :: result()

  @doc "Takes one later Noise message."
  @callback handle_frame(binary(), state()) :: result()

  @doc "Takes a mailbox message the carrier did not claim."
  @callback handle_info(term(), state()) :: result()

  @doc "Releases what the responder holds, as the carrier closes."
  @callback terminate(term(), state()) :: :ok

  @doc "Whether the peer proved what its prelude claims (the bridge keeps its place)."
  @callback past_handshake?(state()) :: boolean()
end
