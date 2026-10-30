defmodule FermixChannels.Desktop.Family do
  @moduledoc """
  One family of what a desktop engine sends the primary over its session
  (M75 §6 to §9): the companion tunnel, forwarded management, the loopback
  forward, the desktop snapshot target.

  `Desktop.Peer` keeps one state per family for each connected desktop, puts
  every chunked payload back together, and hands each complete event to its
  family's module, in the peer's own process. The family a module serves is
  named in `Desktop.Peer`'s one map of families.

  A callback returns promptly: the desktop's session waits for it before it
  reads the next frame. Work that takes longer runs in a process the family
  starts, which answers the desktop with `Desktop.Peer.send/4` and reaches
  the family's state with `Desktop.Peer.tell/4`.
  """

  alias FermixChannels.Desktop.Peer

  @typedoc "What a family keeps for one desktop."
  @type state :: term()

  @doc "Starts the family's state for one desktop, as its peer starts."
  @callback init(Peer.context()) :: {:ok, state()} | {:error, term()}

  @doc """
  One complete event of the family: its type, its header fields (a chunked
  event's `index` and `last` left out) and its whole raw payload. An error is
  answered on the desktop's session as `error{code}`, and the session stays
  open.
  """
  @callback handle_event(type :: String.t(), fields :: map(), payload :: binary(), state()) ::
              {:ok, state()} | {:error, term(), state()}

  @doc "A message for this family, sent with `Desktop.Peer.tell/4`."
  @callback handle_info(message :: term(), state()) :: {:ok, state()}

  @doc "The desktop's session ended: the family lets go of what it held for it."
  @callback terminate(reason :: term(), state()) :: :ok
end
