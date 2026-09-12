defmodule FermixCore.Meetings.Sidecar do
  @moduledoc """
  The meetbot transport seam: everything `FermixCore.Meetings.SidecarSource`
  needs from the Google Meet sidecar, and nothing about how it is carried.

  `FermixCore.Meetings.Sidecar.Port` is the production implementation (an
  Erlang Port to the `fermix-meetbot` binary); tests pass a scripted stub so the
  source's translation table, relaunch bound, and ping policy are provable
  without spawning a browser.

  The implementation runs *inside the owner process* — `launch/2` returns a
  plain state map, not a pid — so the owner's mailbox is where transport
  messages land. `handle_message/2` is the single funnel that turns whatever
  the transport delivers into the three normalized shapes below; the owner
  never pattern-matches a transport detail.

      {:sidecar_control, map()}                              # a decoded control message
      {:sidecar_audio, binary()}                             # PCM s16le 16 kHz mono
      {:sidecar_exit, non_neg_integer() | {:protocol_error, term()}}
  """

  @typedoc "Implementation-private transport state, opaque to the owner."
  @type state :: term()

  @typedoc "What the owner does with an inbound message after normalization."
  @type event ::
          {:sidecar_control, map()}
          | {:sidecar_audio, binary()}
          | {:sidecar_exit, non_neg_integer() | {:protocol_error, term()}}
          | :ignore

  @doc """
  Spawns the sidecar and completes the `hello` handshake before returning, so a
  successful return means a live sidecar speaking protocol v1.

  Options: `binary_path` (required), `profile_dir` (required),
  `handshake_timeout_ms` (defaults to `FermixCore.Timeouts.meetbot_handshake/0`),
  and `args` / `env` for the spawned process (an empty `env` inherits the
  daemon's).
  """
  @callback launch(owner :: pid(), opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc "Sends one control message to the sidecar."
  @callback send_control(state(), msg :: map()) :: :ok | {:error, :closed}

  @doc "Normalizes one message from the owner's mailbox, or `:ignore` if it is not ours."
  @callback handle_message(state(), message :: term()) :: event()

  @doc "Tears the sidecar (and everything it spawned) down. Idempotent."
  @callback stop(state()) :: :ok
end
