defmodule FermixCore.Realtime.CallClient do
  @moduledoc """
  The transport-independent half of one voice connection (M91 §04, D22).

  A struct and functions that run inside the transport adapter's own process:
  the Unix socket's connection handler (`LocalVoiceSocket`) today, a serial or
  WebSocket link and the phone's call channel later. The adapter owns its
  connection, framing, handshake and encoding; this module owns the call:

    * the endpoint the call is for, the peer's realtime protocol version (what
      the Unix handshake negotiated, or the level an adapter translates), and
      the config the connection started with;
    * the per-engine minimum version, refused at `call_start` before any
      session exists;
    * starting the session through `SessionGuard`, which monitors the adapter
      before the session exists and binds it the moment it does, so it never
      outlives the adapter (`session_opts/1` is the default starter's half of
      the session contract);
    * the command verbs, each refused under an engine that has no clause for
      it: `task_cancel` only on the task engines, `playback_progress` only on
      Grok;
    * the ordered flush of frames the session already queued before the
      call's own last word, and teardown.

  Every frame leaves through the adapter's `emit` function, so the adapter
  keeps its own encoding. Each verb answers `{:cont, client}` to keep the
  connection or `{:stop, client}` after a terminal frame. The error vocabulary
  is the realtime wire's (`priv/realtime/PROTOCOL.md`).

  What an adapter does, a GenServer included:

    * calls every verb from its own process, never from a task: the session's
      companion is that process, so the session's frames arrive in its mailbox
      as `{:realtime, event}`, and it writes each with `emit` (the flush before
      a refusal or `idle` drains them itself);
    * hands the session monitor's `:DOWN` (`session_ref`) to `session_down/2`
      and then ends the connection;
    * runs `teardown/1` when it ends the connection on its own, the prompt
      path that also releases the guard.

  It need not trap exits or run `teardown/1` from `terminate/2`: an adapter
  killed or crashed (a serial link stopped by its watcher on unplug, a phone's
  call ended on revocation) has its session torn down by the guard, including
  one that was still starting. `call_start` blocks the adapter while its
  session starts, up to the guard's start bound, so a GenServer adapter whose
  own loop must stay responsive owns each call from a per-call process, as the
  socket's handler task does.
  """

  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.DeviceIdentity
  alias FermixCore.Realtime.Endpoint
  alias FermixCore.Realtime.Protocol
  alias FermixCore.Realtime.SessionControl
  alias FermixCore.Realtime.SessionGuard
  alias FermixCore.Realtime.SessionSupervisor
  alias FermixCore.Setup.ConfigStore

  # The wire version each engine's CALL requires. The handshake window still
  # admits an older companion (it may run an engine it can render); this is the
  # floor for a call, and the number the refusal reports as `min_version`.
  @engine_min_protocol_version %{"openai_realtime" => 1, "openai_live" => 2, "xai_realtime" => 3}
  # How many queued frames are written ahead of the call's own last word (a
  # refusal, a session-down error, a hang-up's `idle`) before the drain gives
  # up and that word is written. A session queues a handful.
  @max_flushed_frames 64

  @enforce_keys [:endpoint, :protocol_version, :config, :emit, :task_supervisor]
  defstruct [
    :endpoint,
    :protocol_version,
    :config,
    :emit,
    :task_supervisor,
    :session,
    :session_ref,
    session_module: SessionControl,
    session_starter: nil,
    # Options of the adapter's own the starter is handed besides the ones this
    # module sets (companion, endpoint, supervisors).
    starter_opts: [],
    session_supervisor: SessionSupervisor,
    session_guard: SessionGuard
  ]

  @type emit :: (map() -> :ok | {:error, term()})
  @type t :: %__MODULE__{
          endpoint: Endpoint.t(),
          protocol_version: pos_integer(),
          config: Config.t(),
          emit: emit(),
          task_supervisor: GenServer.server(),
          session: pid() | nil,
          session_ref: reference() | nil,
          session_module: module(),
          session_starter: SessionGuard.starter(),
          starter_opts: keyword(),
          session_supervisor: GenServer.server(),
          session_guard: GenServer.server()
        }
  @type result :: {:cont, t()} | {:stop, t()}

  @doc """
  A connection's call half, once the peer's version is known. Required:
  `:endpoint`, `:protocol_version`, `:config`, `:emit`, `:task_supervisor`.
  The rest default to the daemon's own (`SessionControl`, the default starter,
  `SessionSupervisor`, `SessionGuard`); a test names doubles.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    _valid = Endpoint.format(endpoint)

    struct!(
      __MODULE__,
      opts
      |> Keyword.put_new(:session_starter, &start_session/1)
      |> Keyword.update!(:protocol_version, &positive_version!/1)
      |> Keyword.update!(:config, fn %Config{} = config -> config end)
      |> Keyword.update!(:emit, fn emit when is_function(emit, 1) -> emit end)
    )
  end

  @doc """
  The options the default starter hands `SessionSupervisor.start_session/2`:
  which engine module runs the call, under which scope, with which
  credentials, and the endpoint's safety identifier (`Endpoint`), which only
  an OpenAI Realtime session sends; the task engines ignore it. Both
  engine-derived values come from `SessionControl`, so the scope prefix a
  trace reader searches for (`session:` vs `voice_live:`) and the module that
  gets started can never disagree about which engine is in force.
  """
  @spec session_opts(keyword()) :: {:ok, keyword()} | {:error, term()}
  def session_opts(opts) when is_list(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    config = Config.current()

    with {:ok, api_key} <- Config.api_key(config),
         {:ok, device_id} <-
           DeviceIdentity.ensure_device_id(ConfigStore.workspace_paths().realtime) do
      owner_id = MemoryConfig.owner_id()

      {:ok,
       opts
       |> Keyword.put(:config, config)
       |> Keyword.put(:engine_module, SessionControl.engine_module(config))
       |> Keyword.put(:api_key, api_key)
       |> Keyword.put(:device_id, device_id)
       |> Keyword.put_new(:session_scope, SessionControl.session_scope(config))
       |> Keyword.put(
         :safety_identifier,
         Endpoint.safety_identifier(endpoint, owner_id, device_id)
       )}
    end
  end

  @doc """
  Starts the call. `call_start` is the first moment both the peer's version
  and the configured engine are known, so the per-engine minimum lands here,
  and BEFORE a session exists: a task-engine session bills by the minute from
  the moment it opens, and an older peer could not render the call anyway.
  """
  @spec call_start(t()) :: result()
  def call_start(%__MODULE__{} = client) do
    if client.protocol_version < engine_min_protocol_version(client.config),
      do: update_required(client),
      else: start_call(client)
  end

  @doc "Forwards one microphone chunk."
  @spec audio(t(), binary()) :: result()
  def audio(%__MODULE__{} = client, audio) when is_binary(audio),
    do: command(client, &client.session_module.audio_chunk(&1, audio))

  @doc "Barge-in. `audio_end_ms` is how much assistant audio actually played."
  @spec interrupt(t(), non_neg_integer() | nil) :: result()
  def interrupt(%__MODULE__{} = client, audio_end_ms),
    do: command(client, &client.session_module.interrupt(&1, audio_end_ms))

  @doc "Gates microphone capture."
  @spec mute(t(), boolean()) :: result()
  def mute(%__MODULE__{} = client, enabled?) when is_boolean(enabled?),
    do: command(client, &client.session_module.mute(&1, enabled?))

  @doc """
  Cancels one backend delegation. Only the task engines have delegations: a
  Realtime call is refused here rather than forwarded to a session with no
  clause for it.
  """
  @spec task_cancel(t(), String.t()) :: result()
  def task_cancel(%__MODULE__{} = client, delegation_id) when is_binary(delegation_id) do
    if Config.hands_off_tasks?(client.config),
      do: cancel_task(client, delegation_id),
      else: stop_with(:unsupported_by_engine, client)
  end

  @doc """
  What the peer has played of one stretch of Grok audio. Only Grok sends audio
  under playback ids; a report the session refuses (an id never sent, an
  offset that went backwards or past the audio sent) ends the connection with
  its reason.
  """
  @spec playback_progress(t(), String.t(), non_neg_integer(), boolean()) :: result()
  def playback_progress(%__MODULE__{} = client, playback_id, played_ms, drained?) do
    if client.config.engine == "xai_realtime",
      do:
        command(
          client,
          &client.session_module.playback_progress(&1, playback_id, played_ms, drained?)
        ),
      else: stop_with(:unsupported_by_engine, client)
  end

  @doc """
  Ends the CALL but keeps the connection for a fresh one. The session's last
  frames were sent before it answered, so they are already queued here: they
  go first, so `idle` is the call's last frame and a fresh `call_start` never
  races the old call's `task` and `usage`.
  """
  @spec call_stop(t()) :: result()
  def call_stop(%__MODULE__{} = client) do
    client = teardown(client)
    _error_sent? = flush_queued_frames(client, false, @max_flushed_frames)
    _ = client.emit.(%{type: "state", state: "idle"})
    {:cont, client}
  end

  @doc """
  The bound session died mid-call (its monitor, `session_ref`, fired). The
  peer is told, so it does not wait on silence, and the connection should end.
  """
  @spec session_down(t(), term()) :: {:stop, t()}
  def session_down(%__MODULE__{session: session} = client, reason) when is_pid(session) do
    _ = client.emit.(error_frame({:session_down, reason}))
    _ = SessionGuard.release(client.session_guard)
    {:stop, %{client | session: nil, session_ref: nil}}
  end

  @doc """
  Tears the bound session down and releases it from the guard: an adapter's
  terminal exit runs this so a billed provider socket never outlives the
  connection, even when the guard could no longer react. A crash cannot run
  it; that path is the guard's.
  """
  @spec teardown(t()) :: t()
  def teardown(%__MODULE__{session: session} = client) when is_pid(session) do
    Process.demonitor(client.session_ref, [:flush])
    :ok = SessionGuard.teardown(session, client.session_module)
    _ = SessionGuard.release(client.session_guard)
    %{client | session: nil, session_ref: nil}
  end

  def teardown(%__MODULE__{} = client), do: client

  @doc "The wire's `error` frame for a failure reason."
  @spec error_frame(term()) :: map()
  def error_frame({:call_in_progress, held_by}) when is_binary(held_by),
    do: %{type: "error", reason: Protocol.call_in_progress(), held_by: held_by}

  def error_frame({:call_in_progress, nil}),
    do: %{type: "error", reason: Protocol.call_in_progress()}

  def error_frame(reason), do: %{type: "error", reason: reason_to_string(reason)}

  defp start_call(client) do
    case ensure_session(client) do
      {:ok, client} -> session_call_start(client)
      # No session was ever started, so nothing can be queued: say the refusal
      # directly.
      {:error, reason} -> stop_with(reason, client)
    end
  end

  defp session_call_start(client) do
    case call_session(client, &client.session_module.call_start(&1)) do
      {:answered, :ok} -> {:cont, client}
      {:answered, {:error, reason}} -> flush_then_stop(reason, client)
      {:down, reason} -> flush_then_stop({:session_down, reason}, client)
    end
  end

  defp ensure_session(%{session: session} = client) when is_pid(session), do: {:ok, client}

  # The guard starts the session for this process and binds it, so it is torn
  # down on ANY adapter exit, even one in the middle of the start. The session
  # is monitored so its death reaches the adapter's loop (`session_down/2`).
  defp ensure_session(client) do
    opts =
      client.starter_opts
      |> Keyword.put(:companion, self())
      |> Keyword.put(:endpoint, client.endpoint)
      |> Keyword.put(:session_supervisor, client.session_supervisor)
      |> Keyword.put_new(:task_supervisor, client.task_supervisor)

    guard = client.session_guard

    case SessionGuard.start_session(guard, client.session_starter, opts, client.session_module) do
      {:ok, session} -> {:ok, %{client | session: session, session_ref: Process.monitor(session)}}
      {:error, reason} -> {:error, start_refusal(reason)}
    end
  end

  defp start_refusal({:already_bound, _session}), do: :session_already_bound
  defp start_refusal(reason), do: reason

  defp command(%{session: nil} = client, _send), do: stop_with(:not_connected, client)

  defp command(client, send) do
    case call_session(client, send) do
      {:answered, :ok} -> {:cont, client}
      {:answered, {:error, reason}} -> stop_with(reason, client)
      {:down, reason} -> flush_then_stop({:session_down, reason}, client)
    end
  end

  # A call into the session exits when the session stopped instead of
  # answering (it died, or a cancel was queued behind its settle) or did not
  # answer in time (`call_start`'s bound). Either is the session's death, told
  # the way `session_down/2` tells it, after what the session queued first,
  # instead of an adapter exit the peer would read as a bare EOF.
  defp call_session(client, send) do
    {:answered, send.(client.session)}
  catch
    :exit, {reason, {GenServer, :call, _args}} -> {:down, reason}
  end

  defp cancel_task(client, delegation_id),
    do: command(client, &client.session_module.cancel_task(&1, delegation_id))

  # The session pushes its frames to the adapter's MAILBOX, and the adapter is
  # blocked inside the call while it does, so the session's own rich `error`
  # (its published `kind`, and the vendor's words in `detail`) is sitting there
  # unwritten by the time the refusal comes back. Write what is queued first,
  # in order. If one of those frames was itself an `error`, stop on it and send
  # no second one: the peer treats the FIRST `error` as terminal, so a bare
  # `reason`-only frame would be the one it read and the diagnosis would be lost.
  defp flush_then_stop(reason, client) do
    if flush_queued_frames(client, false, @max_flushed_frames),
      do: {:stop, client},
      else: stop_with(reason, client)
  end

  # Bounded twice over: `after 0` takes only what the session has ALREADY
  # delivered, never waiting on one that is still producing, and the counter
  # caps a flood. At the cap the drain stops and the caller writes its own
  # frame as usual; on a hang-up the adapter writes whatever is left after it.
  defp flush_queued_frames(_client, error_sent?, 0), do: error_sent?

  defp flush_queued_frames(client, error_sent?, remaining) do
    receive do
      {:realtime, event} ->
        _ = client.emit.(event)
        flush_queued_frames(client, error_sent? or error_frame?(event), remaining - 1)
    after
      0 -> error_sent?
    end
  end

  defp error_frame?(%{type: "error"}), do: true
  defp error_frame?(_event), do: false

  # `min_version` here is the version the ENGINE requires, not the handshake
  # floor the adapter advertised: `required_for` names which engine raised it.
  defp update_required(client) do
    _ =
      client.emit.(%{
        type: "error",
        reason: "unsupported_protocol_version",
        kind: "update_required",
        direction: "client_too_old",
        client_version: client.protocol_version,
        min_version: engine_min_protocol_version(client.config),
        max_version: Protocol.protocol_version(),
        required_for: client.config.engine
      })

    {:stop, client}
  end

  # An engine missing from the table fails loud.
  defp engine_min_protocol_version(%Config{engine: engine}),
    do: Map.fetch!(@engine_min_protocol_version, engine)

  defp stop_with(reason, client) do
    _ = client.emit.(error_frame(reason))
    {:stop, client}
  end

  defp start_session(opts) do
    session_supervisor = Keyword.fetch!(opts, :session_supervisor)
    opts = Keyword.drop(opts, [:session_supervisor])

    with {:ok, started_opts} <- session_opts(opts) do
      SessionSupervisor.start_session(session_supervisor, started_opts)
    end
  end

  defp positive_version!(version) when is_integer(version) and version > 0, do: version

  defp positive_version!(version),
    do:
      raise(
        ArgumentError,
        "protocol_version must be a positive integer, got: #{inspect(version)}"
      )

  # A voice key that is not saved keeps the word the wire always carried for
  # it; which provider's key is missing is readiness's to say, by name.
  defp reason_to_string({:missing_api_key, _provider}), do: "not_configured"
  # A start's crash or bad return is the guard's to log in full; the wire
  # carries the code.
  defp reason_to_string({:session_start_failed, _reason}), do: "session_start_failed"
  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason), do: inspect(reason)
end
