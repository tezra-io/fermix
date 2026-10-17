defmodule FermixCore.Realtime.SessionControl do
  @moduledoc """
  The one client API for a voice session process, whichever engine owns it.

  `SessionServer` (Realtime), `LiveSessionServer` (Live) and `GrokSessionServer`
  (Grok) are different processes with different provider wires, but the
  listener, the session supervisor and the chat drive them all through exactly
  the messages below. Keeping the client side in one module is what lets
  `LocalVoiceSocket` stay engine-agnostic: it holds `session_module:
  SessionControl` and never branches on the engine except where the WIRE differs
  (each engine's minimum protocol version, `task_cancel` and
  `playback_progress`).

  Every engine handles the call verbs (`call_start` through `reload_runtime`).
  The task engines, Live and Grok, which hand every task to the Fermix agent,
  also handle `cancel_task` and the chat's verbs (`chat_typed`, `chat_answered`,
  `call_context`); only Grok handles `playback_progress`. A caller that could
  reach the wrong engine is refused before it sends: the listener by engine,
  the chat through `CallRegistry`, which only a task-engine call claims.
  `SessionServer`'s own public functions already send exactly these, so it
  needs no change; a new engine is written against this list.

  `engine_module/1` and `session_scope/1` are the two engine-derived facts the
  socket needs before a session exists. `engine_module/1` returns the module
  ATOM only — it never calls into it.
  """

  alias FermixCore.Realtime.CallRecord
  alias FermixCore.Realtime.CallSpeech
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.SessionServer

  # `call_start` blocks on the provider handshake, so it sits above the engines'
  # own internal deadlines: an upstream stall must surface as the engine's typed
  # error, never as a GenServer.call exit here.
  #
  # `cancel_task` and `call_stop` wait with no timeout. On Live no finite one
  # covers them: both reach `Gateway.Queue`'s stop of a hand-off's turn through
  # the voice bridge, and that stop waits with no timeout for a busy Queue. The
  # Realtime `call_stop` has a finite bound (it sends a frame and releases what
  # the call holds), but it shares this API with Live, and that is what makes
  # it wait the same way. Each engine keeps its handler for them bounded
  # (`LiveSessionServer` says how). A timed-out cancel crashed the connection's
  # handler and dropped the companion mid-call; a timed-out stop told the
  # companion the call was idle while it was still settling. The call still
  # monitors the session, so a dead session still ends the wait.
  #
  # The companion, not this wait, bounds a cancel in practice. The connection's
  # handler reads nothing while it waits, and the companion keeps streaming
  # audio through a cancel. It drops a connection its writes cannot reach: 8 s
  # after its audio buffer fills (about 2 s of audio), or 5 s for a control
  # frame sent meanwhile. A Queue stop longer than that still ends the call.
  @call_start_timeout_ms 12_000
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

  Only the task engines have delegations; the LISTENER refuses `task_cancel` on
  a Realtime connection before any session call, so `SessionServer` never sees
  it.
  """
  @spec cancel_task(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def cancel_task(server, delegation_id)
      when is_session(server) and is_binary(delegation_id) and delegation_id != "",
      do: GenServer.call(server, {:cancel_task, delegation_id}, :infinity)

  @doc """
  What the companion has played of one stretch of assistant audio (v3, Grok
  only; the listener refuses it under the other engines). `played_ms` is that
  playback's rendered milliseconds so far, `drained?` whether all of it sent so
  far has played. The session answers `{:error, reason}` for an id it never
  sent, an offset that went backwards or one beyond the audio sent, and the
  listener closes the connection on it.
  """
  @spec playback_progress(GenServer.server(), String.t(), non_neg_integer(), boolean()) ::
          :ok | {:error, term()}
  def playback_progress(server, playback_id, played_ms, drained?)
      when is_session(server) and is_binary(playback_id) and playback_id != "" and
             is_integer(played_ms) and played_ms >= 0 and is_boolean(drained?),
      do: GenServer.call(server, {:playback_progress, playback_id, played_ms, drained?})

  @doc """
  The owner typed `text` in the chat (M56 §4.3). Sent, never awaited: a
  task-engine session tells the voice model as quiet context while a call in
  the chat is up, and drops it otherwise. Channels finds the session
  (`CallRegistry`).
  """
  @spec chat_typed(GenServer.server(), String.t()) :: :ok
  def chat_typed(session, text) when is_session(session) and is_binary(text),
    do: GenServer.cast(session, {:chat, {:typed, text}})

  @doc """
  The chat answered the owner's typed message: `message` is that answer as the
  chat's store holds it, its Computer History marker included. Sent, never
  awaited, and told or dropped as `chat_typed/2` is.
  """
  @spec chat_answered(GenServer.server(), map()) :: :ok
  def chat_answered(session, %{role: "assistant", content: content} = message)
      when is_session(session) and is_binary(content),
      do: GenServer.cast(session, {:chat, {:answered, message}})

  @typedoc """
  What a typed chat turn may read of the call in progress (M56 §4.4): when it
  started and how long it has run, its tasks as its record holds them, and what
  was said, the whole call (`CallSpeech`), never written anywhere.
  """
  @type context :: %{
          call_uuid: String.t(),
          started_at: DateTime.t(),
          elapsed_ms: non_neg_integer(),
          tasks: [CallRecord.task()],
          speech: CallSpeech.t()
        }

  @doc """
  The call's context, for `voice_call_context`. The caller bounds the wait:
  a session settling its call answers nothing until it is done.
  """
  @spec call_context(GenServer.server(), timeout()) :: {:ok, context()}
  def call_context(session, timeout)
      when is_session(session) and
             (timeout == :infinity or (is_integer(timeout) and timeout >= 0)),
      do: GenServer.call(session, :call_context, timeout)

  @doc "Ends the call and settles the provider session."
  @spec call_stop(GenServer.server()) :: :ok
  def call_stop(server) when is_session(server),
    do: GenServer.call(server, :call_stop, :infinity)

  @doc "Re-reads runtime config mid-call. What that means is the engine's answer."
  @spec reload_runtime(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def reload_runtime(server) when is_session(server),
    do: GenServer.call(server, :reload_runtime, @reload_runtime_timeout_ms)

  @doc "The session module this config's engine runs on."
  @spec engine_module(Config.t()) :: module()
  def engine_module(%Config{engine: "openai_realtime"}), do: SessionServer
  def engine_module(%Config{engine: "openai_live"}), do: FermixCore.Realtime.LiveSessionServer
  def engine_module(%Config{engine: "xai_realtime"}), do: FermixCore.Realtime.GrokSessionServer

  @doc """
  Mints the scope a new session runs under.

  The prefix is the run kind a trace reader searches for, so a Realtime call is
  never confused with a task-engine call in Opik: `session:<n>` for Realtime,
  `voice_live:<n>` for Live and Grok, whose trace `engine` metadata tells them
  apart.
  """
  @spec session_scope(Config.t()) :: String.t()
  def session_scope(%Config{} = config) do
    scope_prefix(config) <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp scope_prefix(%Config{engine: "openai_realtime"}), do: "session:"
  defp scope_prefix(%Config{engine: "openai_live"}), do: "voice_live:"
  defp scope_prefix(%Config{engine: "xai_realtime"}), do: "voice_live:"
end
