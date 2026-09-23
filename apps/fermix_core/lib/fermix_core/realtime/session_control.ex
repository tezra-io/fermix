defmodule FermixCore.Realtime.SessionControl do
  @moduledoc """
  The one client API for a voice session process, whichever engine owns it.

  `SessionServer` (Realtime) and `LiveSessionServer` (Live) are two different
  processes with two different provider wires, but the listener and the session
  supervisor drive both through exactly the messages below. Keeping the client
  side in one module is what lets `LocalVoiceSocket` stay engine-agnostic: it
  holds `session_module: SessionControl` and never branches on the engine except
  where the WIRE differs (the Live-requires-v2 refusal and `task_cancel`).

  Both engines must therefore handle every message here. `SessionServer`'s own
  public functions already send exactly these, so it needs no change; a new
  engine is written against this list.

  `engine_module/1` and `session_scope/1` are the two engine-derived facts the
  socket needs before a session exists. `engine_module/1` returns the module
  ATOM only — it never calls into it.
  """

  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.SessionServer

  # `call_start` blocks on the provider handshake and `call_stop` on the graceful
  # close (Live keeps receiving until `session.closed`, bounded at 15 s), so both
  # sit above the engines' own internal deadlines: an upstream stall must surface
  # as the engine's typed error, never as a GenServer.call exit here.
  @call_start_timeout_ms 12_000
  @call_stop_timeout_ms 20_000
  @reload_runtime_timeout_ms 10_000

  defguardp is_session(server) when is_pid(server) or is_atom(server) or is_tuple(server)

  @doc "Opens the provider session for this call."
  @spec call_start(GenServer.server()) :: :ok | {:error, term()}
  def call_start(server) when is_session(server),
    do: GenServer.call(server, :call_start, @call_start_timeout_ms)

  @doc """
  Forwards one microphone chunk.

  A cast on purpose: audio is fire-and-forget media, so a session busy with a
  tool or a delegation never blocks the socket reader's send.
  """
  @spec audio_chunk(GenServer.server(), binary()) :: :ok
  def audio_chunk(server, audio) when is_session(server) and is_binary(audio),
    do: GenServer.cast(server, {:audio_chunk, audio})

  @doc "Barge-in. `audio_end_ms` is how much assistant audio actually played."
  @spec interrupt(GenServer.server(), non_neg_integer() | nil) :: :ok | {:error, term()}
  def interrupt(server, audio_end_ms \\ nil)

  def interrupt(server, audio_end_ms)
      when is_session(server) and
             (is_nil(audio_end_ms) or (is_integer(audio_end_ms) and audio_end_ms >= 0)),
      do: GenServer.call(server, {:interrupt, audio_end_ms})

  @doc "Gates microphone capture."
  @spec mute(GenServer.server(), boolean()) :: :ok | {:error, term()}
  def mute(server, enabled?) when is_session(server) and is_boolean(enabled?),
    do: GenServer.call(server, {:mute, enabled?})

  @doc """
  Cancels one backend delegation.

  Only the Live engine has delegations; the LISTENER refuses `task_cancel` on a
  Realtime connection before any session call, so `SessionServer` never sees it.
  """
  @spec cancel_task(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def cancel_task(server, delegation_id)
      when is_session(server) and is_binary(delegation_id) and delegation_id != "",
      do: GenServer.call(server, {:cancel_task, delegation_id})

  @doc "Ends the call and settles the provider session."
  @spec call_stop(GenServer.server()) :: :ok
  def call_stop(server) when is_session(server),
    do: GenServer.call(server, :call_stop, @call_stop_timeout_ms)

  @doc "Re-reads runtime config mid-call. What that means is the engine's answer."
  @spec reload_runtime(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def reload_runtime(server) when is_session(server),
    do: GenServer.call(server, :reload_runtime, @reload_runtime_timeout_ms)

  @doc "The session module this config's engine runs on."
  @spec engine_module(Config.t()) :: module()
  def engine_module(%Config{engine: "openai_realtime"}), do: SessionServer
  def engine_module(%Config{engine: "openai_live"}), do: FermixCore.Realtime.LiveSessionServer

  @doc """
  Mints the scope a new session runs under.

  The prefix is the run kind a trace reader searches for, so the two engines are
  never confused in Opik: `session:<n>` for Realtime, `voice_live:<n>` for Live.
  """
  @spec session_scope(Config.t()) :: String.t()
  def session_scope(%Config{} = config) do
    scope_prefix(config) <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp scope_prefix(%Config{engine: "openai_realtime"}), do: "session:"
  defp scope_prefix(%Config{engine: "openai_live"}), do: "voice_live:"
end
